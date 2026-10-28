// Package power is the control plane of AER Power (M08, ADR-014).
//
// Power devices are Registry entities. Core sends Wake-on-LAN itself (it
// must run on an always-on machine for that to help); shutdown, reboot,
// suspend and one-time OS switch are executed by a host agent
// (aer-power-host, Monitoring agent kind "power") through fixed adapters.
// Clients choose an action from a closed list; no command text ever travels
// from a client to a host. Monitoring only observes: Power reads its
// states, never the other way round.
package power

import "time"

// Actions a client may request.
const (
	ActionWake     = "wake"
	ActionShutdown = "shutdown"
	ActionReboot   = "reboot"
	ActionSuspend  = "suspend"
	ActionSwitchOS = "switch_os"
	ActionCheck    = "check"
)

// AllActions in display order.
var AllActions = []string{ActionWake, ActionShutdown, ActionReboot, ActionSuspend, ActionSwitchOS, ActionCheck}

// JobState of a power job.
type JobState string

const (
	// JobQueued: accepted by Core, waiting for the agent to take it.
	JobQueued JobState = "queued"
	// JobSent: the packet was sent / the agent took the command.
	JobSent JobState = "sent"
	// JobWaiting: executed; Core waits for the device to change state.
	JobWaiting   JobState = "waiting"
	JobSucceeded JobState = "succeeded"
	JobFailed    JobState = "failed"
	// JobTimeout: the expected state never came; the real outcome is unknown.
	JobTimeout   JobState = "timeout"
	JobCancelled JobState = "cancelled"
	// JobSimulated: the agent runs in check mode and executed nothing.
	JobSimulated JobState = "simulated"
)

// Terminal states never change again.
func (s JobState) Terminal() bool {
	switch s {
	case JobSucceeded, JobFailed, JobTimeout, JobCancelled, JobSimulated:
		return true
	}
	return false
}

// WoLTarget is how Core reaches a device's network card when it is off.
type WoLTarget struct {
	MAC string `json:"mac"`
	// Broadcast is the IPv4 destination: the LAN broadcast (x.y.z.255),
	// 255.255.255.255 or a unicast address. Only private, link-local and
	// loopback ranges are accepted.
	Broadcast string `json:"broadcast"`
	// Interface (optional) binds the sending socket to one local NIC.
	Interface string `json:"interface"`
	// Port overrides power.wol.port when non-zero.
	Port int `json:"port"`
}

// Policy is the owner's restriction for a device (intersected with what
// Registry declares and what the agent reports).
type Policy struct {
	Enabled  bool `json:"enabled"`
	Wake     bool `json:"wake"`
	Shutdown bool `json:"shutdown"`
	Reboot   bool `json:"reboot"`
	Suspend  bool `json:"suspend"`
	SwitchOS bool `json:"switchOs"`
	// AllowWithBitLocker: OS switch is refused while BitLocker is on unless
	// the owner confirmed the recovery key is at hand.
	AllowWithBitLocker bool `json:"allowWithBitLocker"`
	Revision           int  `json:"revision"`
}

// DefaultPolicy: power actions on, OS switch off until the owner enables it.
func DefaultPolicy() Policy {
	return Policy{Enabled: true, Wake: true, Shutdown: true, Reboot: true, Suspend: true}
}

// BootEntry is one firmware/boot manager entry reported by the agent.
type BootEntry struct {
	// ID is the adapter's identifier (UEFI Boot#### as 4 hex digits, or a
	// Windows firmware GUID). Core only echoes it back; the agent re-checks.
	ID    string `json:"id"`
	Label string `json:"label"`
	// OS: linux | windows | bootmanager | other.
	OS      string `json:"os"`
	Current bool   `json:"current"`
}

// Capability is one thing the agent can do on this OS, or why not.
type Capability struct {
	Supported bool   `json:"supported"`
	Reason    string `json:"reason"`
}

// HostInfo is what a power agent reports in hello (no secrets).
type HostInfo struct {
	OS        string `json:"os"` // linux | windows
	OSVersion string `json:"osVersion"`
	Hostname  string `json:"hostname"`
	Version   string `json:"version"`
	// BootID changes on every boot (Linux boot_id, Windows boot time).
	BootID string `json:"bootId"`
	// DryRun: the agent only reports what it would run (default).
	DryRun bool `json:"dryRun"`
	// Firmware: uefi | bios | unknown.
	Firmware   string `json:"firmware"`
	SecureBoot string `json:"secureBoot"` // enabled | disabled | unknown
	BitLocker  string `json:"bitlocker"`  // off | on | unknown | n/a
	// BootManager: what the firmware starts first (uefi, refind, grub, windows).
	BootManager string      `json:"bootManager"`
	BootEntries []BootEntry `json:"bootEntries"`
	MACs        []string    `json:"macs"`
	// Actions: shutdown, reboot, suspend, bootNext → supported or why not.
	Actions map[string]Capability `json:"actions"`
}

