package remotehost

import (
	"bytes"
	"context"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
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
)

// End-to-end control plane: a real in-process Core and the host agent with
// a FAKE grdctl and a FAKE connection counter. No RDP server is touched;
// the real transport is checked by the live lab (docs/M07_REMOTE_REPORT.md).

type fakeGrd struct {
	mu    sync.Mutex
	calls [][]string
}

func (f *fakeGrd) run(_ context.Context, argv []string) ([]byte, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.calls = append(f.calls, argv)
	return []byte("RDP:\n\tStatus: disabled\n"), nil
}

func (f *fakeGrd) start(argv []string) (func(), error) {
	f.mu.Lock()
	f.calls = append(f.calls, append([]string{"daemon"}, argv...))
	f.mu.Unlock()
	return func() {
		f.mu.Lock()
		f.calls = append(f.calls, []string{"daemon-stopped"})
		f.mu.Unlock()
	}, nil
}

func (f *fakeGrd) find(sub ...string) []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	for i := len(f.calls) - 1; i >= 0; i-- {
		c := f.calls[i]
		if has(c, sub) {
			return c
		}
	}
	return nil
}

func (f *fakeGrd) count(sub ...string) int {
	f.mu.Lock()
	defer f.mu.Unlock()
	n := 0
	for _, c := range f.calls {
		if has(c, sub) {
			n++
		}
	}
	return n
}

// has: argv contains the words of sub in order, as whole words.
func has(argv, sub []string) bool {
	return strings.Contains(" "+strings.Join(argv, " ")+" ", " "+strings.Join(sub, " ")+" ")
}

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
	var envl struct {
		Data json.RawMessage
	}
	_ = json.NewDecoder(res.Body).Decode(&envl)
	if out != nil {
		_ = json.Unmarshal(envl.Data, out)
	}
	return res.StatusCode
}

func freePort(t *testing.T) int {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	return ln.Addr().(*net.TCPAddr).Port
}

func waitUntil(t *testing.T, what string, cond func() bool) {
	t.Helper()
	for i := 0; i < 200; i++ {
		if cond() {
			return
		}
		time.Sleep(25 * time.Millisecond)
	}
	t.Fatalf("timeout: %s", what)
}

