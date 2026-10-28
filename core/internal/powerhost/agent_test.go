package powerhost

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	"aerhome/core/internal/core"
	"aerhome/core/internal/foundation/config"
	"aerhome/core/internal/modules"
)

// End-to-end: a real in-process Core and the power agent with a FAKE
// system (fake files, fake command runner). No systemctl, efibootmgr,
// sudo, bcdedit or shutdown.exe is ever run; every power action here is
// SIMULATED by construction.

type fakeSys struct {
	mu     sync.Mutex
	calls  [][]string
	outs   map[string]string
	fails  map[string]bool
	files  map[string][]byte
	bootID string
}

func newFakeLinux() *fakeSys {
	f := newFakeLinuxBase()
	f.outs["sudo -n -l"] = "User test may run the following commands on pc-test:\n    (ALL : ALL) ALL\n    (root) NOPASSWD: /usr/bin/efibootmgr\n"
	return f
}

func newFakeLinuxBase() *fakeSys {
	return &fakeSys{bootID: "boot-1",
		outs: map[string]string{
			"efibootmgr":              efibootmgrOut,
			"lsblk -J -o NAME,FSTYPE": `{"blockdevices":[{"name":"nvme0n1","fstype":null,"children":[{"name":"nvme0n1p2","fstype":"ntfs"}]}]}`,
			"busctl call org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager CanPowerOff": `s "yes"`,
			"busctl call org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager CanReboot":   `s "yes"`,
			"busctl call org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager CanSuspend":  `s "challenge"`,
			"sudo -n /usr/bin/efibootmgr --bootnext 0003":                                                           "BootNext: 0003\nBootCurrent: 0001\n",
		},
		fails: map[string]bool{},
		files: map[string][]byte{
			"/etc/os-release": []byte("NAME=\"Ubuntu\"\nPRETTY_NAME=\"Ubuntu 24.04.5 LTS\"\n"),
			"/sys/firmware/efi/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c": {6, 0, 0, 0, 1},
		}}
}

func (f *fakeSys) run(_ context.Context, argv []string) ([]byte, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.calls = append(f.calls, slices.Clone(argv))
	k := strings.Join(argv, " ")
	if f.fails[k] {
		return []byte("permission denied"), errors.New("exit status 1")
	}
	return []byte(f.outs[k]), nil
}

func (f *fakeSys) read(p string) ([]byte, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if p == "/proc/sys/kernel/random/boot_id" {
		return []byte(f.bootID + "\n"), nil
	}
	if b, ok := f.files[p]; ok {
		return b, nil
	}
	return nil, os.ErrNotExist
}

func (f *fakeSys) ran(argv ...string) bool {
	f.mu.Lock()
	defer f.mu.Unlock()
	return slices.ContainsFunc(f.calls, func(c []string) bool { return slices.Equal(c, argv) })
}

func (f *fakeSys) host(goos string, cfg Config) *Host {
	return &Host{GOOS: goos, Run: f.run, ReadFile: f.read, cfg: cfg,
		Stat:     func(p string) (os.FileInfo, error) { return nil, nil },
		Hostname: func() (string, error) { return "pc-test", nil },
		MACs:     func() []string { return []string{"00:00:5e:00:53:aa"} }}
}

func testCfg() Config {
	return Config{CoreURL: "http://127.0.0.1:1", TokenFile: "/nonexistent/token", Allow: slices.Clone(allActions),
		BootNextHelper: []string{"sudo", "-n", "/usr/bin/efibootmgr"}, WindowsDelaySec: 30}
}

func argvs(steps []Step) [][]string {
	out := [][]string{}
	for _, s := range steps {
		out = append(out, s.Argv)
	}
	return out
}

