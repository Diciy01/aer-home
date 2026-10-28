package remotegw

import (
	"bufio"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"aerhome/core/internal/core"
	"aerhome/core/internal/foundation/config"
	"aerhome/core/internal/modules"
	"aerhome/core/internal/remoteengine"
	"aerhome/core/internal/remotehost"
)

// End-to-end on loopback only: a real in-process Core, the Gateway with
// its own TLS certificate, host agents with a FAKE grdctl and a FAKE "RDP
// server" (a TCP service that greets with its host name and echoes).
// Nothing leaves 127.0.0.1; no real RDP server, router or remote machine
// is touched.

// TEST DATA: computers, clients and credentials below are fixtures.

type syncBuf struct {
	mu sync.Mutex
	b  bytes.Buffer
}

func (s *syncBuf) Write(p []byte) (int, error) { s.mu.Lock(); defer s.mu.Unlock(); return s.b.Write(p) }
func (s *syncBuf) String() string              { s.mu.Lock(); defer s.mu.Unlock(); return s.b.String() }

// fakeRDP greets with its name and echoes; it counts live connections.
type fakeRDP struct {
	ln   net.Listener
	name string
	live atomic.Int32
}

func newFakeRDP(t *testing.T, name string) *fakeRDP {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	f := &fakeRDP{ln: ln, name: name}
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			f.live.Add(1)
			go func() {
				defer f.live.Add(-1)
				defer c.Close()
				_, _ = io.WriteString(c, "HOST "+name+"\n")
				_, _ = io.Copy(c, c)
			}()
		}
	}()
	t.Cleanup(func() { ln.Close() })
	return f
}

func (f *fakeRDP) port() int { return f.ln.Addr().(*net.TCPAddr).Port }

type stand struct {
	t       *testing.T
	dir     string
	core    *httptest.Server
	owner   string
	gw      *Gateway
	gwSrv   *httptest.Server
	gwFP    string
	gwLog   *syncBuf
	agentLg *syncBuf
}

