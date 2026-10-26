package config

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func envFrom(m map[string]string) EnvLookup {
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
	if cfg.DataDir != "/home/test/.local/share/aer-home/core" {
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