func TestLinuxInventory(t *testing.T) {
	f := newFakeLinux()
	h := f.host("linux", testCfg())
	inv := h.Inventory(context.Background())
	if inv.OS != "linux" || inv.BootID != "boot-1" || inv.Firmware != "uefi" || inv.SecureBoot != "enabled" || inv.BitLocker != "off" ||
		inv.BootManager != "refind" || len(inv.BootEntries) != 4 || !inv.DryRun || inv.OSVersion != "Ubuntu 24.04.5 LTS" {
		t.Fatalf("inventory: %+v", inv)
	}
	if !inv.Actions["shutdown"].Supported || !inv.Actions["reboot"].Supported || !inv.Actions["bootNext"].Supported {
		t.Fatalf("actions: %+v", inv.Actions)
	}
	if s := inv.Actions["suspend"]; s.Supported || !strings.Contains(s.Reason, "polkit") {
		t.Fatalf("suspend challenge: %+v", s)
	}
	if !f.ran("sudo", "-n", "-l") {
		t.Fatal("helper check")
	}
	// A cached password (listing works, no NOPASSWD rule) does not count.
	f.outs["sudo -n -l"] = "User test may run the following commands on pc-test:\n    (ALL : ALL) ALL\n"
	cfg := testCfg()
	cfg.Allow = []string{"reboot"}
	inv = f.host("linux", cfg).Inventory(context.Background())
	if b := inv.Actions["bootNext"]; b.Supported || !strings.Contains(b.Reason, "sudoers") {
		t.Fatalf("no helper: %+v", b)
	}
	if s := inv.Actions["shutdown"]; s.Supported || !strings.Contains(s.Reason, "allow") {
		t.Fatalf("allow-list: %+v", s)
	}
	for _, c := range f.calls {
		if c[0] == "systemctl" || slices.Contains(c, "--bootnext") {
			t.Fatalf("inventory ran a state-changing command: %v", c)
		}
	}
}

func TestNopasswdAllows(t *testing.T) {
	bin := "/usr/bin/efibootmgr"
	for listing, want := range map[string]bool{
		"    (ALL : ALL) NOPASSWD: ALL":                                true,
		"    (root) NOPASSWD: /usr/bin/efibootmgr":                     true,
		"    (root) NOPASSWD: /usr/bin/efibootmgr --bootnext *":        true,
		"    (root) NOPASSWD: /usr/bin/systemctl, /usr/bin/efibootmgr": true,
		"    (ALL : ALL) ALL":                                          false,
		"    (root) NOPASSWD: /usr/bin/efibootmgr2":                    false,
		"    (root) PASSWD: /usr/bin/efibootmgr":                       false,
		"":                                                             false,
	} {
		if got := NopasswdAllows(listing, bin); got != want {
			t.Errorf("%q → %v", listing, got)
		}
	}
}

func TestPlanLinux(t *testing.T) {
	f := newFakeLinux()
	h := f.host("linux", testCfg())
	inv := h.Inventory(context.Background())
	steps, err := h.Plan(Command{Action: "shutdown"}, inv)
	if err != nil || !slices.EqualFunc(argvs(steps), [][]string{{"systemctl", "poweroff"}}, slices.Equal) {
		t.Fatalf("shutdown: %v %v", argvs(steps), err)
	}
	steps, err = h.Plan(Command{Action: "switch_os", EntryID: "0003", TargetOS: "windows"}, inv)
	want := [][]string{{"sudo", "-n", "/usr/bin/efibootmgr", "--bootnext", "0003"}, {"systemctl", "reboot"}}
	if err != nil || !slices.EqualFunc(argvs(steps), want, slices.Equal) {
		t.Fatalf("switch: %v %v", argvs(steps), err)
	}
	if steps[0].Check("BootNext: 0003\n") != nil || steps[0].Check("Could not set BootNext") == nil {
		t.Fatal("bootnext check")
	}
	for _, bad := range []Command{
		{Action: "switch_os", EntryID: "0003 --delete-bootnum", TargetOS: "windows"},
		{Action: "switch_os", EntryID: "0001", TargetOS: "windows"}, // rEFInd is not Windows
		{Action: "switch_os", EntryID: "0000", TargetOS: "linux"},   // already running
		{Action: "switch_os", EntryID: "0004", TargetOS: "other"},
		{Action: "suspend"}, // polkit challenge
		{Action: "format"},
	} {
		if s, err := h.Plan(bad, inv); err == nil {
			t.Errorf("%+v planned: %v", bad, argvs(s))
		}
	}
}

