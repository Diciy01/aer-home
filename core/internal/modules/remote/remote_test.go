package remote

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"errors"
	"math/big"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"aerhome/core/internal/foundation/config"
	"aerhome/core/internal/foundation/module"
	"aerhome/core/internal/foundation/storage"
	"aerhome/core/internal/modules/monitoring"
	"aerhome/core/internal/modules/registry"
)

// TEST DATA: computers, agents and passwords below are fixtures.

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

type fx struct {
	ctx    context.Context
	dbPath string
	reg    *registry.Service
	mon    *monitoring.Service
	svc    *Service
	clk    *clock
}

func newFx(t *testing.T, mut ...func(*config.Remote)) *fx {
	t.Helper()
	ctx := context.Background()
	path := filepath.Join(t.TempDir(), "t.db")
	db, err := storage.Open(ctx, path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { db.Close() })
	clk := &clock{t: time.Now().UTC().Truncate(time.Second)}
	mcfg := config.DefaultMonitoring()
	mcfg.Docker.Enabled = false
	rm, _ := registry.Factory(registry.DefaultCatalog())(module.Deps{DB: db})
	reg := rm.(*registry.Module).Writer()
	mm, _ := monitoring.Factory(func() registry.Reader { return reg }, clk.now)(module.Deps{DB: db, Config: config.Config{Monitoring: mcfg}})
	cfg := config.DefaultRemote()
	for _, m := range mut {
		m(&cfg)
	}
	for _, m := range []module.Module{rm, mm} {
		if _, err := storage.Migrate(ctx, db, m.Name(), m.Migrations()); err != nil {
			t.Fatal(err)
		}
	}
	if n, err := storage.Migrate(ctx, db, Name, migrations); err != nil || n != 2 {
		t.Fatalf("migrate %d %v", n, err)
	}
	return &fx{ctx: ctx, dbPath: path, reg: reg, mon: mm.(*monitoring.Module).Service(),
		svc: NewService(db, reg, mm.(*monitoring.Module).Service(), cfg, nil, clk.now), clk: clk}
}

func certPEM(t *testing.T) string {
	k, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	tpl := &x509.Certificate{SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "aer-test-host"},
		NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour)}
	der, err := x509.CreateCertificate(rand.Reader, tpl, tpl, &k.PublicKey, k)
	if err != nil {
		t.Fatal(err)
	}
	return string(pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}))
}

// host registers a computer with a remote agent that said hello.
func (f *fx) host(t *testing.T, name string, mut ...func(*HostInfo)) (registry.Entity, monitoring.Agent) {
	t.Helper()
	e, err := f.reg.Create(f.ctx, registry.NewEntity{Name: name, Type: "computer"})
	if err != nil {
		t.Fatal(err)
	}
	cr, err := f.mon.CreateAgent(f.ctx, e.ID, "remote "+name, "remote")
	if err != nil {
		t.Fatal(err)
	}
	a, _ := f.mon.Authenticate(f.ctx, cr.Token)
	info := HostInfo{OS: "linux", Backend: "gnome-rdp", Address: "192.0.2.10", Port: 3389, CertPEM: certPEM(t), FilesPort: 3390,
		Caps: Caps{Desktop: true, Input: true, Clipboard: true, Files: true}, Approval: "auto", Ready: true, Username: "aer"}
	for _, m := range mut {
		m(&info)
	}
	if _, err := f.svc.Hello(f.ctx, a, info); err != nil {
		t.Fatal(err)
	}
	return e, a
}

func refused(err error, reason string) bool {
	var re *RefusedError
	return errors.As(err, &re) && re.Reason == reason
}

func (f *fx) cmds(a monitoring.Agent) []Command { return f.svc.Commands(f.ctx, a, 10*time.Millisecond) }

