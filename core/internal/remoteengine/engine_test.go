package remoteengine

import (
	"context"
	"crypto/tls"
	"errors"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestCapsAndStates(t *testing.T) {
	a := Caps{Desktop: true, Input: true, Clipboard: true, Files: true}
	b := Caps{Desktop: true, Input: true, Clipboard: false, Files: true, Apps: true}
	if got := a.And(b); got != (Caps{Desktop: true, Input: true, Files: true}) {
		t.Fatalf("and: %+v", got)
	}
	for s, term := range map[State]bool{StatePending: false, StateConnected: false, StateReconnecting: false,
		StateDisconnected: true, StateFailed: true, StateExpired: true, StateRevoked: true} {
		if s.Terminal() != term {
			t.Errorf("%s terminal=%v", s, !term)
		}
	}
	if !ValidChannel("rdp") || !ValidChannel("files") || ValidChannel("ssh") || ValidChannel("") {
		t.Fatal("channels")
	}
}

func TestFingerprints(t *testing.T) {
	srv := httptest.NewTLSServer(http.NotFoundHandler())
	defer srv.Close()
	fp := Fingerprint(srv.Certificate().Raw)
	if len(fp) != 95 || strings.Count(fp, ":") != 31 {
		t.Fatalf("format %q", fp)
	}
	if NormalizeFingerprint(strings.ToUpper(fp)) != strings.ReplaceAll(fp, ":", "") {
		t.Fatal("normalize")
	}
	if _, err := FingerprintPEM("junk"); err == nil {
		t.Fatal("junk PEM accepted")
	}
	ok := &http.Client{Transport: &http.Transport{TLSClientConfig: PinnedTLS(strings.ToUpper(fp))}}
	if res, err := ok.Get(srv.URL); err != nil {
		t.Fatalf("pinned: %v", err)
	} else {
		res.Body.Close()
	}
	bad := &http.Client{Transport: &http.Transport{TLSClientConfig: PinnedTLS(strings.Repeat("ab", 32))}}
	if _, err := bad.Get(srv.URL); err == nil || !errors.Is(err, ErrPinMismatch) && !strings.Contains(err.Error(), ErrPinMismatch.Error()) {
		t.Fatalf("foreign certificate accepted: %v", err)
	}
	empty := &http.Client{Transport: &http.Transport{TLSClientConfig: PinnedTLS("")}}
	if _, err := empty.Get(srv.URL); err == nil {
		t.Fatal("empty pin accepts anything")
	}
}

// echoUpgrade accepts a leg and echoes it back.
func echoUpgrade(t *testing.T) *httptest.Server {
	return httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !IsUpgrade(r) {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusUpgradeRequired)
			_, _ = io.WriteString(w, `{"error":{"code":"BAD_REQUEST","message":"upgrade required"}}`)
			return
		}
		if r.Header.Get(HeaderTicket) != "good" {
			w.WriteHeader(http.StatusForbidden)
			_, _ = io.WriteString(w, `{"error":{"code":"FORBIDDEN","message":"bad ticket"}}`)
			return
		}
		c, err := Accept(w)
		if err != nil {
			t.Error(err)
			return
		}
		defer c.Close()
		_, _ = io.Copy(c, c)
	}))
}

