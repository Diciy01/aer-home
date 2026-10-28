package bots

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"testing"
	"time"

	"aerhome/core/internal/foundation/config"
	"aerhome/core/internal/foundation/module"
	"aerhome/core/internal/foundation/storage"
	"aerhome/core/internal/modules/monitoring"
	"aerhome/core/internal/modules/registry"
	"aerhome/core/internal/testenv"
)

// TEST DATA: every bot, process and server below is a fixture of this test.

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
	mon *monitoring.Service
	svc *Service
	clk *clock
	ctx context.Context
	dir string
}

func newFixture(t *testing.T, mut ...func(*config.Bots)) *fixture {
	t.Helper()
	ctx := context.Background()
	dir := t.TempDir()
	db, err := storage.Open(ctx, filepath.Join(dir, "test.db"))
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
	mcfg := config.DefaultMonitoring()
	mcfg.Docker.Enabled = false
	clk := &clock{t: time.Now().UTC().Truncate(time.Second)}
	reg := rm.(*registry.Module).Writer()
	mon := monitoring.NewService(db, reg, mcfg, nil, clk.now)
	mm, _ := monitoring.Factory(func() registry.Reader { return reg }, clk.now)(module.Deps{DB: db, Config: config.Config{Monitoring: mcfg}})
	if _, err := storage.Migrate(ctx, db, monitoring.Name, mm.Migrations()); err != nil {
		t.Fatal(err)
	}
	if n, err := storage.Migrate(ctx, db, Name, migrations); err != nil || n != 1 {
		t.Fatalf("migrate: n=%d err=%v", n, err)
	}
	cfg := config.DefaultBots()
	cfg.DockerSocket = filepath.Join(dir, "no-docker.sock")
	for _, m := range mut {
		m(&cfg)
	}
	if err := cfg.Validate(); err != nil {
		t.Fatalf("config: %v", err)
	}
	svc := NewService(db, reg, mon, cfg, nil, clk.now)
	t.Cleanup(svc.process.StopAll)
	return &fixture{db: db, reg: reg, mon: mon, svc: svc, clk: clk, ctx: ctx, dir: dir}
}

func (f *fixture) bot(t *testing.T, in NewBot) Created {
	t.Helper()
	c, err := f.svc.Create(f.ctx, in)
	if err != nil {
		t.Fatalf("create: %v", err)
	}
	return c
}

func fields(err error) map[string]string {
	var ve *ValidationError
	if errors.As(err, &ve) {
		return ve.Fields
	}
	return nil
}

func TestAdaptersRegistered(t *testing.T) {
	f := newFixture(t, func(c *config.Bots) {
		c.Controllers = []config.BotController{{ID: "echo", Kind: "process", Command: []string{testenv.Shell(t), "-c", "true"}, StopTimeoutSec: 2, Allow: []string{"start"}}}
	})
	got := map[string]AdapterInfo{}
	for _, a := range f.svc.Adapters(f.ctx) {
		got[a.ID] = a
	}
	for _, id := range []string{"heartbeat", "telegram", "process", "systemd_user", "docker", "n8n"} {
		if _, ok := got[id]; !ok {
			t.Errorf("adapter %s not registered", id)
		}
	}
	target := "sh -c"
	if runtime.GOOS == "windows" {
		target = "sh.exe -c"
	}
	if p := got["process"]; p.Status != "ok" || len(p.Instances) != 1 || p.Instances[0].Target != target {
		t.Errorf("process adapter: %+v", p)
	}
	if got["docker"].Status != "disabled" || got["n8n"].Status != "disabled" {
		t.Errorf("unconfigured adapters must be disabled: %+v %+v", got["docker"], got["n8n"])
	}
	// A new adapter kind plugs in without touching the service.
	f.svc.Register(heartbeatAdapter{})
	if len(f.svc.Adapters(f.ctx)) != 7 {
		t.Error("Register did not add the adapter")
	}
}

