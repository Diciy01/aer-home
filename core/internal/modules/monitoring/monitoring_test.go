package monitoring

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"aerhome/core/internal/foundation/config"
	"aerhome/core/internal/foundation/module"
	"aerhome/core/internal/foundation/storage"
	"aerhome/core/internal/modules/registry"
)

// clock is a controllable time source.
type clock struct {
	mu sync.Mutex
	t  time.Time
}

func (c *clock) now() time.Time { c.mu.Lock(); defer c.mu.Unlock(); return c.t }
func (c *clock) add(d time.Duration) {
	c.mu.Lock()
	c.t = c.t.Add(d)
	c.mu.Unlock()
}

type fixture struct {
	db  *sql.DB
	reg *registry.Service
	svc *Service
	clk *clock
	ctx context.Context
}

func newFixture(t *testing.T, mut ...func(*config.Monitoring)) *fixture {
	t.Helper()
	ctx := context.Background()
	db, err := storage.Open(ctx, filepath.Join(t.TempDir(), "test.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { db.Close() })
	rm, err := registry.Factory(registry.DefaultCatalog())(module.Deps{DB: db})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := storage.Migrate(ctx, db, registry.Name, rm.Migrations()); err != nil {
		t.Fatal(err)
	}
	if n, err := storage.Migrate(ctx, db, Name, migrations); err != nil || n != 1 {
		t.Fatalf("migrate: n=%d err=%v", n, err)
	}
	if n, err := storage.Migrate(ctx, db, Name, migrations); err != nil || n != 0 {
		t.Fatalf("re-migrate must be a no-op: n=%d err=%v", n, err)
	}
	cfg := config.DefaultMonitoring()
	cfg.CheckTimeoutSec = 1
	cfg.Docker.Enabled = false
	for _, m := range mut {
		m(&cfg)
	}
	clk := &clock{t: time.Date(2026, 10, 27, 12, 0, 0, 0, time.UTC)}
	reg := rm.(*registry.Module).Service().(*registry.Service)
	return &fixture{db: db, reg: reg, svc: NewService(db, reg, cfg, nil, clk.now), clk: clk, ctx: ctx}
}

func (f *fixture) entity(t *testing.T, name, typ string, addr ...string) registry.Entity {
	t.Helper()
	in := registry.NewEntity{Name: name, Type: typ}
	if len(addr) > 0 {
		in.Address = &addr[0]
	}
	e, err := f.reg.Create(f.ctx, in)
	if err != nil {
		t.Fatal(err)
	}
	return e
}

func (f *fixture) agent(t *testing.T, entityID, name, kind string) (Agent, string) {
	t.Helper()
	c, err := f.svc.CreateAgent(f.ctx, entityID, name, kind)
	if err != nil {
		t.Fatal(err)
	}
	a, ok := f.svc.Authenticate(f.ctx, c.Token)
	if !ok {
		t.Fatal("fresh token must authenticate")
	}
	return a, c.Token
}

func val(v float64) *float64 { return &v }

func (f *fixture) report(t *testing.T, a Agent, samples ...SampleIn) ReportResult {
	t.Helper()
	for i := range samples {
		if samples[i].At.IsZero() {
			samples[i].At = f.clk.now()
		}
		if samples[i].Quality == "" {
			samples[i].Quality = QualityOK
		}
	}
	res, err := f.svc.Ingest(f.ctx, a, Report{Agent: AgentInfo{Version: "0.1.0", OS: "linux"}, Samples: samples})
	if err != nil {
		t.Fatalf("ingest: %v", err)
	}
	return res
}

func (f *fixture) state(t *testing.T, id string) DeviceState {
	t.Helper()
	st, err := f.svc.State(f.ctx, id)
	if err != nil {
		t.Fatal(err)
	}
	return st
}

func (f *fixture) incidents(t *testing.T, status string) []Incident {
	t.Helper()
	p, err := f.svc.Incidents(f.ctx, IncidentFilter{Status: status, Limit: 200})
	if err != nil {
		t.Fatal(err)
	}
	return p.Items
}

func TestAgentCredentialsAndRevocation(t *testing.T) {
	f := newFixture(t)
	pc := f.entity(t, "ПК (тест)", "computer")
	srv := f.entity(t, "Сервер (тест)", "server")
	a, token := f.agent(t, pc.ID, "ubuntu", "host")
	if !strings.HasPrefix(token, "aer1."+a.ID+".") {
		t.Fatalf("token format: %q", token)
	}
	var hash []byte
	if err := f.db.QueryRow(`SELECT secret_hash FROM mon_agents WHERE id = ?`, a.ID).Scan(&hash); err != nil || len(hash) != 32 {
		t.Fatalf("only a SHA-256 hash is stored: %v %d", err, len(hash))
	}
	if strings.Contains(string(hash), token[len(token)-64:]) {
		t.Fatal("secret stored in clear")
	}
	for _, bad := range []string{"", "aer1.x.y", token[:len(token)-1] + "0", strings.Replace(token, a.ID, srv.ID, 1)} {
		if _, ok := f.svc.Authenticate(f.ctx, bad); ok {
			t.Fatalf("token %q must be rejected", bad)
		}
	}
	// The entity always comes from the credential: no impersonation.
	f.report(t, a, SampleIn{Metric: "cpu.usage", Value: val(12)})
	if got := f.state(t, pc.ID).KeyMetrics; len(got) != 1 || *got[0].Value != 12 {
		t.Fatalf("metric not stored for own entity: %+v", got)
	}
	if len(f.state(t, srv.ID).KeyMetrics) != 0 {
		t.Fatal("agent wrote into another entity")
	}
	if _, err := f.svc.RevokeAgent(f.ctx, a.ID); err != nil {
		t.Fatal(err)
	}
	if _, ok := f.svc.Authenticate(f.ctx, token); ok {
		t.Fatal("revoked token still works")
	}
	if _, err := f.svc.CreateAgent(f.ctx, "00000000-0000-4000-8000-000000000000", "x", "host"); err != ErrEntityMissing {
		t.Fatalf("unknown entity: %v", err)
	}
}

func TestIngestValidationAndHistory(t *testing.T) {
	f := newFixture(t)
	pc := f.entity(t, "ПК (тест)", "computer")
	a, _ := f.agent(t, pc.ID, "ubuntu", "host")
	bad := []Report{
		{Samples: []SampleIn{{Metric: "browser.history", Value: val(1), At: f.clk.now(), Quality: QualityOK}}},
		{Samples: []SampleIn{{Metric: "cpu.usage", At: f.clk.now(), Quality: QualityOK}}},
		{Samples: []SampleIn{{Metric: "gpu.usage", Value: val(1), At: f.clk.now(), Quality: QualityUnsupported, Reason: "x"}}},
		{Samples: []SampleIn{{Metric: "gpu.usage", At: f.clk.now(), Quality: QualityUnsupported}}},
		{Samples: []SampleIn{{Metric: "cpu.usage", Value: val(1), At: f.clk.now().Add(-48 * time.Hour), Quality: QualityOK}}},
	}
	for i, r := range bad {
		if _, err := f.svc.Ingest(f.ctx, a, r); err == nil {
			t.Errorf("bad report %d accepted", i)
		}
	}
	start := f.clk.now()
	for i := 0; i < 120; i++ { // 30 minutes at 15 s
		f.report(t, a,
			SampleIn{Metric: "cpu.usage", Value: val(float64(i % 50))},
			SampleIn{Metric: "disk.used_percent", Label: "/", Value: val(40)},
			SampleIn{Metric: "gpu.temperature", Quality: QualityUnsupported, Reason: "Нет датчика"})
		f.clk.add(15 * time.Second)
	}
	ser, err := f.svc.History(f.ctx, pc.ID, "cpu.usage", "", start, f.clk.now())
	if err != nil {
		t.Fatal(err)
	}
	if ser.Resolution != "raw" || len(ser.Points) == 0 {
		t.Fatalf("raw series expected: %+v", ser.Resolution)
	}
	nonNull := 0
	for _, p := range ser.Points {
		if p.Value != nil {
			nonNull++
		}
	}
	if nonNull < 100 {
		t.Fatalf("points with data: %d", nonNull)
	}
	// Long range → 5-minute aggregates; empty hours stay null (gaps, not zeros).
	long, err := f.svc.History(f.ctx, pc.ID, "cpu.usage", "", start.Add(-24*time.Hour), f.clk.now())
	if err != nil {
		t.Fatal(err)
	}
	if long.Resolution != "5m" {
		t.Fatalf("resolution %s", long.Resolution)
	}
	if long.Points[0].Value != nil {
		t.Fatal("no data must be null, not 0")
	}
	gpu := latestOf(f.state(t, pc.ID).KeyMetrics, "gpu.temperature")
	if gpu == nil || gpu.Value != nil || gpu.Quality != QualityUnsupported || gpu.Reason == "" {
		t.Fatalf("unsupported metric must carry a reason, no value: %+v", gpu)
	}
	var rollups int
	_ = f.db.QueryRow(`SELECT COUNT(*) FROM mon_rollups WHERE metric = 'cpu.usage'`).Scan(&rollups)
	if rollups < 6 || rollups > 7 {
		t.Fatalf("5-minute buckets for 30 min: %d", rollups)
	}
}

func latestOf(ms []MetricValue, metric string) *MetricValue {
	for i := range ms {
		if ms[i].Metric == metric {
			return &ms[i]
		}
	}
	return nil
}

func TestHeartbeatLossOfflineIncidentGroupingRecovery(t *testing.T) {
	f := newFixture(t)
	srv := f.entity(t, "Сервер (тест)", "server")
	a, _ := f.agent(t, srv.ID, "ubuntu", "host")
	f.svc.CheckAll(f.ctx)
	if st := f.state(t, srv.ID); st.Status != StatusUnknown {
		t.Fatalf("never reported → unknown, got %s", st.Status)
	}
	f.report(t, a, SampleIn{Metric: "cpu.usage", Value: val(5)})
	if st := f.state(t, srv.ID); st.Status != StatusOnline || st.LastContactAt == nil {
		t.Fatalf("after report: %+v", st)
	}
	f.clk.add(2 * time.Minute) // agent silent
	f.svc.CheckAll(f.ctx)
	if st := f.state(t, srv.ID); st.Status != StatusOnline || !strings.Contains(st.Reason, "1 из 2") {
		t.Fatalf("one missed check must not flip the state: %s %q", st.Status, st.Reason)
	}
	f.svc.CheckAll(f.ctx)
	st := f.state(t, srv.ID)
	if st.Status != StatusOffline {
		t.Fatalf("want offline after 2 failures, got %s", st.Status)
	}
	if st.LastContactAt == nil || !st.LastContactAt.Equal(f.clk.now().Add(-2*time.Minute)) {
		t.Fatalf("last contact must stay the real last report: %v", st.LastContactAt)
	}
	for i := 0; i < 5; i++ {
		f.clk.add(30 * time.Second)
		f.svc.CheckAll(f.ctx)
	}
	open := f.incidents(t, "active")
	if len(open) != 1 || open[0].Severity != SeverityCritical || open[0].Occurrences < 1 {
		t.Fatalf("one grouped incident expected: %+v", open)
	}
	notes, _, _ := f.svc.Notifications(f.ctx, false, 50)
	if len(notes) != 1 || notes[0].Telegram != "disabled" {
		t.Fatalf("one notification per incident, telegram off: %+v", notes)
	}
	// Acknowledge, then recovery resolves automatically.
	if in, err := f.svc.Acknowledge(f.ctx, open[0].ID, "смотрю"); err != nil || in.Status != IncidentAcknowledged {
		t.Fatalf("ack: %v %+v", err, in.Status)
	}
	f.report(t, a, SampleIn{Metric: "cpu.usage", Value: val(3)})
	if st := f.state(t, srv.ID); st.Status != StatusOnline {
		t.Fatalf("recovered: %s", st.Status)
	}
	in, _ := f.svc.Incident(f.ctx, open[0].ID)
	if in.Status != IncidentResolved || in.ResolvedAt == nil {
		t.Fatalf("auto-resolve: %+v", in.Status)
	}
	kinds := []string{}
	for _, e := range in.Timeline {
		kinds = append(kinds, e.Kind)
	}
	if strings.Join(kinds, ",") != "opened,acknowledged,resolved" {
		t.Fatalf("timeline %v", kinds)
	}
	notes, _, _ = f.svc.Notifications(f.ctx, false, 50)
	if len(notes) != 2 || notes[0].Kind != "incident_resolved" {
		t.Fatalf("recovery notification expected: %+v", notes)
	}
	// A new outage is a new incident.
	f.clk.add(5 * time.Minute)
	f.svc.CheckAll(f.ctx)
	f.svc.CheckAll(f.ctx)
	if len(f.incidents(t, "")) != 2 {
		t.Fatal("new outage after resolution must open a new incident")
	}
	ev, _ := f.svc.Events(f.ctx, srv.ID, 0, 50)
	if len(ev) < 4 {
		t.Fatalf("event history: %d", len(ev))
	}
}

func TestDualBootOneActiveAgentIsOnline(t *testing.T) {
	f := newFixture(t)
	pc := f.entity(t, "ПК (тест)", "computer")
	win, _ := f.agent(t, pc.ID, "windows", "host")
	lin, _ := f.agent(t, pc.ID, "ubuntu", "host")
	f.report(t, win, SampleIn{Metric: "cpu.usage", Value: val(1)})
	f.clk.add(10 * time.Minute) // rebooted into Ubuntu long ago
	f.report(t, lin, SampleIn{Metric: "cpu.usage", Value: val(1)})
	for i := 0; i < 3; i++ {
		f.svc.CheckAll(f.ctx)
	}
	st := f.state(t, pc.ID)
	if st.Status != StatusOnline || len(f.incidents(t, "active")) != 0 {
		t.Fatalf("inactive alternate OS must not alarm: %s, %d incidents", st.Status, len(f.incidents(t, "active")))
	}
	var activeN int
	for _, a := range st.Agents {
		if a.Active {
			activeN++
		}
	}
	if activeN != 1 || len(st.Agents) != 2 {
		t.Fatalf("agents %+v", st.Agents)
	}
}

func TestTCPNeverReachableStaysUnknown(t *testing.T) {
	f := newFixture(t)
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	addr := ln.Addr().String()
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			c.Close()
		}
	}()
	router := f.entity(t, "Роутер (тест)", "router", addr)
	// TEST-NET-1: never answers (RFC 5737).
	tv := f.entity(t, "ТВ (тест)", "television", "192.0.2.1:9")
	f.svc.CheckAll(f.ctx)
	if st := f.state(t, router.ID); st.Status != StatusOnline || st.CheckKind != "tcp" {
		t.Fatalf("listening port: %+v", st)
	}
	f.svc.CheckAll(f.ctx)
	if st := f.state(t, tv.ID); st.Status != StatusUnknown || !strings.Contains(st.Reason, "ни разу") {
		t.Fatalf("never-reachable device must stay unknown with explanation: %s %q", st.Status, st.Reason)
	}
	// Refused connection still proves the host is up.
	ln.Close()
	f.svc.CheckAll(f.ctx)
	if st := f.state(t, router.ID); st.Status != StatusOnline || !strings.Contains(st.Reason, "отказом") {
		t.Fatalf("refused = reachable: %s %q", st.Status, st.Reason)
	}
	if len(f.incidents(t, "active")) != 0 {
		t.Fatal("no incidents expected")
	}
}

