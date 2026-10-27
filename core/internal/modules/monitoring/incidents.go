package monitoring

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	"aerhome/core/internal/foundation/ids"
)

type incidentSpec struct {
	key, title, source string
	entityID           *string
	severity           Severity
	cause, message     string
}

// repeatNoteEvery throttles "repeated" timeline entries of a long incident.
const repeatNoteEvery = 10 * time.Minute

// openIncident opens a new incident for spec.key or groups the observation
// into the unresolved one with the same key (no new incident per measurement).
func (s *Service) openIncident(ctx context.Context, sp incidentSpec) (string, bool) {
	s.incMu.Lock()
	defer s.incMu.Unlock()
	now := s.now().UTC()
	var id string
	var sev string
	var updated int64
	err := s.db.QueryRowContext(ctx, `SELECT id, severity, updated_at FROM mon_incidents WHERE key = ? AND status != 'resolved'`, sp.key).
		Scan(&id, &sev, &updated)
	if err == nil {
		newSev := Severity(sev)
		if severityRank[sp.severity] > severityRank[newSev] {
			newSev = sp.severity
		}
		_, _ = s.db.ExecContext(ctx, `UPDATE mon_incidents SET occurrences = occurrences + 1, updated_at = ?, last_message = ?, severity = ?,
			cause = CASE WHEN cause = '' THEN ? ELSE cause END WHERE id = ?`,
			ms(now), truncate(sp.message, 500), string(newSev), truncate(sp.cause, 300), id)
		var lastNote int64
		_ = s.db.QueryRowContext(ctx, `SELECT COALESCE(MAX(ts), 0) FROM mon_incident_events WHERE incident_id = ? AND kind IN ('opened','repeated')`, id).Scan(&lastNote)
		if now.Sub(fromMS(lastNote)) >= repeatNoteEvery {
			s.timeline(ctx, id, "repeated", "Повторно: "+sp.message)
		}
		if newSev != Severity(sev) {
			s.timeline(ctx, id, "note", "Серьёзность повышена до «"+severityRU(newSev)+"»")
		}
		return id, false
	}
	if !errors.Is(err, sql.ErrNoRows) {
		s.log.Warn("incident lookup", "err", err)
		return "", false
	}
	id = ids.New()
	related := s.correlated(ctx, sp.entityID)
	rel, _ := json.Marshal(related)
	if _, err := s.db.ExecContext(ctx, `INSERT INTO mon_incidents (id, key, title, source, entity_id, severity, status, opened_at, updated_at, cause, related, last_message)
		VALUES (?,?,?,?,?,?,?,?,?,?,?,?)`,
		id, sp.key, truncate(sp.title, 200), sp.source, nullStr(sp.entityID), string(sp.severity), string(IncidentOpen),
		ms(now), ms(now), truncate(sp.cause, 300), string(rel), truncate(sp.message, 500)); err != nil {
		s.log.Warn("incident insert", "err", err)
		return "", false
	}
	s.timeline(ctx, id, "opened", sp.message)
	if len(related) > 0 {
		s.timeline(ctx, id, "note", "Возможно связано с открытыми инцидентами зависимостей (корреляция по связям Registry, причина не установлена)")
	}
	s.event(ctx, sp.entityID, "incident_opened", sp.severity, sp.title, &id)
	_, _ = s.db.ExecContext(ctx, `INSERT INTO mon_logs (ts, entity_id, source, level, message, incident_id) VALUES (?,?,?,?,?,?)`,
		ms(now), nullStr(sp.entityID), "core.incidents", levelNum[levelFor(sp.severity)], truncate(sp.title+". "+sp.message, 2000), id)
	s.notifier.create(ctx, "incident_opened", sp.severity, sp.title, sp.message, sp.entityID, &id)
	return id, true
}

func levelFor(s Severity) LogLevel {
	switch s {
	case SeverityCritical:
		return LevelCritical
	case SeverityWarning:
		return LevelWarning
	}
	return LevelInfo
}

// resolveIncident closes the unresolved incident of key after a confirmed
// recovery (acknowledged ones too).
func (s *Service) resolveIncident(ctx context.Context, key, message string) {
	s.incMu.Lock()
	defer s.incMu.Unlock()
	var id, title, sev string
	var entity sql.NullString
	err := s.db.QueryRowContext(ctx, `SELECT id, title, severity, entity_id FROM mon_incidents WHERE key = ? AND status != 'resolved'`, key).
		Scan(&id, &title, &sev, &entity)
	if err != nil {
		return
	}
	now := s.now().UTC()
	if _, err := s.db.ExecContext(ctx, `UPDATE mon_incidents SET status = 'resolved', resolved_at = ?, updated_at = ? WHERE id = ?`,
		ms(now), ms(now), id); err != nil {
		return
	}
	s.timeline(ctx, id, "resolved", message)
	var eid *string
	if entity.Valid {
		eid = &entity.String
	}
	s.event(ctx, eid, "incident_resolved", SeverityInfo, "Восстановлено: "+title, &id)
	if s.cfg.NotifyRecovery {
		s.notifier.create(ctx, "incident_resolved", SeverityInfo, "Восстановлено: "+title, message, eid, &id)
	}
}