func TestCreateBotRegistryIntegration(t *testing.T) {
	f := newFixture(t)
	host, _ := f.reg.Create(f.ctx, registry.NewEntity{Name: "Сервер", Type: "server"})
	db, _ := f.reg.Create(f.ctx, registry.NewEntity{Name: "БД", Type: "database"})
	c := f.bot(t, NewBot{Name: "Тестовый бот", Type: "telegram_bot", Tags: []string{"test"}, HostID: host.ID,
		DependsOn: []string{db.ID}, Category: "уведомления", CreateCredential: true, HeartbeatIntervalSec: 10})
	if !strings.HasPrefix(c.HeartbeatToken, "aer1.") {
		t.Fatalf("token: %q", c.HeartbeatToken)
	}
	b := c.Bot
	if b.Runtime != "telegram" || b.LogSource != "heartbeat" || b.HeartbeatTimeoutSec != 60 || b.Revision != 1 {
		t.Errorf("defaults: %+v", b.Config)
	}
	if b.Host == nil || b.Host.ID != host.ID || len(b.Dependencies) != 1 || b.Dependencies[0].ID != db.ID {
		t.Errorf("relations: host=%+v deps=%+v", b.Host, b.Dependencies)
	}
	e, _ := f.reg.Get(f.ctx, b.EntityID)
	if e.Type != "telegram_bot" || e.Tags[0] != "test" {
		t.Errorf("registry entity: %+v", e)
	}
	var attrs map[string]map[string]any
	_ = json.Unmarshal(e.Attributes, &attrs)
	if attrs["monitoring"]["heartbeatTimeoutSec"] != float64(60) {
		t.Errorf("monitoring attributes: %s", e.Attributes)
	}
	if b.Status != monitoring.StatusUnknown || b.Heartbeat.Credentials != 1 || b.Heartbeat.Active {
		t.Errorf("a silent bot must be unknown, not online: %s %+v", b.Status, b.Heartbeat)
	}
	for _, a := range b.Actions {
		if (a.ID == "start" || a.ID == "stop" || a.ID == "restart") && a.Available {
			t.Errorf("monitoring-only bot must not offer %s", a.ID)
		}
	}

	// Link an existing entity; a second link is a conflict, not a second bot.
	proc, _ := f.reg.Create(f.ctx, registry.NewEntity{Name: "Скрипт", Type: "process", Attributes: json.RawMessage(`{"owner":"me"}`)})
	l := f.bot(t, NewBot{EntityID: proc.ID})
	if l.Bot.Runtime != "python" || l.Bot.Name != "Скрипт" {
		t.Errorf("linked: %+v", l.Bot.Config)
	}
	e2, _ := f.reg.Get(f.ctx, proc.ID)
	if !strings.Contains(string(e2.Attributes), `"owner":"me"`) {
		t.Errorf("other attributes must be kept: %s", e2.Attributes)
	}
	var ce *ConflictError
	if _, err := f.svc.Create(f.ctx, NewBot{EntityID: proc.ID}); !errors.As(err, &ce) {
		t.Errorf("duplicate link: %v", err)
	}
	// Only one Registry: Bots never creates entities of its own.
	p, _ := f.reg.List(f.ctx, registry.ListFilter{Limit: 50})
	if p.Total != 4 {
		t.Errorf("registry entities: %d", p.Total)
	}

	_, err := f.svc.Create(f.ctx, NewBot{Name: "x", Type: "server", ControllerID: "nope", N8NInstanceID: "nope", HeartbeatIntervalSec: 50, HeartbeatTimeoutSec: 60})
	fl := fields(err)
	for _, k := range []string{"type", "controllerId", "n8nInstanceId", "heartbeatTimeoutSec"} {
		if fl[k] == "" {
			t.Errorf("want validation of %s, got %v", k, fl)
		}
	}
}

func TestUpdateArchiveRestore(t *testing.T) {
	f := newFixture(t)
	c := f.bot(t, NewBot{Name: "Бот", Type: "telegram_bot"})
	id := c.Bot.EntityID
	name, cat, to := "Бот 2", "работа", 120
	d, err := f.svc.Update(f.ctx, id, BotPatch{Revision: 1, Name: &name, Category: &cat, HeartbeatTimeoutSec: &to})
	if err != nil || d.Name != "Бот 2" || d.Category != "работа" || d.Revision != 2 {
		t.Fatalf("update: %+v %v", d.Config, err)
	}
	e, _ := f.reg.Get(f.ctx, id)
	if !strings.Contains(string(e.Attributes), `"heartbeatTimeoutSec":120`) {
		t.Errorf("timeout not propagated to Monitoring: %s", e.Attributes)
	}
	var ce *ConflictError
	if _, err := f.svc.Update(f.ctx, id, BotPatch{Revision: 1, Name: &name}); !errors.As(err, &ce) || ce.CurrentRevision != 2 {
		t.Errorf("stale revision: %v", err)
	}
	if d, err = f.svc.SetArchived(f.ctx, id, true); err != nil || !d.Archived {
		t.Fatalf("archive: %v", err)
	}
	if list, _ := f.svc.List(f.ctx, ListFilter{}); len(list) != 0 {
		t.Error("archived bot listed by default")
	}
	if list, _ := f.svc.List(f.ctx, ListFilter{Archived: "true"}); len(list) != 1 {
		t.Error("archived filter")
	}
	for _, a := range d.Actions {
		if a.Available {
			t.Errorf("archived bot offers %s", a.ID)
		}
	}
	if d, err = f.svc.SetArchived(f.ctx, id, false); err != nil || d.Archived {
		t.Fatalf("restore: %v", err)
	}
	if list, _ := f.svc.List(f.ctx, ListFilter{Query: "бот работа"}); len(list) != 1 {
		t.Error("search by name and category")
	}
	if list, _ := f.svc.List(f.ctx, ListFilter{Runtime: "docker"}); len(list) != 0 {
		t.Error("runtime filter")
	}
}

func report(t *testing.T, f *fixture, token string, rep monitoring.Report) {
	t.Helper()
	a, ok := f.mon.Authenticate(f.ctx, token)
	if !ok {
		t.Fatal("token rejected")
	}
	if _, err := f.mon.Ingest(f.ctx, a, rep); err != nil {
		t.Fatalf("ingest: %v", err)
	}
}