func TestHTTPChecks(t *testing.T) {
	f := newFixture(t)
	code := http.StatusOK
	var mu sync.Mutex
	hs := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		mu.Lock()
		defer mu.Unlock()
		w.WriteHeader(code)
	}))
	site := f.entity(t, "Сайт (тест)", "website", hs.URL)
	f.svc.CheckAll(f.ctx)
	if st := f.state(t, site.ID); st.Status != StatusOnline {
		t.Fatalf("200: %+v", st)
	}
	mu.Lock()
	code = http.StatusServiceUnavailable
	mu.Unlock()
	f.svc.CheckAll(f.ctx)
	if st := f.state(t, site.ID); st.Status != StatusDegraded || !strings.Contains(st.Reason, "503") {
		t.Fatalf("503: %+v", st)
	}
	hs.Close()
	f.svc.CheckAll(f.ctx)
	f.svc.CheckAll(f.ctx)
	st := f.state(t, site.ID)
	if st.Status != StatusOffline {
		t.Fatalf("closed server after reachable: %s %q", st.Status, st.Reason)
	}
	open := f.incidents(t, "active")
	if len(open) != 1 || !strings.Contains(open[0].Title, "Сайт") {
		t.Fatalf("site incident: %+v", open)
	}
}

func TestThresholdsDebounceAndDegraded(t *testing.T) {
	f := newFixture(t)
	nas := f.entity(t, "NAS (тест)", "server")
	a, _ := f.agent(t, nas.ID, "agent", "host")
	f.report(t, a, SampleIn{Metric: "disk.used_percent", Label: "/data", Value: val(93)})
	if n := len(f.incidents(t, "active")); n != 0 {
		t.Fatalf("a single breach must not open an incident (debounce), got %d", n)
	}
	f.report(t, a, SampleIn{Metric: "disk.used_percent", Label: "/data", Value: val(96)})
	open := f.incidents(t, "active")
	if len(open) != 1 || open[0].Severity != SeverityCritical {
		t.Fatalf("low disk: %+v", open)
	}
	if st := f.state(t, nas.ID); st.Status != StatusDegraded {
		t.Fatalf("open problem → degraded, got %s", st.Status)
	}
	for i := 0; i < 5; i++ {
		f.report(t, a, SampleIn{Metric: "disk.used_percent", Label: "/data", Value: val(96)})
	}
	if open = f.incidents(t, "active"); len(open) != 1 || open[0].Occurrences < 5 {
		t.Fatalf("repeats grouped: %+v", open)
	}
	f.report(t, a, SampleIn{Metric: "disk.used_percent", Label: "/data", Value: val(89)}) // 11 % free: inside hysteresis
	if len(f.incidents(t, "active")) != 1 {
		t.Fatal("hysteresis: 11 % free must not resolve yet")
	}
	f.report(t, a, SampleIn{Metric: "disk.used_percent", Label: "/data", Value: val(70)})
	if len(f.incidents(t, "active")) != 0 {
		t.Fatal("free space back → resolved")
	}
	if st := f.state(t, nas.ID); st.Status != StatusOnline {
		t.Fatalf("back to online, got %s", st.Status)
	}
	f.report(t, a, SampleIn{Metric: "cpu.temperature", Value: val(95)}, SampleIn{Metric: "service.active", Label: "nginx.service", Value: val(0)})
	f.report(t, a, SampleIn{Metric: "cpu.temperature", Value: val(96)}, SampleIn{Metric: "service.active", Label: "nginx.service", Value: val(0)})
	if n := len(f.incidents(t, "active")); n != 2 {
		t.Fatalf("temperature + service incidents: %d", n)
	}
}

