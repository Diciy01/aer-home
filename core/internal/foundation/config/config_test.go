package config

import (
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"

	"aerhome/core/internal/testenv"
)

// envFrom: on Windows the default data dir comes from LOCALAPPDATA, derived
// here from HOME so the same cases run on both systems.
func envFrom(m map[string]string) EnvLookup {
	if h, ok := m["HOME"]; ok && runtime.GOOS == "windows" {
		m["LOCALAPPDATA"] = testenv.Abs(h)
	}
	return func(k string) (string, bool) { v, ok := m[k]; return v, ok }
}

func TestDefaultsAreValidAndLoopback(t *testing.T) {
	cfg, err := Load("", envFrom(map[string]string{"HOME": "/home/test"}))
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if cfg.Mode != ModeDevelopment || cfg.ListenAddr != "127.0.0.1:8787" {
		t.Fatalf("unexpected defaults: %+v", cfg)
	}
	want := "/home/test/.local/share/aer-home/core"
	if runtime.GOOS == "windows" {
		want = testenv.Abs("/home/test/aer-home/core")
	}
	if cfg.DataDir != want {
		t.Fatalf("DataDir = %q", cfg.DataDir)
	}
	if !cfg.IsDemo() {
		t.Fatal("development mode must be flagged as demo")
	}
}

func TestFileThenEnvPrecedence(t *testing.T) {
	path := filepath.Join(t.TempDir(), "core.json")
	body := `{"mode":"local","listenAddr":"127.0.0.1:9000","logLevel":"debug","modules":{"bots":false}}`
	if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	cfg, err := Load(path, envFrom(map[string]string{
		"HOME":       "/home/test",
		"AER_LISTEN": "127.0.0.1:9100",
	}))
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if cfg.Mode != ModeLocal || cfg.LogLevel != "debug" {
		t.Fatalf("file values not applied: %+v", cfg)
	}
	if cfg.ListenAddr != "127.0.0.1:9100" {
		t.Fatalf("env should override file, got %q", cfg.ListenAddr)
	}
	if cfg.ModuleEnabled("bots") || !cfg.ModuleEnabled("registry") {
		t.Fatal("module switches not applied")
	}
}

func TestRejectsUnknownFields(t *testing.T) {
	path := filepath.Join(t.TempDir(), "core.json")
	if err := os.WriteFile(path, []byte(`{"mode":"local","apiToken":"x"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := Load(path, envFrom(map[string]string{"HOME": "/h"})); err == nil {
		t.Fatal("expected unknown field to be rejected")
	}
}

func TestValidation(t *testing.T) {
	base := Default(envFrom(map[string]string{"HOME": "/h"}))
	cases := map[string]func(*Config){
		"bad mode":          func(c *Config) { c.Mode = "prod" },
		"no port":           func(c *Config) { c.ListenAddr = "127.0.0.1" },
		"dev on LAN":        func(c *Config) { c.ListenAddr = "0.0.0.0:8787" },
		"relative data dir": func(c *Config) { c.DataDir = "data" },
		"bad log level":     func(c *Config) { c.LogLevel = "trace" },
		"bad log format":    func(c *Config) { c.LogFormat = "xml" },
	}
	for name, mutate := range cases {
		t.Run(name, func(t *testing.T) {
			c := base
			mutate(&c)
			if err := c.Validate(); err == nil {
				t.Fatal("expected validation error")
			}
		})
	}

	server := base
	server.Mode = ModeServer
	server.ListenAddr = "0.0.0.0:8787"
	if err := server.Validate(); err != nil {
		t.Fatalf("server mode may bind to LAN: %v", err)
	}
}

func TestValidationReportsAllErrors(t *testing.T) {
	c := Default(envFrom(map[string]string{"HOME": "/h"}))
	c.Mode = "x"
	c.LogLevel = "y"
	err := c.Validate()
	if err == nil || !strings.Contains(err.Error(), "mode") || !strings.Contains(err.Error(), "logLevel") {
		t.Fatalf("want both errors, got %v", err)
	}
}

func TestMonitoringDefaultsAndValidation(t *testing.T) {
	m := DefaultMonitoring()
	if err := m.Validate(); err != nil {
		t.Fatalf("defaults must be valid: %v", err)
	}
	if m.Telegram.Enabled {
		t.Fatal("Telegram must be off by default")
	}
	bad := m
	bad.Docker.Socket = "tcp://192.0.2.10:2375"
	bad.Telegram.Enabled = true
	bad.CheckIntervalSec = 1
	bad.Thresholds.DiskFreeCriticalPercent = 50
	err := bad.Validate()
	if err == nil {
		t.Fatal("expected errors")
	}
	for _, want := range []string{"docker.socket", "telegram: enabled", "checkIntervalSec", "diskFreeCriticalPercent"} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("missing %q in %v", want, err)
		}
	}
}
