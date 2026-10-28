package remotehost

import (
	"context"
	"net"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"testing"
)

func TestWindowsDeployExampleLoads(t *testing.T) {
	if runtime.GOOS != "windows" {
		t.Skip("Windows absolute paths")
	}
	c, err := Load(filepath.Join("..", "..", "..", "deploy", "remote-host.windows.example.json"))
	if err != nil {
		t.Fatal(err)
	}
	if c.Backend != "windows-rdp" || c.Clipboard || c.Files.Enabled {
		t.Fatal("readiness-only example must not advertise clipboard/files")
	}
}

// A listening port is not evidence of an enforceable AER session. This is a
// loopback TCP stub, never the user's RDP service, and runs on Linux too.
func TestWindowsBackendRefusesUnmanagedSessions(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	w := &windowsBackend{c: Config{Port: ln.Addr().(*net.TCPAddr).Port}}
	if ready, reason := w.Ready(context.Background()); ready || !strings.Contains(reason, "M14.4") {
		t.Fatalf("listening port %s: ready=%v reason=%s", strconv.Itoa(w.c.Port), ready, reason)
	}
	if err := w.Open(context.Background(), "", "test"); err == nil {
		t.Fatal("unmanaged Windows session accepted")
	}
	ln.Close()
	if ready, reason := w.Ready(context.Background()); ready || !strings.Contains(reason, "Home") {
		t.Fatalf("closed port: ready=%v reason=%s", ready, reason)
	}
}