func TestLogsRedactionFiltersPaginationAndRateLimit(t *testing.T) {
	f := newFixture(t, func(c *config.Monitoring) { c.LogRatePerMin = 50 })
	pc := f.entity(t, "ПК (тест)", "computer")
	a, token := f.agent(t, pc.ID, "ubuntu", "host")
	secrets := []string{
		"bot 123456789:AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsawQ failed",
		"login password=hunter2 rejected",
		"Authorization: Bearer abcdefghijklmnop",
		"agent token " + token,
		"db postgres://aer:s3cret@db.local/aer",
	}
	var logs []LogIn
	for i, m := range secrets {
		logs = append(logs, LogIn{At: f.clk.now(), Level: LevelError, Source: "app", Message: m, Fields: json.RawMessage(`{"apiKey":"zzz","n":` + fmt.Sprint(i) + `}`)})
	}
	for i := 0; i < 20; i++ {
		logs = append(logs, LogIn{At: f.clk.now(), Level: LevelInfo, Source: "app", Message: fmt.Sprintf("обычная строка %d", i), CorrelationID: "req-1"})
	}
	if _, err := f.svc.Ingest(f.ctx, a, Report{Logs: logs}); err != nil {
		t.Fatal(err)
	}
	var all strings.Builder
	rows, _ := f.db.Query(`SELECT message, COALESCE(fields, '') FROM mon_logs`)
	for rows.Next() {
		var m, fl string
		_ = rows.Scan(&m, &fl)
		all.WriteString(m + " " + fl + "\n")
	}
	rows.Close()
	for _, leak := range []string{"AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsawQ", "hunter2", "abcdefghijklmnop", token[len(token)-64:], "s3cret", "zzz"} {
		if strings.Contains(all.String(), leak) {
			t.Errorf("secret %q stored", leak)
		}
	}
	page, err := f.svc.Logs(f.ctx, LogFilter{MinLevel: "error", EntityID: pc.ID})
	if err != nil || len(page.Items) != len(secrets) {
		t.Fatalf("level filter: %v %d", err, len(page.Items))
	}
	q, _ := f.svc.Logs(f.ctx, LogFilter{Query: "строка 1"})
	if len(q.Items) != 11 { // 1, 10–19
		t.Fatalf("search: %d", len(q.Items))
	}
	p1, _ := f.svc.Logs(f.ctx, LogFilter{Limit: 10, EntityID: pc.ID})
	if p1.NextBefore == nil || len(p1.Items) != 10 {
		t.Fatal("pagination cursor expected")
	}
	p2, _ := f.svc.Logs(f.ctx, LogFilter{Limit: 10, EntityID: pc.ID, Before: *p1.NextBefore})
	if len(p2.Items) != 10 || p2.Items[0].ID >= p1.Items[9].ID {
		t.Fatal("second page must continue below the cursor")
	}
	// Rate limit: 25 accepted already, 50/min → only 25 more this minute.
	var flood []LogIn
	for i := 0; i < 100; i++ {
		flood = append(flood, LogIn{At: f.clk.now(), Level: LevelDebug, Message: "flood"})
	}
	res, _ := f.svc.Ingest(f.ctx, a, Report{Logs: flood})
	if res.AcceptedLogs != 25 || res.DroppedLogs != 75 {
		t.Fatalf("rate limit: %+v", res)
	}
	f.clk.add(61 * time.Second)
	res, _ = f.svc.Ingest(f.ctx, a, Report{Logs: flood[:10]})
	if res.AcceptedLogs != 10 {
		t.Fatalf("new window: %+v", res)
	}
	warn, _ := f.svc.Logs(f.ctx, LogFilter{Query: "превысил лимит"})
	if len(warn.Items) != 1 {
		t.Fatal("dropped lines must be reported once")
	}
}