func TestHeartbeatLossAndRecovery(t *testing.T) {
	f := newFixture(t)
	c := f.bot(t, NewBot{Name: "Бот", Type: "telegram_bot", CreateCredential: true, HeartbeatIntervalSec: 15, HeartbeatTimeoutSec: 45})
	id := c.Bot.EntityID
	started := f.clk.now().Add(-time.Hour)
	ok := true
	report(t, f, c.HeartbeatToken, monitoring.Report{Agent: monitoring.AgentInfo{Version: "0.2.0", OS: "bot"},
		Bot: &monitoring.BotStatus{StartedAt: &started, Version: "1.4.2", APIOK: &ok}})
	d, _ := f.svc.Get(f.ctx, id)
	if d.Status != monitoring.StatusOnline || d.Version != "1.4.2" || d.UptimeSec == nil || *d.UptimeSec != 3600 || !d.Heartbeat.Active {
		t.Fatalf("online: %s ver=%q up=%v hb=%+v", d.Status, d.Version, d.UptimeSec, d.Heartbeat)
	}
	if d.Integration == nil || d.Integration.Kind != "telegram" || d.Integration.Status != "ok" {
		t.Errorf("telegram integration: %+v", d.Integration)
	}
	// Silence longer than the bot's own timeout (45 s < global 60 s).
	f.clk.add(50 * time.Second)
	f.mon.CheckAll(f.ctx)
	f.mon.CheckAll(f.ctx)
	d, _ = f.svc.Get(f.ctx, id)
	if d.Status != monitoring.StatusOffline || d.Heartbeat.Active || d.UptimeSec != nil {
		t.Fatalf("lost: %s %+v up=%v", d.Status, d.Heartbeat, d.UptimeSec)
	}
	if len(d.Crashes) != 1 || d.Crashes[0].Status != monitoring.IncidentOpen {
		t.Fatalf("crash history: %+v", d.Crashes)
	}
	// Recovery after a restart of the bot (new startedAt).
	restarted := f.clk.now()
	report(t, f, c.HeartbeatToken, monitoring.Report{Agent: monitoring.AgentInfo{Version: "0.2.0"},
		Bot: &monitoring.BotStatus{StartedAt: &restarted, Version: "1.4.3", LastError: "Telegram API: 502 Bad Gateway", LastErrorAt: &restarted}})
	d, _ = f.svc.Get(f.ctx, id)
	if d.Status != monitoring.StatusDegraded || d.LastError == "" || d.Version != "1.4.3" {
		t.Fatalf("recovered with error: %s %q", d.Status, d.LastError)
	}
	if d.Crashes[0].Status != monitoring.IncidentResolved {
		t.Errorf("incident must resolve on recovery: %+v", d.Crashes[0])
	}
	found := false
	for _, e := range d.Restarts {
		found = found || e.Kind == "bot_restarted"
	}
	if !found {
		t.Errorf("restart history: %+v", d.Restarts)
	}
}

func TestJobsHistory(t *testing.T) {
	f := newFixture(t)
	c := f.bot(t, NewBot{Name: "Бот", Type: "telegram_bot"})
	id := c.Bot.EntityID
	now := f.clk.now()
	s1, e1 := now.Add(-2*time.Minute), now.Add(-time.Minute)
	n, err := f.svc.IngestJobs(f.ctx, id, JobReport{Jobs: []JobIn{
		{ID: "1", Name: "Рассылка", Status: JobSuccess, StartedAt: &s1, FinishedAt: &e1, Result: "отправлено 3"},
		{ID: "2", Name: "Отчёт", Status: JobFailed, StartedAt: &s1, FinishedAt: &e1, Error: "token=123456:ABCDEFabcdef_ghijklmnopqrstuvwxyz0123 bad"},
		{ID: "3", Name: "Импорт", Status: JobRunning, StartedAt: &s1},
	}})
	if err != nil || n != 3 {
		t.Fatalf("ingest: %d %v", n, err)
	}
	// The same job reported again is updated, not duplicated.
	if _, err := f.svc.IngestJobs(f.ctx, id, JobReport{Jobs: []JobIn{{ID: "3", Name: "Импорт", Status: JobCancelled, StartedAt: &s1, FinishedAt: &e1}}}); err != nil {
		t.Fatal(err)
	}
	p, err := f.svc.Jobs(f.ctx, id, "", "", 2)
	if err != nil || p.Total != 3 || len(p.Items) != 2 || p.NextBefore == nil {
		t.Fatalf("page 1: %+v %v", p, err)
	}
	p2, _ := f.svc.Jobs(f.ctx, id, "", *p.NextBefore, 2)
	if len(p2.Items) != 1 || p2.NextBefore != nil {
		t.Fatalf("page 2: %+v", p2)
	}
	fp, _ := f.svc.Jobs(f.ctx, id, "failed", "", 10)
	if len(fp.Items) != 1 || strings.Contains(fp.Items[0].Error, "ABCDEF") || fp.Items[0].Retryable || *fp.Items[0].DurationMs != 60000 {
		t.Errorf("failed job (redacted, not retryable): %+v", fp.Items)
	}
	d, _ := f.svc.Get(f.ctx, id)
	if d.LastJobOK == nil || d.LastJobOK.Name != "Рассылка" || d.LastJobFailed == nil || d.Jobs.Success24h != 1 || d.Jobs.Failed24h != 1 {
		t.Errorf("summary: ok=%+v failed=%+v counts=%+v", d.LastJobOK, d.LastJobFailed, d.Jobs)
	}
	logs, _ := f.mon.Logs(f.ctx, monitoring.LogFilter{EntityID: id, MinLevel: "error"})
	if len(logs.Items) != 1 || !strings.Contains(logs.Items[0].Message, "Отчёт") {
		t.Errorf("failed job must reach the bot's error log: %+v", logs.Items)
	}
	if _, err := f.svc.IngestJobs(f.ctx, id, JobReport{Jobs: []JobIn{{ID: "", Name: "", Status: "done"}}}); len(fields(err)) == 0 {
		t.Error("invalid job accepted")
	}
	// Retention keeps running jobs and drops old finished ones.
	f.clk.add(100 * 24 * time.Hour)
	r, _ := f.svc.Prune(f.ctx)
	if r.Jobs != 3 {
		t.Errorf("prune: %+v", r)
	}
}

