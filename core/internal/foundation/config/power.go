package config

import (
	"errors"
	"fmt"
)

// Power configures the M08 Power module: Wake-on-LAN sent by Core and
// power/boot jobs executed by host agents through fixed adapters.
type Power struct {
	// WoL: Core sends magic packets only when the owner switched it on.
	WoL WoL `json:"wol"`
	// ConfirmTTLSec: a confirmation token is valid this long (single use).
	ConfirmTTLSec int `json:"confirmTtlSec"`
	// PickupTimeoutSec: the host agent must take a command in time,
	// otherwise the job fails and the command is withdrawn.
	PickupTimeoutSec int `json:"pickupTimeoutSec"`
	// OfflineTimeoutSec: after shutdown/suspend the device must go silent.
	OfflineTimeoutSec int `json:"offlineTimeoutSec"`
	// BootTimeoutSec: after wake/reboot/OS switch the device must report back.
	BootTimeoutSec int `json:"bootTimeoutSec"`
	// AgentTimeoutSec: a power agent silent this long cannot take commands.
	AgentTimeoutSec int `json:"agentTimeoutSec"`
	// MaxActiveJobs: jobs in flight across all devices (one per device).
	MaxActiveJobs int `json:"maxActiveJobs"`
	RetentionDays int `json:"retentionDays"`
}

// WoL configures magic packet sending.
type WoL struct {
	// Enabled is false by default: no packet leaves Core until the owner
	// enables it in the config file.
	Enabled bool `json:"enabled"`
	// Port is the UDP destination port (9 discard or 7 echo by convention).
	Port int `json:"port"`
	// Repeat: packets per attempt (sent 100 ms apart; UDP may drop one).
	Repeat int `json:"repeat"`
}

// DefaultPower returns the M08 defaults.
func DefaultPower() Power {
	return Power{WoL: WoL{Enabled: false, Port: 9, Repeat: 3}, ConfirmTTLSec: 120, PickupTimeoutSec: 60,
		OfflineTimeoutSec: 180, BootTimeoutSec: 300, AgentTimeoutSec: 90, MaxActiveJobs: 8, RetentionDays: 365}
}

// Validate rejects out-of-range values.
func (p Power) Validate() error {
	var errs []error
	in := func(name string, v, lo, hi int) {
		if v < lo || v > hi {
			errs = append(errs, fmt.Errorf("power.%s = %d: want %d…%d", name, v, lo, hi))
		}
	}
	in("wol.port", p.WoL.Port, 1, 65535)
	in("wol.repeat", p.WoL.Repeat, 1, 10)
	in("confirmTtlSec", p.ConfirmTTLSec, 10, 900)
	in("pickupTimeoutSec", p.PickupTimeoutSec, 5, 600)
	in("offlineTimeoutSec", p.OfflineTimeoutSec, 10, 3600)
	in("bootTimeoutSec", p.BootTimeoutSec, 10, 3600)
	in("agentTimeoutSec", p.AgentTimeoutSec, 15, 3600)
	in("maxActiveJobs", p.MaxActiveJobs, 1, 256)
	in("retentionDays", p.RetentionDays, 7, 3650)
	return errors.Join(errs...)
}
