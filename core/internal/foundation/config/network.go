package config

import (
	"errors"
	"fmt"
	"net"
	"net/url"
	"regexp"
	"strconv"
	"strings"
)

// Network configures M09 Network + TV: the internet check, read-only router
// adapters and Sunshine instances. Everything is off/empty by default: an
// unconfigured integration is shown as "not configured", never guessed.
type Network struct {
	IntervalSec int `json:"intervalSec"`
	TimeoutSec  int `json:"timeoutSec"`
	// FailuresBeforeDown: consecutive failed checks before "down".
	FailuresBeforeDown int `json:"failuresBeforeDown"`
	// Internet: explicit targets "host:port" (port 443 or "tls://" → TLS
	// handshake, "tcp://" or other ports → TCP connect); empty = not configured.
	Internet NetInternet `json:"internet"`
	// Routers: optional read-only adapters for Registry router entities.
	Routers []NetRouter `json:"routers"`
	// Sunshine streaming servers to observe.
	Sunshine []SunshineInstance `json:"sunshine"`
}

// NetInternet lists internet probe targets.
type NetInternet struct {
	Targets []string `json:"targets"`
}

// NetRouter: a Registry router entity and its documented read-only API.
type NetRouter struct {
	EntityID string `json:"entityId"`
	// UPnPURL is the UPnP IGD device description URL (rootDesc.xml) when
	// UPnP is enabled on the router; only Get* actions are called.
	UPnPURL string `json:"upnpUrl"`
}

// SunshineInstance is one Sunshine server (observed, never controlled).
type SunshineInstance struct {
	ID   string `json:"id"`
	Name string `json:"name"`
	// EntityID: the Registry object of Sunshine (service) or of its host PC.
	EntityID string `json:"entityId"`
	// TVEntityID: the TV that streams from it (shown separately).
	TVEntityID string `json:"tvEntityId"`
	// ServerInfoURL: GameStream HTTP base, e.g. http://127.0.0.1:47989.
	ServerInfoURL string `json:"serverInfoUrl"`
	// WebURL: Sunshine web UI (opened by the client), e.g. https://127.0.0.1:47990.
	WebURL string `json:"webUrl"`
}

// DefaultNetwork: checks every 30 s, nothing configured.
func DefaultNetwork() Network {
	return Network{IntervalSec: 30, TimeoutSec: 5, FailuresBeforeDown: 2}
}

var (
	netID   = regexp.MustCompile(`^[a-z0-9][a-z0-9_-]{0,39}$`)
	netUUID = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`)
)

func validHTTPURL(raw string) bool {
	u, err := url.Parse(raw)
	return err == nil && (u.Scheme == "http" || u.Scheme == "https") && u.Host != "" && u.User == nil
}

// Validate rejects malformed or unsafe settings.
func (n Network) Validate() error {
	var errs []error
	in := func(name string, v, lo, hi int) {
		if v < lo || v > hi {
			errs = append(errs, fmt.Errorf("network.%s = %d: want %d…%d", name, v, lo, hi))
		}
	}
	in("intervalSec", n.IntervalSec, 10, 3600)
	in("timeoutSec", n.TimeoutSec, 1, 30)
	in("failuresBeforeDown", n.FailuresBeforeDown, 1, 10)
	if n.TimeoutSec >= n.IntervalSec {
		errs = append(errs, errors.New("network.timeoutSec must be below intervalSec"))
	}
	if len(n.Internet.Targets) > 8 {
		errs = append(errs, errors.New("network.internet.targets: at most 8"))
	}
	for _, t := range n.Internet.Targets {
		h, p, err := net.SplitHostPort(strings.TrimPrefix(strings.TrimPrefix(t, "tls://"), "tcp://"))
		if port, perr := strconv.Atoi(p); err != nil || h == "" || perr != nil || port < 1 || port > 65535 {
			errs = append(errs, fmt.Errorf("network.internet.targets: %q, want host:port", t))
		}
	}
	for i, r := range n.Routers {
		if !netUUID.MatchString(r.EntityID) {
			errs = append(errs, fmt.Errorf("network.routers[%d].entityId: Registry id", i))
		}
		if r.UPnPURL != "" && !validHTTPURL(r.UPnPURL) {
			errs = append(errs, fmt.Errorf("network.routers[%d].upnpUrl: http(s) URL without credentials", i))
		}
	}
	seen := map[string]bool{}
	for i, s := range n.Sunshine {
		if !netID.MatchString(s.ID) || seen[s.ID] {
			errs = append(errs, fmt.Errorf("network.sunshine[%d].id: unique, a-z0-9_-", i))
		}
		seen[s.ID] = true
		if !validHTTPURL(s.ServerInfoURL) {
			errs = append(errs, fmt.Errorf("network.sunshine[%d].serverInfoUrl: http(s) URL without credentials", i))
		}
		if s.WebURL != "" && !validHTTPURL(s.WebURL) {
			errs = append(errs, fmt.Errorf("network.sunshine[%d].webUrl: http(s) URL without credentials", i))
		}
		for _, id := range []string{s.EntityID, s.TVEntityID} {
			if id != "" && !netUUID.MatchString(id) {
				errs = append(errs, fmt.Errorf("network.sunshine[%d]: entity ids are Registry ids", i))
			}
		}
	}
	return errors.Join(errs...)
}