func processCfg(t *testing.T, script string, allow ...string) func(*config.Bots) {
	sh := testenv.Shell(t)
	return func(c *config.Bots) {
		c.Controllers = append(c.Controllers, config.BotController{ID: "testproc", Label: "Тестовый процесс", Kind: "process",
			Command: []string{sh, "-c", script}, StopTimeoutSec: 2, Allow: allow})
	}
}

func (f *fixture) do(t *testing.T, id, action, key string, confirm bool) (ActionRecord, error) {
	t.Helper()
	req := ActionRequest{}
	if confirm {
		c, err := f.svc.Prepare(f.ctx, id, action, "")
		if err != nil {
			return ActionRecord{}, err
		}
		req.ConfirmationToken = c.Token
	}
	return f.svc.Execute(f.ctx, id, action, key, req)
}

func waitFor(t *testing.T, what string, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for !cond() {
		if time.Now().After(deadline) {
			t.Fatalf("timeout waiting for %s", what)
		}
		time.Sleep(20 * time.Millisecond)
	}
}

func TestProcessControl(t *testing.T) {
	// An isolated test process: prints lines and sleeps; nothing else runs.
	f := newFixture(t, processCfg(t, `echo "INFO test bot started"; echo "ERROR fake failure token=abc123secretvalue" >&2; while true; do sleep 0.1; done`, "start", "stop", "restart"))
	c := f.bot(t, NewBot{Name: "Тестовый процесс", Type: "process", ControllerID: "testproc"})
	id := c.Bot.EntityID
	if c.Bot.LogSource != "controller" || c.Bot.RuntimeState == nil || c.Bot.RuntimeState.State != "stopped" {
		t.Fatalf("initial: %+v %+v", c.Bot.Config, c.Bot.RuntimeState)
	}

	// No confirmation → refused and audited; nothing started.
	if _, err := f.do(t, id, "start", "key-noconfirm", false); err == nil {
		t.Fatal("start without confirmation must be refused")
	}
	if st := f.svc.process.State(f.ctx, mustCtl(f, "testproc")); st.State != "stopped" {
		t.Fatal("refused action changed state")
	}

	rec, err := f.do(t, id, "start", "key-start-1", true)
	if err != nil || rec.Status != "succeeded" {
		t.Fatalf("start: %+v %v", rec, err)
	}
	// Same key again: replayed, not started twice.
	again, err := f.svc.Execute(f.ctx, id, "start", "key-start-1", ActionRequest{})
	if err != nil || !again.Replayed || again.ID != rec.ID {
		t.Fatalf("replay: %+v %v", again, err)
	}
	pid := f.svc.process.State(f.ctx, mustCtl(f, "testproc")).PID
	if pid == 0 {
		t.Fatal("no pid")
	}
	waitFor(t, "process logs", func() bool {
		p, _ := f.mon.Logs(f.ctx, monitoring.LogFilter{EntityID: id})
		return len(p.Items) >= 2
	})
	p, _ := f.mon.Logs(f.ctx, monitoring.LogFilter{EntityID: id, MinLevel: "error"})
	if len(p.Items) != 1 || strings.Contains(p.Items[0].Message, "abc123secretvalue") {
		t.Errorf("stderr error line (redacted): %+v", p.Items)
	}
	f.svc.process.Sync(f.ctx)
	time.Sleep(50 * time.Millisecond)
	f.svc.process.Sync(f.ctx)
	if v, _ := f.mon.Latest(f.ctx, id, false); len(v) == 0 {
		t.Error("process CPU/RAM not sampled")
	}

	rec, err = f.do(t, id, "restart", "key-restart-1", true)
	if err != nil || rec.Status != "succeeded" {
		t.Fatalf("restart: %+v %v", rec, err)
	}
	if np := f.svc.process.State(f.ctx, mustCtl(f, "testproc")).PID; np == pid || np == 0 {
		t.Errorf("restart kept pid %d → %d", pid, np)
	}
	rec, err = f.do(t, id, "stop", "key-stop-1", true)
	if err != nil || rec.Status != "succeeded" {
		t.Fatalf("stop: %+v %v", rec, err)
	}
	if st := f.svc.process.State(f.ctx, mustCtl(f, "testproc")); st.State != "stopped" {
		t.Fatalf("after stop: %+v", st)
	}
	d, _ := f.svc.Get(f.ctx, id)
	for _, in := range d.Crashes {
		if strings.HasPrefix(in.Key, "bot_process:") {
			t.Errorf("a requested stop is not a crash: %+v", in)
		}
	}
	kinds := map[string]bool{}
	for _, e := range d.Restarts {
		kinds[e.Kind] = true
	}
	if !kinds["bot_started"] || !kinds["bot_stopped"] || !kinds["bot_restarted"] {
		t.Errorf("restart history kinds: %v", kinds)
	}
	audit, _ := f.svc.Audit(f.ctx, id, 50)
	statuses := map[string]int{}
	for _, a := range audit {
		statuses[a.Status]++
	}
	if statuses["rejected"] != 1 || statuses["succeeded"] != 3 {
		t.Errorf("audit: %v", statuses)
	}
	// A used confirmation cannot be reused for another request.
	cf, _ := f.svc.Prepare(f.ctx, id, "start", "")
	if _, err := f.svc.Execute(f.ctx, id, "start", "key-a-123", ActionRequest{ConfirmationToken: cf.Token}); err != nil {
		t.Fatal(err)
	}
	if _, err := f.svc.Execute(f.ctx, id, "start", "key-b-123", ActionRequest{ConfirmationToken: cf.Token}); err == nil {
		t.Error("confirmation token reused")
	}
	// The key belongs to the first operation.
	if _, err := f.svc.Execute(f.ctx, id, "stop", "key-a-123", ActionRequest{}); err == nil {
		t.Error("idempotency key reused for another action")
	}
	// Expired confirmation.
	cf, _ = f.svc.Prepare(f.ctx, id, "stop", "")
	f.clk.add(10 * time.Minute)
	var ae *ActionError
	if _, err := f.svc.Execute(f.ctx, id, "stop", "key-expired", ActionRequest{ConfirmationToken: cf.Token}); !errors.As(err, &ae) || ae.Status != 403 {
		t.Errorf("expired confirmation: %v", err)
	}
}

