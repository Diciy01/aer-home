package remote

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"errors"
	"time"

	"aerhome/core/internal/remoteengine"
)

type TrustedDevice struct {
	Number      string     `json:"number"`
	Name        string     `json:"name"`
	Fingerprint string     `json:"fingerprint"`
	CreatedAt   time.Time  `json:"createdAt"`
	RevokedAt   *time.Time `json:"revokedAt"`
}
type DeviceTrust struct {
	Enabled bool            `json:"enabled"`
	Devices []TrustedDevice `json:"devices"`
}

func boxFingerprint(pub string) string {
	b, err := remoteengine.DecodeKey(pub)
	if err != nil {
		return ""
	}
	h := sha256.Sum256(b)
	return hex.EncodeToString(h[:])
}
func (s *Service) ownTrustDevice(ctx context.Context, c Client) (Device, error) {
	d, err := s.DeviceOf(ctx, c)
	if err == nil && (d.RevokedAt != nil || d.ConflictAt != nil) {
		err = ErrClientAuth
	}
	return d, err
}
func (s *Service) DeviceTrust(ctx context.Context, c Client) (DeviceTrust, error) {
	d, err := s.ownTrustDevice(ctx, c)
	if err != nil {
		return DeviceTrust{}, err
	}
	out := DeviceTrust{Devices: []TrustedDevice{}}
	var enabled int
	if err = s.db.QueryRowContext(ctx, `SELECT unattended_enabled FROM remote_devices WHERE id=?`, d.ID).Scan(&enabled); err != nil {
		return out, err
	}
	out.Enabled = enabled == 1
	rows, err := s.db.QueryContext(ctx, `SELECT v.number,v.name,t.box_pub,t.created_at,COALESCE(t.revoked_at,v.revoked_at,v.conflict_at) FROM remote_device_trust t JOIN remote_devices v ON v.id=t.viewer_id WHERE t.target_id=? ORDER BY t.created_at,v.number`, d.ID)
	if err != nil {
		return out, err
	}
	defer rows.Close()
	for rows.Next() {
		var x TrustedDevice
		var pub string
		var created int64
		var revoked sql.NullInt64
		if err = rows.Scan(&x.Number, &x.Name, &pub, &created, &revoked); err != nil {
			return out, err
		}
		x.Fingerprint, x.CreatedAt, x.RevokedAt = boxFingerprint(pub), fromMS(created), fromNullMS(revoked)
		out.Devices = append(out.Devices, x)
	}
	return out, rows.Err()
}
func (s *Service) TrustCandidate(ctx context.Context, c Client, number string) (TrustedDevice, error) {
	own, err := s.ownTrustDevice(ctx, c)
	if err != nil {
		return TrustedDevice{}, err
	}
	d, err := s.device(ctx, `number=?`, remoteengine.NormalizeDeviceNumber(number))
	if err != nil {
		return TrustedDevice{}, err
	}
	if d.ID == own.ID || d.RevokedAt != nil || d.ConflictAt != nil {
		return TrustedDevice{}, ErrNotFound
	}
	var pub string
	if err = s.db.QueryRowContext(ctx, `SELECT box_pub FROM remote_devices WHERE id=?`, d.ID).Scan(&pub); err != nil {
		return TrustedDevice{}, err
	}
	return TrustedDevice{Number: d.Number, Name: d.Name, Fingerprint: boxFingerprint(pub)}, nil
}
func (s *Service) SetUnattended(ctx context.Context, c Client, enabled bool) (DeviceTrust, error) {
	s.createMu.Lock()
	defer s.createMu.Unlock()
	d, err := s.ownTrustDevice(ctx, c)
	if err != nil {
		return DeviceTrust{}, err
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return DeviceTrust{}, err
	}
	defer tx.Rollback()
	if _, err = tx.ExecContext(ctx, `UPDATE remote_devices SET unattended_enabled=? WHERE id=?`, boolInt(enabled), d.ID); err != nil {
		return DeviceTrust{}, err
	}
	if !enabled {
		// Advance every epoch before closing transports. Even if cleanup fails,
		// re-enabling cannot make an old grant or ticket valid again.
		if _, err = tx.ExecContext(ctx, `UPDATE remote_device_trust SET revision=revision+1 WHERE target_id=?`, d.ID); err != nil {
			return DeviceTrust{}, err
		}
	}
	if err = tx.Commit(); err != nil {
		return DeviceTrust{}, err
	}
	if !enabled {
		if err = s.stopTrustSessions(ctx, d.EntityID, "", true); err != nil {
			return DeviceTrust{}, err
		}
	}
	return s.DeviceTrust(ctx, c)
}
func (s *Service) GrantTrust(ctx context.Context, c Client, number, fingerprint string) (DeviceTrust, error) {
	s.createMu.Lock()
	defer s.createMu.Unlock()
	d, err := s.ownTrustDevice(ctx, c)
	if err != nil {
		return DeviceTrust{}, err
	}
	candidate, err := s.TrustCandidate(ctx, c, number)
	if err != nil {
		return DeviceTrust{}, err
	}
	if candidate.Fingerprint != remoteengine.NormalizeFingerprint(fingerprint) {
		return DeviceTrust{}, refuse(409, "CONFLICT", "key_changed", "Ключ устройства не совпадает — проверьте отпечаток")
	}
	peer, err := s.device(ctx, `number=?`, candidate.Number)
	if err != nil {
		return DeviceTrust{}, err
	}
	var pub string
	if err = s.db.QueryRowContext(ctx, `SELECT box_pub FROM remote_devices WHERE id=?`, peer.ID).Scan(&pub); err != nil {
		return DeviceTrust{}, err
	}
	_, err = s.db.ExecContext(ctx, `INSERT INTO remote_device_trust(target_id,viewer_id,box_pub,created_at) VALUES(?,?,?,?) ON CONFLICT(target_id,viewer_id) DO UPDATE SET box_pub=excluded.box_pub,revision=revision+1,created_at=excluded.created_at,revoked_at=NULL`, d.ID, peer.ID, pub, ms(s.now()))
	if err != nil {
		return DeviceTrust{}, err
	}
	// Regranting never upgrades or resurrects an earlier session/ticket.
	if err = s.stopTrustSessions(ctx, d.EntityID, peer.ClientID, false); err != nil {
		return DeviceTrust{}, err
	}
	return s.DeviceTrust(ctx, c)
}
func (s *Service) RevokeTrust(ctx context.Context, c Client, number string) (DeviceTrust, error) {
	s.createMu.Lock()
	defer s.createMu.Unlock()
	d, err := s.ownTrustDevice(ctx, c)
	if err != nil {
		return DeviceTrust{}, err
	}
	peer, err := s.device(ctx, `number=?`, remoteengine.NormalizeDeviceNumber(number))
	if err != nil {
		return DeviceTrust{}, err
	}
	result, err := s.db.ExecContext(ctx, `UPDATE remote_device_trust SET revoked_at=COALESCE(revoked_at,?),revision=revision+1 WHERE target_id=? AND viewer_id=?`, ms(s.now()), d.ID, peer.ID)
	if err != nil {
		return DeviceTrust{}, err
	}
	n, _ := result.RowsAffected()
	if n == 0 {
		return DeviceTrust{}, ErrNotFound
	}
	if err = s.stopTrustSessions(ctx, d.EntityID, peer.ClientID, false); err != nil {
		return DeviceTrust{}, err
	}
	return s.DeviceTrust(ctx, c)
}
func (s *Service) stopTrustSessions(ctx context.Context, entity, client string, onlyTrusted bool) error {
	where := `entity_id=? AND state NOT IN ('disconnected','failed','revoked','expired')`
	args := []any{entity}
	if client != "" {
		where += ` AND client_id=?`
		args = append(args, client)
	}
	if onlyTrusted {
		where += ` AND trust_revision>0`
	}
	sessions, err := s.sessions(ctx, where, 200, args...)
	if err != nil {
		return err
	}
	for _, x := range sessions {
		if _, err = s.stop(ctx, x.ID, StateRevoked, "Разрешение постоянного доступа изменено владельцем"); err != nil {
			return err
		}
	}
	return nil
}

