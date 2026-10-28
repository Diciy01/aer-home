package network

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"log/slog"
	"net"
	"net/http"
	"slices"
	"strings"
	"sync"
	"time"

	"aerhome/core/internal/foundation/config"
	"aerhome/core/internal/modules/monitoring"
	"aerhome/core/internal/modules/registry"
)

// ErrTooSoon: a manual check was requested again within a few seconds.
var ErrTooSoon = errors.New("too soon")

// logEvery throttles "still failing" log lines of one check.
const logEvery = 5 * time.Minute

// Service runs the network checks and builds the overview.
type Service struct {
	db   *sql.DB
	reg  registry.Reader
	mon  *monitoring.Service
	cfg  config.Network
	mcfg config.Monitoring
	log  *slog.Logger
	now  func() time.Time
	dial Dialer
	http *http.Client

	runMu    sync.Mutex // one round of checks at a time
	mu       sync.Mutex
	lastRun  time.Time
	lastManu time.Time
}

// NewService builds the service; now may be nil.
func NewService(db *sql.DB, reg registry.Reader, mon *monitoring.Service, cfg config.Network, mcfg config.Monitoring, log *slog.Logger, now func() time.Time) *Service {
	if now == nil {
		now = time.Now
	}
	if log == nil {
		log = slog.New(slog.DiscardHandler)
	}
	d := &net.Dialer{}
	timeout := time.Duration(cfg.TimeoutSec) * time.Second
	client := &http.Client{
		Timeout:   timeout,
		Transport: &http.Transport{DialContext: d.DialContext, Proxy: nil, ResponseHeaderTimeout: timeout},
		// Never follow redirects: a read-only probe must not wander off.
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
	}
	return &Service{db: db, reg: reg, mon: mon, cfg: cfg, mcfg: mcfg, log: log, now: now, dial: d.DialContext, http: client}
}

func msT(t time.Time) int64 { return t.UTC().UnixMilli() }

func fromNull(v sql.NullInt64) *time.Time {
	if !v.Valid {
		return nil
	}
	t := time.UnixMilli(v.Int64).UTC()
	return &t
}

// ---- checks ----

type target struct {
	key, kind, name, entityID string
	severity                  monitoring.Severity
	run                       func(ctx context.Context) result
}

func (s *Service) targets() []target {
	timeout := time.Duration(s.cfg.TimeoutSec) * time.Second
	out := []target{{key: "internet", kind: "internet", name: "Интернет", severity: monitoring.SeverityCritical,
		run: func(ctx context.Context) result { return probeInternet(ctx, s.dial, s.cfg.Internet.Targets, timeout) }}}
	for _, r := range s.cfg.Routers {
		if r.UPnPURL == "" {
			continue
		}
		name := "Роутер (WAN)"
		if e, err := s.reg.Get(context.Background(), r.EntityID); err == nil {
			name = "Роутер «" + e.Name + "» (WAN)"
		}
		out = append(out, target{key: "router:" + r.EntityID, kind: "router_wan", name: name, entityID: r.EntityID,
			severity: monitoring.SeverityCritical,
			run:      func(ctx context.Context) result { return probeUPnP(ctx, s.http, r.UPnPURL) }})
	}
	for _, sh := range s.cfg.Sunshine {
		name := sh.Name
		if name == "" {
			name = "Sunshine"
		}
		out = append(out, target{key: "sunshine:" + sh.ID, kind: "sunshine", name: name, entityID: sh.EntityID,
			severity: monitoring.SeverityWarning,
			run: func(ctx context.Context) result {
				return probeSunshine(ctx, s.http, s.dial, sh.ServerInfoURL, sh.WebURL)
			}})
	}
	return out
}