func TestAgentEndToEndWithFakeRDP(t *testing.T) {
	dir := t.TempDir()
	cfg := config.Default(func(string) (string, bool) { return "", false })
	cfg.DataDir = filepath.Join(dir, "core")
	cfg.Monitoring.Docker.Enabled = false
	c, err := core.New(context.Background(), core.Options{Config: cfg, Logger: slog.New(slog.DiscardHandler), Modules: modules.All()})
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	srv := httptest.NewServer(c.Handler())
	defer srv.Close()
	ownerRaw, _ := os.ReadFile(cfg.TokenPath())
	e := &env{t: t, srv: srv, owner: strings.TrimSpace(string(ownerRaw)), dir: dir}

	// TEST DATA: a computer and its remote agent credential.
	var pc struct{ ID string }
	e.call("POST", "/registry/entities", e.owner, `{"name":"ПК (тест)","type":"computer"}`, &pc)
	var cred struct{ Token string }
	e.call("POST", "/monitoring/agents", e.owner, `{"entityId":"`+pc.ID+`","name":"remote","kind":"remote"}`, &cred)
	tokFile := filepath.Join(dir, "remote.token")
	_ = os.WriteFile(tokFile, []byte(cred.Token), 0o600)
	e.call("PUT", "/remote/hosts/"+pc.ID+"/policy", e.owner, `{"enabled":true,"desktop":true,"clipboard":true,"files":true,"maxMinutes":30}`, nil)

	rdpPort, filesPort := freePort(t), freePort(t)
	acfg := Config{CoreURL: srv.URL, TokenFile: tokFile, StateDir: filepath.Join(dir, "agent"), Backend: "gnome-rdp",
		Grdctl: []string{"grdctl", "--headless"}, Daemon: []string{"/bin/true"}, Address: "127.0.0.1", Port: rdpPort, RDPUser: "aer", Approval: "auto",
		Clipboard: true, Files: Files{Enabled: true, Dir: filepath.Join(dir, "exchange"), Port: filesPort, MaxBytes: 1 << 20}}
	if err := acfg.Validate(); err != nil {
		t.Fatal(err)
	}
	a, err := New(acfg, nil)
	if err != nil {
		t.Fatal(err)
	}
	grd := &fakeGrd{}
	a.SetRunner(grd.run, grd.start)
	var conns atomic.Int32
	a.Connections = func() int { return int(conns.Load()) }
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- a.Run(ctx) }()

	var host struct {
		CanConnect bool
		CertSha256 string
		Reason     string
	}
	waitUntil(t, "host ready", func() bool {
		e.call("GET", "/remote/hosts/"+pc.ID, e.owner, "", &host)
		return host.CanConnect
	})
	if grd.find("rdp", "disable") == nil || grd.find("rdp", "set-tls-cert") == nil || grd.count("rdp", "enable") != 0 {
		t.Fatalf("prepare must configure and keep RDP disabled: %v", grd.calls)
	}

	var sess struct{ ID, State string }
	if code := e.call("POST", "/remote/sessions", e.owner, `{"entityId":"`+pc.ID+`","sourceName":"Ноутбук (тест)"}`, &sess); code != 201 {
		t.Fatalf("create: %d", code)
	}
	waitUntil(t, "connecting", func() bool {
		e.call("GET", "/remote/sessions/"+sess.ID, e.owner, "", &sess)
		return sess.State == "connecting"
	})
	if grd.count("rdp", "enable") != 1 || grd.count("daemon") != 1 {
		t.Fatal("RDP must be enabled and the daemon started for the session")
	}
	var g struct {
		Password, CertPem, CertSha256, Username string
		Port                                    int
		Files                                   *struct {
			URL, Token string
		}
	}
	if code := e.call("POST", "/remote/sessions/"+sess.ID+"/grant", e.owner, "", &g); code != 200 {
		t.Fatalf("grant: %d", code)
	}
	creds := grd.find("rdp", "set-credentials")
	if creds == nil || creds[len(creds)-1] != g.Password || len(g.Password) != 30 || g.Username != "aer" || g.Port != rdpPort || g.CertSha256 != host.CertSha256 {
		t.Fatalf("grant must carry the password set on the host: %v / %+v", creds, g)
	}
	if g.Files == nil || g.Files.Token == "" {
		t.Fatal("files channel expected")
	}

	// File channel over HTTPS, pinned to the host certificate.
	blk, _ := pem.Decode([]byte(g.CertPem))
	pool := x509.NewCertPool()
	cert, _ := x509.ParseCertificate(blk.Bytes)
	pool.AddCert(cert)
	hc := &http.Client{Transport: &http.Transport{TLSClientConfig: &tls.Config{RootCAs: pool, InsecureSkipVerify: true,
		VerifyPeerCertificate: func(raw [][]byte, _ [][]*x509.Certificate) error {
			if !bytes.Equal(raw[0], blk.Bytes) {
				return io.ErrUnexpectedEOF
			}
			return nil
		}}}}
	payload := bytes.Repeat([]byte("AER test file (тест)\n"), 1000)
	sum := sha256.Sum256(payload)
	put := func(name, sha, token string, body []byte) int {
		req, _ := http.NewRequest("PUT", g.Files.URL+"/v1/files/"+name, bytes.NewReader(body))
		req.Header.Set("Authorization", "Bearer "+token)
		req.Header.Set("X-AER-SHA256", sha)
		res, err := hc.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		res.Body.Close()
		return res.StatusCode
	}
	if code := put("report.txt", hex.EncodeToString(sum[:]), "wrong-token", payload); code != 401 {
		t.Errorf("wrong token: %d", code)
	}
	if code := put("report.txt", strings.Repeat("0", 64), g.Files.Token, payload); code != 422 {
		t.Errorf("bad checksum must be rejected: %d", code)
	}
	if _, err := os.Stat(filepath.Join(acfg.Files.Dir, "report.txt")); err == nil {
		t.Error("a corrupted upload must not stay")
	}
	if code := put("../escape.txt", hex.EncodeToString(sum[:]), g.Files.Token, payload); code != 400 && code != 404 {
		t.Errorf("path traversal: %d", code)
	}
	if code := put("report.txt", hex.EncodeToString(sum[:]), g.Files.Token, payload); code != 201 {
		t.Fatalf("upload: %d", code)
	}
	if code := put("big.bin", strings.Repeat("a", 64), g.Files.Token, make([]byte, 2<<20)); code != 413 {
		t.Errorf("size limit: %d", code)
	}
	req, _ := http.NewRequest("GET", g.Files.URL+"/v1/files/report.txt", nil)
	req.Header.Set("Authorization", "Bearer "+g.Files.Token)
	res, err := hc.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	got, _ := io.ReadAll(res.Body)
	res.Body.Close()
	if !bytes.Equal(got, payload) || res.Header.Get("X-AER-SHA256") != hex.EncodeToString(sum[:]) {
		t.Error("download content or checksum")
	}

	conns.Store(1)
	waitUntil(t, "connected", func() bool {
		e.call("GET", "/remote/sessions/"+sess.ID, e.owner, "", &sess)
		return sess.State == "connected"
	})
	conns.Store(0)
	waitUntil(t, "reconnecting", func() bool {
		e.call("GET", "/remote/sessions/"+sess.ID, e.owner, "", &sess)
		return sess.State == "reconnecting"
	})
	conns.Store(1)
	waitUntil(t, "back", func() bool {
		e.call("GET", "/remote/sessions/"+sess.ID, e.owner, "", &sess)
		return sess.State == "connected"
	})
	e.call("POST", "/remote/sessions/"+sess.ID+"/revoke", e.owner, "", &sess)
	waitUntil(t, "RDP disabled after revoke", func() bool {
		return grd.count("rdp", "disable") >= 2 && grd.count("rdp", "clear-credentials") >= 2 && grd.count("daemon-stopped") == 1
	})
	if _, err := hc.Get(g.Files.URL + "/v1/files"); err == nil {
		t.Error("file channel must stop with the session")
	}

	// Revoking the device credential stops the agent; RDP stays disabled.
	var agents []struct{ ID, Kind string }
	e.call("GET", "/monitoring/agents?entityId="+pc.ID, e.owner, "", &agents)
	for _, ag := range agents {
		if ag.Kind == "remote" {
			e.call("POST", "/monitoring/agents/"+ag.ID+"/revoke", e.owner, "", nil)
		}
	}
	select {
	case err := <-done:
		if err == nil || !strings.Contains(err.Error(), "credential") {
			t.Errorf("agent stop: %v", err)
		}
	case <-time.After(40 * time.Second):
		t.Error("agent did not stop after its credential was revoked")
	}
	cancel()
	last := grd.calls[len(grd.calls)-1]
	if last[len(last)-1] != "clear-credentials" && last[0] != "daemon-stopped" {
		t.Errorf("last action must leave RDP closed: %v", last)
	}
}