func TestRetentionKeepsLatestAndOpenIncidents(t *testing.T) {
	f := newFixture(t, func(c *config.Monitoring) { c.LogMaxRows = 1000; c.ResolvedIncidentDays = 30 })
	pc := f.entity(t, "ПК (тест)", "computer")
	a, _ := f.agent(t, pc.ID, "ubuntu", "host")
	old := f.clk.now()
	f.report(t, a, SampleIn{Metric: "cpu.usage", Value: val(10)})
	var logs []LogIn
	for i := 0; i < 1500; i++ {
		logs = append(logs, LogIn{At: old, Level: LevelInfo, Message: "x"})
	}
	f.svc.cfg.LogRatePerMin = 5000
	if _, err := f.svc.Ingest(f.ctx, a, Report{Logs: logs[:500]}); err != nil {
		t.Fatal(err)
	}
	_, _ = f.svc.Ingest(f.ctx, a, Report{Logs: logs[500:1000]})
	_, _ = f.svc.Ingest(f.ctx, a, Report{Logs: logs[1000:]})
	f.svc.openIncident(f.ctx, incidentSpec{key: "k-open", title: "open", source: "t", severity: SeverityWarning})
	f.svc.openIncident(f.ctx, incidentSpec{key: "k-res", title: "resolved", source: "t", severity: SeverityWarning})
	f.svc.resolveIncident(f.ctx, "k-res", "ok")

	f.clk.add(8 * 24 * time.Hour)
	r, err := f.svc.Prune(f.ctx)
	if err != nil {
		t.Fatal(err)
	}
	if r.Samples != 1 || r.Rollups != 0 {
		t.Fatalf("after 8 days raw gone, rollups kept: %+v", r)
	}
	var n int
	_ = f.db.QueryRow(`SELECT COUNT(*) FROM mon_logs`).Scan(&n)
	if n > 1000 {
		t.Fatalf("log cap: %d rows", n)
	}
	if latestOf(f.state(t, pc.ID).KeyMetrics, "cpu.usage") == nil {
		t.Fatal("latest values are never pruned")
	}
	f.clk.add(30 * 24 * time.Hour)
	if _, err := f.svc.Prune(f.ctx); err != nil {
		t.Fatal(err)
	}
	all := f.incidents(t, "")
	if len(all) != 1 || all[0].Key != "k-open" {
		t.Fatalf("open incident kept, old resolved removed: %+v", all)
	}
	_ = f.db.QueryRow(`SELECT COUNT(*) FROM mon_rollups`).Scan(&n)
	if n != 0 {
		t.Fatal("rollups older than 30 days must be gone")
	}
}

