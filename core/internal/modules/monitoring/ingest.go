package monitoring

import (
	"context"
	"encoding/json"
	"fmt"
	"math"
	"strings"
	"time"
)

const (
	maxSamplesPerReport = 2000
	maxLogsPerReport    = 500
	rollupBucket        = 5 * time.Minute
)

// SampleIn is one measurement sent by an agent.
type SampleIn struct {
	Metric  string    `json:"metric"`
	Label   string    `json:"label"`
	Value   *float64  `json:"value"`
	At      time.Time `json:"at"`
	Quality Quality   `json:"quality"`
	Reason  string    `json:"reason"`
}

// LogIn is one log line sent by an agent or bot.
type LogIn struct {
	At            time.Time       `json:"at"`
	Level         LogLevel        `json:"level"`
	Source        string          `json:"source"`
	Message       string          `json:"message"`
	CorrelationID string          `json:"correlationId"`
	Fields        json.RawMessage `json:"fields"`
}

// Report is the agent protocol v1 payload: heartbeat + metrics + logs.
type Report struct {
	Agent   AgentInfo  `json:"agent"`
	Bot     *BotStatus `json:"bot"`
	Samples []SampleIn `json:"samples"`
	Logs    []LogIn    `json:"logs"`
	// Dropped counts what the agent discarded from its bounded queue.
	Dropped struct {
		Samples int `json:"samples"`
		Logs    int `json:"logs"`
	} `json:"dropped"`
}

// ReportResult tells the agent what was accepted.
type ReportResult struct {
	AcceptedSamples int       `json:"acceptedSamples"`
	AcceptedLogs    int       `json:"acceptedLogs"`
	DroppedLogs     int       `json:"droppedLogs"`
	ServerTime      time.Time `json:"serverTime"`
	// IntervalSec is the collection interval the server suggests.
	IntervalSec int `json:"intervalSec"`
}

func (r *Report) validate(now time.Time) error {
	v := &ValidationError{}
	if len(r.Samples) > maxSamplesPerReport {
		v.add("samples", fmt.Sprintf("Не больше %d значений в отчёте", maxSamplesPerReport))
	}
	if len(r.Logs) > maxLogsPerReport {
		v.add("logs", fmt.Sprintf("Не больше %d записей журнала в отчёте", maxLogsPerReport))
	}
	if len(r.Agent.Version) > 40 || len(r.Agent.OS) > 40 || len(r.Agent.OSVersion) > 120 || len(r.Agent.Hostname) > 120 || len(r.Agent.Collectors) > 64 {
		v.add("agent", "Слишком длинные сведения об агенте")
	}
	earliest, latest := now.Add(-24*time.Hour), now.Add(5*time.Minute)
	for i, sm := range r.Samples {
		p := fmt.Sprintf("samples[%d]", i)
		if _, ok := metricByID[sm.Metric]; !ok {
			v.add(p+".metric", "Неизвестная метрика (см. GET /monitoring/metric-types)")
		}
		if len([]rune(sm.Label)) > 120 {
			v.add(p+".label", "Метка до 120 символов")
		}
		if sm.At.Before(earliest) || sm.At.After(latest) {
			v.add(p+".at", "Время вне окна −24 ч…+5 мин относительно Core (проверьте часы)")
		}
		switch sm.Quality {
		case QualityOK:
			if sm.Value == nil || math.IsNaN(*sm.Value) || math.IsInf(*sm.Value, 0) {
				v.add(p+".value", "Для quality=ok нужно конечное число")
			}
		case QualityUnsupported, QualityUnavailable:
			if sm.Value != nil {
				v.add(p+".value", "Без значения, если показатель недоступен")
			}
			if strings.TrimSpace(sm.Reason) == "" {
				v.add(p+".reason", "Укажите причину отсутствия значения")
			}
		default:
			v.add(p+".quality", "ok, unsupported или unavailable")
		}
	}
	for i, l := range r.Logs {
		p := fmt.Sprintf("logs[%d]", i)
		if _, ok := levelNum[l.Level]; !ok {
			v.add(p+".level", "debug, info, warning, error или critical")
		}
		if strings.TrimSpace(l.Message) == "" {
			v.add(p+".message", "Пустое сообщение")
		}
		if l.At.Before(earliest) || l.At.After(latest) {
			v.add(p+".at", "Время вне окна −24 ч…+5 мин")
		}
		if len(l.Source) > 120 || len(l.CorrelationID) > 120 {
			v.add(p, "source и correlationId до 120 символов")
		}
	}
	return v.orNil()
}

