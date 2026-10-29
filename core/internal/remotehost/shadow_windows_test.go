//go:build windows

package remotehost

import (
	"aerhome/core/internal/remoteengine"
	"context"
	"crypto/x509"
	pemutil "encoding/pem"
	"golang.org/x/sys/windows"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

func TestShadowConfigSafety(t *testing.T) {
	c := Config{CoreURL: "http://127.0.0.1:18001", TokenFile: filepath.Join(t.TempDir(), "test.token"), StateDir: t.TempDir(),
		Backend: "windows-shadow", ShadowExecutable: filepath.Join(t.TempDir(), "aer-shadow.exe"), ShadowSource: "desktop", Address: "127.0.0.1", Port: 18389,
		Approval: "prompt", GatewayURL: "https://127.0.0.1:18443", GatewayCertSHA256: strings.Repeat("ab", 32)}
	if err := c.Validate(); err != nil {
		t.Fatal(err)
	}
	for _, mut := range []func(*Config){func(c *Config) { c.Address = "0.0.0.0" }, func(c *Config) { c.Approval = "auto" }, func(c *Config) { c.GatewayURL = "" }, func(c *Config) { c.ShadowSource = "unknown" }, func(c *Config) { c.TLSCert = "persistent.crt" }} {
		bad := c
		mut(&bad)
		if bad.Validate() == nil {
			t.Fatal("unsafe shadow config accepted")
		}
	}
}

func TestShadowManagedSyntheticLifecycle(t *testing.T) {
	bin := os.Getenv("AER_SHADOW_BIN")
	if bin == "" {
		t.Skip("requires app-local native helper; SYNTHETIC only")
	}
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	port := ln.Addr().(*net.TCPAddr).Port
	ln.Close()
	backend, err := newShadowBackend(Config{StateDir: t.TempDir(), ShadowExecutable: bin, ShadowSource: "synthetic", Port: port})
	if err != nil {
		t.Fatal(err)
	}
	s := backend.(*shadowBackend)
	defer s.Close(context.Background())
	command := Command{Relay: true, ExpiresAt: time.Now().Add(time.Minute), Allowed: remoteengine.Caps{Desktop: true, Input: true}}
	if err := s.Open(context.Background(), "aer", "TEST-ONLY-password-long-enough"); err == nil {
		t.Fatal("permissionless Open accepted")
	}
	bad := command
	bad.Relay = false
	if err := s.OpenSession(context.Background(), "aer", "TEST-ONLY-password-long-enough", bad); err == nil {
		t.Fatal("direct route accepted")
	}
	var oldPEM string
	for range 2 {
		ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
		err := s.OpenSession(ctx, "aer", "TEST-ONLY-password-long-enough", command)
		cancel()
		if err != nil {
			t.Fatal(err)
		}
		if !s.Alive() {
			t.Fatal("native helper exited")
		}
		cert, key, pem := s.SessionTLS()
		block, _ := pemutil.Decode([]byte(pem))
		if block == nil {
			t.Fatal("missing session certificate")
		}
		parsed, err := x509.ParseCertificate(block.Bytes)
		if err != nil {
			t.Fatal(err)
		}
		if !parsed.NotAfter.Equal(command.ExpiresAt.Truncate(time.Second)) {
			t.Fatal("certificate outlives its session")
		}
		if pem == oldPEM {
			t.Fatal("certificate reused between sessions")
		}
		oldPEM = pem
		sd, err := windows.GetNamedSecurityInfo(filepath.Dir(filepath.Dir(key)), windows.SE_FILE_OBJECT, windows.DACL_SECURITY_INFORMATION)
		if err != nil {
			t.Fatal(err)
		}
		descriptor := sd.String()
		if strings.Contains(descriptor, ";;;BU)") || strings.Contains(descriptor, ";;;WD)") || !strings.Contains(descriptor, "D:P") {
			t.Fatalf("unexpected session DACL %s", descriptor)
		}
		if err := s.Close(context.Background()); err != nil {
			t.Fatal(err)
		}
		if s.Alive() {
			t.Fatal("helper still running after close")
		}
		for _, p := range []string{cert, key} {
			if _, err := os.Stat(p); !os.IsNotExist(err) {
				t.Fatal("session certificate/key retained")
			}
		}
		if _, err := net.DialTimeout("tcp", net.JoinHostPort("127.0.0.1", strconv.Itoa(port)), 100*time.Millisecond); err == nil {
			t.Fatal("RDP listener retained")
		}
	}
}

func TestShadowPresenceDoesNotRetainPrivateKey(t *testing.T) {
	dir := t.TempDir()
	cert, err := shadowPresenceCert(Config{StateDir: dir})
	if err != nil || cert == "" {
		t.Fatalf("presence certificate: %v", err)
	}
	entries, err := os.ReadDir(dir)
	if err != nil || len(entries) != 0 {
		t.Fatal("unused presence key or directory retained")
	}
}

// The real native helper must stop when its own deadline expires even if
// the agent keeps stdin open and no Core/Gateway sends an end command.
func TestShadowSyntheticExpiresWithoutAgentClose(t *testing.T) {
	bin := os.Getenv("AER_SHADOW_BIN")
	if bin == "" {
		t.Skip("requires app-local native helper; SYNTHETIC only")
	}
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	port := ln.Addr().(*net.TCPAddr).Port
	ln.Close()
	backend, err := newShadowBackend(Config{StateDir: t.TempDir(), ShadowExecutable: bin, ShadowSource: "synthetic", Port: port})
	if err != nil {
		t.Fatal(err)
	}
	s := backend.(*shadowBackend)
	defer s.Close(context.Background())
	command := Command{Relay: true, ExpiresAt: time.Now().Add(2 * time.Second), Allowed: remoteengine.Caps{Desktop: true}}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := s.OpenSession(ctx, "aer", "TEST-ONLY-password-long-enough", command); err != nil {
		t.Fatal(err)
	}
	select {
	case <-s.done:
	case <-ctx.Done():
		t.Fatal("native helper did not terminate at its deadline")
	}
	if s.Alive() || s.input == nil {
		t.Fatal("deadline must terminate the helper without the agent closing stdin")
	}
	if conn, err := net.DialTimeout("tcp", net.JoinHostPort("127.0.0.1", strconv.Itoa(port)), 100*time.Millisecond); err == nil {
		conn.Close()
		t.Fatal("expired native RDP listener retained")
	}
}
