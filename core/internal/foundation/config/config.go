// Package config loads and validates AER Core configuration.
//
// Precedence: built-in defaults < JSON config file < AER_* environment variables.
// The config never contains secrets; the API token lives in a separate file.
package config

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"runtime"
	"strings"
)

// Mode is the execution mode described in docs/ARCHITECTURE.md.
type Mode string

const (
	ModeDevelopment Mode = "development"
	ModeLocal       Mode = "local"
	ModeServer      Mode = "server"
)

// Config is the effective Core configuration.
type Config struct {
	Mode       Mode   `json:"mode"`
	ListenAddr string `json:"listenAddr"`
	DataDir    string `json:"dataDir"`
	LogLevel   string `json:"logLevel"`
	LogFormat  string `json:"logFormat"`
	// Modules switches optional modules on or off by name. Absent means enabled.
	Modules map[string]bool `json:"modules,omitempty"`
	// Monitoring configures the Monitoring module (M05).
	Monitoring Monitoring `json:"monitoring"`
	// Bots configures the Bots module (M06): management adapters and integrations.
	Bots Bots `json:"bots"`
	// Remote configures the Remote access control plane (M07).
	Remote Remote `json:"remote"`
	// Power configures Wake-on-LAN and power/boot jobs (M08).
	Power Power `json:"power"`
}

// EnvLookup matches os.LookupEnv so tests can inject an isolated environment.
type EnvLookup func(key string) (string, bool)

// Default returns the configuration used when nothing is overridden.
func Default(env EnvLookup) Config {
	return Config{
		Mode:       ModeDevelopment,
		ListenAddr: "127.0.0.1:8787",
		DataDir:    defaultDataDir(env),
		LogLevel:   "info",
		LogFormat:  "text",
		Monitoring: DefaultMonitoring(),
		Bots:       DefaultBots(),
		Remote:     DefaultRemote(),
		Power:      DefaultPower(),
	}
}

// Load builds the effective configuration. path may be empty.
func Load(path string, env EnvLookup) (Config, error) {
	cfg := Default(env)
	if path != "" {
		raw, err := os.ReadFile(path)
		if err != nil {
			return Config{}, fmt.Errorf("read config %q: %w", path, err)
		}
		dec := json.NewDecoder(bytes.NewReader(raw))
		dec.DisallowUnknownFields()
		if err := dec.Decode(&cfg); err != nil {
			return Config{}, fmt.Errorf("parse config %q: %w", path, err)
		}
	}
	applyEnv(&cfg, env)
	if err := cfg.Validate(); err != nil {
		return Config{}, err
	}
	return cfg, nil
}

func applyEnv(cfg *Config, env EnvLookup) {
	if v, ok := env("AER_MODE"); ok && v != "" {
		cfg.Mode = Mode(v)
	}
	if v, ok := env("AER_LISTEN"); ok && v != "" {
		cfg.ListenAddr = v
	}
	if v, ok := env("AER_DATA_DIR"); ok && v != "" {
		cfg.DataDir = v
	}
	if v, ok := env("AER_LOG_LEVEL"); ok && v != "" {
		cfg.LogLevel = v
	}
	if v, ok := env("AER_LOG_FORMAT"); ok && v != "" {
		cfg.LogFormat = v
	}
}

// Validate rejects unknown values and unsafe combinations.
func (c Config) Validate() error {
	var errs []error
	switch c.Mode {
	case ModeDevelopment, ModeLocal, ModeServer:
	default:
		errs = append(errs, fmt.Errorf("mode %q: want development, local or server", c.Mode))
	}
	host, port, err := net.SplitHostPort(c.ListenAddr)
	if err != nil || port == "" {
		errs = append(errs, fmt.Errorf("listenAddr %q: want host:port", c.ListenAddr))
	} else if c.Mode == ModeDevelopment && !isLoopback(host) {
		// Development builds use demo data and must never be reachable from the LAN.
		errs = append(errs, fmt.Errorf("listenAddr %q: development mode only binds to loopback", c.ListenAddr))
	}
	if c.DataDir == "" || !filepath.IsAbs(c.DataDir) {
		errs = append(errs, fmt.Errorf("dataDir %q: want an absolute path", c.DataDir))
	}
	switch strings.ToLower(c.LogLevel) {
	case "debug", "info", "warn", "error":
	default:
		errs = append(errs, fmt.Errorf("logLevel %q: want debug, info, warn or error", c.LogLevel))
	}
	switch c.LogFormat {
	case "text", "json":
	default:
		errs = append(errs, fmt.Errorf("logFormat %q: want text or json", c.LogFormat))
	}
	if err := c.Monitoring.Validate(); err != nil {
		errs = append(errs, err)
	}
	if err := c.Bots.Validate(); err != nil {
		errs = append(errs, err)
	}
	if err := c.Remote.Validate(); err != nil {
		errs = append(errs, err)
	}
	if err := c.Power.Validate(); err != nil {
		errs = append(errs, err)
	}
	return errors.Join(errs...)
}

// ModuleEnabled reports whether an optional module is switched on.
func (c Config) ModuleEnabled(name string) bool {
	enabled, set := c.Modules[name]
	return !set || enabled
}

// DatabasePath is the SQLite file owned by this Core instance.
func (c Config) DatabasePath() string { return filepath.Join(c.DataDir, "aer-core.db") }

// TokenPath is the file holding the local API bearer token.
func (c Config) TokenPath() string { return filepath.Join(c.DataDir, "core.token") }

// IsDemo reports whether demo/test data may be shown; clients must label it.
func (c Config) IsDemo() bool { return c.Mode == ModeDevelopment }

func isLoopback(host string) bool {
	if host == "localhost" {
		return true
	}
	ip := net.ParseIP(host)
	return ip != nil && ip.IsLoopback()
}

func defaultDataDir(env EnvLookup) string {
	if runtime.GOOS == "windows" {
		if v, ok := env("LOCALAPPDATA"); ok && v != "" {
			return filepath.Join(v, "aer-home", "core")
		}
	}
	if v, ok := env("XDG_DATA_HOME"); ok && v != "" {
		return filepath.Join(v, "aer-home", "core")
	}
	if home, ok := env("HOME"); ok && home != "" {
		return filepath.Join(home, ".local", "share", "aer-home", "core")
	}
	return ""
}
