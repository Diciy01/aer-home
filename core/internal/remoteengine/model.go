// Package remoteengine is the shared part of AER Remote (ADR-017): the
// session model and wire messages used by Core, the Remote Gateway and the
// host agent, the aer-tunnel/1 relay protocol and certificate pinning.
// It has no UI and no knowledge of a particular application; platform
// specifics stay in adapters (remotehost.Backend, client viewers).
package remoteengine

import "time"

// State of a remote session.
type State string

const (
	StatePending          State = "pending"
	StateAwaitingApproval State = "awaiting_approval"
	StateConnecting       State = "connecting"
	StateConnected        State = "connected"
	StateReconnecting     State = "reconnecting"
	StateDisconnected     State = "disconnected"
	StateFailed           State = "failed"
	StateExpired          State = "expired"
	StateRevoked          State = "revoked"
)

// Terminal states never change again.
func (s State) Terminal() bool {
	switch s {
	case StateDisconnected, StateFailed, StateExpired, StateRevoked:
		return true
	}
	return false
}

// Caps are what a host (or a policy, a client, a session) allows.
type Caps struct {
	Desktop   bool `json:"desktop"`
	Input     bool `json:"input"`
	Clipboard bool `json:"clipboard"`
	Files     bool `json:"files"`
	// Apps: single-application sessions (mobile Remote Apps). Declared by
	// the host only when a backend can isolate an application; no current
	// backend can (ADR-013).
	Apps bool `json:"apps"`
}

// And is the intersection of two permission sets.
func (c Caps) And(o Caps) Caps {
	return Caps{Desktop: c.Desktop && o.Desktop, Input: c.Input && o.Input, Clipboard: c.Clipboard && o.Clipboard,
		Files: c.Files && o.Files, Apps: c.Apps && o.Apps}
}

// Routes: how the client reaches the host.
const (
	// RouteDirect: client → host address in the LAN (M07).
	RouteDirect = "direct"
	// RouteRelay: client → Gateway ← host agent, spliced (ADR-017).
	RouteRelay = "relay"
)

// Tunnel channels: what a relay leg carries on the host side.
const (
	ChannelRDP   = "rdp"
	ChannelFiles = "files"
)

// ValidChannel reports a known channel name.
func ValidChannel(c string) bool { return c == ChannelRDP || c == ChannelFiles }

// Command is what Core asks the host agent to do.
type Command struct {
	ID        string    `json:"id"`
	Type      string    `json:"type"` // open | close
	SessionID string    `json:"sessionId"`
	ExpiresAt time.Time `json:"expiresAt"`
	Allowed   Caps      `json:"allowed"`
	Reason    string    `json:"reason,omitempty"`
	// Relay: the client comes through the Gateway; the agent parks
	// outgoing tunnel legs instead of waiting for inbound connections.
	Relay bool `json:"relay,omitempty"`
}

// Agent session events.
const (
	EventAwaitingApproval = "awaiting_approval"
	EventApproved         = "approved"
	EventDenied           = "denied"
	EventReady            = "ready"
	EventConnected        = "connected"
	EventDisconnected     = "disconnected"
	EventClosed           = "closed"
	EventFailed           = "failed"
)

// AgentEvent is what the host agent reports about a session.
type AgentEvent struct {
	Event      string `json:"event"`
	Password   string `json:"password"`
	FilesToken string `json:"filesToken"`
	Message    string `json:"message"`
}

// Grant is the one-time connection data for the client.
type Grant struct {
	SessionID  string     `json:"sessionId"`
	Transport  string     `json:"transport"`
	Route      string     `json:"route"`
	Host       string     `json:"host"`
	Port       int        `json:"port"`
	Username   string     `json:"username"`
	Password   string     `json:"password"`
	CertPEM    string     `json:"certPem"`
	CertSHA256 string     `json:"certSha256"`
	Clipboard  bool       `json:"clipboard"`
	Files      *FilesInfo `json:"files"`
	// Tunnel: relay route only — one-time tickets per channel.
	Tunnel         *TunnelInfo `json:"tunnel"`
	ExpiresAt      time.Time   `json:"expiresAt"`
	ExternalClient string      `json:"externalClient"` // what a fallback client must launch
}

// FilesInfo addresses the host agent's file channel for this session.
// On the relay route URL is empty: the client reaches it through a
// "files" tunnel leg and pins the host certificate.
type FilesInfo struct {
	URL      string `json:"url"`
	Token    string `json:"token"`
	MaxBytes int64  `json:"maxBytes"`
}

// TunnelInfo carries one-time tickets for the relay legs of a session.
type TunnelInfo struct {
	// Path on the Gateway (relative to its base URL).
	Path    string            `json:"path"`
	Tickets map[string]string `json:"tickets"` // channel → ticket
	TTLSec  int               `json:"ttlSec"`
}
