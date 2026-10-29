package remotegw

import (
	"bufio"
	"context"
	"crypto/tls"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"aerhome/core/internal/connecthost"
	"aerhome/core/internal/core"
	"aerhome/core/internal/foundation/config"
	"aerhome/core/internal/modules"
	"aerhome/core/internal/remoteengine"
	"aerhome/core/internal/remotehost"
	"aerhome/core/internal/testenv"
)

// AER Connect Anywhere end to end (ADR-018), loopback only: a real Core and
// Gateway (pinned TLS) that can both be restarted on the same addresses, a
// host device running the real connecthost runtime over its stdio protocol
// (backend: the FAKE RDP service of this package, consent answered by the
// test), and viewer devices doing exactly what AER Connect does over HTTP.
// TEST DATA: every device, code and password here is generated.

type anywhere struct {
	t                *testing.T
	dir              string
	cfg              config.Config
	coreAddr, gwAddr string
	core             *core.Core
	coreSrv, gwSrv   *http.Server
	gw               *Gateway
	gwFP             string
	owner            string
	gwToken          string
}

func listenOn(t *testing.T, addr string) net.Listener {
	t.Helper()
	var ln net.Listener
	var err error
	for range 50 { // the old listener of a restart may need a moment
		if ln, err = net.Listen("tcp", addr); err == nil {
			return ln
		}
		time.Sleep(50 * time.Millisecond)
	}
	t.Fatal(err)
	return nil
}

func (s *anywhere) startCore() {
	c, err := core.New(context.Background(), core.Options{Config: s.cfg, Logger: slog.New(slog.DiscardHandler), Modules: modules.All()})
	if err != nil {
		s.t.Fatal(err)
	}
	ln := listenOn(s.t, s.coreAddr)
	s.coreAddr = ln.Addr().String()
	s.core, s.coreSrv = c, &http.Server{Handler: c.Handler()}
	go func() { _ = s.coreSrv.Serve(ln) }()
}

func (s *anywhere) stopCore() {
	_ = s.coreSrv.Close()
	s.core.Close()
}

func (s *anywhere) startGateway() {
	gcfg := Default()
	gcfg.ListenAddr, gcfg.CoreURL, gcfg.TokenFile, gcfg.StateDir = s.gwAddr, "http://"+s.coreAddr, filepath.Join(s.dir, "gateway.token"), filepath.Join(s.dir, "gw")
	gcfg.PairWaitSec = 5
	g, err := New(gcfg, slog.New(slog.DiscardHandler))
	if err != nil {
		s.t.Fatal(err)
	}
	tc, _ := g.TLSConfig()
	ln := listenOn(s.t, s.gwAddr)
	s.gwAddr = ln.Addr().String()
	srv := &http.Server{Handler: g.Handler(), TLSConfig: tc, TLSNextProto: map[string]func(*http.Server, *tls.Conn, http.Handler){}}
	go func() { _ = srv.Serve(tls.NewListener(ln, tc)) }()
	ctx, cancel := context.WithCancel(context.Background())
	go g.Maintain(ctx)
	s.t.Cleanup(cancel)
	s.gw, s.gwSrv = g, srv
	s.gwFP, _ = g.Fingerprint()
}

func (s *anywhere) stopGateway() {
	_ = s.gwSrv.Close()
	s.gw.closeAll()
}

func newAnywhere(t *testing.T) *anywhere {
	dir := t.TempDir()
	cfg := config.Default(func(string) (string, bool) { return "", false })
	cfg.DataDir = filepath.Join(dir, "core")
	cfg.Monitoring.Docker.Enabled = false
	s := &anywhere{t: t, dir: dir, cfg: cfg, coreAddr: "127.0.0.1:0", gwAddr: "127.0.0.1:0"}
	s.startCore()
	t.Cleanup(func() { s.stopCore() })
	raw, _ := os.ReadFile(cfg.TokenPath())
	s.owner = strings.TrimSpace(string(raw))
	var server struct{ ID string }
	s.ownerCall("POST", "/registry/entities", `{"name":"Домашний сервер (тест)","type":"server"}`, &server)
	var gw struct{ Token string }
	s.ownerCall("POST", "/monitoring/agents", `{"entityId":"`+server.ID+`","name":"gateway","kind":"gateway"}`, &gw)
	_ = os.WriteFile(filepath.Join(dir, "gateway.token"), []byte(gw.Token), 0o600)
	s.startGateway()
	t.Cleanup(func() { s.stopGateway() })
	return s
}