func mustCtl(f *fixture, id string) config.BotController {
	c, _ := f.svc.cfg.Controller(id)
	return c
}

func TestProcessCrashOpensIncident(t *testing.T) {
	f := newFixture(t, processCfg(t, `echo "Traceback: boom" >&2; exit 3`, "start"))
	c := f.bot(t, NewBot{Name: "Падающий процесс", Type: "process", ControllerID: "testproc"})
	id := c.Bot.EntityID
	if _, err := f.do(t, id, "start", "key-crash-1", true); err != nil {
		t.Fatal(err)
	}
	waitFor(t, "crash incident", func() bool {
		p, _ := f.mon.Incidents(f.ctx, monitoring.IncidentFilter{EntityID: id})
		return len(p.Items) == 1
	})
	p, _ := f.mon.Incidents(f.ctx, monitoring.IncidentFilter{EntityID: id})
	if p.Items[0].Key != "bot_process:"+id || p.Items[0].Cause != "код 3" {
		t.Errorf("incident: %+v", p.Items[0])
	}
	d, _ := f.svc.Get(f.ctx, id)
	if len(d.Crashes) != 1 || d.RuntimeState.State != "stopped" || !strings.Contains(d.RuntimeState.Reason, "код 3") {
		t.Errorf("detail: crashes=%d rt=%+v", len(d.Crashes), d.RuntimeState)
	}
	// stop/restart are not in allow → not available, refused with 403.
	var ae *ActionError
	if _, err := f.svc.Prepare(f.ctx, id, "stop", ""); !errors.As(err, &ae) || ae.Code != "PERMISSION_REQUIRED" {
		t.Errorf("not allowed action: %v", err)
	}
}

func TestConcurrentActionsOnOneBot(t *testing.T) {
	// The stop takes ~1 s (trap ignores TERM) so the second request overlaps.
	f := newFixture(t, processCfg(t, `trap "" TERM; while true; do sleep 0.05; done`, "start", "stop"))
	c := f.bot(t, NewBot{Name: "Медленный", Type: "process", ControllerID: "testproc"})
	id := c.Bot.EntityID
	if _, err := f.do(t, id, "start", "key-slow-start", true); err != nil {
		t.Fatal(err)
	}
	c1, _ := f.svc.Prepare(f.ctx, id, "stop", "")
	c2, _ := f.svc.Prepare(f.ctx, id, "stop", "")
	var wg sync.WaitGroup
	errs := make([]error, 2)
	recs := make([]ActionRecord, 2)
	for i, tok := range []string{c1.Token, c2.Token} {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if i == 1 {
				time.Sleep(200 * time.Millisecond)
			}
			recs[i], errs[i] = f.svc.Execute(f.ctx, id, "stop", fmt.Sprintf("key-slow-stop-%d", i), ActionRequest{ConfirmationToken: tok})
		}()
	}
	wg.Wait()
	var ae *ActionError
	if errs[0] != nil || !errors.As(errs[1], &ae) || ae.Status != 409 {
		t.Fatalf("want first ok, second 409: %v / %v", errs[0], errs[1])
	}
	if !strings.Contains(recs[0].Message, "принудительно") {
		t.Errorf("TERM-ignoring child must be killed after the grace period: %q", recs[0].Message)
	}
}