func (s *Service) timeline(ctx context.Context, id, kind, msg string) {
	_, _ = s.db.ExecContext(ctx, `INSERT INTO mon_incident_events (incident_id, ts, kind, message) VALUES (?,?,?,?)`,
		id, ms(s.now()), kind, truncate(msg, 1000))
}

// correlated finds open availability incidents of entities this one depends
// on (runs_on, hosted_by, depends_on, installed_on) via Registry relations.
func (s *Service) correlated(ctx context.Context, entityID *string) []string {
	out := []string{}
	if entityID == nil {
		return out
	}
	rels, err := s.reg.Relations(ctx, *entityID)
	if err != nil {
		return out
	}
	for _, r := range rels {
		if r.Direction != "outgoing" {
			continue
		}
		switch r.Kind {
		case "runs_on", "hosted_by", "depends_on", "installed_on":
		default:
			continue
		}
		var id string
		if s.db.QueryRowContext(ctx, `SELECT id FROM mon_incidents WHERE key = ? AND status != 'resolved'`, "availability:"+r.Peer.ID).Scan(&id) == nil {
			out = append(out, id)
		}
	}
	return out
}

// Acknowledge marks an open incident as seen by the owner.
func (s *Service) Acknowledge(ctx context.Context, id, note string) (Incident, error) {
	s.incMu.Lock()
	res, err := s.db.ExecContext(ctx, `UPDATE mon_incidents SET status = 'acknowledged', acknowledged_at = ?, updated_at = ? WHERE id = ? AND status = 'open'`,
		ms(s.now()), ms(s.now()), id)
	s.incMu.Unlock()
	if err != nil {
		return Incident{}, err
	}
	if n, _ := res.RowsAffected(); n > 0 {
		msg := "Подтверждено пользователем"
		if note = strings.TrimSpace(note); note != "" {
			msg += ": " + truncate(Redact(note), 300)
		}
		s.timeline(ctx, id, "acknowledged", msg)
	}
	return s.Incident(ctx, id)
}

const incidentCols = `id, key, title, source, entity_id, severity, status, opened_at, updated_at, acknowledged_at, resolved_at, cause, related, occurrences, last_message`

func scanIncident(row interface{ Scan(...any) error }) (Incident, error) {
	var in Incident
	var entity sql.NullString
	var sev, st, rel string
	var opened, updated int64
	var ack, resolved sql.NullInt64
	if err := row.Scan(&in.ID, &in.Key, &in.Title, &in.Source, &entity, &sev, &st, &opened, &updated, &ack, &resolved,
		&in.Cause, &rel, &in.Occurrences, &in.LastMessage); err != nil {
		return Incident{}, err
	}
	if entity.Valid {
		in.EntityID = &entity.String
	}
	in.Severity, in.Status = Severity(sev), IncidentStatus(st)
	in.OpenedAt, in.UpdatedAt = fromMS(opened), fromMS(updated)
	in.AcknowledgedAt, in.ResolvedAt = fromNullMS(ack), fromNullMS(resolved)
	in.Related = []string{}
	_ = json.Unmarshal([]byte(rel), &in.Related)
	return in, nil
}

// Incident returns one incident with its timeline.
func (s *Service) Incident(ctx context.Context, id string) (Incident, error) {
	in, err := scanIncident(s.db.QueryRowContext(ctx, `SELECT `+incidentCols+` FROM mon_incidents WHERE id = ?`, id))
	if errors.Is(err, sql.ErrNoRows) {
		return Incident{}, ErrNotFound
	}
	if err != nil {
		return Incident{}, err
	}
	rows, err := s.db.QueryContext(ctx, `SELECT ts, kind, message FROM mon_incident_events WHERE incident_id = ? ORDER BY ts, rowid`, id)
	if err != nil {
		return Incident{}, err
	}
	defer rows.Close()
	in.Timeline = []IncidentEvent{}
	for rows.Next() {
		var ev IncidentEvent
		var ts int64
		if err := rows.Scan(&ts, &ev.Kind, &ev.Message); err != nil {
			return Incident{}, err
		}
		ev.At = fromMS(ts)
		in.Timeline = append(in.Timeline, ev)
	}
	return in, rows.Err()
}

// IncidentFilter for listing.
type IncidentFilter struct {
	Status   string // "", active, open, acknowledged, resolved
	Severity string
	EntityID string
	Limit    int
	Offset   int
}

// IncidentPage is a page of incidents.
type IncidentPage struct {
	Items []Incident `json:"items"`
	Total int        `json:"total"`
}

