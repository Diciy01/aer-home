package remotegw

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"

	"aerhome/core/internal/foundation/config"
)

// deploy/ubuntu (ADR-018): the shipped server configs must stay loadable.
// Unknown fields are refused everywhere; full validation needs Linux paths.
func TestUbuntuDeployConfigs(t *testing.T) {
	dir := filepath.Join("..", "..", "..", "deploy", "ubuntu")
	gwRaw, err := os.ReadFile(filepath.Join(dir, "remote-gateway.json"))
	if err != nil {
		t.Fatal(err)
	}
	gw := Default()
	dec := json.NewDecoder(bytes.NewReader(gwRaw))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&gw); err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(gw.CoreURL, "http://127.0.0.1:") || !gw.AgentProxy {
		t.Fatalf("gateway must reach Core on loopback and proxy host agents: %+v", gw)
	}
	coreRaw, _ := os.ReadFile(filepath.Join(dir, "core.json"))
	c := config.Default(func(string) (string, bool) { return "", false })
	dec = json.NewDecoder(bytes.NewReader(coreRaw))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&c); err != nil {
		t.Fatal(err)
	}
	if c.ListenAddr != "127.0.0.1:8787" {
		t.Fatalf("Core must stay on loopback, got %s", c.ListenAddr)
	}
	for _, unit := range []string{"aer-core.service", "aer-remote-gateway.service"} {
		raw, err := os.ReadFile(filepath.Join(dir, unit))
		if err != nil {
			t.Fatal(err)
		}
		for _, must := range []string{"NoNewPrivileges=yes", "ProtectSystem=strict", "CapabilityBoundingSet=\n", "User=aer-"} {
			if !strings.Contains(strings.ReplaceAll(string(raw), "\r\n", "\n"), must) {
				t.Fatalf("%s lacks %q", unit, must)
			}
		}
	}
	if runtime.GOOS != "linux" {
		t.Log("full Validate of Linux paths: UNVERIFIED on this OS")
		return
	}
	if err := gw.Validate(); err != nil {
		t.Fatal(err)
	}
	if _, err := config.Load(filepath.Join(dir, "core.json"), func(string) (string, bool) { return "", false }); err != nil {
		t.Fatal(err)
	}
}