func TestHostReadinessAndRegistry(t *testing.T) {
	f := newFx(t)
	bare, _ := f.reg.Create(f.ctx, registry.NewEntity{Name: "ПК без агента (тест)", Type: "computer"})
	h, _ := f.svc.Host(f.ctx, bare.ID)
	if h.CanConnect || !strings.Contains(h.Reason, "агент") {
		t.Errorf("a declared capability is not readiness: %+v", h)
	}
	if _, err := f.svc.Create(f.ctx, NewSession{EntityID: bare.ID}, ""); !refused(err, "not_ready") {
		t.Errorf("connect to a host without agent: %v", err)
	}
	e, _ := f.host(t, "ПК (тест)")
	h, _ = f.svc.Host(f.ctx, e.ID)
	if !h.CanConnect || !h.AgentActive || h.CertSHA256 == "" || !h.Effective.Desktop || h.Effective.Files {
		t.Fatalf("ready host (files off by default policy): %+v", h)
	}
	list, _ := f.svc.Hosts(f.ctx)
	if len(list) != 2 {
		t.Errorf("hosts: %d", len(list))
	}
	f.clk.add(2 * time.Minute) // agent silent
	h, _ = f.svc.Host(f.ctx, e.ID)
	if h.CanConnect || h.AgentActive {
		t.Errorf("silent agent must not look connectable: %+v", h)
	}
	srv, _ := f.reg.Create(f.ctx, registry.NewEntity{Name: "Сервер", Type: "server"})
	if h, _ := f.svc.Host(f.ctx, srv.ID); h.CanConnect || !strings.Contains(h.Reason, "Registry") {
		t.Errorf("no remote.desktop capability: %+v", h.Reason)
	}
	if a, _ := f.svc.Apps(f.ctx, e.ID); a.Status != "unsupported" || a.Reason == "" {
		t.Errorf("apps must be honest: %+v", a)
	}
}

func TestSessionLifecycleGrantOnce(t *testing.T) {
	f := newFx(t)
	e, a := f.host(t, "ПК (тест)")
	if _, err := f.svc.SetPolicy(f.ctx, e.ID, Policy{Enabled: true, Desktop: true, Clipboard: true, Files: true, MaxMinutes: 30}); err != nil {
		t.Fatal(err)
	}
	x, err := f.svc.Create(f.ctx, NewSession{EntityID: e.ID, SourceName: "Ноутбук (тест)", Minutes: 600}, "key-1")
	if err != nil || x.State != StatePending || !x.ExpiresAt.Equal(x.CreatedAt.Add(30*time.Minute)) {
		t.Fatalf("create: %+v %v", x, err)
	}
	again, _ := f.svc.Create(f.ctx, NewSession{EntityID: e.ID}, "key-1")
	if again.ID != x.ID {
		t.Error("same Idempotency-Key must return the same session")
	}
	c := f.cmds(a)
	if len(c) != 1 || c[0].Type != "open" || c[0].SessionID != x.ID || !c[0].Allowed.Files {
		t.Fatalf("open command: %+v", c)
	}
	if _, err := f.svc.Grant(f.ctx, x.ID); !refused(err, "not_ready") {
		t.Errorf("grant before ready: %v", err)
	}
	f.svc.OnAgentEvent(f.ctx, a, x.ID, AgentEvent{Event: "approved"})
	if _, err := f.svc.OnAgentEvent(f.ctx, a, x.ID, AgentEvent{Event: "ready"}); err == nil {
		t.Error("gnome host must deliver a session password")
	}
	x, _ = f.svc.OnAgentEvent(f.ctx, a, x.ID, AgentEvent{Event: "ready", Password: "Session-Pass-TEST-123", FilesToken: "files-token-test"})
	if x.State != StateConnecting {
		t.Fatalf("ready: %s", x.State)
	}
	g, err := f.svc.Grant(f.ctx, x.ID)
	if err != nil || g.Password != "Session-Pass-TEST-123" || g.Port != 3389 || g.CertPEM == "" || g.Files == nil || g.Files.Token != "files-token-test" {
		t.Fatalf("grant: %+v %v", g, err)
	}
	if _, err := f.svc.Grant(f.ctx, x.ID); !refused(err, "already_granted") {
		t.Errorf("second grant: %v", err)
	}
	raw, _ := os.ReadFile(f.dbPath)
	wal, _ := os.ReadFile(f.dbPath + "-wal")
	if strings.Contains(string(raw)+string(wal), "Session-Pass-TEST-123") || strings.Contains(string(raw)+string(wal), "files-token-test") {
		t.Error("session secrets must never be stored")
	}
	x, _ = f.svc.OnAgentEvent(f.ctx, a, x.ID, AgentEvent{Event: "connected"})
	if x.State != StateConnected || x.ConnectedAt == nil {
		t.Fatalf("connected: %+v", x)
	}
	if _, err := f.svc.Create(f.ctx, NewSession{EntityID: e.ID}, ""); !refused(err, "busy") {
		t.Errorf("second session on a busy host: %v", err)
	}
	x, _ = f.svc.OnAgentEvent(f.ctx, a, x.ID, AgentEvent{Event: "disconnected"})
	if x.State != StateReconnecting {
		t.Fatalf("lost: %s", x.State)
	}
	x, _ = f.svc.OnAgentEvent(f.ctx, a, x.ID, AgentEvent{Event: "connected"})
	if x.State != StateConnected {
		t.Fatalf("reconnected: %s", x.State)
	}
	x, _ = f.svc.End(f.ctx, x.ID)
	if x.State != StateDisconnected || x.EndedAt == nil {
		t.Fatalf("end: %+v", x)
	}
	if c := f.cmds(a); len(c) != 1 || c[0].Type != "close" {
		t.Errorf("close command: %+v", c)
	}
	x, _ = f.svc.Session(f.ctx, x.ID)
	kinds := []string{}
	for _, ev := range x.Events {
		kinds = append(kinds, ev.Kind)
	}
	want := "created approved ready granted connected connection_lost connected disconnected"
	if strings.Join(kinds, " ") != want {
		t.Errorf("audit: %v", kinds)
	}
	for _, ev := range x.Events {
		if strings.Contains(ev.Message, "Session-Pass") {
			t.Error("password in audit")
		}
	}
}

