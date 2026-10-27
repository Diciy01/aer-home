package monitoring

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"strings"
	"time"

	"aerhome/core/internal/modules/registry"
)

// States returns the current state of every active Registry entity. Entities
// never evaluated yet are reported as "unknown" (no data), not as healthy.
func (s *Service) States(ctx context.Context) ([]DeviceState, error) {
	entities, err := s.activeEntities(ctx)
	if err != nil {
		return nil, err
	}
	out := make([]DeviceState, 0, len(entities))
	for _, e := range entities {
		st, err := s.state(ctx, e, false)
		if err != nil {
			return nil, err
		}
		out = append(out, st)
	}
	return out, nil
}

// State returns one entity's state with all latest metrics and its agents.
func (s *Service) State(ctx context.Context, id string) (DeviceState, error) {
	e, err := s.reg.Get(ctx, id)
	if errors.Is(err, registry.ErrNotFound) {
		return DeviceState{}, ErrEntityMissing
	}
	if err != nil {
		return DeviceState{}, err
	}
	return s.state(ctx, e, true)
}

func (s *Service) state(ctx context.Context, e registry.Entity, full bool) (DeviceState, error) {
	st := DeviceState{EntityID: e.ID, Name: e.Name, Type: e.Type, Status: StatusUnknown,
		Reason: "Ещё не проверялся", CheckKind: "none", KeyMetrics: []MetricValue{}, Agents: []Agent{}}
	var status, reason, kind string
	var contact, check, changed sql.NullInt64
	err := s.db.QueryRowContext(ctx, `SELECT status, reason, check_kind, last_contact, last_check, changed_at FROM mon_state WHERE entity_id = ?`, e.ID).
		Scan(&status, &reason, &kind, &contact, &check, &changed)
	if err == nil {
		st.Status, st.Reason, st.CheckKind = Status(status), reason, kind
		st.LastContactAt, st.LastCheckAt, st.ChangedAt = fromNullMS(contact), fromNullMS(check), fromNullMS(changed)
	} else if !errors.Is(err, sql.ErrNoRows) {
		return st, err
	}
	if e.Archived {
		st.Status, st.Reason = StatusUnsupported, "Объект в архиве Registry: не проверяется"
	}
	metrics, err := s.Latest(ctx, e.ID, !full)
	if err != nil {
		return st, err
	}
	st.KeyMetrics = metrics
	var worst sql.NullString
	if err := s.db.QueryRowContext(ctx, `SELECT COUNT(*), (SELECT severity FROM mon_incidents WHERE entity_id = ?1 AND status != 'resolved'
		ORDER BY CASE severity WHEN 'critical' THEN 0 WHEN 'warning' THEN 1 ELSE 2 END LIMIT 1)
		FROM mon_incidents WHERE entity_id = ?1 AND status != 'resolved'`, e.ID).Scan(&st.OpenIncidents, &worst); err != nil {
		return st, err
	}
	if worst.Valid {
		w := Severity(worst.String)
		st.WorstSeverity = &w
	}
	if agents, err := s.ListAgents(ctx, e.ID); err == nil {
		st.Agents = agents
	}
	return st, nil
}