// RunChecks performs one round of all configured checks (in parallel).
func (s *Service) RunChecks(ctx context.Context) {
	s.runMu.Lock()
	defer s.runMu.Unlock()
	ts := s.targets()
	var wg sync.WaitGroup
	for _, t := range ts {
		wg.Add(1)
		go func() {
			defer wg.Done()
			cctx, cancel := context.WithTimeout(ctx, time.Duration(s.cfg.TimeoutSec+2)*time.Second)
			defer cancel()
			r := t.run(cctx)
			s.settle(context.WithoutCancel(ctx), t, r)
		}()
	}
	wg.Wait()
	s.prune(ctx, ts)
	s.mu.Lock()
	s.lastRun = s.now()
	s.mu.Unlock()
}

// CheckNow runs checks on request (and refreshes Monitoring for network
// devices); at most once per 5 s.
func (s *Service) CheckNow(ctx context.Context) error {
	s.mu.Lock()
	if s.now().Sub(s.lastManu) < 5*time.Second {
		s.mu.Unlock()
		return ErrTooSoon
	}
	s.lastManu = s.now()
	s.mu.Unlock()
	for _, d := range s.deviceEntities(ctx) {
		s.mon.RefreshEntity(ctx, d.ID)
	}
	s.RunChecks(ctx)
	return nil
}

type row struct {
	status   Status
	reason   string
	failures int
	lastLog  *time.Time
	exists   bool
}

func (s *Service) load(ctx context.Context, key string) row {
	var r row
	var st string
	var ll sql.NullInt64
	err := s.db.QueryRowContext(ctx, `SELECT status, reason, failures, last_log FROM net_checks WHERE key = ?`, key).
		Scan(&st, &r.reason, &r.failures, &ll)
	if err == nil {
		r.status, r.exists, r.lastLog = Status(st), true, fromNull(ll)
	}
	return r
}

// settle applies a probe result: confirmation of failures, state change
// history (Monitoring events + logs), incidents and their resolution.
func (s *Service) settle(ctx context.Context, t target, r result) {
	now := s.now().UTC()
	prev := s.load(ctx, t.key)
	status, reason, failures := StatusUp, r.reason, 0
	switch {
	case r.ok:
	case r.status == StatusUnconfigured:
		status = StatusUnconfigured
	default:
		failures = prev.failures + 1
		status = r.status
		if failures < s.cfg.FailuresBeforeDown && prev.status == StatusUp {
			status = StatusUp
			reason = r.reason + " — ждём подтверждения следующей проверкой"
		}
	}
	reason = monitoring.Redact(reason)
	det, _ := json.Marshal(r.details)
	if r.details == nil {
		det = []byte("{}")
	}
	changed := !prev.exists || prev.status != status
	var lastOK, changedAt any
	if r.ok {
		lastOK = msT(now)
	}
	if changed {
		changedAt = msT(now)
	}
	logNow := false
	if !r.ok && status != StatusUnconfigured && (changed || prev.lastLog == nil || now.Sub(*prev.lastLog) >= logEvery) {
		logNow = true
	}
	if changed && status == StatusUp {
		logNow = true
	}
	var lastLog any
	if logNow {
		lastLog = msT(now)
	}
	if _, err := s.db.ExecContext(ctx, `INSERT INTO net_checks (key, kind, name, entity_id, status, reason, latency_ms, details, failures, last_check, last_ok, changed_at, last_log)
		VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT (key) DO UPDATE SET kind = excluded.kind, name = excluded.name,
		entity_id = excluded.entity_id, status = excluded.status, reason = excluded.reason, latency_ms = excluded.latency_ms,
		details = excluded.details, failures = excluded.failures, last_check = excluded.last_check,
		last_ok = COALESCE(excluded.last_ok, net_checks.last_ok), changed_at = COALESCE(excluded.changed_at, net_checks.changed_at),
		last_log = COALESCE(excluded.last_log, net_checks.last_log)`,
		t.key, t.kind, t.name, t.entityID, string(status), reason, ms(r.latency), string(det), failures, msT(now),
		lastOK, changedAt, lastLog); err != nil {
		s.log.Warn("network check state", "key", t.key, "err", err)
		return
	}
	source := "net." + t.kind
	if logNow {
		lvl := monitoring.LevelWarning
		if status == StatusUp {
			lvl = monitoring.LevelInfo
		}
		if err := s.mon.AppendLog(ctx, t.entityID, source, lvl, t.name+": "+reason); err != nil {
			s.log.Warn("network log", "err", err)
		}
	}
	integ := map[Status]string{StatusUp: "ok", StatusUnconfigured: "disabled"}[status]
	if integ == "" {
		integ = "unavailable"
	}
	s.mon.SetIntegrationStatus("net:"+t.key, t.name, integ, reason)
	if !changed || status == StatusUnconfigured {
		return
	}
	incKey := "network:" + t.key
	switch status {
	case StatusUp:
		if prev.exists && prev.status != StatusUnknown && prev.status != StatusUnconfigured {
			s.mon.RecordEvent(ctx, t.entityID, "net_recovered", monitoring.SeverityInfo, t.name+": восстановлено. "+reason)
		}
		s.mon.ResolveIncident(ctx, incKey, t.name+": восстановлено")
	case StatusDown, StatusError:
		title := t.name + ": недоступно"
		if status == StatusError {
			title = t.name + ": ошибка проверки"
		}
		s.mon.RecordEvent(ctx, t.entityID, "net_"+string(status), t.severity, t.name+": "+reason)
		s.mon.RaiseIncident(ctx, incKey, title, "network", t.entityID, t.severity, reason, reason)
	}
}

