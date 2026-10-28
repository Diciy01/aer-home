package power

import (
	"bytes"
	"context"
	"errors"
	"net"
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

// TEST DATA: computers, MACs, boot entries and agents below are fixtures
// (MACs from the documentation range 00:00:5e:00:53:xx, RFC 7042).
// Every power operation is SIMULATED: no packet leaves loopback and no
// host command runs.

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

type sent struct {
	iface string
	dst   string
	port  int
	data  []byte
}

type fakeNet struct {
	mu   sync.Mutex
	ifs  []Interface
	sent []sent
	err  error
}

func (n *fakeNet) Interfaces() ([]Interface, error) { return n.ifs, nil }
func (n *fakeNet) Send(_ context.Context, iface string, dst net.IP, port int, p []byte) error {
	n.mu.Lock()
	defer n.mu.Unlock()
	if n.err != nil {
		return n.err
	}
	n.sent = append(n.sent, sent{iface, dst.String(), port, append([]byte(nil), p...)})
	return nil
}
func (n *fakeNet) count() int { n.mu.Lock(); defer n.mu.Unlock(); return len(n.sent) }

type fx struct {
	ctx context.Context
	reg *registry.Service
	mon *monitoring.Service
	svc *Service
	clk *clock
	net *fakeNet
}

const (
	coreMAC = "00:00:5e:00:53:01"
	pcMAC   = "00:00:5e:00:53:aa"
)

func newFx(t *testing.T, mut ...func(*config.Power)) *fx {
	t.Helper()
	ctx := context.Background()
	db, err := storage.Open(ctx, filepath.Join(t.TempDir(), "t.db"))
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
	cfg := config.DefaultPower()
	cfg.WoL.Enabled = true
	for _, m := range mut {
		m(&cfg)
	}
	for _, m := range []module.Module{rm, mm} {
		if _, err := storage.Migrate(ctx, db, m.Name(), m.Migrations()); err != nil {
			t.Fatal(err)
		}
	}
	if n, err := storage.Migrate(ctx, db, Name, migrations); err != nil || n != 1 {
		t.Fatalf("migrate %d %v", n, err)
	}
	fn := &fakeNet{ifs: []Interface{{Name: "eth0", MAC: coreMAC, Up: true, Addresses: []string{"192.168.50.2/24"}, Broadcasts: []string{"192.168.50.255"}}}}
	mon := mm.(*monitoring.Module).Service()
	return &fx{ctx: ctx, reg: reg, mon: mon, svc: NewService(db, reg, mon, cfg, nil, clk.now, fn), clk: clk, net: fn}
}

var allPowerCaps = []string{"power.wake", "power.shutdown", "power.reboot", "power.suspend", "power.switch_os", "network.ping"}

func (f *fx) computer(t *testing.T, name string, caps ...string) registry.Entity {
	t.Helper()
	if caps == nil {
		caps = allPowerCaps
	}
	e, err := f.reg.Create(f.ctx, registry.NewEntity{Name: name, Type: "computer", Capabilities: &caps})
	if err != nil {
		t.Fatal(err)
	}
	return e
}

func linuxInfo(boot string) HostInfo {
	yes := Capability{Supported: true}
	return HostInfo{OS: "linux", Hostname: "pc-test", BootID: boot, Firmware: "uefi", SecureBoot: "enabled", BitLocker: "off",
		BootManager: "refind", MACs: []string{pcMAC},
		BootEntries: []BootEntry{{ID: "0000", Label: "Ubuntu", OS: "linux"}, {ID: "0001", Label: "rEFInd", OS: "bootmanager", Current: true},
			{ID: "0003", Label: "Windows Boot Manager", OS: "windows"}},
		Actions: map[string]Capability{"shutdown": yes, "reboot": yes, "suspend": yes, "bootNext": yes}}
}

func (f *fx) agent(t *testing.T, e registry.Entity, name string) monitoring.Agent {
	t.Helper()
	cr, err := f.mon.CreateAgent(f.ctx, e.ID, name, "power")
	if err != nil {
		t.Fatal(err)
	}
	a, ok := f.mon.Authenticate(f.ctx, cr.Token)
	if !ok {
		t.Fatal("auth")
	}
	return a
}

func (f *fx) hello(t *testing.T, a monitoring.Agent, info HostInfo) {
	t.Helper()
	if _, err := f.svc.Hello(f.ctx, a, info); err != nil {
		t.Fatal(err)
	}
}

func (f *fx) device(t *testing.T, id string) Device {
	t.Helper()
	d, err := f.svc.Device(f.ctx, id)
	if err != nil {
		t.Fatal(err)
	}
	return d
}

func actionOf(d Device, a string) ActionInfo {
	for _, x := range d.Actions {
		if x.ID == a {
			return x
		}
	}
	return ActionInfo{}
}

func (f *fx) run(t *testing.T, id, action, target, key string) (Job, error) {
	t.Helper()
	c, err := f.svc.Prepare(f.ctx, id, action, target)
	if err != nil {
		return Job{}, err
	}
	return f.svc.Execute(f.ctx, id, action, key, ActionRequest{ConfirmationToken: c.Token, TargetOS: target})
}

func (f *fx) cmds(a monitoring.Agent) []Command { return f.svc.Commands(f.ctx, a, 10*time.Millisecond) }

func (f *fx) event(t *testing.T, a monitoring.Agent, job, kind string) {
	t.Helper()
	if _, err := f.svc.OnAgentEvent(f.ctx, a, job, AgentEvent{Kind: kind}); err != nil {
		t.Fatal(err)
	}
}

func (f *fx) job(t *testing.T, id string) Job {
	t.Helper()
	j, err := f.svc.Job(f.ctx, id)
	if err != nil {
		t.Fatal(err)
	}
	return j
}

func refused(err error, reason string) bool {
	var re *RefusedError
	return errors.As(err, &re) && re.Reason == reason
}

func (f *fx) incidents(t *testing.T, entityID string) []monitoring.Incident {
	p, err := f.mon.Incidents(f.ctx, monitoring.IncidentFilter{EntityID: entityID, Status: "active"})
	if err != nil {
		t.Fatal(err)
	}
	return p.Items
}

// ---- Wake-on-LAN primitives ----

func TestMagicPacket(t *testing.T) {
	p, err := MagicPacket(pcMAC)
	if err != nil || len(p) != 102 {
		t.Fatalf("len %d %v", len(p), err)
	}
	if !bytes.Equal(p[:6], bytes.Repeat([]byte{0xFF}, 6)) {
		t.Fatal("sync stream")
	}
	mac := []byte{0x00, 0x00, 0x5e, 0x00, 0x53, 0xaa}
	for i := range 16 {
		if !bytes.Equal(p[6+i*6:12+i*6], mac) {
			t.Fatalf("repetition %d", i)
		}
	}
}

func TestParseMAC(t *testing.T) {
	for _, in := range []string{"00:00:5E:00:53:AA", "00-00-5e-00-53-aa", "00005e0053aa", "0000.5e00.53aa", " 00:00:5e:00:53:aa "} {
		if m, err := ParseMAC(in); err != nil || m != pcMAC {
			t.Errorf("%q → %q %v", in, m, err)
		}
	}
	for _, in := range []string{"", "00:00:5e:00:53", "zz:00:5e:00:53:aa", "01:00:5e:00:00:01", "ff:ff:ff:ff:ff:ff",
		"00:00:00:00:00:00", "00:00:5e:00:53:aa:01:02", "00:00:5e:00:53:aa; reboot"} {
		if _, err := ParseMAC(in); err == nil {
			t.Errorf("%q accepted", in)
		}
	}
}

func TestCheckDestination(t *testing.T) {
	for _, ok := range []string{"192.168.1.255", "10.0.0.255", "172.16.5.255", "255.255.255.255", "127.0.0.1", "169.254.1.255"} {
		if _, err := CheckDestination(ok); err != nil {
			t.Errorf("%s: %v", ok, err)
		}
	}
	for _, bad := range []string{"8.8.8.8", "203.0.113.255", "::1", "fe80::1", "example.org", "", "192.168.1.256"} {
		if _, err := CheckDestination(bad); err == nil {
			t.Errorf("%s accepted", bad)
		}
	}
}

// TestSystemNetLoopbackReceiver delivers a real magic packet to a test UDP
// receiver on 127.0.0.1 (never to the LAN), with and without an interface.
func TestSystemNetLoopbackReceiver(t *testing.T) {
	rx, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	defer rx.Close()
	port := rx.LocalAddr().(*net.UDPAddr).Port
	pkt, _ := MagicPacket(pcMAC)
	var lo string
	ifs, _ := SystemNet{}.Interfaces()
	for _, i := range ifs {
		if i.Loopback && i.Up && len(i.Addresses) > 0 {
			lo = i.Name
		}
	}
	for _, iface := range []string{"", lo} {
		if err := (SystemNet{}).Send(context.Background(), iface, net.IPv4(127, 0, 0, 1), port, pkt); err != nil {
			t.Fatalf("send via %q: %v", iface, err)
		}
		buf := make([]byte, 512)
		_ = rx.SetReadDeadline(time.Now().Add(2 * time.Second))
		n, from, err := rx.ReadFromUDP(buf)
		if err != nil || !bytes.Equal(buf[:n], pkt) {
			t.Fatalf("received %d bytes from %v: %v", n, from, err)
		}
	}
	if err := (SystemNet{}).Send(context.Background(), "aer-no-such-if0", net.IPv4(127, 0, 0, 1), port, pkt); err == nil {
		t.Fatal("unknown interface accepted")
	}
}

// ---- wake ----

func TestWakeFlow(t *testing.T) {
	f := newFx(t)
	e := f.computer(t, "ПК (тест)")
	d := f.device(t, e.ID)
	if w := actionOf(d, ActionWake); w.Available || !strings.Contains(w.Reason, "MAC") {
		t.Fatalf("wake without MAC: %+v", w)
	}
	if _, err := f.svc.SetWoL(f.ctx, e.ID, WoLTarget{MAC: "00:00:5e:00:53:aa", Broadcast: "8.8.8.8"}); err == nil {
		t.Fatal("internet destination accepted")
	}
	if _, err := f.svc.SetWoL(f.ctx, e.ID, WoLTarget{MAC: pcMAC, Broadcast: "192.168.50.255", Interface: "wlan9"}); err == nil {
		t.Fatal("unknown interface accepted")
	}
	if _, err := f.svc.SetWoL(f.ctx, e.ID, WoLTarget{MAC: "00-00-5E-00-53-AA", Broadcast: "192.168.50.255", Interface: "eth0"}); err != nil {
		t.Fatal(err)
	}
	d = f.device(t, e.ID)
	if d.WoL.MAC != pcMAC || !actionOf(d, ActionWake).Available || d.SameMachine {
		t.Fatalf("device: %+v %+v", d.WoL, actionOf(d, ActionWake))
	}
	if d.State != "unknown" {
		t.Fatalf("state %s", d.State)
	}
	// No confirmation → refused, audited.
	if _, err := f.svc.Execute(f.ctx, e.ID, ActionWake, "key-wake-0", ActionRequest{}); !refused(err, "confirmation_required") {
		t.Fatalf("no confirmation: %v", err)
	}
	if f.net.count() != 0 {
		t.Fatal("packet sent without confirmation")
	}
	j, err := f.run(t, e.ID, ActionWake, "", "key-wake-1")
	if err != nil || j.State != JobWaiting {
		t.Fatalf("wake: %+v %v", j, err)
	}
	if f.net.count() != 3 {
		t.Fatalf("packets %d", f.net.count())
	}
	s := f.net.sent[0]
	want, _ := MagicPacket(pcMAC)
	if s.iface != "eth0" || s.dst != "192.168.50.255" || s.port != 9 || !bytes.Equal(s.data, want) {
		t.Fatalf("sent %+v", s)
	}
	// Replay of the same key: same job, nothing re-sent.
	again, err := f.svc.Execute(f.ctx, e.ID, ActionWake, "key-wake-1", ActionRequest{})
	if err != nil || !again.Replayed || again.ID != j.ID || f.net.count() != 3 {
		t.Fatalf("replay: %+v %v (sent %d)", again, err, f.net.count())
	}
	if _, err := f.svc.Execute(f.ctx, e.ID, ActionShutdown, "key-wake-1", ActionRequest{}); !refused(err, "key_reused") {
		t.Fatalf("key reuse for another action: %v", err)
	}
	if d := f.device(t, e.ID); d.State != "waking" || actionOf(d, ActionWake).Available {
		t.Fatalf("while waking: %s %+v", d.State, actionOf(d, ActionWake))
	}
	// The PC boots and its agent reports.
	f.clk.add(40 * time.Second)
	f.hello(t, f.agent(t, e, "power ubuntu"), linuxInfo("boot-1"))
	if j = f.job(t, j.ID); j.State != JobSucceeded || len(j.Events) < 3 {
		t.Fatalf("after hello: %+v", j)
	}
	if d := f.device(t, e.ID); d.State != "online" || d.CurrentOS != "linux" {
		t.Fatalf("online: %s %s", d.State, d.CurrentOS)
	}
	if w := actionOf(f.device(t, e.ID), ActionWake); w.Available || w.Reason != "Компьютер уже включён" {
		t.Fatalf("already on: %+v", w)
	}
}

func TestWakeTimeoutRaisesIncident(t *testing.T) {
	f := newFx(t)
	e := f.computer(t, "ПК (тест)")
	if _, err := f.svc.SetWoL(f.ctx, e.ID, WoLTarget{MAC: pcMAC, Broadcast: "192.168.50.255"}); err != nil {
		t.Fatal(err)
	}
	j, err := f.run(t, e.ID, ActionWake, "", "key-wake-2")
	if err != nil {
		t.Fatal(err)
	}
	f.clk.add(time.Duration(f.svc.cfg.BootTimeoutSec-1) * time.Second)
	f.svc.Sweep(f.ctx)
	if f.job(t, j.ID).State != JobWaiting {
		t.Fatal("finished before the deadline")
	}
	f.clk.add(2 * time.Second)
	f.svc.Sweep(f.ctx)
	j = f.job(t, j.ID)
	if j.State != JobTimeout || !strings.Contains(j.Message, "UEFI") {
		t.Fatalf("timeout: %+v", j)
	}
	if inc := f.incidents(t, e.ID); len(inc) != 1 || inc[0].Source != "power" {
		t.Fatalf("incidents: %+v", inc)
	}
}

func TestWakeSendErrorAndDisabledConfig(t *testing.T) {
	f := newFx(t)
	e := f.computer(t, "ПК (тест)")
	_, _ = f.svc.SetWoL(f.ctx, e.ID, WoLTarget{MAC: pcMAC})
	f.net.err = errors.New("network is unreachable")
	j, err := f.run(t, e.ID, ActionWake, "", "key-wake-3")
	if err != nil || j.State != JobFailed || !strings.Contains(j.Message, "unreachable") {
		t.Fatalf("send error: %+v %v", j, err)
	}
	g := newFx(t, func(c *config.Power) { c.WoL.Enabled = false })
	e = g.computer(t, "ПК (тест)")
	_, _ = g.svc.SetWoL(g.ctx, e.ID, WoLTarget{MAC: pcMAC})
	if w := actionOf(g.device(t, e.ID), ActionWake); w.Available || !strings.Contains(w.Reason, "power.wol.enabled") {
		t.Fatalf("disabled: %+v", w)
	}
	if _, err := g.svc.Prepare(g.ctx, e.ID, ActionWake, ""); !refused(err, "unavailable") {
		t.Fatalf("prepare while disabled: %v", err)
	}
}

func TestSameMachineAsCore(t *testing.T) {
	f := newFx(t)
	e := f.computer(t, "Этот ПК (тест)")
	if _, err := f.svc.SetWoL(f.ctx, e.ID, WoLTarget{MAC: coreMAC}); err != nil {
		t.Fatal(err)
	}
	d := f.device(t, e.ID)
	if !d.SameMachine || d.SameMachineNote == "" || actionOf(d, ActionWake).Available {
		t.Fatalf("same machine: %+v %+v", d.SameMachine, actionOf(d, ActionWake))
	}
	// Agent MACs reveal it too; shutdown is allowed but warns.
	g := newFx(t)
	e = g.computer(t, "Этот ПК (тест)")
	info := linuxInfo("b")
	info.MACs = []string{coreMAC}
	g.hello(t, g.agent(t, e, "power"), info)
	c, err := g.svc.Prepare(g.ctx, e.ID, ActionShutdown, "")
	if err != nil || !strings.Contains(strings.Join(c.Risks, " "), "Core работает на этом компьютере") {
		t.Fatalf("risks: %+v %v", c.Risks, err)
	}
}

// ---- agent actions ----

func TestShutdownFlow(t *testing.T) {
	f := newFx(t)
	e := f.computer(t, "ПК (тест)")
	a := f.agent(t, e, "power ubuntu")
	f.hello(t, a, linuxInfo("boot-1"))
	j, err := f.run(t, e.ID, ActionShutdown, "", "key-shut-1")
	if err != nil || j.State != JobQueued {
		t.Fatalf("queued: %+v %v", j, err)
	}
	cmds := f.cmds(a)
	if len(cmds) != 1 || cmds[0].Action != "shutdown" || cmds[0].JobID != j.ID {
		t.Fatalf("commands: %+v", cmds)
	}
	if len(f.cmds(a)) != 0 {
		t.Fatal("command delivered twice")
	}
	if f.job(t, j.ID).State != JobSent {
		t.Fatal("not sent")
	}
	if _, err := f.svc.Cancel(f.ctx, j.ID); !refused(err, "not_cancellable") {
		t.Fatalf("cancel after delivery: %v", err)
	}
	f.event(t, a, j.ID, "accepted")
	f.event(t, a, j.ID, "executing")
	if d := f.device(t, e.ID); d.State != "shutting_down" {
		t.Fatalf("state %s", d.State)
	}
	f.clk.add(30 * time.Second)
	f.svc.Sweep(f.ctx)
	if f.job(t, j.ID).State != JobWaiting {
		t.Fatal("decided too early")
	}
	f.clk.add(20 * time.Second)
	f.svc.Sweep(f.ctx)
	if j = f.job(t, j.ID); j.State != JobSucceeded || !strings.Contains(j.Message, "перестало отвечать") {
		t.Fatalf("after silence: %+v", j)
	}
}

func TestShutdownStillAnswering(t *testing.T) {
	f := newFx(t)
	e := f.computer(t, "ПК (тест)")
	a := f.agent(t, e, "power")
	f.hello(t, a, linuxInfo("boot-1"))
	j, _ := f.run(t, e.ID, ActionShutdown, "", "key-shut-2")
	f.cmds(a)
	f.event(t, a, j.ID, "executing")
	for range 10 { // the host keeps polling: it did not power off
		f.clk.add(20 * time.Second)
		f.cmds(a)
		f.svc.Sweep(f.ctx)
	}
	if j = f.job(t, j.ID); j.State != JobTimeout || !strings.Contains(j.Message, "продолжает отвечать") {
		t.Fatalf("still answering: %+v", j)
	}
	if len(f.incidents(t, e.ID)) != 1 {
		t.Fatal("no incident")
	}
}

func TestConfirmationSingleUseBoundAndExpiring(t *testing.T) {
	f := newFx(t)
	e := f.computer(t, "ПК (тест)")
	other := f.computer(t, "Другой ПК (тест)")
	a := f.agent(t, e, "power")
	f.hello(t, a, linuxInfo("boot-1"))
	f.hello(t, f.agent(t, other, "power2"), linuxInfo("boot-x"))
	c, err := f.svc.Prepare(f.ctx, e.ID, ActionReboot, "")
	if err != nil || len(c.Risks) == 0 || len(c.Checks) == 0 {
		t.Fatalf("prepare: %+v %v", c, err)
	}
	// A reboot token is not a shutdown token, and is burnt by the attempt.
	if _, err := f.svc.Execute(f.ctx, e.ID, ActionShutdown, "key-conf-1", ActionRequest{ConfirmationToken: c.Token}); !refused(err, "confirmation_required") {
		t.Fatalf("other action: %v", err)
	}
	if _, err := f.svc.Execute(f.ctx, e.ID, ActionReboot, "key-conf-2", ActionRequest{ConfirmationToken: c.Token}); !refused(err, "confirmation_required") {
		t.Fatalf("burnt token: %v", err)
	}
	c, _ = f.svc.Prepare(f.ctx, e.ID, ActionReboot, "")
	if _, err := f.svc.Execute(f.ctx, other.ID, ActionReboot, "key-conf-3", ActionRequest{ConfirmationToken: c.Token}); !refused(err, "confirmation_required") {
		t.Fatalf("other device: %v", err)
	}
	c, _ = f.svc.Prepare(f.ctx, e.ID, ActionReboot, "")
	f.clk.add(time.Duration(f.svc.cfg.ConfirmTTLSec+1) * time.Second)
	f.hello(t, a, linuxInfo("boot-1"))
	if _, err := f.svc.Execute(f.ctx, e.ID, ActionReboot, "key-conf-4", ActionRequest{ConfirmationToken: c.Token}); !refused(err, "confirmation_required") {
		t.Fatalf("expired: %v", err)
	}
	if _, err := f.svc.Execute(f.ctx, e.ID, ActionReboot, "short", ActionRequest{}); err == nil {
		t.Fatal("short Idempotency-Key accepted")
	}
	jobs, _ := f.svc.Jobs(f.ctx, e.ID, 50)
	if len(jobs) != 3 {
		t.Fatalf("audit of refusals: %d", len(jobs))
	}
	for _, j := range jobs {
		if j.State != JobRejected {
			t.Fatalf("audit: %+v", j)
		}
	}
	if len(f.cmds(a)) != 0 {
		t.Fatal("refused request reached the agent")
	}
}

func TestCancelQueuedAndPolicyRevoke(t *testing.T) {
	f := newFx(t)
	e := f.computer(t, "ПК (тест)")
	a := f.agent(t, e, "power")
	f.hello(t, a, linuxInfo("boot-1"))
	j, _ := f.run(t, e.ID, ActionReboot, "", "key-cancel-1")
	if j, err := f.svc.Cancel(f.ctx, j.ID); err != nil || j.State != JobCancelled {
		t.Fatalf("cancel: %+v %v", j, err)
	}
	if len(f.cmds(a)) != 0 {
		t.Fatal("cancelled command delivered")
	}
	if _, err := f.svc.Cancel(f.ctx, j.ID); !refused(err, "not_cancellable") {
		t.Fatal("cancel twice")
	}
	// Revoking permission withdraws a queued job.
	j, _ = f.run(t, e.ID, ActionShutdown, "", "key-cancel-2")
	p := DefaultPolicy()
	p.Shutdown = false
	d, err := f.svc.SetPolicy(f.ctx, e.ID, p)
	if err != nil || actionOf(d, ActionShutdown).Available {
		t.Fatalf("policy: %v", err)
	}
	if j = f.job(t, j.ID); j.State != JobCancelled || len(f.cmds(a)) != 0 {
		t.Fatalf("revoked: %+v", j)
	}
	p.Enabled = false
	d, _ = f.svc.SetPolicy(f.ctx, e.ID, p)
	for _, x := range d.Actions {
		if x.ID != ActionCheck && x.Available {
			t.Fatalf("%s available with power disabled", x.ID)
		}
	}
	d.Policy.Revision = 1
	if _, err := f.svc.SetPolicy(f.ctx, e.ID, d.Policy); !refused(err, "revision_mismatch") {
		t.Fatalf("stale revision: %v", err)
	}
}

func TestPickupTimeoutAndRecover(t *testing.T) {
	f := newFx(t)
	e := f.computer(t, "ПК (тест)")
	a := f.agent(t, e, "power")
	f.hello(t, a, linuxInfo("boot-1"))
	j, _ := f.run(t, e.ID, ActionReboot, "", "key-pick-1")
	f.clk.add(time.Duration(f.svc.cfg.PickupTimeoutSec+1) * time.Second)
	f.svc.Sweep(f.ctx)
	if j = f.job(t, j.ID); j.State != JobFailed || !strings.Contains(j.Message, "не забрал") {
		t.Fatalf("pickup: %+v", j)
	}
	if len(f.cmds(a)) != 0 {
		t.Fatal("expired command delivered")
	}
	// Sent but never reported.
	f.hello(t, a, linuxInfo("boot-1"))
	j, _ = f.run(t, e.ID, ActionReboot, "", "key-pick-2")
	f.cmds(a)
	f.clk.add(time.Duration(f.svc.cfg.PickupTimeoutSec+1) * time.Second)
	f.svc.Sweep(f.ctx)
	if j = f.job(t, j.ID); j.State != JobTimeout {
		t.Fatalf("no report: %+v", j)
	}
	// Core restart: a queued command is failed, never re-sent.
	f.hello(t, a, linuxInfo("boot-1"))
	j, _ = f.run(t, e.ID, ActionReboot, "", "key-pick-3")
	f.svc.Recover(f.ctx)
	if j = f.job(t, j.ID); j.State != JobFailed || !strings.Contains(j.Message, "перезапущен") {
		t.Fatalf("recover: %+v", j)
	}
}

func TestAgentFailureSimulationAndIsolation(t *testing.T) {
	f := newFx(t)
	e := f.computer(t, "ПК (тест)")
	a := f.agent(t, e, "power")
	f.hello(t, a, linuxInfo("boot-1"))
	j, _ := f.run(t, e.ID, ActionReboot, "", "key-fail-1")
	f.cmds(a)
	// Another device's agent cannot see or move this job.
	o := f.computer(t, "Чужой ПК (тест)")
	oa := f.agent(t, o, "power other")
	if _, err := f.svc.OnAgentEvent(f.ctx, oa, j.ID, AgentEvent{Kind: "simulated"}); !errors.Is(err, ErrNotFound) {
		t.Fatalf("foreign agent: %v", err)
	}
	if _, err := f.svc.OnAgentEvent(f.ctx, a, j.ID, AgentEvent{Kind: "rm -rf"}); err == nil {
		t.Fatal("unknown event kind")
	}
	f.event(t, a, j.ID, "failed")
	if j = f.job(t, j.ID); j.State != JobFailed || len(f.incidents(t, e.ID)) != 1 {
		t.Fatalf("failed: %+v", j)
	}
	if _, err := f.svc.OnAgentEvent(f.ctx, a, j.ID, AgentEvent{Kind: "executing"}); !refused(err, "not_active") {
		t.Fatal("event after the end")
	}
	// Check mode: nothing runs, the job says so; a success resolves the incident.
	info := linuxInfo("boot-1")
	info.DryRun = true
	f.hello(t, a, info)
	c, _ := f.svc.Prepare(f.ctx, e.ID, ActionReboot, "")
	if !strings.Contains(strings.Join(c.Risks, " "), "SIMULATED") {
		t.Fatalf("dry-run risk: %+v", c.Risks)
	}
	j, _ = f.svc.Execute(f.ctx, e.ID, ActionReboot, "key-fail-2", ActionRequest{ConfirmationToken: c.Token})
	f.cmds(a)
	f.event(t, a, j.ID, "simulated")
	if j = f.job(t, j.ID); j.State != JobSimulated || !j.Simulated {
		t.Fatalf("simulated: %+v", j)
	}
	j, _ = f.run(t, e.ID, ActionReboot, "", "key-fail-3")
	f.cmds(a)
	f.event(t, a, j.ID, "executing")
	f.clk.add(30 * time.Second)
	f.hello(t, a, linuxInfo("boot-2"))
	if j = f.job(t, j.ID); j.State != JobSucceeded || len(f.incidents(t, e.ID)) != 0 {
		t.Fatalf("reboot: %+v, incidents %d", j, len(f.incidents(t, e.ID)))
	}
}

func TestRebootNeedsNewBoot(t *testing.T) {
	f := newFx(t)
	e := f.computer(t, "ПК (тест)")
	a := f.agent(t, e, "power")
	f.hello(t, a, linuxInfo("boot-1"))
	j, _ := f.run(t, e.ID, ActionReboot, "", "key-boot-1")
	f.cmds(a)
	f.event(t, a, j.ID, "executing")
	f.clk.add(10 * time.Second)
	f.hello(t, a, linuxInfo("boot-1")) // same boot: not rebooted yet
	if f.job(t, j.ID).State != JobWaiting {
		t.Fatal("same boot accepted")
	}
	f.clk.add(time.Duration(f.svc.cfg.BootTimeoutSec) * time.Second)
	f.svc.Sweep(f.ctx)
	if j = f.job(t, j.ID); j.State != JobTimeout || !strings.Contains(j.Message, "автоматического повтора нет") {
		t.Fatalf("timeout: %+v", j)
	}
	if len(f.cmds(a)) != 0 {
		t.Fatal("reboot repeated automatically")
	}
}

// ---- dual boot ----

func TestSwitchOS(t *testing.T) {
	f := newFx(t)
	e := f.computer(t, "ПК dual-boot (тест)")
	ub := f.agent(t, e, "power ubuntu")
	f.hello(t, ub, linuxInfo("boot-1"))
	d := f.device(t, e.ID)
	if sw := actionOf(d, ActionSwitchOS); sw.Available || sw.Reason != "Действие запрещено политикой устройства" {
		t.Fatalf("off by default: %+v", sw)
	}
	p := d.Policy
	p.SwitchOS = true
	d, _ = f.svc.SetPolicy(f.ctx, e.ID, p)
	sw := actionOf(d, ActionSwitchOS)
	if !sw.Available || len(sw.Targets) != 2 || sw.Targets[0].Available || !sw.Targets[1].Available || sw.Targets[1].EntryID != "0003" {
		t.Fatalf("targets: %+v", sw)
	}
	if _, err := f.svc.Prepare(f.ctx, e.ID, ActionSwitchOS, "linux"); !refused(err, "target_unavailable") {
		t.Fatalf("current OS as target: %v", err)
	}
	if _, err := f.svc.Prepare(f.ctx, e.ID, ActionSwitchOS, "macos"); err == nil {
		t.Fatal("unknown target")
	}
	c, err := f.svc.Prepare(f.ctx, e.ID, ActionSwitchOS, "windows")
	if err != nil || !strings.Contains(strings.Join(c.Risks, " "), "Secure Boot") {
		t.Fatalf("prepare: %+v %v", c, err)
	}
	// A token for Windows is not a token for another target.
	if _, err := f.svc.Execute(f.ctx, e.ID, ActionSwitchOS, "key-sw-0", ActionRequest{ConfirmationToken: c.Token, TargetOS: "linux"}); err == nil {
		t.Fatal("target swapped")
	}
	j, err := f.run(t, e.ID, ActionSwitchOS, "windows", "key-sw-1")
	if err != nil || j.BootEntryID != "0003" || j.FromOS != "linux" {
		t.Fatalf("job: %+v %v", j, err)
	}
	cmds := f.cmds(ub)
	if len(cmds) != 1 || cmds[0].EntryID != "0003" || cmds[0].TargetOS != "windows" {
		t.Fatalf("command: %+v", cmds)
	}
	f.event(t, ub, j.ID, "executing")
	if f.device(t, e.ID).State != "switching" {
		t.Fatal("state")
	}
	// Windows comes up with its own agent on the same entity.
	f.clk.add(90 * time.Second)
	win := f.agent(t, e, "power windows")
	wi := HostInfo{OS: "windows", BootID: "win-boot-1", Firmware: "uefi", SecureBoot: "enabled", BitLocker: "off",
		BootEntries: []BootEntry{{ID: "{a0000000-0000-4000-8000-000000000001}", Label: "Windows Boot Manager", OS: "windows", Current: true}},
		Actions:     map[string]Capability{"shutdown": {Supported: true}, "reboot": {Supported: true}, "suspend": {Reason: "Не поддерживается"}}}
	f.hello(t, win, wi)
	if j = f.job(t, j.ID); j.State != JobSucceeded {
		t.Fatalf("switch: %+v", j)
	}
	d = f.device(t, e.ID)
	if d.CurrentOS != "windows" || actionOf(d, ActionSuspend).Available || actionOf(d, ActionSuspend).Reason != "Не поддерживается" {
		t.Fatalf("after switch: %s %+v", d.CurrentOS, actionOf(d, ActionSuspend))
	}
	if sw := actionOf(d, ActionSwitchOS); sw.Available || !strings.Contains(sw.Reason, "Не поддерживается") && !strings.Contains(sw.Reason, "не поддерживает") {
		t.Fatalf("no bootNext on windows agent: %+v", sw)
	}
}

func TestSwitchOSWrongOSComesBack(t *testing.T) {
	f := newFx(t)
	e := f.computer(t, "ПК dual-boot (тест)")
	ub := f.agent(t, e, "power ubuntu")
	f.hello(t, ub, linuxInfo("boot-1"))
	p := DefaultPolicy()
	p.SwitchOS = true
	_, _ = f.svc.SetPolicy(f.ctx, e.ID, p)
	j, _ := f.run(t, e.ID, ActionSwitchOS, "windows", "key-sw-2")
	f.cmds(ub)
	f.event(t, ub, j.ID, "executing")
	f.clk.add(60 * time.Second)
	f.hello(t, ub, linuxInfo("boot-2")) // Ubuntu again: BootNext ignored
	if j = f.job(t, j.ID); j.State != JobFailed || !strings.Contains(j.Message, "Загрузилась Ubuntu вместо Windows") {
		t.Fatalf("wrong OS: %+v", j)
	}
	if len(f.cmds(ub)) != 0 {
		t.Fatal("automatic retry")
	}
}

func TestSwitchOSPrechecks(t *testing.T) {
	f := newFx(t)
	e := f.computer(t, "ПК (тест)")
	a := f.agent(t, e, "power")
	p := DefaultPolicy()
	p.SwitchOS = true
	_, _ = f.svc.SetPolicy(f.ctx, e.ID, p)
	// BitLocker on blocks until the owner allows it.
	info := linuxInfo("b")
	info.BitLocker = "on"
	f.hello(t, a, info)
	if sw := actionOf(f.device(t, e.ID), ActionSwitchOS); sw.Available || !strings.Contains(sw.Reason, "BitLocker") {
		t.Fatalf("bitlocker: %+v", sw)
	}
	p.AllowWithBitLocker = true
	_, _ = f.svc.SetPolicy(f.ctx, e.ID, p)
	c, err := f.svc.Prepare(f.ctx, e.ID, ActionSwitchOS, "windows")
	if err != nil || !strings.Contains(strings.Join(c.Risks, " "), "ключ восстановления") {
		t.Fatalf("bitlocker allowed: %+v %v", c.Risks, err)
	}
	// Target missing / ambiguous.
	info = linuxInfo("b")
	info.BootEntries = []BootEntry{{ID: "0000", Label: "Ubuntu", OS: "linux"}}
	f.hello(t, a, info)
	if sw := actionOf(f.device(t, e.ID), ActionSwitchOS); sw.Available || !strings.Contains(sw.Reason, "не найдена") {
		t.Fatalf("missing: %+v", sw)
	}
	info.BootEntries = append(info.BootEntries, BootEntry{ID: "0003", OS: "windows"}, BootEntry{ID: "0004", OS: "windows"})
	f.hello(t, a, info)
	if sw := actionOf(f.device(t, e.ID), ActionSwitchOS); sw.Available || !strings.Contains(sw.Reason, "неоднозначен") {
		t.Fatalf("ambiguous: %+v", sw)
	}
	// Bootloader helper missing on the host.
	info = linuxInfo("b")
	info.Actions["bootNext"] = Capability{Reason: "Нет помощника с правами для efibootmgr --bootnext"}
	f.hello(t, a, info)
	if sw := actionOf(f.device(t, e.ID), ActionSwitchOS); sw.Available || !strings.Contains(sw.Reason, "помощника") {
		t.Fatalf("helper: %+v", sw)
	}
}

func TestHelloValidation(t *testing.T) {
	f := newFx(t)
	e := f.computer(t, "ПК (тест)")
	a := f.agent(t, e, "power")
	bad := []func(*HostInfo){
		func(i *HostInfo) { i.OS = "macos" },
		func(i *HostInfo) { i.BootEntries[0].ID = "0003; reboot" },
		func(i *HostInfo) { i.BootEntries[0].ID = "--bootnext" },
		func(i *HostInfo) { i.BootEntries[0].OS = "dos" },
		func(i *HostInfo) { i.MACs = []string{"nope"} },
		func(i *HostInfo) { i.Actions["exec"] = Capability{Supported: true} },
		func(i *HostInfo) { i.SecureBoot = "maybe" },
		func(i *HostInfo) { i.BitLocker = "" },
	}
	for n, m := range bad {
		info := linuxInfo("b")
		m(&info)
		if _, err := f.svc.Hello(f.ctx, a, info); err == nil {
			t.Errorf("case %d accepted", n)
		}
	}
	if !ValidEntryID("000A") || !ValidEntryID("{a0000000-0000-4000-8000-0000000000ff}") || ValidEntryID("{bootmgr}") {
		t.Fatal("entry ids")
	}
}

func TestOneJobPerDeviceAndGlobalLimit(t *testing.T) {
	f := newFx(t, func(c *config.Power) { c.MaxActiveJobs = 2 })
	var ids []string
	for i := range 3 {
		e := f.computer(t, "ПК "+string(rune('A'+i))+" (тест)")
		f.hello(t, f.agent(t, e, "power"), linuxInfo("b"))
		ids = append(ids, e.ID)
	}
	if _, err := f.run(t, ids[0], ActionReboot, "", "key-lim-1"); err != nil {
		t.Fatal(err)
	}
	if r := actionOf(f.device(t, ids[0]), ActionShutdown); r.Available || !strings.Contains(r.Reason, "Уже выполняется") {
		t.Fatalf("busy: %+v", r)
	}
	if _, err := f.run(t, ids[1], ActionReboot, "", "key-lim-2"); err != nil {
		t.Fatal(err)
	}
	if _, err := f.run(t, ids[2], ActionReboot, "", "key-lim-3"); !refused(err, "limit") {
		t.Fatalf("global limit: %v", err)
	}
}

func TestConcurrentSameKey(t *testing.T) {
	f := newFx(t)
	e := f.computer(t, "ПК (тест)")
	a := f.agent(t, e, "power")
	f.hello(t, a, linuxInfo("b"))
	var wg sync.WaitGroup
	got := make([]string, 8)
	for i := range 8 {
		c, _ := f.svc.Prepare(f.ctx, e.ID, ActionReboot, "")
		wg.Add(1)
		go func() {
			defer wg.Done()
			j, err := f.svc.Execute(f.ctx, e.ID, ActionReboot, "key-same-1", ActionRequest{ConfirmationToken: c.Token})
			if err == nil {
				got[i] = j.ID
			}
		}()
	}
	wg.Wait()
	for _, g := range got {
		if g != got[0] || g == "" {
			t.Fatalf("ids: %v", got)
		}
	}
	if n := len(f.cmds(a)); n != 1 {
		t.Fatalf("commands %d", n)
	}
}

func TestCapabilitiesAgentsAndCheck(t *testing.T) {
	f := newFx(t)
	e := f.computer(t, "ПК без питания (тест)", "network.ping")
	a := f.agent(t, e, "power")
	f.hello(t, a, linuxInfo("b"))
	d := f.device(t, e.ID)
	if r := actionOf(d, ActionReboot); r.Available || !strings.Contains(r.Reason, "power.reboot") {
		t.Fatalf("registry capability: %+v", r)
	}
	// Check is read-only, needs no confirmation and asks for fresh inventory.
	j, err := f.svc.Execute(f.ctx, e.ID, ActionCheck, "key-check-1", ActionRequest{})
	if err != nil || j.State != JobSucceeded {
		t.Fatalf("check: %+v %v", j, err)
	}
	_, _ = f.svc.Execute(f.ctx, e.ID, ActionCheck, "key-check-2", ActionRequest{})
	if c := f.cmds(a); len(c) != 1 || c[0].Action != "inventory" || c[0].JobID != "" {
		t.Fatalf("inventory (coalesced): %+v", c)
	}
	if _, err := f.svc.Prepare(f.ctx, e.ID, ActionCheck, ""); err == nil {
		t.Fatal("check confirmation")
	}
	// A revoked agent is not "active": no actions, offline after silence.
	if _, err := f.mon.RevokeAgent(f.ctx, a.ID); err != nil {
		t.Fatal(err)
	}
	g := f.computer(t, "ПК 2 (тест)")
	ga := f.agent(t, g, "power")
	f.hello(t, ga, linuxInfo("b"))
	_, _ = f.mon.RevokeAgent(f.ctx, ga.ID)
	if r := actionOf(f.device(t, g.ID), ActionReboot); r.Available || !strings.Contains(r.Reason, "не на связи") {
		t.Fatalf("revoked agent: %+v", r)
	}
	list, err := f.svc.Devices(f.ctx)
	if err != nil || len(list) != 2 {
		t.Fatalf("devices: %d %v", len(list), err)
	}
}

func TestPrune(t *testing.T) {
	f := newFx(t)
	e := f.computer(t, "ПК (тест)")
	_, _ = f.svc.Execute(f.ctx, e.ID, ActionCheck, "key-prune-1", ActionRequest{})
	f.clk.add(time.Duration(f.svc.cfg.RetentionDays+1) * 24 * time.Hour)
	if err := f.svc.Prune(f.ctx); err != nil {
		t.Fatal(err)
	}
	if j, _ := f.svc.Jobs(f.ctx, e.ID, 10); len(j) != 0 {
		t.Fatalf("kept %d", len(j))
	}
}