// Ingest stores one agent report atomically and updates the device state.
func (s *Service) Ingest(ctx context.Context, a Agent, r Report) (ReportResult, error) {
	now := s.now().UTC()
	if err := r.validate(now); err != nil {
		return ReportResult{}, err
	}
	res := ReportResult{ServerTime: now, IntervalSec: 15}
	accepted, rateDropped := s.admitLogs(a.ID, len(r.Logs), now)
	res.DroppedLogs = rateDropped

	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return res, err
	}
	defer tx.Rollback()

	info, _ := json.Marshal(r.Agent)
	var bot any
	if r.Bot != nil {
		b, _ := json.Marshal(r.Bot)
		bot = string(b)
	}
	if _, err := tx.ExecContext(ctx, `UPDATE mon_agents SET last_seen_at = ?, info = ?, bot = COALESCE(?, bot) WHERE id = ?`,
		ms(now), string(info), bot, a.ID); err != nil {
		return res, err
	}

	source := "agent:" + a.Name
	insSample, err := tx.PrepareContext(ctx, `INSERT OR REPLACE INTO mon_samples (entity_id, metric, label, ts, value, quality) VALUES (?,?,?,?,?,?)`)
	if err != nil {
		return res, err
	}
	defer insSample.Close()
	upRollup, err := tx.PrepareContext(ctx, `INSERT INTO mon_rollups (entity_id, metric, label, bucket, n, sum, min, max) VALUES (?,?,?,?,1,?,?,?)
		ON CONFLICT (entity_id, metric, label, bucket) DO UPDATE SET n = n + 1, sum = sum + excluded.sum,
		min = MIN(min, excluded.min), max = MAX(max, excluded.max)`)
	if err != nil {
		return res, err
	}
	defer upRollup.Close()
	upLatest, err := tx.PrepareContext(ctx, `INSERT INTO mon_latest (entity_id, metric, label, ts, value, quality, reason, source) VALUES (?,?,?,?,?,?,?,?)
		ON CONFLICT (entity_id, metric, label) DO UPDATE SET ts = excluded.ts, value = excluded.value, quality = excluded.quality,
		reason = excluded.reason, source = excluded.source WHERE excluded.ts >= mon_latest.ts`)
	if err != nil {
		return res, err
	}
	defer upLatest.Close()

	for _, sm := range r.Samples {
		t := ms(sm.At)
		var val any
		if sm.Value != nil {
			val = *sm.Value
		}
		if _, err := insSample.ExecContext(ctx, a.EntityID, sm.Metric, sm.Label, t, val, string(sm.Quality)); err != nil {
			return res, err
		}
		if sm.Quality == QualityOK {
			b := sm.At.UTC().Truncate(rollupBucket).UnixMilli()
			if _, err := upRollup.ExecContext(ctx, a.EntityID, sm.Metric, sm.Label, b, *sm.Value, *sm.Value, *sm.Value); err != nil {
				return res, err
			}
		}
		if _, err := upLatest.ExecContext(ctx, a.EntityID, sm.Metric, sm.Label, t, val, string(sm.Quality), truncate(Redact(sm.Reason), 300), source); err != nil {
			return res, err
		}
		res.AcceptedSamples++
	}

	if accepted > 0 {
		insLog, err := tx.PrepareContext(ctx, `INSERT INTO mon_logs (ts, entity_id, source, level, message, correlation_id, fields) VALUES (?,?,?,?,?,?,?)`)
		if err != nil {
			return res, err
		}
		defer insLog.Close()
		for _, l := range r.Logs[:accepted] {
			src := strings.TrimSpace(l.Source)
			if src == "" {
				src = source
			} else {
				src = source + "/" + src
			}
			var fields any
			if f := RedactFields(l.Fields); f != nil {
				fields = string(f)
			}
			if _, err := insLog.ExecContext(ctx, ms(l.At), a.EntityID, truncate(src, 160), levelNum[l.Level],
				cleanMessage(l.Message), truncate(l.CorrelationID, 120), fields); err != nil {
				return res, err
			}
			res.AcceptedLogs++
		}
	}
	if err := tx.Commit(); err != nil {
		return res, err
	}
	if r.Dropped.Samples+r.Dropped.Logs > 0 {
		s.logSystem(ctx, LevelWarning, fmt.Sprintf("Агент «%s» отбросил из очереди %d значений и %d записей журнала (Core был недоступен)",
			a.Name, r.Dropped.Samples, r.Dropped.Logs), &a.EntityID)
	}
	s.evaluateThresholds(ctx, a, r.Samples)
	s.RefreshEntity(ctx, a.EntityID)
	return res, nil
}

