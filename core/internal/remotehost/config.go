// Package remotehost is the AER Remote host agent (aer-remote-host, M07):
// it opens the local RDP server only for sessions Core authorized, with a
// fresh password per session, and serves the session's file channel.
// It runs as the logged-in user and never bypasses the OS's consent rules.
package remotehost

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"os"
	"path/filepath"

	"aerhome/core/internal/remoteengine"
)

// Config of the host agent (JSON file; the token lives in TokenFile).
type Config struct {
	CoreURL   string `json:"coreUrl"`
	TokenFile string `json:"tokenFile"`
	StateDir  string `json:"stateDir"`
	// Backend: gnome-rdp (gnome-remote-desktop through grdctl) or
	// windows-rdp (built-in RDP; readiness only, OS account credentials).
	Backend string `json:"backend"`
	// ShadowExecutable is the app-local aer-shadow.exe (never Windows RDP).
	ShadowExecutable string `json:"shadowExecutable"`
	// ShadowSource: desktop, or explicitly synthetic for isolated tests only.
	ShadowSource   string `json:"shadowSource"`
	ShadowViewOnly bool   `json:"shadowViewOnly"`
	// Grdctl is the argv prefix for grdctl, e.g. ["grdctl"] or
	// ["grdctl","--headless"] for a headless GNOME session.
	Grdctl []string `json:"grdctl"`
	// Daemon is the gnome-remote-desktop daemon argv the agent starts for
	// each session and stops at its end. The daemon reads credentials only
	// at start (verified on GNOME 46), so a long-running daemon would keep
	// accepting the previous password; per-session start avoids that.
	// Empty: the agent does not manage the daemon (UNSAFE, refused).
	Daemon []string `json:"daemon"`
	// Address the clients use to reach this host (LAN or VPN name/IP).
	Address string `json:"address"`
	Port    int    `json:"port"`
	RDPUser string `json:"rdpUser"`
	// TLSCert/TLSKey: the RDP server certificate (generated in StateDir when empty).
	TLSCert string `json:"tlsCert"`
	TLSKey  string `json:"tlsKey"`
	// Approval: auto (owner policy is enough) or prompt (ask the user here).
	Approval      string   `json:"approval"`
	PromptCommand []string `json:"promptCommand"`
	Clipboard     bool     `json:"clipboard"`
	Files         Files    `json:"files"`
	// CoreCertSHA256 pins Core's (or the Gateway's agent proxy) TLS
	// certificate when coreUrl is https and the certificate is self-signed.
	CoreCertSHA256 string `json:"coreCertSha256"`
	// GatewayURL: the Remote Gateway for relay sessions (ADR-017), e.g.
	// https://home.example:443. Empty: relay sessions are refused.
	GatewayURL        string `json:"gatewayUrl"`
	GatewayCertSHA256 string `json:"gatewayCertSha256"`
}

// Files is the session file channel (HTTPS on this host, not via Core).
type Files struct {
	Enabled  bool   `json:"enabled"`
	Dir      string `json:"dir"`
	Port     int    `json:"port"`
	MaxBytes int64  `json:"maxBytes"`
}

// Load reads and validates a config file.
func Load(path string) (Config, error) {
	c := Config{Backend: "gnome-rdp", Grdctl: []string{"grdctl"}, Daemon: []string{"/usr/libexec/gnome-remote-desktop-daemon"}, Port: 3389, RDPUser: "aer", Approval: "auto",
		PromptCommand: []string{"zenity", "--question", "--title=AER HOME", "--timeout=100"}, Clipboard: true,
		Files: Files{Port: 3390, MaxBytes: 2 << 30}}
	raw, err := os.ReadFile(path)
	if err != nil {
		return c, err
	}
	dec := json.NewDecoder(bytesReader(raw))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&c); err != nil {
		return c, fmt.Errorf("parse %s: %w", path, err)
	}
	return c, c.Validate()
}

// Validate rejects unsafe or incomplete settings.
func (c Config) Validate() error {
	var errs []error
	if u, err := url.Parse(c.CoreURL); err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Host == "" {
		errs = append(errs, errors.New("coreUrl: want http(s)://host:port"))
	}
	if !filepath.IsAbs(c.TokenFile) || !filepath.IsAbs(c.StateDir) {
		errs = append(errs, errors.New("tokenFile and stateDir: absolute paths"))
	}
	if c.Backend != "gnome-rdp" && c.Backend != "windows-rdp" && c.Backend != "windows-shadow" {
		errs = append(errs, errors.New("backend: gnome-rdp, windows-rdp or windows-shadow"))
	}
	if c.Backend == "windows-shadow" {
		if !filepath.IsAbs(c.ShadowExecutable) || c.Address != "127.0.0.1" || c.Approval != "prompt" || c.GatewayURL == "" {
			errs = append(errs, errors.New("windows-shadow: absolute shadowExecutable, loopback address, prompt approval and Gateway required"))
		}
		if c.ShadowSource != "desktop" && c.ShadowSource != "synthetic" {
			errs = append(errs, errors.New("shadowSource: desktop or synthetic (test only)"))
		}
		if c.TLSCert != "" || c.TLSKey != "" {
			errs = append(errs, errors.New("windows-shadow generates private per-session TLS certificates"))
		}
	}
	if c.Backend == "gnome-rdp" && (len(c.Grdctl) == 0 || len(c.Daemon) == 0 || !filepath.IsAbs(c.Daemon[0])) {
		errs = append(errs, errors.New("grdctl and daemon (absolute path): the agent runs gnome-remote-desktop per session"))
	}
	if c.Address == "" || c.Port < 1 || c.Port > 65535 {
		errs = append(errs, errors.New("address/port: where clients reach the RDP server"))
	}
	if c.Approval != "auto" && c.Approval != "prompt" {
		errs = append(errs, errors.New("approval: auto or prompt"))
	}
	if c.Approval == "prompt" && len(c.PromptCommand) == 0 && c.Backend != "windows-shadow" {
		errs = append(errs, errors.New("promptCommand required for approval=prompt"))
	}
	if c.GatewayURL != "" {
		if u, err := url.Parse(c.GatewayURL); err != nil || u.Scheme != "https" || u.Host == "" || (u.Path != "" && u.Path != "/") {
			errs = append(errs, errors.New("gatewayUrl: https://host[:port] (TLS only)"))
		}
		if len(remoteengine.NormalizeFingerprint(c.GatewayCertSHA256)) != 64 {
			errs = append(errs, errors.New("gatewayCertSha256: the pinned SHA-256 of the Gateway certificate"))
		}
	}
	if c.CoreCertSHA256 != "" && len(remoteengine.NormalizeFingerprint(c.CoreCertSHA256)) != 64 {
		errs = append(errs, errors.New("coreCertSha256: SHA-256 fingerprint"))
	}
	if c.Files.Enabled {
		if !filepath.IsAbs(c.Files.Dir) {
			errs = append(errs, errors.New("files.dir: absolute path of the exchange folder"))
		}
		if c.Files.Port < 1 || c.Files.Port > 65535 || c.Files.Port == c.Port {
			errs = append(errs, errors.New("files.port: a separate port"))
		}
		if c.Files.MaxBytes < 1 {
			errs = append(errs, errors.New("files.maxBytes: positive"))
		}
	}
	return errors.Join(errs...)
}