// AgentView is a power agent of a device as Core sees it.
type AgentView struct {
	AgentID   string    `json:"agentId"`
	Name      string    `json:"name"`
	Active    bool      `json:"active"`
	LastHello time.Time `json:"lastHelloAt"`
	Info      HostInfo  `json:"info"`
}

// ActionInfo says whether an action can be requested now, and why not.
type ActionInfo struct {
	ID        string `json:"id"`
	Label     string `json:"label"`
	Available bool   `json:"available"`
	Reason    string `json:"reason"`
	Dangerous bool   `json:"dangerous"`
	// Targets: OS switch choices (linux / windows) with availability.
	Targets []Target `json:"targets,omitempty"`
}

// Target is one OS a device can be switched to.
type Target struct {
	OS        string `json:"os"`
	Label     string `json:"label"`
	EntryID   string `json:"entryId"`
	Available bool   `json:"available"`
	Reason    string `json:"reason"`
}

// Device is the list/detail view of a power-manageable computer.
type Device struct {
	EntityID string   `json:"entityId"`
	Name     string   `json:"name"`
	Type     string   `json:"type"`
	Declared []string `json:"declaredCapabilities"`
	// State: online | offline | waking | shutting_down | rebooting |
	// switching | suspending | unknown.
	State       string     `json:"state"`
	StateReason string     `json:"stateReason"`
	CurrentOS   string     `json:"currentOs"`
	LastContact *time.Time `json:"lastContactAt"`
	// MonitoringStatus is Monitoring's view (observation only).
	MonitoringStatus string       `json:"monitoringStatus"`
	WoL              *WoLTarget   `json:"wol"`
	SameMachine      bool         `json:"sameMachineAsCore"`
	SameMachineNote  string       `json:"sameMachineNote"`
	Agents           []AgentView  `json:"agents"`
	Policy           Policy       `json:"policy"`
	Actions          []ActionInfo `json:"actions"`
	ActiveJob        *Job         `json:"activeJob"`
	LastJob          *Job         `json:"lastJob"`
}

// Confirmation is the plan shown to the owner before a state change.
type Confirmation struct {
	Token     string    `json:"token"`
	EntityID  string    `json:"entityId"`
	Action    string    `json:"action"`
	TargetOS  string    `json:"targetOs"`
	Summary   string    `json:"summary"`
	Risks     []string  `json:"risks"`
	Checks    []Check   `json:"checks"`
	ExpiresAt time.Time `json:"expiresAt"`
}

// Check is one precondition evaluated for the plan.
type Check struct {
	Name    string `json:"name"`
	OK      bool   `json:"ok"`
	Message string `json:"message"`
}

// ActionRequest is the body of POST /power/devices/{id}/actions/{action}.
type ActionRequest struct {
	ConfirmationToken string `json:"confirmationToken"`
	TargetOS          string `json:"targetOs"`
}

// Job is one power operation and its audit trail.
type Job struct {
	ID             string     `json:"id"`
	EntityID       string     `json:"entityId"`
	DeviceName     string     `json:"deviceName"`
	Action         string     `json:"action"`
	TargetOS       string     `json:"targetOs"`
	BootEntryID    string     `json:"bootEntryId"`
	State          JobState   `json:"state"`
	Message        string     `json:"message"`
	IdempotencyKey string     `json:"-"`
	Replayed       bool       `json:"replayed"`
	Simulated      bool       `json:"simulated"`
	FromOS         string     `json:"fromOs"`
	RequestedAt    time.Time  `json:"requestedAt"`
	SentAt         *time.Time `json:"sentAt"`
	FinishedAt     *time.Time `json:"finishedAt"`
	Deadline       time.Time  `json:"deadline"`
	Events         []Event    `json:"events,omitempty"`
}

// Event is one audit entry of a job.
type Event struct {
	At      time.Time `json:"at"`
	Kind    string    `json:"kind"`
	Message string    `json:"message"`
}

// Command is what Core asks a power agent to do. It names an action from
// the closed list and, for an OS switch, a boot entry the agent itself
// reported; the agent validates both against its own fresh inventory.
type Command struct {
	ID        string    `json:"id"`
	JobID     string    `json:"jobId"`
	Action    string    `json:"action"` // shutdown | reboot | suspend | switch_os | inventory
	EntryID   string    `json:"entryId,omitempty"`
	TargetOS  string    `json:"targetOs,omitempty"`
	ExpiresAt time.Time `json:"expiresAt"`
}

// AgentEvent is the agent's report on a command.
type AgentEvent struct {
	// Kind: accepted | executing | simulated | failed.
	Kind    string `json:"kind"`
	Message string `json:"message"`
}
