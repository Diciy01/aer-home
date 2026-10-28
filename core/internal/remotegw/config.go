// Package remotegw is the AER Remote Gateway (aer-remote-gateway, ADR-017):
// the only AER component meant to face the internet. It terminates TLS,
// limits failed attempts per address, forwards client requests to Core's
// /remote/gw API (Core decides everything) and splices aer-tunnel/1 legs
// of clients and host agents. It keeps no registry, no credentials and no
// sessions of its own — only the tunnels that are open right now.
package remotegw

import (
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/url"
	"os"
	"path/filepath"
)

// Config of the Gateway (JSON file; the credential lives in TokenFile).
type Config struct {
	// ListenAddr: where TLS is served, e.g. "0.0.0.0:8443" (the owner
	// forwards WAN 443 here by hand).
	ListenAddr string `json:"listenAddr"`
	// CoreURL: Core on the same server. Plain http only to loopback.
	CoreURL string `json:"coreUrl"`
	// TokenFile: the Gateway's agent credential (kind=gateway), 0600.
	TokenFile string `json:"tokenFile"`
	StateDir  string `json:"stateDir"`
	// TLSCert/TLSKey: the Gateway certificate; a self-signed ECDSA pair is
	// created in StateDir when empty. Clients pin it either way.
	TLSCert string `json:"tlsCert"`
	TLSKey  string `json:"tlsKey"`

	MaxTunnels          int `json:"maxTunnels"`
	MaxTunnelsPerClient int `json:"maxTunnelsPerClient"`
	MaxParkedPerSession int `json:"maxParkedPerSession"`
	IdleTimeoutSec      int `json:"idleTimeoutSec"`
	ParkTimeoutSec      int `json:"parkTimeoutSec"`
	PairWaitSec         int `json:"pairWaitSec"`
	AliveCheckSec       int `json:"aliveCheckSec"`
	// CoreLossSec: tunnels are closed when Core is unreachable this long.
	CoreLossSec int `json:"coreLossSec"`
	// Failed authentications per address before a ban.
	AuthFailLimit     int `json:"authFailLimit"`
	AuthFailWindowSec int `json:"authFailWindowSec"`
	BanSec            int `json:"banSec"`
	// PairLimit: pairing attempts per address per window (successful too).
	PairLimit int `json:"pairLimit"`
	// AgentProxy lets host agents outside the LAN reach Core's host agent
	// API through the Gateway (fixed list of agent paths only).
	AgentProxy bool `json:"agentProxy"`
}

// Default returns safe defaults (listen address and paths still needed).
func Default() Config {
	return Config{MaxTunnels: 16, MaxTunnelsPerClient: 4, MaxParkedPerSession: 2, IdleTimeoutSec: 600, ParkTimeoutSec: 120,
		PairWaitSec: 15, AliveCheckSec: 5, CoreLossSec: 60, AuthFailLimit: 10, AuthFailWindowSec: 600, BanSec: 900,
		PairLimit: 5, AgentProxy: true}
}

// Load reads and validates a config file.
func Load(path string) (Config, error) {
	c := Default()
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
	if _, _, err := net.SplitHostPort(c.ListenAddr); err != nil {
		errs = append(errs, errors.New("listenAddr: host:port"))
	}
	u, err := url.Parse(c.CoreURL)
	switch {
	case err != nil || u.Host == "" || (u.Scheme != "http" && u.Scheme != "https"):
		errs = append(errs, errors.New("coreUrl: http(s)://host:port"))
	case u.Scheme == "http" && !loopbackHost(u.Hostname()):
		errs = append(errs, errors.New("coreUrl: plain http only to loopback (the Gateway credential must not cross the network)"))
	}
	if !filepath.IsAbs(c.TokenFile) || !filepath.IsAbs(c.StateDir) {
		errs = append(errs, errors.New("tokenFile and stateDir: absolute paths"))
	}
	if (c.TLSCert == "") != (c.TLSKey == "") {
		errs = append(errs, errors.New("tlsCert and tlsKey: both or neither"))
	}
	in := func(name string, v, lo, hi int) {
		if v < lo || v > hi {
			errs = append(errs, fmt.Errorf("%s = %d: want %d…%d", name, v, lo, hi))
		}
	}
	in("maxTunnels", c.MaxTunnels, 1, 256)
	in("maxTunnelsPerClient", c.MaxTunnelsPerClient, 1, c.MaxTunnels)
	in("maxParkedPerSession", c.MaxParkedPerSession, 1, 8)
	in("idleTimeoutSec", c.IdleTimeoutSec, 10, 24*3600)
	in("parkTimeoutSec", c.ParkTimeoutSec, 5, 3600)
	in("pairWaitSec", c.PairWaitSec, 1, 120)
	in("aliveCheckSec", c.AliveCheckSec, 1, 60)
	in("coreLossSec", c.CoreLossSec, 5, 3600)
	in("authFailLimit", c.AuthFailLimit, 1, 1000)
	in("authFailWindowSec", c.AuthFailWindowSec, 10, 86400)
	in("banSec", c.BanSec, 10, 86400)
	in("pairLimit", c.PairLimit, 1, 100)
	return errors.Join(errs...)
}

func loopbackHost(h string) bool {
	if h == "localhost" {
		return true
	}
	ip := net.ParseIP(h)
	return ip != nil && ip.IsLoopback()
}