func TestDockerUnavailableAndFake(t *testing.T) {
	f := newFixture(t, func(c *config.Bots) {
		c.Controllers = []config.BotController{{ID: "ctr", Kind: "docker", Container: "test-bot", Allow: []string{"start", "stop", "restart"}}}
	})
	c := f.bot(t, NewBot{Name: "Контейнерный бот", Type: "telegram_bot", ControllerID: "ctr"})
	id := c.Bot.EntityID
	if c.Bot.Runtime != "telegram" || c.Bot.RuntimeState.State != "unavailable" || !strings.Contains(c.Bot.RuntimeState.Reason, "не найден") {
		t.Errorf("docker missing: %+v", c.Bot.RuntimeState)
	}
	e, _ := f.reg.Get(f.ctx, id)
	if !strings.Contains(string(e.Attributes), `"container":"test-bot"`) {
		t.Errorf("container binding for Monitoring: %s", e.Attributes)
	}
	rec, err := f.do(t, id, "restart", "key-docker-1", true)
	if err != nil || rec.Status != "failed" || !strings.Contains(rec.Message, "Docker") {
		t.Errorf("restart without Docker must fail with a reason: %+v %v", rec, err)
	}

	// Fake Docker Engine API on a unix socket (no real Docker involved).
	sock := filepath.Join(f.dir, "d.sock")
	ln, err := net.Listen("unix", sock)
	if err != nil {
		t.Skip("unix sockets unavailable:", err)
	}
	var mu sync.Mutex
	var calls []string
	state := "exited"
	srv := &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		defer mu.Unlock()
		calls = append(calls, r.Method+" "+r.URL.Path)
		switch {
		case strings.Contains(r.URL.Path, "/containers/missing/"):
			w.WriteHeader(404)
			_, _ = w.Write([]byte(`{"message":"No such container"}`))
		case r.Method == "GET":
			fmt.Fprintf(w, `{"State":{"Status":%q,"Pid":42,"StartedAt":"2026-10-27T10:00:00Z"}}`, state)
		case strings.HasSuffix(r.URL.Path, "/start"):
			state = "running"
			w.WriteHeader(204)
		case strings.HasSuffix(r.URL.Path, "/stop"):
			state = "exited"
			w.WriteHeader(204)
		case strings.HasSuffix(r.URL.Path, "/restart"):
			state = "running"
			w.WriteHeader(204)
		}
	})}
	go srv.Serve(ln)
	t.Cleanup(func() { srv.Close() })
	da := f.svc.controllers["docker"].(*dockerAdapter)
	da.sock = sock
	da.client.Transport.(*http.Transport).DialContext = func(ctx context.Context, _, _ string) (net.Conn, error) {
		var d net.Dialer
		return d.DialContext(ctx, "unix", sock)
	}
	for i, a := range []string{"start", "restart", "stop"} {
		rec, err := f.do(t, id, a, fmt.Sprintf("key-docker-ok-%d", i), true)
		if err != nil || rec.Status != "succeeded" {
			t.Fatalf("%s: %+v %v", a, rec, err)
		}
	}
	if st := da.State(f.ctx, mustCtl(f, "ctr")); st.State != "stopped" {
		t.Errorf("state: %+v", st)
	}
	if _, err := da.Control(f.ctx, config.BotController{ID: "m", Kind: "docker", Container: "missing"}, id, "start"); err == nil || !strings.Contains(err.Error(), "не найден") {
		t.Errorf("missing container: %v", err)
	}
	mu.Lock()
	defer mu.Unlock()
	for _, c := range calls {
		if !strings.Contains(c, "/containers/test-bot/") && !strings.Contains(c, "/containers/missing/") {
			t.Errorf("unexpected Docker call %s", c)
		}
	}
}

func TestSystemdAdapterFakeRunner(t *testing.T) {
	f := newFixture(t, func(c *config.Bots) {
		c.Controllers = []config.BotController{{ID: "unit", Kind: "systemd_user", Unit: "test-bot.service", Allow: []string{"restart"}}}
	})
	sa := f.svc.controllers["systemd_user"].(*systemdAdapter)
	var calls [][]string
	sa.run = func(_ context.Context, args ...string) ([]byte, error) {
		calls = append(calls, args)
		if args[0] == "show" {
			return []byte("ActiveState=active\nSubState=running\nMainPID=777\nLoadState=loaded\n"), nil
		}
		return nil, nil
	}
	c := f.bot(t, NewBot{Name: "Юнит", Type: "service", ControllerID: "unit"})
	if c.Bot.RuntimeState.State != "running" || c.Bot.RuntimeState.PID != 777 {
		t.Fatalf("state: %+v", c.Bot.RuntimeState)
	}
	rec, err := f.do(t, c.Bot.EntityID, "restart", "key-unit-1", true)
	if err != nil || rec.Status != "succeeded" {
		t.Fatalf("restart: %+v %v", rec, err)
	}
	found := false
	for _, a := range calls {
		if len(a) == 2 && a[0] == "restart" && a[1] == "test-bot.service" {
			found = true
		}
	}
	if !found {
		t.Errorf("calls: %v", calls)
	}
	if err := (config.Bots{Controllers: []config.BotController{{ID: "x", Kind: "systemd_user", Unit: "evil; rm -rf /"}}}).Validate(); err == nil {
		t.Error("unsafe unit name accepted")
	}
}