func (s *anywhere) ownerCall(method, path, body string, out any) int {
	s.t.Helper()
	req, _ := http.NewRequest(method, "http://"+s.coreAddr+"/api/v1"+path, strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer "+s.owner)
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		s.t.Fatal(err)
	}
	defer res.Body.Close()
	var env struct{ Data json.RawMessage }
	_ = json.NewDecoder(res.Body).Decode(&env)
	if out != nil {
		_ = json.Unmarshal(env.Data, out)
	}
	return res.StatusCode
}

// device is one AER Connect installation as the app sees it.
type device struct {
	s                *anywhere
	hc               *http.Client
	number, entityID string
	agentToken, cred string
	boxKey, installT string
}

func (s *anywhere) gwURL() string { return "https://" + s.gwAddr }

func (d *device) call(method, path string, body any, out any) (int, string, string) {
	d.s.t.Helper()
	var rd io.Reader
	if body != nil {
		b, _ := json.Marshal(body)
		rd = strings.NewReader(string(b))
	}
	req, _ := http.NewRequest(method, d.s.gwURL()+path, rd)
	if d.cred != "" {
		req.Header.Set("Authorization", "Bearer "+d.cred)
	}
	res, err := d.hc.Do(req)
	if err != nil {
		return 0, err.Error(), ""
	}
	defer res.Body.Close()
	var env struct {
		Data  json.RawMessage
		Error struct {
			Code, Message string
			Details       struct{ Reason string }
		}
	}
	_ = json.NewDecoder(res.Body).Decode(&env)
	if out != nil {
		_ = json.Unmarshal(env.Data, out)
	}
	return res.StatusCode, env.Error.Code, env.Error.Details.Reason
}

func (s *anywhere) enroll(code, name string) *device {
	s.t.Helper()
	k, _ := remoteengine.NewBoxKey()
	d := &device{s: s, hc: &http.Client{Transport: &http.Transport{TLSClientConfig: remoteengine.PinnedTLS(s.gwFP)}, Timeout: 40 * time.Second},
		boxKey: remoteengine.EncodeKey(k.Bytes()), installT: "install-" + name + "-0123456789abcdef"}
	var e struct {
		Number, EntityID, AgentToken, ClientCredential string
	}
	st, c, _ := d.call("POST", "/gw/v1/devices/enroll", map[string]string{"code": code, "deviceName": name,
		"boxPub": remoteengine.EncodeKey(k.PublicKey().Bytes()), "instance": connecthost.Instance(d.installT)}, &e)
	if st != 200 {
		s.t.Fatalf("enroll %s: %d %s", name, st, c)
	}
	d.number, d.entityID, d.agentToken, d.cred = e.Number, e.EntityID, e.AgentToken, e.ClientCredential
	return d
}

// hostProc runs the connecthost runtime like the app runs aer-connect-host.
type hostProc struct {
	stdin  *io.PipeWriter
	mu     sync.Mutex
	status []connecthost.Out
	other  []connecthost.Out
	done   chan error
	rdp    *fakeRDP
	prompt chan bool
}

func (h *hostProc) last() connecthost.Out {
	h.mu.Lock()
	defer h.mu.Unlock()
	if len(h.status) == 0 {
		return connecthost.Out{}
	}
	return h.status[len(h.status)-1]
}

func (h *hostProc) send(c connecthost.Command) {
	b, _ := json.Marshal(c)
	_, _ = h.stdin.Write(append(b, '\n'))
}

