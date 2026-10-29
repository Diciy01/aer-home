package remote

import (
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"strings"
	"time"

	"aerhome/core/internal/foundation/ids"
	"aerhome/core/internal/remoteengine"
)

// RegistrationInput never carries a package-wide secret. Proof is a random
// challenge that only the requesting installation can decrypt.
type RegistrationInput struct {
	DeviceName string `json:"deviceName"`
	BoxPub     string `json:"boxPub"`
	Instance   string `json:"instance"`
	Proof      string `json:"proof,omitempty"`
}

type RegistrationReply struct {
	ID     string                        `json:"id"`
	Status string                        `json:"status"`
	Box    *remoteengine.RegistrationBox `json:"box,omitempty"`
}

type RegistrationRequest struct {
	ID          string    `json:"id"`
	Name        string    `json:"name"`
	Fingerprint string    `json:"fingerprint"`
	Status      string    `json:"status"`
	CreatedAt   time.Time `json:"createdAt"`
	ExpiresAt   time.Time `json:"expiresAt"`
}

// Registration is an idempotent, bounded request/poll operation. No credential
// is issued before an owner approves a verified request on Core's owner API.
func (s *Service) Registration(ctx context.Context, in RegistrationInput, addr string) (RegistrationReply, error) {
	in.DeviceName = strings.TrimSpace(in.DeviceName)
	if in.DeviceName == "" || len([]rune(in.DeviceName)) > 80 || !remoteengine.ValidBoxKey(in.BoxPub) ||
		len(in.Instance) < 16 || len(in.Instance) > 128 || strings.Trim(in.Instance, "0123456789abcdef") != "" || len(in.Proof) > 128 {
		return RegistrationReply{}, &ValidationError{Fields: map[string]string{"registration": "Некорректная идентичность установки"}}
	}
	key, _ := remoteengine.DecodeKey(in.BoxPub)
	in.BoxPub = remoteengine.EncodeKey(key)
	s.registrationMu.Lock()
	defer s.registrationMu.Unlock()
	var id, instance, status, challengeBox, credentialBox, deviceID string
	var proofHash []byte
	var expires int64
	err := s.db.QueryRowContext(ctx, `SELECT id,instance,status,challenge_box,proof_hash,credential_box,device_id,expires_at FROM remote_registrations WHERE box_pub=?`, in.BoxPub).
		Scan(&id, &instance, &status, &challengeBox, &proofHash, &credentialBox, &deviceID, &expires)
	if errors.Is(err, sql.ErrNoRows) {
		// Drop only unapproved expired requests. Approved/rejected identities are
		// tombstones: a revoked identity cannot silently register itself again.
		if _, err = s.db.ExecContext(ctx, `DELETE FROM remote_registrations WHERE status IN ('verifying','pending') AND expires_at < ?`, ms(s.now())); err != nil {
			return RegistrationReply{}, err
		}
		var count int
		if err = s.db.QueryRowContext(ctx, `SELECT count(*) FROM remote_registrations WHERE status IN ('verifying','pending')`).Scan(&count); err != nil {
			return RegistrationReply{}, err
		}
		if count >= 128 || s.limited("registration:"+addr, 5, true) {
			return RegistrationReply{}, refuse(429, "UNAVAILABLE", "registration_limit", "Регистрация временно занята. Повторите позже")
		}
		id, instance, status, expires = ids.New(), in.Instance, "verifying", ms(s.now().Add(24*time.Hour))
		challenge := remoteengine.NewSecret()
		hash := remoteengine.HashSecret(challenge)
		box, err := remoteengine.SealRegistration(in.BoxPub, id, instance, []byte(challenge))
		if err != nil {
			return RegistrationReply{}, refuse(422, "VALIDATION_FAILED", "invalid_key", "Ключ установки не поддерживается")
		}
		b, _ := json.Marshal(box)
		if _, err = s.db.ExecContext(ctx, `INSERT INTO remote_registrations(id,name,box_pub,instance,status,challenge_box,proof_hash,created_at,expires_at) VALUES(?,?,?,?,?,?,?,?,?)`, id, in.DeviceName, in.BoxPub, instance, status, string(b), hash[:], ms(s.now()), expires); err != nil {
			return RegistrationReply{}, err
		}
		return RegistrationReply{ID: id, Status: "verifying", Box: &box}, nil
	}
	if err != nil {
		return RegistrationReply{}, err
	}
	bad := refuse(401, "UNAUTHORIZED", "registration_identity", "Не удалось подтвердить идентичность установки")
	if instance != in.Instance {
		return RegistrationReply{}, bad
	}
	if status != "approved" && status != "rejected" && expires <= ms(s.now()) {
		return RegistrationReply{}, refuse(410, "UNAVAILABLE", "registration_expired", "Заявка регистрации истекла. Обратитесь к владельцу сервера")
	}
	if in.Proof == "" {
		var box remoteengine.RegistrationBox
		if err = json.Unmarshal([]byte(challengeBox), &box); err != nil {
			return RegistrationReply{}, err
		}
		return RegistrationReply{ID: id, Status: "verifying", Box: &box}, nil
	}
	hash := remoteengine.HashSecret(in.Proof)
	if subtle.ConstantTimeCompare(hash[:], proofHash) != 1 {
		return RegistrationReply{}, bad
	}
	if status == "verifying" {
		if _, err = s.db.ExecContext(ctx, `UPDATE remote_registrations SET status='pending' WHERE id=?`, id); err != nil {
			return RegistrationReply{}, err
		}
		status = "pending"
	}
	reply := RegistrationReply{ID: id, Status: status}
	if status == "approved" {
		d, err := s.device(ctx, `id = ?`, deviceID)
		if err != nil {
			return RegistrationReply{}, err
		}
		if d.RevokedAt != nil || d.ConflictAt != nil {
			reply.Status = "revoked"
			return reply, nil
		}
		// Check revocation of either credential as well as the device itself.
		var active int
		if err = s.db.QueryRowContext(ctx, `SELECT count(*) FROM remote_clients c JOIN remote_devices d ON d.client_id=c.id JOIN mon_agents a ON a.id=d.agent_id WHERE d.id=? AND c.revoked_at IS NULL AND a.revoked_at IS NULL`, deviceID).Scan(&active); err != nil {
			return RegistrationReply{}, err
		}
		if active != 1 {
			reply.Status = "revoked"
			return reply, nil
		}
		var box remoteengine.RegistrationBox
		if err = json.Unmarshal([]byte(credentialBox), &box); err != nil {
			return RegistrationReply{}, err
		}
		reply.Box = &box
	}
	return reply, nil
}