func TestConcurrentIngest(t *testing.T) {
	f := newFixture(t)
	var agents []Agent
	for i := 0; i < 10; i++ {
		e := f.entity(t, fmt.Sprintf("Узел %d (тест)", i), "server")
		a, _ := f.agent(t, e.ID, "a", "host")
		agents = append(agents, a)
	}
	var wg sync.WaitGroup
	errs := make(chan error, 500)
	for _, a := range agents {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for j := 0; j < 30; j++ {
				at := f.clk.now().Add(-time.Duration(j) * time.Second)
				_, err := f.svc.Ingest(f.ctx, a, Report{Samples: []SampleIn{
					{Metric: "cpu.usage", Value: val(1), At: at, Quality: QualityOK},
					{Metric: "mem.used_percent", Value: val(2), At: at, Quality: QualityOK}}})
				if err != nil {
					errs <- err
				}
			}
		}()
	}
	wg.Wait()
	close(errs)
	for err := range errs {
		t.Fatal(err)
	}
	var n int
	_ = f.db.QueryRow(`SELECT COUNT(*) FROM mon_samples`).Scan(&n)
	if n != 10*30*2 {
		t.Fatalf("samples %d", n)
	}
}

func TestBotHeartbeatSignals(t *testing.T) {
	f := newFixture(t)
	bot := f.entity(t, "Бот (тест)", "telegram_bot")
	f.svc.CheckAll(f.ctx)
	if st := f.state(t, bot.ID); st.Status != StatusUnknown || !strings.Contains(st.Reason, "heartbeat") {
		t.Fatalf("bot without heartbeat source: %+v", st)
	}
	a, _ := f.agent(t, bot.ID, "pico", "bot")
	ok, bad := true, false
	now := f.clk.now()
	_, err := f.svc.Ingest(f.ctx, a, Report{Bot: &BotStatus{APIOK: &ok, LastSuccessAt: &now}})
	if err != nil {
		t.Fatal(err)
	}
	if st := f.state(t, bot.ID); st.Status != StatusOnline || st.CheckKind != "heartbeat" {
		t.Fatalf("healthy bot: %+v", st)
	}
	later := now.Add(time.Second)
	_, _ = f.svc.Ingest(f.ctx, a, Report{Bot: &BotStatus{APIOK: &bad, LastSuccessAt: &now, LastError: "timeout to api", LastErrorAt: &later},
		Samples: []SampleIn{{Metric: "bot.api_ok", Value: val(0), At: now, Quality: QualityOK}}})
	if st := f.state(t, bot.ID); st.Status != StatusDegraded {
		t.Fatalf("process alive but API failing → degraded, got %s", st.Status)
	}
	f.clk.add(5 * time.Minute)
	f.svc.CheckAll(f.ctx)
	f.svc.CheckAll(f.ctx)
	open := f.incidents(t, "active")
	found := false
	for _, in := range open {
		if strings.Contains(in.Title, "heartbeat") {
			found = true
		}
	}
	if !found {
		t.Fatalf("lost heartbeat incident expected: %+v", open)
	}
}