func (s *stand) coreCall(method, path, body string, out any) int {
	s.t.Helper()
	var rd io.Reader
	if body != "" {
		rd = strings.NewReader(body)
	}
	req, _ := http.NewRequest(method, s.core.URL+"/api/v1"+path, rd)
	req.Header.Set("Authorization", "Bearer "+s.owner)
	res, err := s.core.Client().Do(req)
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

// client is what AER Connect does, minus the UI.
type client struct {
	s    *stand
	hc   *http.Client
	cred string
}

func (s *stand) newClient() *client {
	tr := &http.Transport{TLSClientConfig: remoteengine.PinnedTLS(s.gwFP)}
	return &client{s: s, hc: &http.Client{Transport: tr, Timeout: 30 * time.Second}}
}

func (c *client) call(method, path, body string, out any, hdr ...string) (int, string) {
	c.s.t.Helper()
	var rd io.Reader
	if body != "" {
		rd = strings.NewReader(body)
	}
	req, _ := http.NewRequest(method, c.s.gwSrv.URL+path, rd)
	if c.cred != "" {
		req.Header.Set("Authorization", "Bearer "+c.cred)
	}
	for i := 0; i+1 < len(hdr); i += 2 {
		req.Header.Set(hdr[i], hdr[i+1])
	}
	res, err := c.hc.Do(req)
	if err != nil {
		c.s.t.Fatal(err)
	}
	defer res.Body.Close()
	raw, _ := io.ReadAll(res.Body)
	var env struct {
		Data  json.RawMessage
		Error struct{ Code, Message string }
	}
	_ = json.Unmarshal(raw, &env)
	if out != nil {
		_ = json.Unmarshal(env.Data, out)
	}
	return res.StatusCode, env.Error.Code
}

func (c *client) tunnel(ticket string) (io.ReadWriteCloser, error) {
	return remoteengine.Dial(context.Background(), c.hc, c.s.gwSrv.URL+"/gw/v1/tunnel",
		http.Header{"Authorization": {"Bearer " + c.cred}, remoteengine.HeaderTicket: {ticket}})
}

func waitUntil(t *testing.T, what string, cond func() bool) {
	t.Helper()
	for range 400 {
		if cond() {
			return
		}
		time.Sleep(25 * time.Millisecond)
	}
	t.Fatalf("timeout: %s", what)
}

func newStand(t *testing.T) *stand {
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
	s := &stand{t: t, dir: dir, core: srv, owner: strings.TrimSpace(string(ownerRaw)), gwLog: &syncBuf{}, agentLg: &syncBuf{}}

	var server struct{ ID string }
	s.coreCall("POST", "/registry/entities", `{"name":"Сервер (тест)","type":"server"}`, &server)
	var gwCred struct{ Token string }
	s.coreCall("POST", "/monitoring/agents", `{"entityId":"`+server.ID+`","name":"gateway","kind":"gateway"}`, &gwCred)
	tok := filepath.Join(dir, "gateway.token")
	_ = os.WriteFile(tok, []byte(gwCred.Token), 0o600)

	gcfg := Default()
	gcfg.ListenAddr, gcfg.CoreURL, gcfg.TokenFile, gcfg.StateDir = "127.0.0.1:0", srv.URL, tok, filepath.Join(dir, "gw")
	gcfg.PairWaitSec, gcfg.AuthFailLimit = 5, 10
	if err := gcfg.Validate(); err != nil {
		t.Fatal(err)
	}
	g, err := New(gcfg, slog.New(slog.NewTextHandler(s.gwLog, &slog.HandlerOptions{Level: slog.LevelDebug})))
	if err != nil {
		t.Fatal(err)
	}
	tc, err := g.TLSConfig()
	if err != nil {
		t.Fatal(err)
	}
	gs := httptest.NewUnstartedServer(g.Handler())
	gs.TLS = tc
	gs.StartTLS()
	t.Cleanup(gs.Close)
	s.gw, s.gwSrv = g, gs
	if s.gwFP, err = g.Fingerprint(); err != nil {
		t.Fatal(err)
	}
	return s
}

type host struct {
	id    string
	rdp   *fakeRDP
	agent *remotehost.Agent
	done  chan error
	files string
}

// addHost registers a computer with a running host agent; viaGateway
// makes the agent reach Core only through the Gateway's agent proxy
// (scenario B: a work PC without any inbound access).
func (s *stand) addHost(name string, viaGateway bool) *host {
	t := s.t
	var pc struct{ ID string }
	s.coreCall("POST", "/registry/entities", `{"name":"`+name+`","type":"computer"}`, &pc)
	var cred struct{ Token string }
	s.coreCall("POST", "/monitoring/agents", `{"entityId":"`+pc.ID+`","name":"remote","kind":"remote"}`, &cred)
	s.coreCall("PUT", "/remote/hosts/"+pc.ID+"/policy", `{"enabled":true,"desktop":true,"clipboard":true,"files":true,"maxMinutes":30}`, nil)
	d := filepath.Join(s.dir, pc.ID)
	tok := filepath.Join(d, "remote.token")
	_ = os.MkdirAll(d, 0o700)
	_ = os.WriteFile(tok, []byte(cred.Token), 0o600)
	h := &host{id: pc.ID, rdp: newFakeRDP(t, name), done: make(chan error, 1), files: filepath.Join(d, "exchange")}
	ln, _ := net.Listen("tcp", "127.0.0.1:0")
	filesPort := ln.Addr().(*net.TCPAddr).Port
	ln.Close()
	acfg := remotehost.Config{CoreURL: s.core.URL, TokenFile: tok, StateDir: filepath.Join(d, "agent"), Backend: "gnome-rdp",
		Grdctl: []string{"grdctl"}, Daemon: []string{"/bin/true"}, Address: "192.0.2.10", Port: h.rdp.port(), RDPUser: "aer", Approval: "auto",
		Clipboard: true, Files: remotehost.Files{Enabled: true, Dir: h.files, Port: filesPort, MaxBytes: 1 << 20},
		GatewayURL: s.gwSrv.URL, GatewayCertSHA256: s.gwFP}
	if viaGateway {
		acfg.CoreURL, acfg.CoreCertSHA256 = s.gwSrv.URL+"/gw/v1/agent", s.gwFP
	}
	if err := acfg.Validate(); err != nil {
		t.Fatal(err)
	}
	a, err := remotehost.New(acfg, slog.New(slog.NewTextHandler(s.agentLg, nil)))
	if err != nil {
		t.Fatal(err)
	}
	a.SetRunner(func(context.Context, []string) ([]byte, error) { return []byte("RDP:\n\tStatus: disabled\n"), nil },
		func([]string) (func(), error) { return func() {}, nil })
	a.Connections = func() int { return int(h.rdp.live.Load()) }
	h.agent = a
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(func() { cancel(); <-h.done })
	go func() { h.done <- a.Run(ctx) }()
	waitUntil(t, name+" ready", func() bool {
		var x struct{ CanConnect bool }
		s.coreCall("GET", "/remote/hosts/"+pc.ID, "", &x)
		return x.CanConnect
	})
	return h
}

// pair creates a remote client for hosts and pairs it through the Gateway.
func (s *stand) pair(name string, files bool, hosts ...string) (*client, string) {
	var p struct {
		Code   string
		Client struct{ ID string }
	}
	if code := s.coreCall("POST", "/remote/clients", fmt.Sprintf(`{"name":%q,"hosts":["%s"],"clipboard":true,"files":%v}`, name, strings.Join(hosts, `","`), files), &p); code != 201 {
		s.t.Fatalf("create client: %d", code)
	}
	c := s.newClient()
	var got struct{ Credential string }
	if st, code := c.call("POST", "/gw/v1/pair", `{"code":"`+p.Code+`","deviceName":"Рабочий ПК (тест)"}`, &got); st != 200 {
		s.t.Fatalf("pair: %d %s", st, code)
	}
	c.cred = got.Credential
	return c, p.Client.ID
}

type grant struct {
	Password, CertPem, CertSha256, Route, Host string
	Files                                      *struct{ Token, URL string }
	Tunnel                                     struct {
		Path    string
		Tickets map[string]string
	}
}

func (c *client) open(hostID string) (string, grant) {
	t := c.s.t
	t.Helper()
	var x struct{ ID, State string }
	if st, code := c.call("POST", "/gw/v1/sessions", `{"entityId":"`+hostID+`"}`, &x, "Idempotency-Key", "k-"+hostID); st != 201 {
		t.Fatalf("session: %d %s", st, code)
	}
	waitUntil(t, "connecting", func() bool {
		c.call("GET", "/gw/v1/sessions/"+x.ID, "", &x)
		return x.State == "connecting"
	})
	var g grant
	if st, code := c.call("POST", "/gw/v1/sessions/"+x.ID+"/grant", "", &g); st != 200 {
		t.Fatalf("grant: %d %s", st, code)
	}
	return x.ID, g
}

func (c *client) state(id string) string {
	var x struct{ State string }
	c.call("GET", "/gw/v1/sessions/"+id, "", &x)
	return x.State
}

func greet(t *testing.T, rwc io.ReadWriteCloser) (string, *bufio.Reader) {
	t.Helper()
	br := bufio.NewReader(rwc)
	line, err := br.ReadString('\n')
	if err != nil {
		t.Fatalf("greeting: %v", err)
	}
	return strings.TrimSpace(line), br
}

func TestGatewayEndToEnd(t *testing.T) {
	s := newStand(t)
	home := s.addHost("Домашний ПК (тест)", false)
	work := s.addHost("Рабочий ПК (тест)", true) // only reachable through the Gateway

	// Scenario A: AER Connect at work → home PC.
	c1, c1ID := s.pair("AER Connect (тест)", true, home.id)
	var hosts struct {
		Hosts []struct {
			EntityID   string
			CanConnect bool
		}
	}
	if st, _ := c1.call("GET", "/gw/v1/hosts", "", &hosts); st != 200 || len(hosts.Hosts) != 1 || !hosts.Hosts[0].CanConnect {
		t.Fatalf("hosts: %d %+v", st, hosts)
	}
	s1, g1 := c1.open(home.id)
	if g1.Route != "relay" || g1.Host != "" || g1.Password == "" || g1.Files == nil || g1.Tunnel.Tickets["rdp"] == "" {
		t.Fatalf("grant: %+v", g1)
	}
	rdp, err := c1.tunnel(g1.Tunnel.Tickets["rdp"])
	if err != nil {
		t.Fatal(err)
	}
	if hello, br := greet(t, rdp); hello != "HOST Домашний ПК (тест)" {
		t.Fatalf("reached %q", hello)
	} else {
		_, _ = io.WriteString(rdp, "кадр\n")
		if echo, _ := br.ReadString('\n'); echo != "кадр\n" {
			t.Fatalf("echo %q", echo)
		}
	}
	waitUntil(t, "connected", func() bool { return c1.state(s1) == "connected" })
	if _, err := c1.tunnel(g1.Tunnel.Tickets["rdp"]); !refusedWith(err, 403) {
		t.Fatalf("ticket replay: %v", err)
	}

	// Files through the relay, end-to-end TLS pinned to the host certificate.
	files := forward(t, func() (io.ReadWriteCloser, error) {
		var tk struct{ Ticket string }
		if st, code := c1.call("POST", "/gw/v1/sessions/"+s1+"/tickets", `{"channel":"files"}`, &tk); st != 200 {
			return nil, fmt.Errorf("ticket %d %s", st, code)
		}
		return c1.tunnel(tk.Ticket)
	})
	hostFP, _ := remoteengine.FingerprintPEM(g1.CertPem)
	fc := &http.Client{Transport: &http.Transport{TLSClientConfig: remoteengine.PinnedTLS(hostFP)}, Timeout: 20 * time.Second}
	body := []byte("отчёт для дома")
	sum := sha256.Sum256(body)
	req, _ := http.NewRequest(http.MethodPut, "https://"+files+"/v1/files/report.txt", bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer "+g1.Files.Token)
	req.Header.Set("X-AER-SHA256", hex.EncodeToString(sum[:]))
	res, err := fc.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	res.Body.Close()
	if res.StatusCode >= 300 {
		t.Fatalf("upload: %d", res.StatusCode)
	}
	if got, _ := os.ReadFile(filepath.Join(home.files, "report.txt")); !bytes.Equal(got, body) {
		t.Fatalf("file on host: %q", got)
	}
	big := bytes.Repeat([]byte("x"), 2<<20) // over the host's 1 MiB limit
	sum = sha256.Sum256(big)
	req, _ = http.NewRequest(http.MethodPut, "https://"+files+"/v1/files/big.bin", bytes.NewReader(big))
	req.Header.Set("Authorization", "Bearer "+g1.Files.Token)
	req.Header.Set("X-AER-SHA256", hex.EncodeToString(sum[:]))
	if res, err := fc.Do(req); err == nil {
		res.Body.Close()
		if res.StatusCode < 400 {
			t.Fatalf("over-limit upload accepted: %d", res.StatusCode)
		}
	}
	if _, err := os.Stat(filepath.Join(home.files, "big.bin")); err == nil {
		t.Fatal("over-limit file kept")
	}

	// Scenario B at the same time: another client → work PC behind the Gateway.
	c2, _ := s.pair("Ноутбук дома (тест)", false, work.id, home.id)
	s2, g2 := c2.open(work.id)
	if g2.Files != nil || len(g2.Tunnel.Tickets) != 1 {
		t.Fatalf("files leaked to a client without the right: %+v", g2)
	}
	rdp2, err := c2.tunnel(g2.Tunnel.Tickets["rdp"])
	if err != nil {
		t.Fatal(err)
	}
	if hello, _ := greet(t, rdp2); hello != "HOST Рабочий ПК (тест)" {
		t.Fatalf("session isolation: reached %q", hello)
	}
	// Isolation between clients.
	if st, _ := c2.call("GET", "/gw/v1/sessions/"+s1, "", nil); st != 404 {
		t.Fatalf("foreign session visible: %d", st)
	}
	var tk struct{ Ticket string }
	c1.call("POST", "/gw/v1/sessions/"+s1+"/tickets", `{"channel":"rdp"}`, &tk)
	if _, err := c2.tunnel(tk.Ticket); !refusedWith(err, 403) {
		t.Fatalf("foreign ticket: %v", err)
	}
	if st, code := c2.call("POST", "/gw/v1/sessions/"+s2+"/tickets", `{"channel":"files"}`, nil); st != 403 || code != "PERMISSION_REQUIRED" {
		t.Fatalf("files ticket without right: %d %s", st, code)
	}
	if st, _ := c2.call("POST", "/gw/v1/sessions", `{"entityId":"`+home.id+`"}`, nil); st != 409 {
		t.Fatalf("second session on a busy host: %d", st)
	}

	// Connection loss and reconnect.
	rdp.Close()
	waitUntil(t, "reconnecting", func() bool { return c1.state(s1) == "reconnecting" })
	c1.call("POST", "/gw/v1/sessions/"+s1+"/tickets", `{"channel":"rdp"}`, &tk)
	rdp, err = c1.tunnel(tk.Ticket)
	if err != nil {
		t.Fatal(err)
	}
	greet(t, rdp)
	waitUntil(t, "connected again", func() bool { return c1.state(s1) == "connected" })

	// Revoking the client cuts its live tunnel (Gateway asks Core) and the
	// host closes the session.
	if code := s.coreCall("POST", "/remote/clients/"+c1ID+"/revoke", "", nil); code != 200 {
		t.Fatalf("revoke: %d", code)
	}
	s.gw.CheckAlive(context.Background())
	readDone := make(chan error, 1)
	go func() { _, err := io.ReadAll(rdp); readDone <- err }()
	select {
	case <-readDone:
	case <-time.After(5 * time.Second):
		t.Fatal("revoked tunnel still open")
	}
	waitUntil(t, "host freed", func() bool {
		var x struct{ ActiveSession *struct{} }
		s.coreCall("GET", "/remote/hosts/"+home.id, "", &x)
		return x.ActiveSession == nil
	})
	if st, _ := c1.call("GET", "/gw/v1/hosts", "", nil); st != 401 {
		t.Fatalf("revoked credential: %d", st)
	}

	// Client 2 ends normally.
	if st, _ := c2.call("POST", "/gw/v1/sessions/"+s2+"/end", "", nil); st != 200 {
		t.Fatalf("end: %d", st)
	}
	s.gw.CheckAlive(context.Background())
	if _, err := io.ReadAll(rdp2); err != nil && !strings.Contains(err.Error(), "closed") {
		t.Logf("read after end: %v", err)
	}

	// Secrets never reach the logs.
	logs := s.gwLog.String() + s.agentLg.String()
	for _, secret := range []string{c1.cred, c2.cred, strings.SplitN(c1.cred, ".", 3)[2], g1.Password, g1.Tunnel.Tickets["rdp"], g1.Files.Token, tk.Ticket} {
		if secret != "" && strings.Contains(logs, secret) {
			t.Fatalf("secret in logs: %.12s…", secret)
		}
	}
	if !strings.Contains(s.gwLog.String(), "tunnel opened") {
		t.Fatal("tunnel audit missing from the Gateway log")
	}
	var x struct{ Events []struct{ Kind string } }
	s.coreCall("GET", "/remote/sessions/"+s1, "", &x)
	kinds := []string{}
	for _, e := range x.Events {
		kinds = append(kinds, e.Kind)
	}
	if j := strings.Join(kinds, ","); !strings.Contains(j, "tunnel_opened") || !strings.Contains(j, "tunnel_closed") || !strings.Contains(j, "revoked") {
		t.Fatalf("Core audit: %s", j)
	}
}

// forward is the client engine's local port: each accepted connection
// gets a fresh tunnel leg. It returns host:port on 127.0.0.1.
func forward(t *testing.T, leg func() (io.ReadWriteCloser, error)) string {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ln.Close() })
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			go func() {
				r, err := leg()
				if err != nil {
					t.Logf("forward: %v", err)
					c.Close()
					return
				}
				remoteengine.Splice(c, r, time.Minute, nil)
			}()
		}
	}()
	return ln.Addr().String()
}