func TestAuthorizationOfAgents(t *testing.T) {
	f := newFx(t)
	e1, a1 := f.host(t, "ПК 1 (тест)")
	_, a2 := f.host(t, "ПК 2 (тест)")
	x, _ := f.svc.Create(f.ctx, NewSession{EntityID: e1.ID}, "")
	if _, err := f.svc.OnAgentEvent(f.ctx, a2, x.ID, AgentEvent{Event: "ready", Password: "p"}); !refused(err, "foreign") {
		t.Errorf("another host's agent: %v", err)
	}
	if c := f.cmds(a2); len(c) != 0 {
		t.Error("commands leaked to another host")
	}
	if c := f.cmds(a1); len(c) != 1 {
		t.Error("own commands")
	}
	// Revoking the host credential makes the host unreachable at once.
	if _, err := f.mon.RevokeAgent(f.ctx, a1.ID); err != nil {
		t.Fatal(err)
	}
	f.svc.End(f.ctx, x.ID)
	if h, _ := f.svc.Host(f.ctx, e1.ID); h.CanConnect || h.AgentActive {
		t.Errorf("revoked credential: %+v", h)
	}
	if _, err := f.svc.Hello(f.ctx, a2, HostInfo{Backend: "gnome-rdp", Address: "h", Port: 1, Approval: "auto"}); err == nil {
		t.Error("gnome host without certificate accepted")
	}
}

