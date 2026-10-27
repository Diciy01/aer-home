package monitoring

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"aerhome/core/internal/modules/registry"
)

// observation is the raw result of one check, before hysteresis.
type observation struct {
	status Status
	reason string
	kind   string // agent | heartbeat | http | tcp | docker | none
	// failure: the target is really unreachable (counts towards offline).
	failure bool
	// reachable: a positive sign of life (enables "offline" later).
	reachable bool
	contact   *time.Time
	cause     string
}

// entitySettings are optional overrides in Registry attributes.monitoring.
type entitySettings struct {
	Disabled  bool   `json:"disabled"`
	Ports     []int  `json:"ports"`
	Container string `json:"container"`
	URL       string `json:"url"`
	// HeartbeatTimeoutSec overrides the global timeout for this entity's
	// agents (set by Bots from the bot's heartbeat settings).
	HeartbeatTimeoutSec int `json:"heartbeatTimeoutSec"`
}

func settingsOf(e registry.Entity) entitySettings {
	var wrap struct {
		Monitoring entitySettings `json:"monitoring"`
	}
	_ = json.Unmarshal(e.Attributes, &wrap)
	return wrap.Monitoring
}

var defaultPorts = []int{80, 443, 22, 53}

// CheckAll evaluates every active Registry entity with bounded concurrency
// and a timeout per check. Runs on the server whether or not a client is open.
func (s *Service) CheckAll(ctx context.Context) {
	entities, err := s.activeEntities(ctx)
	if err != nil {
		s.setIntegration(IntegrationStatus{ID: "checks", Label: "Проверки доступности", Status: "unavailable", Reason: "Registry недоступен: " + err.Error()})
		return
	}
	sem := make(chan struct{}, s.cfg.MaxConcurrentChecks)
	var wg sync.WaitGroup
	for _, e := range entities {
		select {
		case <-ctx.Done():
			wg.Wait()
			return
		case sem <- struct{}{}:
		}
		wg.Add(1)
		go func() {
			defer wg.Done()
			defer func() { <-sem }()
			cctx, cancel := context.WithTimeout(ctx, time.Duration(s.cfg.CheckTimeoutSec+2)*time.Second)
			defer cancel()
			s.checkEntity(cctx, e)
		}()
	}
	wg.Wait()
	s.setIntegration(IntegrationStatus{ID: "checks", Label: "Проверки доступности", Status: "ok",
		Reason: fmt.Sprintf("%d объектов, каждые %d с", len(entities), s.cfg.CheckIntervalSec)})
}

func (s *Service) activeEntities(ctx context.Context) ([]registry.Entity, error) {
	var out []registry.Entity
	for offset := 0; ; offset += 200 {
		p, err := s.reg.List(ctx, registry.ListFilter{Limit: 200, Offset: offset})
		if err != nil {
			return nil, err
		}
		out = append(out, p.Items...)
		if len(p.Items) < 200 {
			return out, nil
		}
	}
}

// RefreshEntity re-evaluates one entity now (after a report or incident change).
func (s *Service) RefreshEntity(ctx context.Context, id string) {
	e, err := s.reg.Get(ctx, id)
	if err != nil || e.Archived {
		return
	}
	s.checkEntity(ctx, e)
}

func (s *Service) checkEntity(ctx context.Context, e registry.Entity) {
	obs := s.observe(ctx, e)
	// The probe may have used up the check deadline; the result is still saved.
	s.apply(context.WithoutCancel(ctx), e, obs)
}

func (s *Service) observe(ctx context.Context, e registry.Entity) observation {
	set := settingsOf(e)
	if set.Disabled {
		return observation{status: StatusUnsupported, kind: "none", reason: "Мониторинг выключен в атрибутах объекта"}
	}
	agents, _ := s.ListAgents(ctx, e.ID)
	live := agents[:0:0]
	for _, a := range agents {
		if a.RevokedAt == nil {
			live = append(live, a)
		}
	}
	if len(live) > 0 {
		return s.observeAgents(e, live)
	}
	switch e.Type {
	case "website":
		u := set.URL
		if u == "" && e.Address != nil {
			u = *e.Address
		}
		return s.probeHTTP(ctx, u)
	case "docker_container":
		name := set.Container
		if name == "" {
			name = e.Name
		}
		return s.docker.observe(name)
	case "telegram_bot", "application", "process", "service", "automation":
		// A bot without heartbeat can still be watched through its container
		// or its HTTP health endpoint (n8n /healthz), when configured.
		switch {
		case set.Container != "":
			return s.docker.observe(set.Container)
		case set.URL != "":
			return s.probeHTTP(ctx, set.URL)
		}
		return observation{status: StatusUnknown, kind: "none",
			reason: "Нет источника heartbeat: создайте для объекта учётные данные агента или бота (Мониторинг → Агенты)"}
	case "virtual_object", "custom":
		return observation{status: StatusUnsupported, kind: "none", reason: "Для этого типа нет способа проверки"}
	}
	if e.Address == nil || strings.TrimSpace(*e.Address) == "" {
		return observation{status: StatusUnknown, kind: "none", reason: "Нет адреса и агента: проверять нечем"}
	}
	ports := set.Ports
	host := strings.TrimSpace(*e.Address)
	if u, err := url.Parse(host); err == nil && u.Host != "" {
		host = u.Host
	}
	if h, p, err := net.SplitHostPort(host); err == nil {
		if n, err := strconv.Atoi(p); err == nil {
			host, ports = h, []int{n}
		}
	}
	if len(ports) == 0 {
		ports = defaultPorts
	}
	return s.probeTCP(ctx, host, ports)
}