func TestCorrelationIsNotCause(t *testing.T) {
	f := newFixture(t)
	host := f.entity(t, "Сервер (тест)", "server")
	bot := f.entity(t, "Бот (тест)", "telegram_bot")
	if _, err := f.reg.AddRelation(f.ctx, bot.ID, "runs_on", host.ID, ""); err != nil {
		t.Fatal(err)
	}
	ha, _ := f.agent(t, host.ID, "srv", "host")
	ba, _ := f.agent(t, bot.ID, "bot", "bot")
	f.report(t, ha)
	f.report(t, ba)
	f.clk.add(3 * time.Minute)
	f.svc.RefreshEntity(f.ctx, host.ID)
	f.svc.RefreshEntity(f.ctx, host.ID)
	f.svc.RefreshEntity(f.ctx, bot.ID)
	f.svc.RefreshEntity(f.ctx, bot.ID)
	p, _ := f.svc.Incidents(f.ctx, IncidentFilter{EntityID: bot.ID})
	if len(p.Items) != 1 {
		t.Fatalf("bot incident: %+v", p.Items)
	}
	in, _ := f.svc.Incident(f.ctx, p.Items[0].ID)
	if len(in.Related) != 1 || in.Cause != "" {
		t.Fatalf("related set, cause empty (correlation only): %+v", in)
	}
}