func TestPlanWindows(t *testing.T) {
	f := &fakeSys{outs: map[string]string{
		"bcdedit /enum firmware": bcdEN, "manage-bde -status C:": "Conversion Status: Fully Decrypted\nProtection Status: Protection Off",
		"powershell -NoProfile -NonInteractive -Command Confirm-SecureBootUEFI":        "True\r\n",
		"bcdedit /set {fwbootmgr} bootsequence {a0000000-0000-4000-8000-000000000002}": "The operation completed successfully.",
	}, fails: map[string]bool{}, files: map[string][]byte{}}
	h := f.host("windows", testCfg())
	inv := h.Inventory(context.Background())
	if inv.OS != "windows" || inv.SecureBoot != "enabled" || inv.BitLocker != "off" || !inv.Actions["bootNext"].Supported || inv.Actions["suspend"].Supported {
		t.Fatalf("windows inventory: %+v", inv)
	}
	steps, err := h.Plan(Command{Action: "switch_os", EntryID: "{a0000000-0000-4000-8000-000000000002}", TargetOS: "linux"}, inv)
	want := [][]string{{"bcdedit", "/set", "{fwbootmgr}", "bootsequence", "{a0000000-0000-4000-8000-000000000002}"},
		{"shutdown.exe", "/r", "/t", "30", "/c", "AER HOME: перезагрузка по команде владельца"}}
	if err != nil || !slices.EqualFunc(argvs(steps), want, slices.Equal) {
		t.Fatalf("switch: %v %v", argvs(steps), err)
	}
	if steps[0].Check("The operation completed successfully.") != nil || steps[0].Check("Access is denied.") == nil {
		t.Fatal("bcdedit check")
	}
	if s, _ := h.Plan(Command{Action: "shutdown"}, inv); s[0].Argv[0] != "shutdown.exe" || s[0].Argv[1] != "/s" {
		t.Fatalf("shutdown: %v", argvs(s))
	}
	// Not elevated: no firmware inventory, no OS switch.
	f.fails["bcdedit /enum firmware"] = true
	inv = h.Inventory(context.Background())
	if b := inv.Actions["bootNext"]; b.Supported || !strings.Contains(b.Reason, "администратора") {
		t.Fatalf("not elevated: %+v", b)
	}
}

// ---- end to end with a real Core ----

type env struct {
	t     *testing.T
	srv   *httptest.Server
	owner string
	dir   string
}

func (e *env) call(method, path, token, body string, out any, hdr ...string) int {
	e.t.Helper()
	var rd io.Reader
	if body != "" {
		rd = strings.NewReader(body)
	}
	req, _ := http.NewRequest(method, e.srv.URL+"/api/v1"+path, rd)
	req.Header.Set("Authorization", "Bearer "+token)
	for i := 0; i+1 < len(hdr); i += 2 {
		req.Header.Set(hdr[i], hdr[i+1])
	}
	res, err := e.srv.Client().Do(req)
	if err != nil {
		e.t.Fatal(err)
	}
	defer res.Body.Close()
	var envl struct{ Data json.RawMessage }
	_ = json.NewDecoder(res.Body).Decode(&envl)
	if out != nil {
		_ = json.Unmarshal(envl.Data, out)
	}
	return res.StatusCode
}

func waitUntil(t *testing.T, what string, cond func() bool) {
	t.Helper()
	for range 200 {
		if cond() {
			return
		}
		time.Sleep(25 * time.Millisecond)
	}
	t.Fatalf("timeout: %s", what)
}