// prune forgets checks that are no longer configured.
func (s *Service) prune(ctx context.Context, ts []target) {
	keys := make([]any, 0, len(ts))
	ph := make([]string, 0, len(ts))
	for _, t := range ts {
		keys = append(keys, t.key)
		ph = append(ph, "?")
	}
	_, _ = s.db.ExecContext(ctx, `DELETE FROM net_checks WHERE key NOT IN (`+strings.Join(ph, ",")+`)`, keys...)
}

// Run checks every IntervalSec until ctx ends.
func (s *Service) Run(ctx context.Context) {
	s.RunChecks(ctx)
	t := time.NewTicker(time.Duration(s.cfg.IntervalSec) * time.Second)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			s.RunChecks(ctx)
		}
	}
}

// ---- overview ----

func (s *Service) check(ctx context.Context, key string) (Check, bool) {
	var c Check
	var st, det string
	var lat sql.NullFloat64
	var lc, lo, ch sql.NullInt64
	err := s.db.QueryRowContext(ctx, `SELECT key, kind, name, entity_id, status, reason, latency_ms, details, failures, last_check, last_ok, changed_at
		FROM net_checks WHERE key = ?`, key).Scan(&c.Key, &c.Kind, &c.Name, &c.EntityID, &st, &c.Reason, &lat, &det, &c.Failures, &lc, &lo, &ch)
	if err != nil {
		return c, false
	}
	c.Status, c.LastCheck, c.LastOK, c.ChangedAt = Status(st), fromNull(lc), fromNull(lo), fromNull(ch)
	if lat.Valid {
		v := lat.Float64
		c.LatencyMs = &v
	}
	if det != "{}" && det != "null" {
		c.Details = &Details{}
		_ = json.Unmarshal([]byte(det), c.Details)
	}
	stale := 3 * time.Duration(s.cfg.IntervalSec) * time.Second
	c.Stale = c.LastCheck != nil && s.now().Sub(*c.LastCheck) > stale
	return c, true
}

func (s *Service) checkOr(ctx context.Context, key, kind, name, entityID string, unconfigured string) Check {
	if c, ok := s.check(ctx, key); ok {
		return c
	}
	if unconfigured != "" {
		return Check{Key: key, Kind: kind, Name: name, EntityID: entityID, Status: StatusUnconfigured, Reason: unconfigured}
	}
	return Check{Key: key, Kind: kind, Name: name, EntityID: entityID, Status: StatusUnknown, Reason: "Ещё не проверялось"}
}

var deviceTypes = []string{"router", "network_device", "television"}