// Incidents lists incidents, most severe and newest first for active ones.
func (s *Service) Incidents(ctx context.Context, f IncidentFilter) (IncidentPage, error) {
	where := []string{"1=1"}
	args := []any{}
	switch f.Status {
	case "":
	case "active":
		where = append(where, "status != 'resolved'")
	case "open", "acknowledged", "resolved":
		where = append(where, "status = ?")
		args = append(args, f.Status)
	default:
		return IncidentPage{}, &ValidationError{Fields: map[string]string{"status": "active, open, acknowledged или resolved"}}
	}
	if f.Severity != "" {
		if _, ok := severityRank[Severity(f.Severity)]; !ok {
			return IncidentPage{}, &ValidationError{Fields: map[string]string{"severity": "info, warning или critical"}}
		}
		where = append(where, "severity = ?")
		args = append(args, f.Severity)
	}
	if f.EntityID != "" {
		where = append(where, "entity_id = ?")
		args = append(args, f.EntityID)
	}
	if f.Limit <= 0 || f.Limit > 200 {
		f.Limit = 50
	}
	w := strings.Join(where, " AND ")
	var page IncidentPage
	if err := s.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM mon_incidents WHERE `+w, args...).Scan(&page.Total); err != nil {
		return page, err
	}
	rows, err := s.db.QueryContext(ctx, `SELECT `+incidentCols+` FROM mon_incidents WHERE `+w+`
		ORDER BY (status = 'resolved'), CASE severity WHEN 'critical' THEN 0 WHEN 'warning' THEN 1 ELSE 2 END, opened_at DESC
		LIMIT ? OFFSET ?`, append(args, f.Limit, f.Offset)...)
	if err != nil {
		return page, err
	}
	defer rows.Close()
	page.Items = []Incident{}
	for rows.Next() {
		in, err := scanIncident(rows)
		if err != nil {
			return page, err
		}
		page.Items = append(page.Items, in)
	}
	return page, rows.Err()
}

func severityRU(s Severity) string {
	switch s {
	case SeverityCritical:
		return "критично"
	case SeverityWarning:
		return "предупреждение"
	}
	return "информация"
}

// evaluateThresholds turns reported values into incidents with debounce
// (N consecutive breaches) and hysteresis on recovery.
func (s *Service) evaluateThresholds(ctx context.Context, a Agent, samples []SampleIn) {
	t := s.cfg.Thresholds
	e, err := s.reg.Get(ctx, a.EntityID)
	if err != nil {
		return
	}
	id := e.ID
	for _, sm := range samples {
		if sm.Quality != QualityOK || sm.Value == nil {
			continue
		}
		v := *sm.Value
		switch sm.Metric {
		case "disk.used_percent":
			free := 100 - v
			key := "disk_low:" + id + ":" + sm.Label
			sev := SeverityWarning
			if free < t.DiskFreeCriticalPercent {
				sev = SeverityCritical
			}
			s.rule(ctx, key, free < t.DiskFreeWarnPercent, free > t.DiskFreeWarnPercent+2, incidentSpec{
				key: key, title: fmt.Sprintf("Мало места на «%s»: %s", e.Name, sm.Label), source: "metrics/disk", entityID: &id,
				severity: sev, message: fmt.Sprintf("Свободно %.1f %% на %s (порог %.0f %%)", free, sm.Label, t.DiskFreeWarnPercent),
			}, fmt.Sprintf("Свободно %.1f %% на %s", free, sm.Label))
		case "cpu.temperature", "gpu.temperature":
			limit, what := t.CPUTempWarnC, "процессора"
			if sm.Metric == "gpu.temperature" {
				limit, what = t.GPUTempWarnC, "видеокарты"
			}
			key := sm.Metric + ":" + id
			s.rule(ctx, key, v >= limit, v < limit-5, incidentSpec{
				key: key, title: fmt.Sprintf("Высокая температура %s на «%s»", what, e.Name), source: "metrics/temperature", entityID: &id,
				severity: SeverityWarning, message: fmt.Sprintf("%.0f °C (порог %.0f °C)", v, limit),
			}, fmt.Sprintf("Температура снизилась до %.0f °C", v))
		case "service.active":
			key := "service_down:" + id + ":" + sm.Label
			s.rule(ctx, key, v < 0.5, v >= 0.5, incidentSpec{
				key: key, title: fmt.Sprintf("Служба %s на «%s» не работает", sm.Label, e.Name), source: "metrics/service", entityID: &id,
				severity: SeverityWarning, message: "Служба не активна (" + sm.Label + ")",
			}, "Служба снова активна")
		case "bot.api_ok":
			key := "bot_api:" + id
			s.rule(ctx, key, v < 0.5, v >= 0.5, incidentSpec{
				key: key, title: fmt.Sprintf("Бот «%s» не может связаться с API Telegram", e.Name), source: "bot/heartbeat", entityID: &id,
				severity: SeverityWarning, message: "Бот сообщил, что зависимость (API Telegram) недоступна",
			}, "Связь бота с API Telegram восстановлена")
		}
	}
}

func (s *Service) rule(ctx context.Context, key string, breach, clear bool, sp incidentSpec, recovered string) {
	s.mu.Lock()
	n := s.breaches[key]
	if breach {
		n++
		s.breaches[key] = n
	} else {
		delete(s.breaches, key)
	}
	s.mu.Unlock()
	switch {
	case breach && n >= s.cfg.Thresholds.ConsecutiveBreaches:
		s.openIncident(ctx, sp)
	case clear:
		s.resolveIncident(ctx, key, recovered)
	}
}
