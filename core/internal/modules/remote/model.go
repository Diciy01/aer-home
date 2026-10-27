// Package remote is the control plane of AER Remote (M07, ADR-013).
//
// Remote hosts are Registry entities with a host agent (aer-remote-host,
// Monitoring agent kind "remote"). Core keeps host facts, the owner's
// policy, sessions and their audit; it never carries video, input,
// clipboard or files: those go client ↔ host over RDP/TLS (and the
// agent's own HTTPS file channel).
package remote

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

// Caps are what a host (or a policy, or a session) allows.
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

func (c Caps) and(o Caps) Caps {
	return Caps{Desktop: c.Desktop && o.Desktop, Input: c.Input && o.Input, Clipboard: c.Clipboard && o.Clipboard,
		Files: c.Files && o.Files, Apps: c.Apps && o.Apps}
}

// HostInfo is what the host agent reports in hello (no secrets).
type HostInfo struct {
	OS        string `json:"os"`
	OSVersion string `json:"osVersion"`
	Hostname  string `json:"hostname"`
	Version   string `json:"version"`
	// Backend: gnome-rdp (gnome-remote-desktop via grdctl) | windows-rdp.
	Backend   string `json:"backend"`
	Transport string `json:"transport"` // rdp
	Address   string `json:"address"`
	Port      int    `json:"port"`
	// CertPEM is the host's TLS certificate (public), pinned by clients.
	CertPEM   string `json:"certPem"`
	FilesPort int    `json:"filesPort"`
	Monitors  int    `json:"monitors"`
	Caps      Caps   `json:"capabilities"`
	// Approval: auto | prompt (the user on the host confirms each session).
	Approval string `json:"approval"`
	Ready    bool   `json:"ready"`
	Reason   string `json:"reason"`
	// Username for RDP; empty when the OS account is used (Windows).
	Username string `json:"username"`
}

// Policy is the owner's restriction for a host (intersected with Caps).
type Policy struct {
	Enabled    bool `json:"enabled"`
	Desktop    bool `json:"desktop"`
	Clipboard  bool `json:"clipboard"`
	Files      bool `json:"files"`
	MaxMinutes int  `json:"maxMinutes"`
	Revision   int  `json:"revision"`
}

// DefaultPolicy: desktop with clipboard, files off until the owner allows.
func DefaultPolicy() Policy {
	return Policy{Enabled: true, Desktop: true, Clipboard: true, Files: false, MaxMinutes: 60}
}

// Host is the list/detail view of a remote-capable computer.
type Host struct {
	EntityID string   `json:"entityId"`
	Name     string   `json:"name"`
	Type     string   `json:"type"`
	Archived bool     `json:"archived"`
	Declared []string `json:"declaredCapabilities"` // Registry capabilities remote.*/files.transfer
	// Agent: nil when no host agent ever said hello.
	Agent         *HostInfo  `json:"agent"`
	AgentActive   bool       `json:"agentActive"`
	LastHelloAt   *time.Time `json:"lastHelloAt"`
	CertSHA256    string     `json:"certSha256"`
	Policy        Policy     `json:"policy"`
	Effective     Caps       `json:"effective"`
	CanConnect    bool       `json:"canConnect"`
	Reason        string     `json:"reason"`
	Status        string     `json:"status"` // Monitoring status
	StatusReason  string     `json:"statusReason"`
	LastContactAt *time.Time `json:"lastContactAt"`
	ActiveSession *Session   `json:"activeSession"`
	LastSession   *Session   `json:"lastSession"`
}

// Session is one remote access session (metadata only: never screen
// content, keystrokes or file contents).
type Session struct {
	ID           string     `json:"id"`
	EntityID     string     `json:"entityId"`
	HostName     string     `json:"hostName"`
	Kind         string     `json:"kind"` // desktop | app
	SourceName   string     `json:"sourceName"`
	SourceEntity string     `json:"sourceEntityId"`
	ClientID     string     `json:"clientId"`
	Transport    string     `json:"transport"`
	State        State      `json:"state"`
	Reason       string     `json:"reason"`
	Allowed      Caps       `json:"allowed"`
	CreatedAt    time.Time  `json:"createdAt"`
	ApprovedAt   *time.Time `json:"approvedAt"`
	ReadyAt      *time.Time `json:"readyAt"`
	GrantedAt    *time.Time `json:"grantedAt"`
	ConnectedAt  *time.Time `json:"connectedAt"`
	EndedAt      *time.Time `json:"endedAt"`
	ExpiresAt    time.Time  `json:"expiresAt"`
	Events       []Event    `json:"events,omitempty"`
}

// Event is one audit entry of a session.
type Event struct {
	At      time.Time `json:"at"`
	Kind    string    `json:"kind"`
	Message string    `json:"message"`
}

// Grant is the one-time connection data for the client.
type Grant struct {
	SessionID      string     `json:"sessionId"`
	Transport      string     `json:"transport"`
	Host           string     `json:"host"`
	Port           int        `json:"port"`
	Username       string     `json:"username"`
	Password       string     `json:"password"`
	CertPEM        string     `json:"certPem"`
	CertSHA256     string     `json:"certSha256"`
	Clipboard      bool       `json:"clipboard"`
	Files          *FilesInfo `json:"files"`
	ExpiresAt      time.Time  `json:"expiresAt"`
	ExternalClient string     `json:"externalClient"` // what the client must launch
}

// FilesInfo addresses the host agent's file channel for this session.
type FilesInfo struct {
	URL      string `json:"url"`
	Token    string `json:"token"`
	MaxBytes int64  `json:"maxBytes"`
}

// AppsInfo answers the mobile Remote Apps question honestly.
type AppsInfo struct {
	Status string   `json:"status"` // unsupported | available
	Reason string   `json:"reason"`
	Apps   []AppRef `json:"apps"`
}

// AppRef is one allowed application window (future backends).
type AppRef struct {
	ID    string `json:"id"`
	Title string `json:"title"`
}

// Command is what Core asks the host agent to do.
type Command struct {
	ID        string    `json:"id"`
	Type      string    `json:"type"` // open | close
	SessionID string    `json:"sessionId"`
	ExpiresAt time.Time `json:"expiresAt"`
	Allowed   Caps      `json:"allowed"`
	Reason    string    `json:"reason,omitempty"`
}