// observeAgents: an entity is online if ANY of its agents reports (dual boot:
// the Windows agent of a PC running Ubuntu is inactive, not an alarm).
func (s *Service) observeAgents(e registry.Entity, agents []Agent) observation {
	var last *time.Time
	var active []Agent
	timeout := time.Duration(s.cfg.HeartbeatTimeoutSec) * time.Second
	if t := settingsOf(e).HeartbeatTimeoutSec; t > 0 {
		timeout = time.Duration(t) * time.Second
	}
	for _, a := range agents {
		if a.LastSeenAt != nil && (last == nil || a.LastSeenAt.After(*last)) {
			last = a.LastSeenAt
		}
		if a.RevokedAt == nil && a.LastSeenAt != nil && s.now().Sub(*a.LastSeenAt) <= timeout {
			active = append(active, a)
		}
	}
	kind := "agent"
	if agents[0].Kind == "bot" {
		kind = "heartbeat"
	}
	if len(active) == 0 {
		if last == nil {
			return observation{status: StatusUnknown, kind: kind, reason: "Агент ещё ни разу не присылал данные"}
		}
		return observation{failure: true, kind: kind, contact: last,
			reason: "Нет heartbeat с " + last.Local().Format("02.01 15:04:05")}
	}
	o := observation{status: StatusOnline, kind: kind, reachable: true, contact: last}
	names := make([]string, 0, len(active))
	for _, a := range active {
		n := a.Name
		if a.Info != nil && a.Info.OS != "" {
			n += " (" + a.Info.OS + ")"
		}
		names = append(names, n)
	}
	o.reason = "Данные от " + strings.Join(names, ", ")
	for _, a := range active {
		if b := a.Bot; b != nil {
			if b.APIOK != nil && !*b.APIOK {
				o.status, o.reason = StatusDegraded, "Бот работает, но API Telegram недоступен"
			}
			if b.LastErrorAt != nil && (b.LastSuccessAt == nil || b.LastErrorAt.After(*b.LastSuccessAt)) {
				o.status = StatusDegraded
				o.reason = "Последнее действие завершилось ошибкой: " + truncate(Redact(b.LastError), 160)
			}
		}
	}
	return o
}

func (s *Service) probeHTTP(ctx context.Context, raw string) observation {
	u, err := url.Parse(strings.TrimSpace(raw))
	if err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Host == "" {
		return observation{status: StatusUnknown, kind: "http", reason: "Адрес не похож на http(s)-URL — проверка невозможна"}
	}
	client := &http.Client{
		Timeout: time.Duration(s.cfg.CheckTimeoutSec) * time.Second,
		CheckRedirect: func(_ *http.Request, via []*http.Request) error {
			if len(via) >= 5 {
				return http.ErrUseLastResponse
			}
			return nil
		},
	}
	req, _ := http.NewRequestWithContext(ctx, http.MethodGet, u.String(), nil)
	req.Header.Set("User-Agent", "AER-HOME-monitoring/1")
	start := s.now()
	resp, err := client.Do(req)
	if err != nil {
		var cert *tls.CertificateVerificationError
		var unk x509.UnknownAuthorityError
		if errors.As(err, &cert) || errors.As(err, &unk) {
			return observation{status: StatusDegraded, kind: "http", reachable: true, reason: "Сайт отвечает, но сертификат TLS не прошёл проверку"}
		}
		if isDNSError(err) {
			return observation{status: StatusUnknown, kind: "http", reason: "Не удалось разрешить имя сайта (DNS)"}
		}
		return observation{failure: true, kind: "http", reason: "Нет ответа по HTTP: " + shortNetErr(err)}
	}
	_, _ = io.CopyN(io.Discard, resp.Body, 1024)
	resp.Body.Close()
	took := s.now().Sub(start).Milliseconds()
	now := s.now().UTC()
	switch {
	case resp.StatusCode >= 500:
		return observation{status: StatusDegraded, kind: "http", reachable: true, contact: &now,
			reason: fmt.Sprintf("HTTP %d за %d мс", resp.StatusCode, took), cause: fmt.Sprintf("Сервер вернул HTTP %d", resp.StatusCode)}
	case resp.StatusCode >= 400:
		return observation{status: StatusDegraded, kind: "http", reachable: true, contact: &now,
			reason: fmt.Sprintf("HTTP %d за %d мс — сервер отвечает, но страница с ошибкой", resp.StatusCode, took)}
	}
	return observation{status: StatusOnline, kind: "http", reachable: true, contact: &now, reason: fmt.Sprintf("HTTP %d за %d мс", resp.StatusCode, took)}
}

