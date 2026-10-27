package config

import (
	"errors"
	"fmt"
)

// Remote configures the M07 Remote control plane. Video, input and files
// never pass through Core; these are session lifecycle limits.
type Remote struct {
	MaxActiveSessions  int `json:"maxActiveSessions"`
	DefaultMinutes     int `json:"defaultMinutes"`
	MaxMinutes         int `json:"maxMinutes"`
	ApprovalTimeoutSec int `json:"approvalTimeoutSec"`
	// PickupTimeoutSec: the host agent must react to a new session in time.
	PickupTimeoutSec int `json:"pickupTimeoutSec"`
	// GrantTTLSec: the client must fetch the one-time grant in time.
	GrantTTLSec       int `json:"grantTtlSec"`
	ReconnectGraceSec int `json:"reconnectGraceSec"`
	// AgentTimeoutSec: a host agent silent this long is not ready.
	AgentTimeoutSec int `json:"agentTimeoutSec"`
	RetentionDays   int `json:"retentionDays"`
}

// DefaultRemote returns the M07 defaults.
func DefaultRemote() Remote {
	return Remote{MaxActiveSessions: 4, DefaultMinutes: 60, MaxMinutes: 480, ApprovalTimeoutSec: 120,
		PickupTimeoutSec: 30, GrantTTLSec: 60, ReconnectGraceSec: 120, AgentTimeoutSec: 90, RetentionDays: 365}
}

// Validate rejects out-of-range values.
func (r Remote) Validate() error {
	var errs []error
	in := func(name string, v, lo, hi int) {
		if v < lo || v > hi {
			errs = append(errs, fmt.Errorf("remote.%s = %d: want %d…%d", name, v, lo, hi))
		}
	}
	in("maxActiveSessions", r.MaxActiveSessions, 1, 64)
	in("maxMinutes", r.MaxMinutes, 5, 24*60)
	in("defaultMinutes", r.DefaultMinutes, 5, r.MaxMinutes)
	in("approvalTimeoutSec", r.ApprovalTimeoutSec, 10, 900)
	in("pickupTimeoutSec", r.PickupTimeoutSec, 5, 300)
	in("grantTtlSec", r.GrantTTLSec, 10, 600)
	in("reconnectGraceSec", r.ReconnectGraceSec, 5, 3600)
	in("agentTimeoutSec", r.AgentTimeoutSec, 15, 3600)
	in("retentionDays", r.RetentionDays, 7, 3650)
	return errors.Join(errs...)
}
