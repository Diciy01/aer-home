package monitoring

import (
	"context"
	"strings"
	"time"
)

// Hooks for other Core modules (Bots, M06). They write into Monitoring's
// own storage through the same rules as agents: redaction, rate limits,
// incident grouping. Other modules never touch mon_* tables directly.

// AppendLog stores one log line of an entity (e.g. stdout of a supervised
// bot process). The message is redacted; the source is rate limited.
func (s *Service) AppendLog(ctx context.Context, entityID, source string, lvl LogLevel, msg string) error {
	if _, ok := levelNum[lvl]; !ok {
		lvl = LevelInfo
	}
	if strings.TrimSpace(msg) == "" {
		return nil
	}
	if acc, _ := s.admitLogs("entity:"+entityID+"/"+source, 1, s.now()); acc == 0 {
		return nil
	}
	_, err := s.db.ExecContext(ctx, `INSERT INTO mon_logs (ts, entity_id, source, level, message) VALUES (?,?,?,?,?)`,
		ms(s.now()), entityID, truncate(source, 160), levelNum[lvl], cleanMessage(msg))
	return err
}

// RecordEvent appends to the event history of an entity.
func (s *Service) RecordEvent(ctx context.Context, entityID, kind string, sev Severity, msg string) {
	s.event(ctx, &entityID, kind, sev, Redact(msg), nil)
}

// StoreSamples records Core-collected measurements (process CPU/RAM of a
// supervised bot). Unknown metrics and empty values are skipped.
func (s *Service) StoreSamples(ctx context.Context, entityID, source string, samples []SampleIn) error {
	return s.storeSamples(ctx, entityID, source, samples)
}

// RaiseIncident opens (or groups into) the unresolved incident of key.
// Keys of other modules must carry their own prefix ("n8n:", "bot_process:").
func (s *Service) RaiseIncident(ctx context.Context, key, title, source, entityID string, sev Severity, cause, msg string) {
	id := entityID
	if _, opened := s.openIncident(ctx, incidentSpec{key: key, title: title, source: source, entityID: &id,
		severity: sev, cause: Redact(cause), message: Redact(msg)}); opened {
		s.RefreshEntity(ctx, entityID)
	}
}

// ResolveIncident closes the unresolved incident of key, if any.
func (s *Service) ResolveIncident(ctx context.Context, key, msg string) {
	s.resolveIncident(ctx, key, msg)
}

// SetIntegrationStatus publishes the health of an integration owned by
// another module ("bots", "n8n") on the Monitoring overview.
func (s *Service) SetIntegrationStatus(id, label, status, reason string) {
	s.setIntegration(IntegrationStatus{ID: id, Label: label, Status: status, Reason: reason})
}

// EventsOfKinds lists an entity's events of the given kinds (newest first).
func (s *Service) EventsOfKinds(ctx context.Context, entityID string, kinds []string, limit int) ([]Event, error) {
	if limit <= 0 || limit > 200 {
		limit = 50
	}
	if len(kinds) == 0 {
		return s.Events(ctx, entityID, 0, limit)
	}
	q := `SELECT id, ts, entity_id, kind, severity, message, incident_id FROM mon_events WHERE entity_id = ? AND kind IN (?` +
		strings.Repeat(",?", len(kinds)-1) + `) ORDER BY id DESC LIMIT ?`
	args := []any{entityID}
	for _, k := range kinds {
		args = append(args, k)
	}
	rows, err := s.db.QueryContext(ctx, q, append(args, limit)...)
	if err != nil {
		return nil, err
	}
	return scanEvents(rows)
}

// HeartbeatTimeout is the effective silence limit of an entity's agents.
func (s *Service) HeartbeatTimeout() time.Duration {
	return time.Duration(s.cfg.HeartbeatTimeoutSec) * time.Second
}