// probeTCP checks reachability by TCP connect. A refused connection proves
// the host is up; silence on every port is "no answer", not proof of power-off.
func (s *Service) probeTCP(ctx context.Context, host string, ports []int) observation {
	// All ports in parallel within one timeout budget: a silent host costs
	// one timeout, not one per port.
	ctx, cancel := context.WithTimeout(ctx, time.Duration(s.cfg.CheckTimeoutSec)*time.Second)
	defer cancel()
	type res struct {
		port int
		err  error
	}
	out := make(chan res, len(ports))
	for _, p := range ports {
		go func() {
			var d net.Dialer
			conn, err := d.DialContext(ctx, "tcp", net.JoinHostPort(host, strconv.Itoa(p)))
			if err == nil {
				conn.Close()
			}
			out <- res{p, err}
		}()
	}
	var lastErr error
	for range ports {
		r := <-out
		now := s.now().UTC()
		switch {
		case r.err == nil:
			return observation{status: StatusOnline, kind: "tcp", reachable: true, contact: &now, reason: fmt.Sprintf("Отвечает на TCP-порт %d", r.port)}
		case errors.Is(r.err, syscall.ECONNREFUSED):
			return observation{status: StatusOnline, kind: "tcp", reachable: true, contact: &now,
				reason: fmt.Sprintf("Хост в сети (порт %d закрыт, но ответил отказом)", r.port)}
		case isDNSError(r.err):
			return observation{status: StatusUnknown, kind: "tcp", reason: "Не удалось разрешить имя хоста (DNS)"}
		}
		lastErr = r.err
	}
	ps := make([]string, len(ports))
	for i, p := range ports {
		ps[i] = strconv.Itoa(p)
	}
	return observation{failure: true, kind: "tcp",
		reason: "Не отвечает на TCP-порты " + strings.Join(ps, ", ") + " (" + shortNetErr(lastErr) + ")"}
}

func isDNSError(err error) bool {
	var d *net.DNSError
	return errors.As(err, &d)
}

func shortNetErr(err error) string {
	switch {
	case err == nil:
		return "нет ответа"
	case errors.Is(err, context.DeadlineExceeded), strings.Contains(err.Error(), "timeout"):
		return "тайм-аут"
	case errors.Is(err, syscall.EHOSTUNREACH):
		return "хост недостижим"
	case errors.Is(err, syscall.ENETUNREACH):
		return "сеть недостижима"
	case errors.Is(err, syscall.ECONNREFUSED):
		return "соединение отклонено"
	case errors.Is(err, syscall.ECONNRESET):
		return "соединение сброшено"
	}
	return truncate(Redact(err.Error()), 120)
}

type stateRow struct {
	status        Status
	reason        string
	failures      int
	everReachable bool
	exists        bool
}

func (s *Service) loadState(ctx context.Context, id string) stateRow {
	var r stateRow
	var st string
	var ever int
	err := s.db.QueryRowContext(ctx, `SELECT status, reason, failures, ever_reachable FROM mon_state WHERE entity_id = ?`, id).
		Scan(&st, &r.reason, &r.failures, &ever)
	if err == nil {
		r.status, r.everReachable, r.exists = Status(st), ever == 1, true
	}
	return r
}