func refusedWith(err error, status int) bool {
	te, ok := err.(*remoteengine.TunnelError)
	return ok && te.Status == status
}

func TestGatewayRefusesBadInput(t *testing.T) {
	s := newStand(t)
	c := s.newClient()
	// Upgrade required, malformed JSON, unknown agent path.
	if st, _ := c.call("GET", "/gw/v1/tunnel", "", nil); st != http.StatusUpgradeRequired {
		t.Fatalf("plain GET tunnel: %d", st)
	}
	c.cred = "aerc1.x." + strings.Repeat("0", 64)
	if st, _ := c.call("POST", "/gw/v1/sessions", "{not json", nil); st != 400 {
		t.Fatalf("malformed JSON: %d", st)
	}
	if st, _ := c.call("GET", "/gw/v1/sessions/..%2F..%2Fclients", "", nil); st != 404 {
		t.Fatalf("path tricks: %d", st)
	}
	c.cred = ""
	for _, p := range []string{"/gw/v1/agent/api/v1/remote/hosts", "/gw/v1/agent/api/v1/registry/entities", "/gw/v1/agent/api/v1/remote/clients"} {
		if st, _ := c.call("GET", p, "", nil, "Authorization", "Bearer "+s.owner); st != 404 {
			t.Fatalf("owner API through the agent proxy %s: %d", p, st)
		}
	}
	// The owner token is not a client credential.
	c.cred = s.owner
	if st, _ := c.call("GET", "/gw/v1/hosts", "", nil); st != 401 {
		t.Fatalf("owner token at the Gateway: %d", st)
	}
	// Host leg for a bogus session.
	_, err := remoteengine.Dial(context.Background(), c.hc, s.gwSrv.URL+"/gw/v1/agent/tunnel?session=nope&channel=rdp",
		http.Header{"Authorization": {"Bearer aer1.x.y"}})
	if !refusedWith(err, 401) && !refusedWith(err, 404) {
		t.Fatalf("bogus host leg: %v", err)
	}
	// Foreign certificate: the client refuses the Gateway.
	bad := &http.Client{Transport: &http.Transport{TLSClientConfig: remoteengine.PinnedTLS(strings.Repeat("ab", 32))}}
	if _, err := bad.Get(s.gwSrv.URL + "/gw/v1/health"); err == nil {
		t.Fatal("client trusted a Gateway with another certificate")
	}
	// Pairing attempts are capped per address.
	c.cred = ""
	var st int
	for range 6 {
		st, _ = c.call("POST", "/gw/v1/pair", `{"code":"AAAA-BBBB-CCCC"}`, nil)
	}
	if st != http.StatusTooManyRequests {
		t.Fatalf("pairing not rate-limited: %d", st)
	}
	// Repeated bad credentials ban the address for everything.
	c.cred = "aerc1.00000000-0000-0000-0000-000000000000." + strings.Repeat("0", 64)
	for range 12 {
		st, _ = c.call("GET", "/gw/v1/hosts", "", nil)
	}
	if st != http.StatusTooManyRequests {
		t.Fatalf("no ban after failures: %d", st)
	}
	if st, _ := c.call("GET", "/gw/v1/health", "", nil); st != http.StatusTooManyRequests {
		t.Fatalf("banned address still served: %d", st)
	}
	s.gw.now = func() time.Time { return time.Now().Add(time.Hour) }
	if st, _ := c.call("GET", "/gw/v1/health", "", nil); st != 200 {
		t.Fatalf("ban must expire: %d", st)
	}
}

func TestGatewayConfig(t *testing.T) {
	c := Default()
	c.ListenAddr, c.TokenFile, c.StateDir = "0.0.0.0:8443", "/x/t", "/x"
	for url, ok := range map[string]bool{"http://127.0.0.1:8787": true, "http://localhost:8787": true, "https://core.lan:8787": true,
		"http://192.0.2.20:8787": false, "ftp://x": false} {
		c.CoreURL = url
		if err := c.Validate(); (err == nil) != ok {
			t.Errorf("%s: %v", url, err)
		}
	}
	c.CoreURL = "http://127.0.0.1:8787"
	c.MaxTunnelsPerClient = c.MaxTunnels + 1
	if c.Validate() == nil {
		t.Error("per-client limit above total")
	}
}

func TestDeployExampleLoads(t *testing.T) {
	if _, err := Load(filepath.Join("..", "..", "..", "deploy", "remote-gateway.example.json")); err != nil {
		t.Fatal(err)
	}
}