func TestLocalExpiryWithoutCore(t *testing.T) {
	grd := &fakeGrd{}
	a := &Agent{cfg: Config{Port: 1}, backend: &gnomeBackend{c: Config{Grdctl: []string{"grdctl"}, Daemon: []string{"/bin/true"}}, run: grd.run, start: grd.start},
		log: slog.New(slog.DiscardHandler), http: &http.Client{Timeout: time.Second}, Connections: func() int { return 0 }}
	a.cfg.CoreURL, a.cfg.TokenFile = "http://127.0.0.1:1", filepath.Join(t.TempDir(), "none")
	a.Handle(context.Background(), Command{Type: "open", SessionID: "s1", ExpiresAt: time.Now().Add(1500 * time.Millisecond)})
	if grd.count("rdp", "enable") != 1 {
		t.Fatal("open")
	}
	waitUntil(t, "local expiry", func() bool { return grd.count("rdp", "disable") == 1 && grd.count("daemon-stopped") == 1 })
}

func TestConfigValidation(t *testing.T) {
	bad := Config{CoreURL: "ftp://x", TokenFile: "rel", StateDir: "rel", Backend: "vnc", Approval: "maybe",
		Files: Files{Enabled: true, Dir: "rel", Port: 3389, MaxBytes: 0}, Port: 3389}
	err := bad.Validate()
	for _, want := range []string{"coreUrl", "tokenFile", "backend", "address", "approval", "files.dir", "files.port", "files.maxBytes"} {
		if err == nil || !strings.Contains(err.Error(), want) {
			t.Errorf("want %s in %v", want, err)
		}
	}
	for _, n := range []string{"../x", ".hidden", "a/b", "", "ok.txt"} {
		if validName(n) != (n == "ok.txt") {
			t.Errorf("validName(%q)", n)
		}
	}
}

func TestPasswordShape(t *testing.T) {
	seen := map[string]bool{}
	for i := 0; i < 200; i++ {
		p := newPassword()
		if len(p) != 30 || strings.Trim(p, alnum) != "" || seen[p] {
			t.Fatalf("password %q", p)
		}
		seen[p] = true
	}
}