type fakeN8N struct {
	mu       sync.Mutex
	calls    []string
	healthy  bool
	keyOK    bool
	execs    string
	retryKey string
}

func (n *fakeN8N) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	n.mu.Lock()
	defer n.mu.Unlock()
	n.calls = append(n.calls, r.Method+" "+r.URL.Path)
	if r.URL.Path == "/healthz" {
		if !n.healthy {
			w.WriteHeader(503)
			return
		}
		_, _ = w.Write([]byte(`{"status":"ok"}`))
		return
	}
	if r.Header.Get("X-N8N-API-KEY") != "test-key" || !n.keyOK {
		w.WriteHeader(401)
		return
	}
	switch {
	case r.Method == "GET" && r.URL.Path == "/api/v1/workflows":
		_, _ = w.Write([]byte(`{"data":[{"id":"wf1","name":"Ежедневный отчёт","active":true},{"id":"wf2","name":"Черновик","active":false}],"nextCursor":null}`))
	case r.Method == "GET" && r.URL.Path == "/api/v1/executions":
		_, _ = w.Write([]byte(n.execs))
	case r.Method == "POST" && strings.HasSuffix(r.URL.Path, "/retry"):
		n.retryKey = r.Header.Get("Idempotency-Key")
		_, _ = w.Write([]byte(`{"id":"103","mode":"retry","status":"running","workflowId":"wf1"}`))
	default:
		w.WriteHeader(404)
	}
}

func TestN8NAdapter(t *testing.T) {
	fake := &fakeN8N{healthy: true, keyOK: true, execs: `{"data":[
		{"id":101,"finished":true,"mode":"trigger","startedAt":"2026-10-27T09:00:00Z","stoppedAt":"2026-10-27T09:00:05Z","workflowId":"wf1","status":"success"},
		{"id":102,"finished":false,"mode":"trigger","startedAt":"2026-10-27T10:00:00Z","stoppedAt":"2026-10-27T10:00:02Z","workflowId":"wf1","status":"error"}]}`}
	srv := httptest.NewServer(fake)
	defer srv.Close()
	keyFile := filepath.Join(t.TempDir(), "n8n.key")
	_ = os.WriteFile(keyFile, []byte("test-key\n"), 0o600)
	f := newFixture(t, func(c *config.Bots) {
		c.N8N = []config.N8NInstance{{ID: "home", Label: "n8n (тест)", BaseURL: srv.URL, APIKeyFile: keyFile, AllowRetry: true}}
	})
	c := f.bot(t, NewBot{Name: "Автоматизации", Type: "automation", N8NInstanceID: "home"})
	id := c.Bot.EntityID
	if c.Bot.Runtime != "n8n" || c.Bot.LogSource != "n8n" {
		t.Errorf("defaults: %+v", c.Bot.Config)
	}
	e, _ := f.reg.Get(f.ctx, id)
	if !strings.Contains(string(e.Attributes), srv.URL+"/healthz") {
		t.Errorf("health URL for Monitoring: %s", e.Attributes)
	}
	f.svc.n8n.Sync(f.ctx)
	d, _ := f.svc.Get(f.ctx, id)
	if d.Integration == nil || d.Integration.Status != "ok" || len(d.Integration.Workflows) != 2 {
		t.Fatalf("integration: %+v", d.Integration)
	}
	if d.LastJobOK == nil || d.LastJobOK.Name != "Ежедневный отчёт" || *d.LastJobOK.DurationMs != 5000 || d.LastJobFailed == nil {
		t.Fatalf("jobs: ok=%+v failed=%+v", d.LastJobOK, d.LastJobFailed)
	}
	inc, _ := f.mon.Incidents(f.ctx, monitoring.IncidentFilter{EntityID: id, Status: "active"})
	if len(inc.Items) != 1 || inc.Items[0].Key != "n8n_failed:"+id {
		t.Errorf("failed execution incident: %+v", inc.Items)
	}
	// Sync again: the same failure does not create repeats.
	f.svc.n8n.Sync(f.ctx)
	inc, _ = f.mon.Incidents(f.ctx, monitoring.IncidentFilter{EntityID: id, Status: "active"})
	if inc.Items[0].Occurrences != 1 {
		t.Errorf("repeated sync re-raised the incident: %d", inc.Items[0].Occurrences)
	}

	// Retry needs a confirmation and the adapter's permission.
	failed := d.LastJobFailed
	cf, err := f.svc.Prepare(f.ctx, id, "job.retry", failed.ID)
	if err != nil {
		t.Fatal(err)
	}
	rec, err := f.svc.Execute(f.ctx, id, "job.retry", "key-retry-1", ActionRequest{ConfirmationToken: cf.Token, JobID: failed.ID})
	if err != nil || rec.Status != "succeeded" || fake.retryKey != "key-retry-1" {
		t.Fatalf("retry: %+v %v key=%q", rec, err, fake.retryKey)
	}
	var ae *ActionError
	if _, err := f.svc.Prepare(f.ctx, id, "job.retry", d.LastJobOK.ID); !errors.As(err, &ae) {
		t.Errorf("retry of a successful run must be refused: %v", err)
	}
	// Workflows are never modified: only reads and the confirmed retry.
	fake.mu.Lock()
	for _, call := range fake.calls {
		if !strings.HasPrefix(call, "GET ") && !strings.HasSuffix(call, "/api/v1/executions/102/retry") {
			t.Errorf("unexpected n8n call %s", call)
		}
	}
	fake.mu.Unlock()

	// n8n unavailable: reason visible, nothing crashes.
	fake.mu.Lock()
	fake.healthy = false
	fake.mu.Unlock()
	f.svc.n8n.Sync(f.ctx)
	d, _ = f.svc.Get(f.ctx, id)
	if d.Integration.Status != "unavailable" || !strings.Contains(d.Integration.Reason, "503") {
		t.Errorf("unavailable: %+v", d.Integration)
	}
	fake.mu.Lock()
	fake.healthy, fake.keyOK = true, false
	fake.mu.Unlock()
	rec, _ = f.svc.Execute(f.ctx, id, "check", "key-check-n8n", ActionRequest{})
	if rec.Status != "failed" || !strings.Contains(rec.Message, "ключ API") || strings.Contains(rec.Message, "test-key") {
		t.Errorf("check with a rejected key: %+v", rec)
	}
	srv.Close()
	f.svc.n8n.Sync(f.ctx)
	if d, _ = f.svc.Get(f.ctx, id); !strings.Contains(d.Integration.Reason, "не отвечает") {
		t.Errorf("down: %+v", d.Integration)
	}
}