// apply turns an observation into a state with hysteresis: offline only
// after N consecutive failures, and only for targets that were reachable
// before (a device that never answered stays "unknown").
func (s *Service) apply(ctx context.Context, e registry.Entity, o observation) {
	s.stateMu.Lock() // serialize state transitions (reports and checks race)
	defer s.stateMu.Unlock()
	now := s.now().UTC()
	prev := s.loadState(ctx, e.ID)
	failures := 0
	ever := prev.everReachable || o.reachable
	status, reason := o.status, o.reason
	if o.failure {
		failures = prev.failures + 1
		switch {
		case failures < s.cfg.FailuresBeforeOffline && prev.exists:
			status = prev.status
			reason = fmt.Sprintf("%s — проверка не прошла (%d из %d), ждём подтверждения", o.reason, failures, s.cfg.FailuresBeforeOffline)
		case failures < s.cfg.FailuresBeforeOffline:
			status = StatusUnknown
		case ever || o.kind == "agent" || o.kind == "heartbeat":
			status = StatusOffline
		default:
			status = StatusUnknown
			reason = o.reason + ". Устройство ни разу не ответило — возможно, оно блокирует проверки; это не доказывает, что оно выключено"
		}
	}
	if status == StatusOnline {
		if titles := s.openProblemTitles(ctx, e.ID); len(titles) > 0 {
			status, reason = StatusDegraded, strings.Join(titles, "; ")
		}
	}
	var contact any
	if o.contact != nil {
		contact = ms(*o.contact)
	}
	changed := !prev.exists || prev.status != status
	changedAt := any(nil)
	if changed {
		changedAt = ms(now)
	}
	_, err := s.db.ExecContext(ctx, `INSERT INTO mon_state (entity_id, status, reason, check_kind, last_contact, last_check, changed_at, failures, ever_reachable)
		VALUES (?,?,?,?,?,?,?,?,?)
		ON CONFLICT (entity_id) DO UPDATE SET status = excluded.status, reason = excluded.reason, check_kind = excluded.check_kind,
		last_contact = COALESCE(excluded.last_contact, mon_state.last_contact), last_check = excluded.last_check,
		changed_at = COALESCE(excluded.changed_at, mon_state.changed_at), failures = excluded.failures, ever_reachable = excluded.ever_reachable`,
		e.ID, string(status), truncate(reason, 500), o.kind, contact, ms(now), changedAt, failures, boolInt(ever))
	if err != nil {
		s.log.Warn("save state", "err", err)
		return
	}
	if !changed {
		return
	}
	id := e.ID
	if prev.exists {
		sev := SeverityInfo
		if status == StatusOffline {
			sev = severityForType(e.Type)
		}
		s.event(ctx, &id, "status_changed", sev, fmt.Sprintf("«%s»: %s → %s. %s", e.Name, statusRU(prev.status), statusRU(status), reason), nil)
	}
	key := "availability:" + e.ID
	switch {
	case status == StatusOffline:
		s.openIncident(ctx, incidentSpec{
			key: key, title: offlineTitle(e, o.kind), source: "availability/" + o.kind, entityID: &id,
			severity: severityForType(e.Type), cause: o.cause, message: reason,
		})
	case prev.status == StatusOffline && (status == StatusOnline || status == StatusDegraded):
		s.resolveIncident(ctx, key, "Снова на связи: "+reason)
	}
}

func boolInt(b bool) int {
	if b {
		return 1
	}
	return 0
}

// openProblemTitles lists unresolved non-availability incidents of an entity
// (low disk, temperature, stopped service): they make it "degraded".
func (s *Service) openProblemTitles(ctx context.Context, id string) []string {
	rows, err := s.db.QueryContext(ctx, `SELECT title FROM mon_incidents WHERE entity_id = ? AND status != 'resolved'
		AND key NOT LIKE 'availability:%' AND severity != 'info' ORDER BY opened_at LIMIT 3`, id)
	if err != nil {
		return nil
	}
	defer rows.Close()
	var out []string
	for rows.Next() {
		var t string
		if rows.Scan(&t) == nil {
			out = append(out, t)
		}
	}
	return out
}

func severityForType(t string) Severity {
	switch t {
	case "server", "router", "website", "database", "docker_container", "telegram_bot", "network_device", "storage":
		return SeverityCritical
	}
	return SeverityWarning
}

func offlineTitle(e registry.Entity, kind string) string {
	switch {
	case e.Type == "telegram_bot":
		return "Бот «" + e.Name + "» перестал отправлять heartbeat"
	case kind == "agent":
		return "«" + e.Name + "» перестал отвечать (нет данных от агента)"
	case e.Type == "website":
		return "Сайт «" + e.Name + "» недоступен"
	case e.Type == "docker_container":
		return "Контейнер «" + e.Name + "» не работает"
	}
	return "«" + e.Name + "» недоступен"
}

func statusRU(s Status) string {
	switch s {
	case StatusOnline:
		return "в сети"
	case StatusDegraded:
		return "есть проблемы"
	case StatusOffline:
		return "недоступен"
	case StatusUnsupported:
		return "не поддерживается"
	}
	return "неизвестно"
}

// event appends to the event history.
func (s *Service) event(ctx context.Context, entityID *string, kind string, sev Severity, msg string, incidentID *string) {
	_, _ = s.db.ExecContext(ctx, `INSERT INTO mon_events (ts, entity_id, kind, severity, message, incident_id) VALUES (?,?,?,?,?,?)`,
		ms(s.now()), nullStr(entityID), kind, string(sev), truncate(msg, 1000), nullStr(incidentID))
}