// Latest returns the newest value of each series; keyOnly keeps card metrics.
func (s *Service) Latest(ctx context.Context, entityID string, keyOnly bool) ([]MetricValue, error) {
	rows, err := s.db.QueryContext(ctx, `SELECT metric, label, ts, value, quality, reason, source FROM mon_latest
		WHERE entity_id = ? ORDER BY metric, label`, entityID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []MetricValue{}
	for rows.Next() {
		var m MetricValue
		var ts int64
		var v sql.NullFloat64
		var q string
		if err := rows.Scan(&m.Metric, &m.Label, &ts, &v, &q, &m.Reason, &m.Source); err != nil {
			return nil, err
		}
		t := metricByID[m.Metric]
		if keyOnly && !t.Key {
			continue
		}
		m.At, m.Quality, m.Unit = fromMS(ts), Quality(q), t.Unit
		if v.Valid {
			val := v.Float64
			m.Value = &val
		}
		out = append(out, m)
	}
	return out, rows.Err()
}

const maxPoints = 400

// History returns a chart-ready series: raw samples for recent short ranges,
// 5-minute aggregates otherwise. Missing intervals are null points (gaps).
func (s *Service) History(ctx context.Context, entityID, metric, label string, from, to time.Time) (Series, error) {
	t, ok := metricByID[metric]
	v := &ValidationError{}
	if !ok {
		v.add("metric", "Неизвестная метрика")
	}
	if !to.After(from) {
		v.add("from", "from должен быть раньше to")
	}
	if to.Sub(from) > 400*24*time.Hour {
		v.add("from", "Период не длиннее 400 дней")
	}
	if err := v.orNil(); err != nil {
		return Series{}, err
	}
	from, to = from.UTC(), to.UTC()
	ser := Series{EntityID: entityID, Metric: metric, Label: label, Unit: t.Unit, From: from, To: to, Points: []Point{}}
	rawFrom := s.now().Add(-time.Duration(s.cfg.RawRetentionDays) * 24 * time.Hour)
	useRaw := to.Sub(from) <= 6*time.Hour && from.After(rawFrom)
	span := to.Sub(from)
	step := span / maxPoints
	if useRaw {
		ser.Resolution = "raw"
		if step < 15*time.Second {
			step = 15 * time.Second
		}
	} else {
		ser.Resolution = "5m"
		if step < rollupBucket {
			step = rollupBucket
		}
		step = step.Truncate(rollupBucket)
	}
	ser.StepSec = int(step.Seconds())
	stepMS := step.Milliseconds()
	var rows *sql.Rows
	var err error
	if useRaw {
		rows, err = s.db.QueryContext(ctx, `SELECT (ts - ?1) / ?2, AVG(value), MIN(value), MAX(value), COUNT(value)
			FROM mon_samples WHERE entity_id = ?3 AND metric = ?4 AND label = ?5 AND ts >= ?1 AND ts < ?6
			GROUP BY 1 ORDER BY 1`, ms(from), stepMS, entityID, metric, label, ms(to))
	} else {
		rows, err = s.db.QueryContext(ctx, `SELECT (bucket - ?1) / ?2, SUM(sum) / SUM(n), MIN(min), MAX(max), SUM(n)
			FROM mon_rollups WHERE entity_id = ?3 AND metric = ?4 AND label = ?5 AND bucket >= ?1 AND bucket < ?6
			GROUP BY 1 ORDER BY 1`, ms(from), stepMS, entityID, metric, label, ms(to))
	}
	if err != nil {
		return ser, err
	}
	defer rows.Close()
	type agg struct{ avg, min, max sql.NullFloat64 }
	byIdx := map[int64]agg{}
	for rows.Next() {
		var i, n int64
		var a agg
		if err := rows.Scan(&i, &a.avg, &a.min, &a.max, &n); err != nil {
			return ser, err
		}
		if n > 0 {
			byIdx[i] = a
		}
	}
	if err := rows.Err(); err != nil {
		return ser, err
	}
	count := int64(span / step)
	for i := int64(0); i <= count; i++ {
		p := Point{T: from.Add(time.Duration(i) * step)}
		if a, ok := byIdx[i]; ok {
			p.Value, p.Min, p.Max = fptr(a.avg), fptr(a.min), fptr(a.max)
		}
		ser.Points = append(ser.Points, p)
	}
	return ser, nil
}

func fptr(v sql.NullFloat64) *float64 {
	if !v.Valid {
		return nil
	}
	x := v.Float64
	return &x
}

// LogFilter selects log entries; pagination by descending id cursor.
type LogFilter struct {
	Query      string
	EntityID   string
	Source     string
	MinLevel   string
	IncidentID string
	From, To   *time.Time
	Before     int64
	Limit      int
}

// LogPage is one page of logs (newest first).
type LogPage struct {
	Items      []LogEntry `json:"items"`
	NextBefore *int64     `json:"nextBefore"`
}

// Logs searches centralized logs.
func (s *Service) Logs(ctx context.Context, f LogFilter) (LogPage, error) {
	where := []string{"1=1"}
	args := []any{}
	if f.Query != "" {
		for _, term := range strings.Fields(f.Query) {
			where = append(where, `(message LIKE ? ESCAPE '\' OR source LIKE ? ESCAPE '\')`)
			like := "%" + escapeLike(term) + "%"
			args = append(args, like, like)
		}
	}
	if f.EntityID != "" {
		where = append(where, "entity_id = ?")
		args = append(args, f.EntityID)
	}
	if f.Source != "" {
		where = append(where, `source LIKE ? ESCAPE '\'`)
		args = append(args, escapeLike(f.Source)+"%")
	}
	if f.MinLevel != "" {
		n, ok := levelNum[LogLevel(f.MinLevel)]
		if !ok {
			return LogPage{}, &ValidationError{Fields: map[string]string{"level": "debug, info, warning, error или critical"}}
		}
		where = append(where, "level >= ?")
		args = append(args, n)
	}
	if f.IncidentID != "" {
		where = append(where, "incident_id = ?")
		args = append(args, f.IncidentID)
	}
	if f.From != nil {
		where = append(where, "ts >= ?")
		args = append(args, ms(*f.From))
	}
	if f.To != nil {
		where = append(where, "ts < ?")
		args = append(args, ms(*f.To))
	}
	if f.Before > 0 {
		where = append(where, "id < ?")
		args = append(args, f.Before)
	}
	if f.Limit <= 0 || f.Limit > 500 {
		f.Limit = 100
	}
	rows, err := s.db.QueryContext(ctx, `SELECT id, ts, entity_id, source, level, message, correlation_id, fields, incident_id
		FROM mon_logs WHERE `+strings.Join(where, " AND ")+` ORDER BY id DESC LIMIT ?`, append(args, f.Limit+1)...)
	if err != nil {
		return LogPage{}, err
	}
	defer rows.Close()
	page := LogPage{Items: []LogEntry{}}
	for rows.Next() {
		l, err := scanLog(rows)
		if err != nil {
			return page, err
		}
		page.Items = append(page.Items, l)
	}
	if len(page.Items) > f.Limit {
		page.Items = page.Items[:f.Limit]
		next := page.Items[len(page.Items)-1].ID
		page.NextBefore = &next
	}
	return page, rows.Err()
}

func escapeLike(s string) string {
	return strings.NewReplacer(`\`, `\\`, `%`, `\%`, `_`, `\_`).Replace(s)
}

func scanLog(row interface{ Scan(...any) error }) (LogEntry, error) {
	var l LogEntry
	var ts int64
	var lvl int
	var ent, fields, inc sql.NullString
	if err := row.Scan(&l.ID, &ts, &ent, &l.Source, &lvl, &l.Message, &l.CorrelationID, &fields, &inc); err != nil {
		return l, err
	}
	l.At, l.Level = fromMS(ts), levelName(lvl)
	if ent.Valid {
		l.EntityID = &ent.String
	}
	if inc.Valid {
		l.IncidentID = &inc.String
	}
	if fields.Valid {
		l.Fields = json.RawMessage(fields.String)
	}
	return l, nil
}

// Log returns one log entry.
func (s *Service) Log(ctx context.Context, id int64) (LogEntry, error) {
	l, err := scanLog(s.db.QueryRowContext(ctx, `SELECT id, ts, entity_id, source, level, message, correlation_id, fields, incident_id
		FROM mon_logs WHERE id = ?`, id))
	if errors.Is(err, sql.ErrNoRows) {
		return l, ErrNotFound
	}
	return l, err
}

// Events lists the event history (newest first).
func (s *Service) Events(ctx context.Context, entityID string, before int64, limit int) ([]Event, error) {
	if limit <= 0 || limit > 200 {
		limit = 50
	}
	q := `SELECT id, ts, entity_id, kind, severity, message, incident_id FROM mon_events WHERE 1=1`
	args := []any{}
	if entityID != "" {
		q += ` AND entity_id = ?`
		args = append(args, entityID)
	}
	if before > 0 {
		q += ` AND id < ?`
		args = append(args, before)
	}
	rows, err := s.db.QueryContext(ctx, q+` ORDER BY id DESC LIMIT ?`, append(args, limit)...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Event{}
	for rows.Next() {
		var e Event
		var ts int64
		var sev string
		var ent, inc sql.NullString
		if err := rows.Scan(&e.ID, &ts, &ent, &e.Kind, &sev, &e.Message, &inc); err != nil {
			return nil, err
		}
		e.At, e.Severity = fromMS(ts), Severity(sev)
		if ent.Valid {
			e.EntityID = &ent.String
		}
		if inc.Valid {
			e.IncidentID = &inc.String
		}
		out = append(out, e)
	}
	return out, rows.Err()
}

// Overview summarizes the house for the dashboard.
func (s *Service) Overview(ctx context.Context) (Overview, error) {
	states, err := s.States(ctx)
	if err != nil {
		return Overview{}, err
	}
	o := Overview{GeneratedAt: s.now().UTC(), Devices: len(states), ByStatus: map[Status]int{
		StatusOnline: 0, StatusDegraded: 0, StatusOffline: 0, StatusUnknown: 0, StatusUnsupported: 0}}
	for _, st := range states {
		o.ByStatus[st.Status]++
	}
	if err := s.db.QueryRowContext(ctx, `SELECT COUNT(*), COALESCE(SUM(severity = 'critical'), 0) FROM mon_incidents WHERE status != 'resolved'`).
		Scan(&o.OpenIncidents, &o.CriticalOpen); err != nil {
		return o, err
	}
	_ = s.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM mon_notifications WHERE read_at IS NULL`).Scan(&o.UnreadNotices)
	o.Integrations = s.integrationList()
	if o.RecentEvents, err = s.Events(ctx, "", 0, 10); err != nil {
		return o, err
	}
	return o, nil
}

// PruneResult reports what retention removed.
type PruneResult struct {
	Samples       int64 `json:"samples"`
	Rollups       int64 `json:"rollups"`
	Logs          int64 `json:"logs"`
	Incidents     int64 `json:"incidents"`
	Events        int64 `json:"events"`
	Notifications int64 `json:"notifications"`
}

// Prune applies the retention policy. Raw samples are removed only after
// their 5-minute aggregates exist (written together on ingest), latest
// values and device states are never pruned, and unresolved incidents are
// never deleted.
func (s *Service) Prune(ctx context.Context) (PruneResult, error) {
	now := s.now()
	day := 24 * time.Hour
	var r PruneResult
	exec := func(dst *int64, q string, args ...any) error {
		res, err := s.db.ExecContext(ctx, q, args...)
		if err != nil {
			return err
		}
		n, _ := res.RowsAffected()
		*dst += n
		return nil
	}
	c := s.cfg
	if err := exec(&r.Samples, `DELETE FROM mon_samples WHERE ts < ?`, ms(now.Add(-time.Duration(c.RawRetentionDays)*day))); err != nil {
		return r, err
	}
	if err := exec(&r.Rollups, `DELETE FROM mon_rollups WHERE bucket < ?`, ms(now.Add(-time.Duration(c.RollupRetentionDays)*day))); err != nil {
		return r, err
	}
	if err := exec(&r.Logs, `DELETE FROM mon_logs WHERE ts < ?`, ms(now.Add(-time.Duration(c.LogRetentionDays)*day))); err != nil {
		return r, err
	}
	if err := exec(&r.Logs, `DELETE FROM mon_logs WHERE id <= (SELECT id FROM mon_logs ORDER BY id DESC LIMIT 1 OFFSET ?)`, c.LogMaxRows); err != nil {
		return r, err
	}
	if c.ResolvedIncidentDays > 0 {
		if err := exec(&r.Incidents, `DELETE FROM mon_incidents WHERE status = 'resolved' AND resolved_at < ?`,
			ms(now.Add(-time.Duration(c.ResolvedIncidentDays)*day))); err != nil {
			return r, err
		}
	}
	if err := exec(&r.Events, `DELETE FROM mon_events WHERE ts < ?`, ms(now.Add(-time.Duration(max(c.RollupRetentionDays, 30))*day))); err != nil {
		return r, err
	}
	if err := exec(&r.Notifications, `DELETE FROM mon_notifications WHERE ts < ?`, ms(now.Add(-time.Duration(c.NotificationRetentionDays)*day))); err != nil {
		return r, err
	}
	if r.Samples+r.Logs > 0 {
		s.log.Info("retention", "samples", r.Samples, "rollups", r.Rollups, "logs", r.Logs, "incidents", r.Incidents)
	}
	return r, nil
}