func TestTelegramDisabledByDefaultAndGroupedWhenEnabled(t *testing.T) {
	var got []string
	var mu sync.Mutex
	api := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b, _ := io.ReadAll(r.Body)
		mu.Lock()
		got = append(got, r.URL.Path+" "+string(b))
		mu.Unlock()
		w.WriteHeader(http.StatusOK)
	}))
	defer api.Close()
	tokFile := filepath.Join(t.TempDir(), "tg.token")
	const botToken = "123456789:TESTTESTTESTTESTTESTTESTTESTTESTTE"
	if err := os.WriteFile(tokFile, []byte(botToken+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	f := newFixture(t, func(c *config.Monitoring) {
		c.Telegram = config.TelegramNotify{Enabled: true, BotTokenFile: tokFile, ChatID: "42", MinSeverity: "critical", APIBase: api.URL}
	})
	f.svc.openIncident(f.ctx, incidentSpec{key: "a", title: "Сервер недоступен", source: "t", severity: SeverityCritical})
	f.svc.openIncident(f.ctx, incidentSpec{key: "b", title: "Роутер недоступен", source: "t", severity: SeverityCritical})
	f.svc.openIncident(f.ctx, incidentSpec{key: "a", title: "Сервер недоступен", source: "t", severity: SeverityCritical}) // repeat
	f.svc.openIncident(f.ctx, incidentSpec{key: "c", title: "Мало места", source: "t", severity: SeverityWarning})
	f.svc.notifier.Dispatch(f.ctx)
	f.svc.notifier.Dispatch(f.ctx)
	if len(got) != 1 {
		t.Fatalf("one grouped message expected, got %d", len(got))
	}
	if !strings.Contains(got[0], "2 событий") || strings.Contains(got[0], "Мало места") {
		t.Fatalf("grouped critical only: %s", got[0])
	}
	notes, _, _ := f.svc.Notifications(f.ctx, false, 50)
	states := map[string]int{}
	for _, n := range notes {
		states[n.Telegram]++
	}
	if states["sent"] != 2 || states["skipped"] != 1 {
		t.Fatalf("telegram states: %v", states)
	}
}

// fakeDocker serves a minimal Docker Engine API on a unix socket.
type fakeDocker struct {
	mu    sync.Mutex
	state string
	exit  int
}

func (d *fakeDocker) handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/v1.41/containers/json", func(w http.ResponseWriter, _ *http.Request) {
		d.mu.Lock()
		defer d.mu.Unlock()
		_ = json.NewEncoder(w).Encode([]map[string]any{
			{"Id": "aaa111", "Names": []string{"/pico-bot"}, "Image": "pico:1", "State": d.state},
			{"Id": "bbb222", "Names": []string{"/postgres"}, "Image": "postgres:16", "State": "running"},
		})
	})
	mux.HandleFunc("/v1.41/containers/{id}/json", func(w http.ResponseWriter, r *http.Request) {
		d.mu.Lock()
		defer d.mu.Unlock()
		st := "running"
		code := 0
		if r.PathValue("id") == "aaa111" {
			st, code = d.state, d.exit
		}
		_ = json.NewEncoder(w).Encode(map[string]any{"RestartCount": 1, "State": map[string]any{
			"Status": st, "ExitCode": code, "OOMKilled": code == 137, "StartedAt": "2026-10-27T10:00:00Z", "FinishedAt": "0001-01-01T00:00:00Z"}})
	})
	mux.HandleFunc("/v1.41/containers/{id}/stats", func(w http.ResponseWriter, _ *http.Request) {
		_, _ = io.WriteString(w, `{"cpu_stats":{"cpu_usage":{"total_usage":2000},"system_cpu_usage":20000,"online_cpus":2},
			"precpu_stats":{"cpu_usage":{"total_usage":1000},"system_cpu_usage":10000},
			"memory_stats":{"usage":5000000,"stats":{"inactive_file":1000000}},"networks":{"eth0":{"rx_bytes":100,"tx_bytes":50}}}`)
	})
	mux.HandleFunc("/v1.41/containers/{id}/logs", func(w http.ResponseWriter, _ *http.Request) {
		line := []byte("panic: token=abc123secret\n")
		hdr := []byte{2, 0, 0, 0, 0, 0, 0, byte(len(line))}
		_, _ = w.Write(append(hdr, line...))
	})
	return mux
}