func TestTimeoutsExpiryAndRevoke(t *testing.T) {
	f := newFx(t)
	e, a := f.host(t, "ПК (тест)", func(i *HostInfo) { i.Approval = "prompt" })
	// Host never answers.
	x, _ := f.svc.Create(f.ctx, NewSession{EntityID: e.ID}, "")
	f.clk.add(31 * time.Second)
	f.svc.Sweep(f.ctx)
	if x, _ = f.svc.Session(f.ctx, x.ID); x.State != StateFailed {
		t.Fatalf("pickup timeout: %s", x.State)
	}
	f.cmds(a)
	// Nobody confirms on the host.
	f.host2(t, a)
	x, _ = f.svc.Create(f.ctx, NewSession{EntityID: e.ID}, "")
	f.svc.OnAgentEvent(f.ctx, a, x.ID, AgentEvent{Event: "awaiting_approval"})
	f.clk.add(121 * time.Second)
	f.svc.Sweep(f.ctx)
	if x, _ = f.svc.Session(f.ctx, x.ID); x.State != StateFailed || !strings.Contains(x.Reason, "подтверждения") {
		t.Fatalf("approval timeout: %+v", x)
	}
	// The grant is not fetched in time.
	f.host2(t, a)
	x, _ = f.svc.Create(f.ctx, NewSession{EntityID: e.ID}, "")
	f.svc.OnAgentEvent(f.ctx, a, x.ID, AgentEvent{Event: "ready", Password: "p-test"})
	f.clk.add(61 * time.Second)
	f.svc.Sweep(f.ctx)
	if x, _ = f.svc.Session(f.ctx, x.ID); x.State != StateExpired {
		t.Fatalf("grant ttl: %s", x.State)
	}
	if _, err := f.svc.Grant(f.ctx, x.ID); !refused(err, "ended") {
		t.Errorf("grant after expiry: %v", err)
	}
	// Session lifetime, then the lost connection grace.
	f.host2(t, a)
	x, _ = f.svc.Create(f.ctx, NewSession{EntityID: e.ID, Minutes: 5}, "")
	f.svc.OnAgentEvent(f.ctx, a, x.ID, AgentEvent{Event: "ready", Password: "p-test"})
	f.svc.Grant(f.ctx, x.ID)
	f.svc.OnAgentEvent(f.ctx, a, x.ID, AgentEvent{Event: "connected"})
	f.clk.add(6 * time.Minute)
	f.svc.Sweep(f.ctx)
	if x, _ = f.svc.Session(f.ctx, x.ID); x.State != StateExpired {
		t.Fatalf("lifetime: %s", x.State)
	}
	f.cmds(a)
	f.host2(t, a)
	x, _ = f.svc.Create(f.ctx, NewSession{EntityID: e.ID}, "")
	f.svc.OnAgentEvent(f.ctx, a, x.ID, AgentEvent{Event: "ready", Password: "p-test"})
	f.svc.Grant(f.ctx, x.ID)
	f.svc.OnAgentEvent(f.ctx, a, x.ID, AgentEvent{Event: "connected"})
	f.svc.OnAgentEvent(f.ctx, a, x.ID, AgentEvent{Event: "disconnected"})
	f.clk.add(121 * time.Second)
	f.svc.Sweep(f.ctx)
	if x, _ = f.svc.Session(f.ctx, x.ID); x.State != StateDisconnected || !strings.Contains(x.Reason, "Связь") {
		t.Fatalf("lost and not back: %+v", x)
	}
	// Revoke and policy switch-off.
	f.host2(t, a)
	x, _ = f.svc.Create(f.ctx, NewSession{EntityID: e.ID}, "")
	f.cmds(a)
	x, _ = f.svc.Revoke(f.ctx, x.ID)
	if x.State != StateRevoked {
		t.Fatalf("revoke: %s", x.State)
	}
	if c := f.cmds(a); len(c) != 1 || c[0].Type != "close" {
		t.Errorf("revoke must close on the host: %+v", c)
	}
	f.host2(t, a)
	x, _ = f.svc.Create(f.ctx, NewSession{EntityID: e.ID}, "")
	h, _ := f.svc.SetPolicy(f.ctx, e.ID, Policy{Enabled: false, MaxMinutes: 60})
	if x, _ = f.svc.Session(f.ctx, x.ID); x.State != StateRevoked || h.CanConnect {
		t.Fatalf("policy off must revoke and block: %s %v", x.State, h.CanConnect)
	}
	if _, err := f.svc.Create(f.ctx, NewSession{EntityID: e.ID, Kind: "app"}, ""); !refused(err, "apps_unsupported") {
		t.Errorf("apps: %v", err)
	}
}

// host2 refreshes the agent hello after the clock moved.
func (f *fx) host2(t *testing.T, a monitoring.Agent) {
	t.Helper()
	row, _ := f.svc.hostRow(f.ctx, a.EntityID)
	if _, err := f.svc.Hello(f.ctx, a, row.info); err != nil {
		t.Fatal(err)
	}
}

func TestParallelCreatesAndLimit(t *testing.T) {
	f := newFx(t, func(c *config.Remote) { c.MaxActiveSessions = 2 })
	e, _ := f.host(t, "ПК (тест)")
	var wg sync.WaitGroup
	var mu sync.Mutex
	okN, busy := 0, 0
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			_, err := f.svc.Create(f.ctx, NewSession{EntityID: e.ID}, "")
			mu.Lock()
			defer mu.Unlock()
			switch {
			case err == nil:
				okN++
			case refused(err, "busy"):
				busy++
			}
		}()
	}
	wg.Wait()
	if okN != 1 || busy != 7 {
		t.Fatalf("one session per host: ok=%d busy=%d", okN, busy)
	}
	e2, _ := f.host(t, "ПК 2 (тест)")
	if _, err := f.svc.Create(f.ctx, NewSession{EntityID: e2.ID}, ""); err != nil {
		t.Fatal(err)
	}
	e3, _ := f.host(t, "ПК 3 (тест)")
	if _, err := f.svc.Create(f.ctx, NewSession{EntityID: e3.ID}, ""); !refused(err, "limit") {
		t.Errorf("global limit: %v", err)
	}
	if _, err := f.svc.Create(f.ctx, NewSession{EntityID: e3.ID}, "k"); err == nil {
		t.Error("limit")
	}
	if _, err := f.svc.Create(f.ctx, NewSession{EntityID: e2.ID}, "k2"); !refused(err, "busy") {
		t.Errorf("busy e2: %v", err)
	}
}

func TestCertFingerprint(t *testing.T) {
	if _, err := CertFingerprint("garbage"); err == nil {
		t.Error("garbage accepted")
	}
	fp, err := CertFingerprint(certPEM(t))
	if err != nil || len(fp) != 95 {
		t.Errorf("fp %q %v", fp, err)
	}
}