func (s *Service) deviceEntities(ctx context.Context) []registry.Entity {
	var out []registry.Entity
	for offset := 0; ; offset += 200 {
		p, err := s.reg.List(ctx, registry.ListFilter{Types: deviceTypes, Limit: 200, Offset: offset})
		if err != nil {
			return out
		}
		out = append(out, p.Items...)
		if offset+len(p.Items) >= p.Total || len(p.Items) == 0 {
			return out
		}
	}
}

// device turns Monitoring's observation into the five network states.
func (s *Service) device(ctx context.Context, e registry.Entity) DeviceView {
	d := DeviceView{EntityID: e.ID, Name: e.Name, Type: e.Type, Status: StatusUnknown, Reason: "Мониторинг ещё не проверял устройство"}
	if e.Address != nil {
		d.Address = *e.Address
	}
	st, err := s.mon.State(ctx, e.ID)
	if err != nil {
		d.Status, d.Reason = StatusError, "Нет данных Мониторинга"
		return d
	}
	d.MonitoringStatus, d.Reason = string(st.Status), st.Reason
	d.LastContact, d.LastCheck, d.ChangedAt, d.OpenIncidents = st.LastContactAt, st.LastCheckAt, st.ChangedAt, st.OpenIncidents
	switch st.Status {
	case monitoring.StatusOnline, monitoring.StatusDegraded:
		d.Status = StatusUp
	case monitoring.StatusOffline:
		d.Status = StatusDown
	case monitoring.StatusUnsupported:
		d.Status = StatusUnconfigured
	default:
		switch {
		case st.CheckKind == "none":
			d.Status = StatusUnconfigured
		case st.LastCheckAt == nil:
			d.Status = StatusUnknown
		default:
			d.Status = StatusError
		}
	}
	if lat, err := s.mon.Latest(ctx, e.ID, false); err == nil {
		for _, m := range lat {
			if m.Metric == "net.latency" && m.Value != nil {
				v, at := *m.Value, m.At
				d.LatencyMs, d.LatencyAt = &v, &at
			}
		}
	}
	stale := 3 * time.Duration(s.mcfg.CheckIntervalSec) * time.Second
	d.Stale = d.LastCheck != nil && s.now().Sub(*d.LastCheck) > stale
	return d
}

// Overview builds the network view.
func (s *Service) Overview(ctx context.Context) (Overview, error) {
	o := Overview{IntervalSec: s.cfg.IntervalSec, GeneratedAt: s.now().UTC(), Routers: []RouterView{}, Devices: []DeviceView{},
		TVs: []DeviceView{}, Sunshine: []SunshineView{}, Incidents: []monitoring.Incident{}, Recent: []monitoring.LogEntry{}}
	unconf := ""
	if len(s.cfg.Internet.Targets) == 0 {
		unconf = "Не настроено: укажите цели network.internet.targets в конфигурации Core"
	}
	o.Internet = s.checkOr(ctx, "internet", "internet", "Интернет", "", unconf)
	adapters := map[string]config.NetRouter{}
	for _, r := range s.cfg.Routers {
		adapters[r.EntityID] = r
	}
	ents := s.deviceEntities(ctx)
	byID := map[string]DeviceView{}
	netIDs := map[string]bool{}
	for _, e := range ents {
		d := s.device(ctx, e)
		byID[e.ID], netIDs[e.ID] = d, true
		switch e.Type {
		case "router":
			rv := RouterView{Device: d, Adapter: "none",
				AdapterNote: "Только доступность и задержка: API роутера для чтения не настроен (поддерживается UPnP IGD, если он включён на роутере)"}
			if a, ok := adapters[e.ID]; ok && a.UPnPURL != "" {
				rv.Adapter, rv.AdapterNote = "upnp", "UPnP IGD: только чтение состояния WAN"
				w := s.checkOr(ctx, "router:"+e.ID, "router_wan", "Роутер «"+e.Name+"» (WAN)", e.ID, "")
				rv.WAN = &w
			}
			o.Routers = append(o.Routers, rv)
		case "television":
			o.TVs = append(o.TVs, d)
		default:
			o.Devices = append(o.Devices, d)
		}
	}
	for _, sh := range s.cfg.Sunshine {
		name := sh.Name
		if name == "" {
			name = "Sunshine"
		}
		v := SunshineView{ID: sh.ID, Name: name, WebURL: sh.WebURL,
			Check: s.checkOr(ctx, "sunshine:"+sh.ID, "sunshine", name, sh.EntityID, "")}
		for _, pair := range []struct {
			id  string
			dst **DeviceView
		}{{sh.EntityID, &v.Entity}, {sh.TVEntityID, &v.TV}} {
			if pair.id == "" {
				continue
			}
			d, ok := byID[pair.id]
			if !ok {
				e, err := s.reg.Get(ctx, pair.id)
				if err != nil {
					continue
				}
				d = s.device(ctx, e)
			}
			*pair.dst = &d
			netIDs[pair.id] = true
		}
		o.Sunshine = append(o.Sunshine, v)
	}
	if p, err := s.mon.Incidents(ctx, monitoring.IncidentFilter{Status: "active", Limit: 200}); err == nil {
		for _, i := range p.Items {
			if i.Source == "network" || (i.EntityID != nil && netIDs[*i.EntityID]) {
				o.Incidents = append(o.Incidents, i)
			}
		}
	}
	if len(o.Incidents) > 20 {
		o.Incidents = o.Incidents[:20]
	}
	if p, err := s.mon.Logs(ctx, monitoring.LogFilter{Source: "net.", Limit: 15}); err == nil {
		o.Recent = p.Items
	}
	o.Summary = summarize(o, len(ents))
	return o, nil
}