// rateWindow limits log intake per source per minute.
type rateWindow struct {
	start   time.Time
	count   int
	dropped int
}

// admitLogs returns how many of n log lines may be stored now.
func (s *Service) admitLogs(source string, n int, now time.Time) (accepted, dropped int) {
	s.mu.Lock()
	w := s.logWindows[source]
	if w == nil {
		w = &rateWindow{start: now}
		s.logWindows[source] = w
	}
	var report int
	if now.Sub(w.start) >= time.Minute {
		report = w.dropped
		w.start, w.count, w.dropped = now, 0, 0
	}
	room := s.cfg.LogRatePerMin - w.count
	if room < 0 {
		room = 0
	}
	accepted = min(n, room)
	dropped = n - accepted
	w.count += accepted
	w.dropped += dropped
	s.mu.Unlock()
	if report > 0 {
		s.logSystem(context.Background(), LevelWarning,
			fmt.Sprintf("Источник превысил лимит журнала (%d/мин): отброшено %d записей", s.cfg.LogRatePerMin, report), nil)
	}
	return accepted, dropped
}

// IngestSystemLog stores a Core log record (from the Foundation log sink).
func (s *Service) IngestSystemLog(ctx context.Context, at time.Time, lvl LogLevel, source, msg string, fields json.RawMessage) error {
	acc, _ := s.admitLogs("core", 1, s.now())
	if acc == 0 {
		return nil
	}
	var f any
	if r := RedactFields(fields); r != nil {
		f = string(r)
	}
	_, err := s.db.ExecContext(ctx, `INSERT INTO mon_logs (ts, entity_id, source, level, message, fields) VALUES (?,?,?,?,?,?)`,
		ms(at), nil, truncate(source, 160), levelNum[lvl], cleanMessage(msg), f)
	return err
}

// storeSamples writes Core-collected samples (Docker stats) for an entity.
func (s *Service) storeSamples(ctx context.Context, entityID, source string, samples []SampleIn) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	for _, sm := range samples {
		if _, ok := metricByID[sm.Metric]; !ok || sm.Value == nil {
			continue
		}
		t := ms(sm.At)
		v := *sm.Value
		if _, err := tx.ExecContext(ctx, `INSERT OR REPLACE INTO mon_samples (entity_id, metric, label, ts, value, quality) VALUES (?,?,?,?,?,'ok')`,
			entityID, sm.Metric, sm.Label, t, v); err != nil {
			return err
		}
		b := sm.At.UTC().Truncate(rollupBucket).UnixMilli()
		if _, err := tx.ExecContext(ctx, `INSERT INTO mon_rollups (entity_id, metric, label, bucket, n, sum, min, max) VALUES (?,?,?,?,1,?,?,?)
			ON CONFLICT (entity_id, metric, label, bucket) DO UPDATE SET n = n + 1, sum = sum + excluded.sum,
			min = MIN(min, excluded.min), max = MAX(max, excluded.max)`, entityID, sm.Metric, sm.Label, b, v, v, v); err != nil {
			return err
		}
		if _, err := tx.ExecContext(ctx, `INSERT INTO mon_latest (entity_id, metric, label, ts, value, quality, reason, source) VALUES (?,?,?,?,?,'ok','',?)
			ON CONFLICT (entity_id, metric, label) DO UPDATE SET ts = excluded.ts, value = excluded.value, quality = 'ok', reason = '', source = excluded.source
			WHERE excluded.ts >= mon_latest.ts`, entityID, sm.Metric, sm.Label, t, v, source); err != nil {
			return err
		}
	}
	return tx.Commit()
}