func newEnv(t *testing.T) (*env, string, string) {
	dir := t.TempDir()
	cfg := config.Default(func(string) (string, bool) { return "", false })
	cfg.DataDir = filepath.Join(dir, "core")
	cfg.Monitoring.Docker.Enabled = false
	c, err := core.New(context.Background(), core.Options{Config: cfg, Logger: slog.New(slog.DiscardHandler), Modules: modules.All()})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { c.Close() })
	srv := httptest.NewServer(c.Handler())
	t.Cleanup(srv.Close)
	ownerRaw, _ := os.ReadFile(cfg.TokenPath())
	e := &env{t: t, srv: srv, owner: strings.TrimSpace(string(ownerRaw)), dir: dir}
	// TEST DATA: a dual-boot computer and its power agent credential.
	var pc struct{ ID string }
	e.call("POST", "/registry/entities", e.owner, `{"name":"ПК (тест)","type":"computer",
		"capabilities":["power.shutdown","power.reboot","power.suspend","power.switch_os"]}`, &pc)
	var cred struct {
		Token string
		Agent struct{ ID string }
	}
	e.call("POST", "/monitoring/agents", e.owner, `{"entityId":"`+pc.ID+`","name":"power ubuntu","kind":"power"}`, &cred)
	tok := filepath.Join(dir, "power.token")
	_ = os.WriteFile(tok, []byte(cred.Token), 0o600)
	return e, pc.ID, tok
}

type job struct {
	ID, State, Message string
	Simulated          bool
}

func (e *env) act(id, action, target, key string) job {
	e.t.Helper()
	var c struct{ Token string }
	if code := e.call("POST", "/power/devices/"+id+"/actions/"+action+"/confirm", e.owner, `{"targetOs":"`+target+`"}`, &c); code != 200 {
		e.t.Fatalf("confirm %s: %d", action, code)
	}
	var j job
	if code := e.call("POST", "/power/devices/"+id+"/actions/"+action, e.owner, `{"confirmationToken":"`+c.Token+`","targetOs":"`+target+`"}`, &j,
		"Idempotency-Key", key); code != 202 {
		e.t.Fatalf("execute %s: %d", action, code)
	}
	return j
}

func (e *env) job(id string) job {
	var j job
	e.call("GET", "/power/jobs/"+id, e.owner, "", &j)
	return j
}

func startAgent(t *testing.T, cfg Config, f *fakeSys) (*Agent, chan error, context.CancelFunc) {
	a := New(cfg, nil)
	a.host = f.host("linux", cfg)
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- a.Run(ctx) }()
	t.Cleanup(cancel)
	return a, done, cancel
}