// Zero means manual approval; a revoked pair is forbidden even when the
// global switch is off. Re-enabling never silently clears a revocation.
func (s *Service) trustRevision(ctx context.Context, client, entity string) (int64, error) {
	var enabled int
	var rev int64
	var revoked sql.NullInt64
	var pin, current string
	var targetBad, viewerBad int
	err := s.db.QueryRowContext(ctx, `SELECT d.unattended_enabled,t.revision,t.revoked_at,t.box_pub,v.box_pub,
 (d.revoked_at IS NOT NULL OR d.conflict_at IS NOT NULL),(v.revoked_at IS NOT NULL OR v.conflict_at IS NOT NULL)
 FROM remote_devices d JOIN remote_device_trust t ON t.target_id=d.id JOIN remote_devices v ON v.id=t.viewer_id WHERE d.entity_id=? AND v.client_id=?`, entity, client).Scan(&enabled, &rev, &revoked, &pin, &current, &targetBad, &viewerBad)
	if errors.Is(err, sql.ErrNoRows) {
		return 0, nil
	}
	if err != nil {
		return 0, err
	}
	if revoked.Valid || pin != current || targetBad != 0 || viewerBad != 0 {
		return 0, refuse(403, "FORBIDDEN", "trust_revoked", "Доступ этого устройства отозван владельцем")
	}
	if enabled != 1 {
		return 0, nil
	}
	return rev, nil
}
func (s *Service) sessionTrust(ctx context.Context, x Session) error {
	if x.State.Terminal() || x.TrustRevision == 0 {
		return nil
	}
	rev, err := s.trustRevision(ctx, x.ClientID, x.EntityID)
	if err != nil {
		return err
	}
	if rev != x.TrustRevision {
		return refuse(403, "FORBIDDEN", "trust_revoked", "Разрешение постоянного доступа больше не действует")
	}
	return nil
}