func (d *device) runHost(t *testing.T, incoming bool) *hostProc {
	inR, inW := io.Pipe()
	outR, outW := io.Pipe()
	h := &hostProc{stdin: inW, done: make(chan error, 1), rdp: newFakeRDP(t, "ПК "+d.number), prompt: make(chan bool, 4)}
	exe := testenv.ExistingFile(t)
	newAgent := func(cfg remotehost.Config, log *slog.Logger) (*remotehost.Agent, error) {
		// Same agent, FAKE desktop: the test's RDP stand-in instead of the
		// native helper; consent comes from the test, never automatically.
		cfg.Backend, cfg.ShadowExecutable, cfg.ShadowSource = "gnome-rdp", "", ""
		cfg.Grdctl, cfg.Daemon, cfg.Port, cfg.RDPUser, cfg.PromptCommand = []string{"grdctl"}, []string{exe}, h.rdp.port(), "aer", []string{"consent"}
		if err := cfg.Validate(); err != nil {
			return nil, err
		}
		a, err := remotehost.New(cfg, log)
		if err != nil {
			return nil, err
		}
		a.SetRunner(func(context.Context, []string) ([]byte, error) { return []byte("RDP:\n\tStatus: disabled\n"), nil },
			func([]string) (func(), error) { return func() {}, nil })
		a.Connections = func() int { return int(h.rdp.live.Load()) }
		a.Prompt = func(ctx context.Context, text string) bool {
			if !strings.Contains(text, "AER Connect") {
				t.Errorf("prompt without viewer: %q", text)
			}
			select {
			case ok := <-h.prompt:
				return ok
			case <-ctx.Done():
				return false
			}
		}
		return a, nil
	}
	go func() {
		h.done <- connecthost.Run(context.Background(), inR, outW, connecthost.Options{NewAgent: newAgent})
		outW.Close()
	}()
	go func() {
		sc := bufio.NewScanner(outR)
		for sc.Scan() {
			var o connecthost.Out
			_ = json.Unmarshal(sc.Bytes(), &o)
			h.mu.Lock()
			if o.Type == "status" {
				h.status = append(h.status, o)
			} else {
				h.other = append(h.other, o)
			}
			h.mu.Unlock()
		}
	}()
	init := connecthost.Init{Type: "init", GatewayURL: d.s.gwURL(), GatewayCertSHA256: d.s.gwFP, AgentToken: d.agentToken, BoxKey: d.boxKey,
		Number: d.number, InstallID: d.installT, StateDir: filepath.Join(d.s.dir, "host-"+d.number), ShadowExecutable: exe,
		Clipboard: true, AllowIncoming: incoming}
	b, _ := json.Marshal(init)
	_, _ = inW.Write(append(b, '\n'))
	t.Cleanup(func() {
		inW.Close()
		select {
		case <-h.done:
		case <-time.After(10 * time.Second):
			t.Error("host runtime did not stop after stdin closed")
		}
	})
	return h
}

// connect does what AER Connect's «Подключиться» does: challenge, seal, connect.
func (d *device) connect(number, password string) (string, int, string) {
	var ch struct{ AttemptID, Number, BoxPub, ViewerNumber string }
	st, code, reason := d.call("POST", "/gw/v1/connect/challenge", map[string]string{"number": number}, &ch)
	if st != 200 {
		return "", st, or(reason, code)
	}
	sealed, err := remoteengine.SealPassword(ch.BoxPub, remoteengine.ConnectAuth{AttemptID: ch.AttemptID, ViewerNumber: ch.ViewerNumber, TargetNumber: ch.Number}, password, time.Now())
	if err != nil {
		d.s.t.Fatal(err)
	}
	var x struct{ ID string }
	st, code, reason = d.call("POST", "/gw/v1/connect", map[string]any{"attemptId": ch.AttemptID, "ephPub": sealed.EphPub, "ciphertext": sealed.Ciphertext}, &x)
	return x.ID, st, or(reason, code)
}

func or(a, b string) string {
	if a != "" {
		return a
	}
	return b
}

func (d *device) state(id string) string {
	var x struct{ State string }
	d.call("GET", "/gw/v1/sessions/"+id, nil, &x)
	return x.State
}

func (d *device) tunnel(ticket string) (io.ReadWriteCloser, error) {
	return remoteengine.Dial(context.Background(), d.hc, d.s.gwURL()+"/gw/v1/tunnel",
		http.Header{"Authorization": {"Bearer " + d.cred}, remoteengine.HeaderTicket: {ticket}})
}