func TestAgentEndToEnd(t *testing.T) {
	e, id, tok := newEnv(t)
	cfg := testCfg()
	cfg.CoreURL, cfg.TokenFile = e.srv.URL, tok
	f := newFakeLinux()

	// 1. Check mode (default): the job ends SIMULATED, nothing runs.
	_, done, cancel := startAgent(t, cfg, f)
	var dev struct{ State, CurrentOs string }
	waitUntil(t, "agent online", func() bool {
		e.call("GET", "/power/devices/"+id, e.owner, "", &dev)
		return dev.State == "online"
	})
	j := e.act(id, "reboot", "", "e2e-reboot-1")
	waitUntil(t, "simulated", func() bool { return e.job(j.ID).State == "simulated" })
	if j = e.job(j.ID); !j.Simulated || !strings.Contains(j.Message, "systemctl reboot") {
		t.Fatalf("simulated: %+v", j)
	}
	if f.ran("systemctl", "reboot") {
		t.Fatal("check mode executed a command")
	}
	cancel()
	<-done

	// 2. Execute mode with the FAKE runner: switch to Windows. The agent
	// sets BootNext through the helper, reboots and stops polling.
	e.call("PUT", "/power/devices/"+id+"/policy", e.owner, `{"enabled":true,"shutdown":true,"reboot":true,"suspend":true,"switchOs":true}`, nil)
	cfg.Execute = true
	a, done, _ := startAgent(t, cfg, f)
	waitUntil(t, "hello in execute mode", func() bool {
		var d struct {
			Agents []struct{ Info struct{ DryRun bool } }
		}
		e.call("GET", "/power/devices/"+id, e.owner, "", &d)
		return len(d.Agents) == 1 && !d.Agents[0].Info.DryRun
	})
	j = e.act(id, "switch_os", "windows", "e2e-switch-1")
	select {
	case err := <-done:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("agent kept running after reboot")
	}
	if !f.ran("sudo", "-n", "/usr/bin/efibootmgr", "--bootnext", "0003") || !f.ran("systemctl", "reboot") {
		t.Fatalf("argv: %v", f.calls)
	}
	if j = e.job(j.ID); j.State != "waiting" {
		t.Fatalf("waiting: %+v", j)
	}
	// Ubuntu comes back instead of Windows: honest failure, no retry.
	f.bootID = "boot-2"
	if err := a.Hello(context.Background()); err != nil {
		t.Fatal(err)
	}
	if j = e.job(j.ID); j.State != "failed" || !strings.Contains(j.Message, "вместо Windows") {
		t.Fatalf("wrong OS: %+v", j)
	}

	// 3. Replay and expiry are refused locally.
	if a.Handle(context.Background(), Command{ID: "c1", JobID: j.ID, Action: "reboot", ExpiresAt: time.Now().Add(-time.Second)}) {
		t.Fatal("expired command executed")
	}
	if a.Handle(context.Background(), Command{ID: "c1", JobID: j.ID, Action: "reboot", ExpiresAt: time.Now().Add(time.Minute)}) {
		t.Fatal("replayed command executed")
	}

	// 4. A failing step: the helper refuses → job failed, agent keeps going.
	f.mu.Lock()
	f.calls = nil
	f.outs["sudo -n /usr/bin/efibootmgr --bootnext 0003"] = "EFI variables are not supported"
	f.mu.Unlock()
	_, done, cancel = startAgent(t, cfg, f)
	waitUntil(t, "online again", func() bool {
		e.call("GET", "/power/devices/"+id, e.owner, "", &dev)
		return dev.State == "online"
	})
	j = e.act(id, "switch_os", "windows", "e2e-switch-2")
	waitUntil(t, "failed", func() bool { return e.job(j.ID).State == "failed" })
	if f.ran("systemctl", "reboot") {
		t.Fatal("rebooted although BootNext was not confirmed")
	}
	cancel()
	<-done
}

func TestAgentRevokedAndNoCore(t *testing.T) {
	e, id, tok := newEnv(t)
	cfg := testCfg()
	cfg.CoreURL, cfg.TokenFile = e.srv.URL, tok
	f := newFakeLinux()
	_, done, _ := startAgent(t, cfg, f)
	var d struct{ Agents []struct{ AgentID string } }
	waitUntil(t, "hello", func() bool {
		e.call("GET", "/power/devices/"+id, e.owner, "", &d)
		return len(d.Agents) == 1
	})
	e.call("POST", "/monitoring/agents/"+d.Agents[0].AgentID+"/revoke", e.owner, "", nil)
	select {
	case err := <-done:
		if err == nil || !strings.Contains(err.Error(), "credential rejected") {
			t.Fatalf("revoked: %v", err)
		}
	case <-time.After(30 * time.Second):
		t.Fatal("agent did not stop after revocation")
	}
	// No Core at all: the agent retries quietly and runs nothing.
	cfg.CoreURL = "http://127.0.0.1:1"
	g := newFakeLinux()
	_, done, cancel := startAgent(t, cfg, g)
	time.Sleep(300 * time.Millisecond)
	cancel()
	if err := <-done; err != nil {
		t.Fatal(err)
	}
	for _, c := range g.calls {
		if c[0] == "systemctl" || slices.Contains(c, "--bootnext") {
			t.Fatalf("ran without Core: %v", c)
		}
	}
}

func TestDeployExampleLoads(t *testing.T) {
	c, err := Load(filepath.Join("..", "..", "..", "deploy", "power-host.example.json"))
	if err != nil || c.Execute || len(c.Allow) != 4 {
		t.Fatalf("example: %+v %v", c, err)
	}
	bad := testCfg()
	bad.Allow = []string{"rm"}
	bad.BootNextHelper = []string{"efibootmgr"}
	if bad.Validate() == nil {
		t.Fatal("invalid config accepted")
	}
}