func TestTunnelRoundTrip(t *testing.T) {
	srv := echoUpgrade(t)
	defer srv.Close()
	hc := &http.Client{Timeout: 50 * time.Millisecond, // must not cut the tunnel
		Transport: &http.Transport{TLSClientConfig: PinnedTLS(Fingerprint(srv.Certificate().Raw))}}
	hdr := http.Header{HeaderTicket: {"good"}}
	rwc, err := Dial(context.Background(), hc, srv.URL+"/t", hdr)
	if err != nil {
		t.Fatal(err)
	}
	defer rwc.Close()
	time.Sleep(100 * time.Millisecond)
	msg := strings.Repeat("кадр RDP ", 20000)
	go func() { _, _ = io.WriteString(rwc, msg) }()
	buf := make([]byte, len(msg))
	if _, err := io.ReadFull(rwc, buf); err != nil || string(buf) != msg {
		t.Fatalf("echo: %v", err)
	}

	_, err = Dial(context.Background(), hc, srv.URL+"/t", http.Header{HeaderTicket: {"used"}})
	var te *TunnelError
	if !errors.As(err, &te) || te.Status != 403 || te.Code != "FORBIDDEN" {
		t.Fatalf("refusal: %v", err)
	}
	// A plain GET is not an upgrade.
	res, err := hc.Get(srv.URL + "/t")
	if err != nil {
		t.Fatal(err)
	}
	res.Body.Close()
	if res.StatusCode != http.StatusUpgradeRequired {
		t.Fatalf("plain GET: %d", res.StatusCode)
	}
	// Pinned to another certificate: no handshake at all.
	other := &http.Client{Transport: &http.Transport{TLSClientConfig: PinnedTLS(strings.Repeat("00", 32))}}
	if _, err := Dial(context.Background(), other, srv.URL+"/t", hdr); err == nil {
		t.Fatal("dialled a server with a foreign certificate")
	}
}

func TestIsUpgrade(t *testing.T) {
	r := httptest.NewRequest(http.MethodGet, "/", nil)
	r.Header.Set("Connection", "keep-alive, Upgrade")
	r.Header.Set("Upgrade", "AER-TUNNEL/1")
	if !IsUpgrade(r) {
		t.Fatal("token list")
	}
	r.Header.Set("Upgrade", "websocket")
	if IsUpgrade(r) {
		t.Fatal("websocket is not aer-tunnel")
	}
	p := httptest.NewRequest(http.MethodPost, "/", nil)
	p.Header.Set("Connection", "Upgrade")
	p.Header.Set("Upgrade", Protocol)
	if IsUpgrade(p) {
		t.Fatal("POST")
	}
}

func TestSpliceCountsAndCloses(t *testing.T) {
	a1, a2 := net.Pipe()
	b1, b2 := net.Pipe()
	done := make(chan [2]int64)
	go func() { x, y := Splice(a2, b1, 0, nil); done <- [2]int64{x, y} }()
	go func() { _, _ = a1.Write([]byte("hello")) }()
	buf := make([]byte, 5)
	if _, err := io.ReadFull(b2, buf); err != nil || string(buf) != "hello" {
		t.Fatal(err)
	}
	go func() { _, _ = b2.Write([]byte("hi")) }()
	if _, err := io.ReadFull(a1, buf[:2]); err != nil {
		t.Fatal(err)
	}
	a1.Close() // one side ends → the other is closed too
	n := <-done
	if n != [2]int64{5, 2} {
		t.Fatalf("counts %v", n)
	}
	if _, err := b2.Read(buf); err == nil {
		t.Fatal("other side still open")
	}
}

func TestSpliceIdleAndStop(t *testing.T) {
	a1, a2 := net.Pipe()
	b1, b2 := net.Pipe()
	defer a1.Close()
	defer b2.Close()
	start := time.Now()
	Splice(a2, b1, 80*time.Millisecond, nil)
	if d := time.Since(start); d < 80*time.Millisecond || d > 2*time.Second {
		t.Fatalf("idle close after %v", d)
	}
	c1, c2 := net.Pipe()
	d1, d2 := net.Pipe()
	defer c1.Close()
	defer d2.Close()
	stop := make(chan struct{})
	go func() { time.Sleep(30 * time.Millisecond); close(stop) }()
	Splice(c2, d1, time.Hour, stop)
	if _, err := c1.Write([]byte("x")); err == nil {
		t.Fatal("stop did not close")
	}
}

func TestPinnedTLSMinVersion(t *testing.T) {
	if PinnedTLS("ab").MinVersion < tls.VersionTLS12 {
		t.Fatal("old TLS allowed")
	}
}