func summarize(o Overview, devices int) Summary {
	s := Summary{Level: "ok", Issues: []string{}}
	worse := func(l string) {
		rank := map[string]int{"ok": 0, "warning": 1, "critical": 2}
		if rank[l] > rank[s.Level] {
			s.Level = l
		}
	}
	switch o.Internet.Status {
	case StatusDown:
		s.Issues = append(s.Issues, "Нет доступа в интернет")
		worse("critical")
	case StatusError:
		s.Issues = append(s.Issues, "Проверка интернета не удалась")
		worse("warning")
	}
	for _, r := range o.Routers {
		if r.Device.Status == StatusDown {
			s.Issues = append(s.Issues, "Роутер «"+r.Device.Name+"» не отвечает")
			worse("critical")
		}
		switch {
		case r.WAN == nil:
		case r.WAN.Status == StatusDown:
			s.Issues = append(s.Issues, "Роутер «"+r.Device.Name+"» сообщает: WAN не подключён")
			worse("critical")
		case r.WAN.Status == StatusError:
			s.Issues = append(s.Issues, "Роутер «"+r.Device.Name+"»: состояние WAN не получено")
			worse("warning")
		}
	}
	down := 0
	for _, d := range slices.Concat(o.Devices, o.TVs) {
		if d.Status == StatusDown {
			down++
		}
	}
	if down > 0 {
		s.Issues = append(s.Issues, "Не отвечают устройства: "+itoa(down))
		worse("warning")
	}
	for _, sh := range o.Sunshine {
		switch sh.Check.Status {
		case StatusDown:
			s.Issues = append(s.Issues, "Sunshine «"+sh.Name+"» не отвечает")
			worse("warning")
		case StatusError:
			s.Issues = append(s.Issues, "Sunshine «"+sh.Name+"»: ошибка проверки")
			worse("warning")
		}
	}
	configured := o.Internet.Status != StatusUnconfigured || devices > 0 || len(o.Sunshine) > 0
	switch {
	case !configured:
		s.Level, s.Title = "unconfigured", "Сеть не настроена: добавьте роутер в «Устройствах» и цели проверки интернета в конфигурации Core"
	case len(s.Issues) == 0:
		s.Title = "Сеть в порядке"
	default:
		s.Title = s.Issues[0]
	}
	return s
}

func itoa(n int) string {
	b, _ := json.Marshal(n)
	return string(b)
}