func (s *Service) Registrations(ctx context.Context) ([]RegistrationRequest, error) {
	rows, err := s.db.QueryContext(ctx, `SELECT id,name,box_pub,status,created_at,expires_at FROM remote_registrations WHERE status='pending' AND expires_at>? ORDER BY created_at,id`, ms(s.now()))
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []RegistrationRequest{}
	for rows.Next() {
		var r RegistrationRequest
		var pub string
		var created, expires int64
		if err = rows.Scan(&r.ID, &r.Name, &pub, &r.Status, &created, &expires); err != nil {
			return nil, err
		}
		raw, _ := remoteengine.DecodeKey(pub)
		h := sha256.Sum256(raw)
		r.Fingerprint = hex.EncodeToString(h[:])
		r.CreatedAt, r.ExpiresAt = fromMS(created), fromMS(expires)
		out = append(out, r)
	}
	return out, rows.Err()
}

func (s *Service) DecideRegistration(ctx context.Context, id string, approve bool) (RegistrationReply, error) {
	s.registrationMu.Lock()
	defer s.registrationMu.Unlock()
	var name, pub, instance, status string
	var expires int64
	err := s.db.QueryRowContext(ctx, `SELECT name,box_pub,instance,status,expires_at FROM remote_registrations WHERE id=?`, id).Scan(&name, &pub, &instance, &status, &expires)
	if errors.Is(err, sql.ErrNoRows) {
		return RegistrationReply{}, ErrNotFound
	}
	if err != nil {
		return RegistrationReply{}, err
	}
	if status != "pending" || expires <= ms(s.now()) {
		return RegistrationReply{}, refuse(409, "CONFLICT", "registration_state", "Заявка не ожидает решения владельца")
	}
	if !approve {
		_, err = s.db.ExecContext(ctx, `UPDATE remote_registrations SET status='rejected' WHERE id=?`, id)
		return RegistrationReply{ID: id, Status: "rejected"}, err
	}
	// Reuse the exact provisioning/rollback path of code-based enrollment.
	// The single-use code is generated and consumed inside Core, never shared.
	code, err := s.CreateEnrollment(ctx, EnrollmentInput{Name: "Автоматическая регистрация", MaxUses: 1, Hours: 1})
	if err != nil {
		return RegistrationReply{}, err
	}
	enrolled, err := s.Enroll(ctx, EnrollInput{Code: code.Code, DeviceName: name, BoxPub: pub, Instance: instance}, "")
	if err != nil {
		_, _ = s.RevokeEnrollment(context.WithoutCancel(ctx), code.Enrollment.ID)
		return RegistrationReply{}, err
	}
	plain, _ := json.Marshal(enrolled)
	box, err := remoteengine.SealRegistration(pub, id, instance, plain)
	if err == nil {
		var b []byte
		b, err = json.Marshal(box)
		if err == nil {
			_, err = s.db.ExecContext(ctx, `UPDATE remote_registrations SET status='approved',credential_box=?,device_id=? WHERE id=?`, string(b), enrolled.DeviceID, id)
		}
	}
	if err != nil {
		_, _ = s.RevokeDevice(context.WithoutCancel(ctx), enrolled.DeviceID)
		return RegistrationReply{}, err
	}
	return RegistrationReply{ID: id, Status: "approved"}, nil
}