func TestTelegramCheckNeverLeaksToken(t *testing.T) {
	const token = "123456789:AAFakeTokenForTestsOnly_abcdefghijkl"
	var path string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		path = r.URL.Path
		if strings.Contains(r.URL.Path, token) {
			_, _ = w.Write([]byte(`{"ok":true,"result":{"username":"aer_test_bot"}}`))
			return
		}
		w.WriteHeader(401)
		_, _ = w.Write([]byte(`{"ok":false,"description":"Unauthorized"}`))
	}))
	defer srv.Close()
	file := filepath.Join(t.TempDir(), "tg.token")
	_ = os.WriteFile(file, []byte(token), 0o600)
	f := newFixture(t, func(c *config.Bots) {
		c.TelegramAPIBase = srv.URL
		c.TelegramTokens = []config.TelegramToken{{ID: "test", File: file}}
	})
	c := f.bot(t, NewBot{Name: "TG", Type: "telegram_bot", TelegramTokenID: "test"})
	rec, _ := f.svc.Execute(f.ctx, c.Bot.EntityID, "check", "key-tg-1", ActionRequest{})
	if !strings.Contains(rec.Message, "@aer_test_bot") || path != "/bot"+token+"/getMe" {
		t.Errorf("getMe: %+v", rec)
	}
	_ = os.WriteFile(file, []byte("999:wrong"), 0o600)
	rec, _ = f.svc.Execute(f.ctx, c.Bot.EntityID, "check", "key-tg-2", ActionRequest{})
	srv.Close()
	rec3, _ := f.svc.Execute(f.ctx, c.Bot.EntityID, "check", "key-tg-3", ActionRequest{})
	for _, r := range []ActionRecord{rec, rec3} {
		if strings.Contains(r.Message, "999:wrong") || strings.Contains(r.Message, token) || r.Status != "failed" {
			t.Errorf("token leaked or wrong status: %+v", r)
		}
	}
	logs, _ := f.mon.Logs(f.ctx, monitoring.LogFilter{})
	ev, _ := f.mon.Events(f.ctx, "", 0, 200)
	raw, _ := json.Marshal([]any{logs, ev})
	if strings.Contains(string(raw), "AAFakeToken") || strings.Contains(string(raw), "999:wrong") {
		t.Error("token in logs or events")
	}
}

func TestConfigRejectsUnsafeControllers(t *testing.T) {
	bad := []config.BotController{
		{ID: "rel", Kind: "process", Command: []string{"python3", "bot.py"}, StopTimeoutSec: 5},
		{ID: "env", Kind: "process", Command: []string{testenv.Abs("/usr/bin/python3")}, Env: []string{"BOT_TOKEN=123"}, StopTimeoutSec: 5},
		{ID: "ctr", Kind: "docker", Container: "a b"},
		{ID: "act", Kind: "docker", Container: "x", Allow: []string{"exec"}},
		{ID: "Bad ID", Kind: "shell"},
	}
	for _, c := range bad {
		cfg := config.DefaultBots()
		cfg.Controllers = []config.BotController{c}
		if cfg.Validate() == nil {
			t.Errorf("accepted %+v", c)
		}
	}
	cfg := config.DefaultBots()
	cfg.N8N = []config.N8NInstance{{ID: "n", BaseURL: "http://user:pass@host", APIKeyFile: "/k"}}
	if cfg.Validate() == nil {
		t.Error("credentials in n8n URL accepted")
	}
}