func TestConnectAnywhereEndToEnd(t *testing.T) {
	s := newAnywhere(t)
	var en struct{ Code string }
	if st := s.ownerCall("POST", "/remote/enrollments", `{"name":"Семья (тест)","maxUses":3}`, &en); st != 201 {
		t.Fatalf("enrollment: %d", st)
	}
	homePC, laptop := s.enroll(en.Code, "Домашний ПК"), s.enroll(en.Code, "Ноутбук")
	if homePC.number == laptop.number {
		t.Fatal("same number twice")
	}
	var me struct{ Number, Status string }
	if st, _, _ := laptop.call("GET", "/gw/v1/devices/me", nil, &me); st != 200 || me.Number != laptop.number {
		t.Fatalf("me: %d %+v", st, me)
	}

	// Host A goes online by itself through the Gateway (no inbound port).
	host := homePC.runHost(t, true)
	waitUntil(t, "host online", func() bool { return host.last().Link == remotehost.LinkOnline })
	temp := host.last().TempPassword
	if len(temp) != 8 || host.last().Number != homePC.number {
		t.Fatalf("status %+v", host.last())
	}
	waitUntil(t, "device online", func() bool {
		laptop.call("GET", "/gw/v1/devices/me", nil, &me)
		var devs []struct{ Number, Status string }
		s.ownerCall("GET", "/remote/devices", "", &devs)
		for _, d := range devs {
			if d.Number == homePC.number {
				return d.Status == "online"
			}
		}
		return false
	})

	// Wrong password, unknown ID, and the password never reaches logs.
	if _, st, why := laptop.connect(homePC.number, "wrongpass"); st != 403 || why != "bad_password" {
		t.Fatalf("wrong password: %d %s", st, why)
	}
	if _, st, why := laptop.connect("123456780", temp); st != 404 || why != "unknown_device" {
		t.Fatalf("unknown id: %d %s", st, why)
	}

	// Right password → local consent → relay session with real bytes.
	host.prompt <- true
	id, st, why := laptop.connect(" "+homePC.number[:3]+" "+homePC.number[3:6]+" "+homePC.number[6:], temp)
	if st != 201 {
		t.Fatalf("connect: %d %s", st, why)
	}
	waitUntil(t, "connecting", func() bool { return laptop.state(id) == "connecting" })
	var g grant
	if st, _, _ := laptop.call("POST", "/gw/v1/sessions/"+id+"/grant", nil, &g); st != 200 || g.Route != "relay" || g.Host != "" {
		t.Fatalf("grant %d %+v", st, g)
	}
	leg, err := laptop.tunnel(g.Tunnel.Tickets["rdp"])
	if err != nil {
		t.Fatal(err)
	}
	name, br := greet(t, leg)
	if name != "HOST ПК "+homePC.number {
		t.Fatalf("reached %q", name)
	}
	echo(t, leg, br, "кириллица и unicode ✓\n")
	waitUntil(t, "connected", func() bool { return laptop.state(id) == "connected" })
	waitUntil(t, "host shows the session", func() bool {
		s := host.last().Session
		return s != nil && s.State == "connected" && strings.Contains(s.Viewer, laptop.number)
	})
	// One session at a time: a third device is refused while busy.
	third := s.enroll(en.Code, "Третий")
	if _, st, why := third.connect(homePC.number, temp); st != 409 || why != "busy" {
		t.Fatalf("busy: %d %s", st, why)
	}

	// Reconnect: the leg drops, a fresh ticket opens a new one.
	leg.Close()
	waitUntil(t, "reconnecting", func() bool { return laptop.state(id) == "reconnecting" })
	var tk struct{ Ticket string }
	laptop.call("POST", "/gw/v1/sessions/"+id+"/tickets", map[string]string{"channel": "rdp"}, &tk)
	leg, err = laptop.tunnel(tk.Ticket)
	if err != nil {
		t.Fatal(err)
	}
	if n, _ := greet(t, leg); n != "HOST ПК "+homePC.number {
		t.Fatal("reconnect reached another host")
	}
	waitUntil(t, "connected again", func() bool { return laptop.state(id) == "connected" })

	// Stop on the host ends the session and changes the temporary password.
	host.send(connecthost.Command{Cmd: "stopSession"})
	waitUntil(t, "stopped", func() bool { return laptop.state(id) == "disconnected" })
	readClosed(t, leg)
	waitUntil(t, "temp rotated", func() bool { return host.last().Session == nil && host.last().TempPassword != temp })
	if _, st, _ := laptop.connect(homePC.number, temp); st != 403 {
		t.Fatalf("old temporary password still accepted: %d", st)
	}

	// Consent refused on the host: no session.
	temp = host.last().TempPassword
	host.prompt <- false
	id, st, _ = laptop.connect(homePC.number, temp)
	if st != 201 {
		t.Fatalf("connect for refusal: %d", st)
	}
	waitUntil(t, "denied", func() bool { return laptop.state(id) == "failed" })

	// Permanent password: weak refused, strong accepted, then disabled.
	host.send(connecthost.Command{Cmd: "setPermanent", Password: "short"})
	host.send(connecthost.Command{Cmd: "setPermanent", Password: "Дом-2026-надёжный"})
	waitUntil(t, "permanent", func() bool { return host.last().Permanent })
	host.mu.Lock()
	var problems, verifiers int
	for _, o := range host.other {
		if o.Type == "permanent" && o.Problem != "" {
			problems++
		}
		if o.Type == "permanent" && o.Verifier != nil {
			verifiers++
		}
	}
	host.mu.Unlock()
	if problems != 1 || verifiers != 1 {
		t.Fatalf("permanent replies: %d problems, %d verifiers", problems, verifiers)
	}
	host.prompt <- true
	id, st, why = laptop.connect(homePC.number, "Дом-2026-надёжный")
	if st != 201 {
		t.Fatalf("permanent password: %d %s", st, why)
	}
	waitUntil(t, "permanent session ready", func() bool { return laptop.state(id) == "connecting" })
	laptop.call("POST", "/gw/v1/sessions/"+id+"/end", nil, nil)
	waitUntil(t, "host idle", func() bool { return host.last().Session == nil })
	host.send(connecthost.Command{Cmd: "clearPermanent"})
	waitUntil(t, "permanent off", func() bool { return !host.last().Permanent })
	if _, st, _ := laptop.connect(homePC.number, "Дом-2026-надёжный"); st != 403 {
		t.Fatalf("disabled permanent password accepted: %d", st)
	}

	// Incoming switched off on the host.
	host.send(connecthost.Command{Cmd: "allowIncoming", Value: false})
	waitUntil(t, "incoming off", func() bool { return !host.last().AllowIncoming })
	if _, st, why := laptop.connect(homePC.number, host.last().TempPassword); st != 403 || why != "incoming_disabled" {
		t.Fatalf("incoming off: %d %s", st, why)
	}
	host.send(connecthost.Command{Cmd: "allowIncoming", Value: true})
	waitUntil(t, "incoming on", func() bool { return host.last().AllowIncoming })

	// Server restart: Gateway first, then Core. The host comes back by itself.
	s.stopGateway()
	waitUntil(t, "host notices", func() bool {
		l := host.last().Link
		return l == remotehost.LinkReconnecting || l == remotehost.LinkConnecting
	})
	s.startGateway()
	waitLong(t, "host back after Gateway restart", func() bool { return host.last().Link == remotehost.LinkOnline })
	s.stopCore()
	s.startCore()
	waitLong(t, "device online after Core restart", func() bool {
		_, st, _ := laptop.connect(homePC.number, "not-the-password")
		return st == 403
	})
	host.prompt <- true
	id, st, why = laptop.connect(homePC.number, host.last().TempPassword)
	if st != 201 {
		t.Fatalf("after restart: %d %s", st, why)
	}
	waitUntil(t, "ready after restart", func() bool { return laptop.state(id) == "connecting" })
	laptop.call("POST", "/gw/v1/sessions/"+id+"/end", nil, nil)

	// The owner revokes the host device: the runtime stops as revoked.
	var devs []struct{ ID, Number string }
	s.ownerCall("GET", "/remote/devices", "", &devs)
	for _, d := range devs {
		if d.Number == homePC.number {
			s.ownerCall("POST", "/remote/devices/"+d.ID+"/revoke", "", nil)
		}
	}
	select {
	case err := <-host.done:
		if !errors.Is(err, connecthost.ErrRevoked) {
			t.Fatalf("runtime ended with %v", err)
		}
		host.done <- err // for the cleanup
	case <-time.After(60 * time.Second):
		t.Fatal("revoked host kept running")
	}
	if _, st, why := laptop.connect(homePC.number, "x"); st != 410 || why != "device_revoked" {
		t.Fatalf("revoked target: %d %s", st, why)
	}
	if st, _, _ := homePC.call("GET", "/gw/v1/devices/me", nil, nil); st != 401 {
		t.Fatalf("revoked viewer credential: %d", st)
	}
}

func echo(t *testing.T, rwc io.ReadWriteCloser, br *bufio.Reader, line string) {
	t.Helper()
	if _, err := io.WriteString(rwc, line); err != nil {
		t.Fatal(err)
	}
	got, err := br.ReadString('\n')
	if err != nil || got != line {
		t.Fatalf("echo %q %v", got, err)
	}
}

func readClosed(t *testing.T, rwc io.ReadWriteCloser) {
	t.Helper()
	done := make(chan struct{})
	go func() {
		_, _ = io.Copy(io.Discard, rwc)
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(15 * time.Second):
		t.Fatal("tunnel stayed open")
	}
}

func waitLong(t *testing.T, what string, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(90 * time.Second)
	for time.Now().Before(deadline) {
		if cond() {
			return
		}
		time.Sleep(200 * time.Millisecond)
	}
	t.Fatalf("timeout: %s", what)
}