func TestDockerIntegration(t *testing.T) {
	dir, err := os.MkdirTemp("/tmp", "aerdock")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(dir)
	sock := filepath.Join(dir, "d.sock")
	f := newFixture(t, func(c *config.Monitoring) {
		c.Docker = config.DockerMonitoring{Enabled: true, Socket: sock, IntervalSec: 30, StatsIntervalSec: 10}
	})
	// Socket missing: explained, not empty.
	f.svc.docker.Poll(f.ctx)
	_, st, _ := f.svc.Containers(f.ctx)
	if st.Status != "unavailable" || !strings.Contains(st.Reason, "не найден") {
		t.Fatalf("missing socket: %+v", st)
	}
	ln, err := net.Listen("unix", sock)
	if err != nil {
		t.Fatal(err)
	}
	fd := &fakeDocker{state: "running"}
	hs := &http.Server{Handler: fd.handler()}
	go func() { _ = hs.Serve(ln) }()
	defer hs.Close()

	db := f.entity(t, "postgres", "docker_container")
	f.svc.docker.Poll(f.ctx)
	items, st, _ := f.svc.Containers(f.ctx)
	if st.Status != "ok" || len(items) != 2 {
		t.Fatalf("containers: %+v %d", st, len(items))
	}
	f.svc.CheckAll(f.ctx)
	if s := f.state(t, db.ID); s.Status != StatusOnline || s.CheckKind != "docker" {
		t.Fatalf("bound container: %+v", s)
	}
	if latestOf(f.state(t, db.ID).KeyMetrics, "docker.cpu_percent") == nil {
		// key metrics hide docker.*; check full latest instead
		all, _ := f.svc.Latest(f.ctx, db.ID, false)
		if latestOf(all, "docker.cpu_percent") == nil {
			t.Fatal("docker stats stored for bound container")
		}
	}
	// Unbound container stops with OOM: incident with established cause + redacted stderr.
	fd.mu.Lock()
	fd.state, fd.exit = "exited", 137
	fd.mu.Unlock()
	f.svc.docker.Poll(f.ctx)
	open := f.incidents(t, "active")
	if len(open) != 1 || !strings.Contains(open[0].Cause, "137") || !strings.Contains(open[0].Cause, "OOMKilled") {
		t.Fatalf("container incident with cause: %+v", open)
	}
	logs, _ := f.svc.Logs(f.ctx, LogFilter{Source: "docker:pico-bot"})
	joined := ""
	for _, l := range logs.Items {
		joined += l.Message + "\n"
	}
	if !strings.Contains(joined, "exited") || strings.Contains(joined, "abc123secret") {
		t.Fatalf("docker logs (redacted): %s", joined)
	}
	fd.mu.Lock()
	fd.state, fd.exit = "running", 0
	fd.mu.Unlock()
	f.svc.docker.Poll(f.ctx)
	if len(f.incidents(t, "active")) != 0 {
		t.Fatal("container running again → resolved")
	}
	// Docker goes away after working: integration incident.
	hs.Close()
	os.Remove(sock)
	f.svc.docker.Poll(f.ctx)
	open = f.incidents(t, "active")
	if len(open) != 1 || open[0].Key != "integration:docker" {
		t.Fatalf("lost docker: %+v", open)
	}
}

func TestRedact(t *testing.T) {
	cases := map[string]string{
		"password: \"p@ss w\" next":   "password: [скрыто] next",
		"API_KEY=abc":                 "API_KEY=[скрыто]",
		"https://u:p@example.org/x":   "https://[скрыто]@example.org/x",
		"basic dXNlcjpwYXNzd29yZA==":  "basic [скрыто]",
		"ordinary message, no secret": "ordinary message, no secret",
	}
	for in, want := range cases {
		if got := Redact(in); got != want {
			t.Errorf("Redact(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestSilentHostWithManyPortsIsStillRecorded(t *testing.T) {
	f := newFixture(t, func(c *config.Monitoring) { c.CheckTimeoutSec = 1 })
	r := f.entity(t, "Роутер (тест)", "router", "192.0.2.1") // default 4 ports, TEST-NET
	start := time.Now()
	f.svc.CheckAll(f.ctx)
	if time.Since(start) > 2500*time.Millisecond {
		t.Fatalf("ports must be probed in parallel: %v", time.Since(start))
	}
	st := f.state(t, r.ID)
	if st.LastCheckAt == nil || st.Reason == "Ещё не проверялся" {
		t.Fatalf("result must be saved even after the deadline: %+v", st)
	}
}
