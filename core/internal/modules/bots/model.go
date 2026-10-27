// Package bots is the control center for Telegram bots, Python processes,
// containers, n8n and other automations (M06).
//
// A bot is a Registry entity (no second registry): Bots keeps only its own
// configuration (runtime, adapters, heartbeat settings), job history and the
// audit of management actions in bot_* tables keyed by entity UUID. State,
// metrics, logs and incidents live in Monitoring and are read and written
// only through its service (ADR-012).
package bots

import (
	"time"

	"aerhome/core/internal/modules/monitoring"
)

// BotTypes are the Registry entity types a bot may have.
var BotTypes = []string{"telegram_bot", "process", "service", "automation", "application", "docker_container"}

// Runtimes describe where a bot runs; they pick defaults, never code paths
// tied to one language.
var Runtimes = []string{"python", "docker", "telegram", "n8n", "service", "custom"}

// LogSources say where the bot's logs come from.
var LogSources = []string{"heartbeat", "controller", "docker", "n8n", "none"}

// Config is the Bots-owned part of a bot (table bot_configs).
type Config struct {
	EntityID             string    `json:"entityId"`
	Runtime              string    `json:"runtime"`
	Category             string    `json:"category"`
	ControllerID         string    `json:"controllerId"`
	N8NInstanceID        string    `json:"n8nInstanceId"`
	N8NWorkflowIDs       []string  `json:"n8nWorkflowIds"`
	TelegramTokenID      string    `json:"telegramTokenId"`
	Container            string    `json:"container"`
	HeartbeatIntervalSec int       `json:"heartbeatIntervalSec"`
	HeartbeatTimeoutSec  int       `json:"heartbeatTimeoutSec"`
	LogSource            string    `json:"logSource"`
	Notes                string    `json:"notes"`
	Revision             int       `json:"revision"`
	CreatedAt            time.Time `json:"createdAt"`
	UpdatedAt            time.Time `json:"updatedAt"`
}

// EntityRef is a short reference to another Registry entity.
type EntityRef struct {
	ID       string            `json:"id"`
	Name     string            `json:"name"`
	Type     string            `json:"type"`
	Relation string            `json:"relation,omitempty"`
	Status   monitoring.Status `json:"status,omitempty"`
	Reason   string            `json:"reason,omitempty"`
}

// HeartbeatInfo summarizes the bot's heartbeat credentials and signal.
type HeartbeatInfo struct {
	Credentials int        `json:"credentials"`
	Active      bool       `json:"active"`
	LastSeenAt  *time.Time `json:"lastSeenAt"`
	IntervalSec int        `json:"intervalSec"`
	TimeoutSec  int        `json:"timeoutSec"`
	Library     string     `json:"library"`
}

// RuntimeState is what a management adapter knows about the bot's runtime.
// "running" here means the process/container exists — not that the bot works.
type RuntimeState struct {
	Adapter string     `json:"adapter"`
	State   string     `json:"state"` // running | stopped | starting | unknown | unavailable
	PID     int        `json:"pid,omitempty"`
	Since   *time.Time `json:"since"`
	Reason  string     `json:"reason"`
}

// JobCounts are recent job results.
type JobCounts struct {
	Success24h int `json:"success24h"`
	Failed24h  int `json:"failed24h"`
	Running    int `json:"running"`
}

// Bot is the list/card view: Registry facts + config + live signals.
type Bot struct {
	Config
	Name           string            `json:"name"`
	Type           string            `json:"type"`
	Description    string            `json:"description"`
	Tags           []string          `json:"tags"`
	Archived       bool              `json:"archived"`
	EntityRevision int               `json:"entityRevision"`
	Host           *EntityRef        `json:"host"`
	Status         monitoring.Status `json:"status"`
	StatusReason   string            `json:"statusReason"`
	LastContactAt  *time.Time        `json:"lastContactAt"`
	OpenIncidents  int               `json:"openIncidents"`
	Heartbeat      HeartbeatInfo     `json:"heartbeat"`
	Version        string            `json:"version"`
	StartedAt      *time.Time        `json:"startedAt"`
	UptimeSec      *int64            `json:"uptimeSec"`
	LastError      string            `json:"lastError"`
	LastErrorAt    *time.Time        `json:"lastErrorAt"`
	LastSuccessAt  *time.Time        `json:"lastSuccessAt"`
	APIOK          *bool             `json:"apiOk"`
	CPUPercent     *float64          `json:"cpuPercent"`
	MemBytes       *float64          `json:"memBytes"`
	RuntimeState   *RuntimeState     `json:"runtimeState"`
	LastJobOK      *Job              `json:"lastJobOk"`
	LastJobFailed  *Job              `json:"lastJobFailed"`
	Jobs           JobCounts         `json:"jobs"`
}

// Detail is the full bot page.
type Detail struct {
	Bot
	Dependencies []EntityRef           `json:"dependencies"`
	Crashes      []monitoring.Incident `json:"crashes"`
	Restarts     []monitoring.Event    `json:"restarts"`
	Actions      []ActionInfo          `json:"actions"`
	Integration  *IntegrationInfo      `json:"integration"`
}

// IntegrationInfo is adapter-specific detail (n8n workflows, Telegram check).
type IntegrationInfo struct {
	Kind      string        `json:"kind"`
	Label     string        `json:"label"`
	Status    string        `json:"status"` // ok | unavailable | disabled | unknown
	Reason    string        `json:"reason"`
	CheckedAt *time.Time    `json:"checkedAt"`
	Workflows []N8NWorkflow `json:"workflows,omitempty"`
}

// N8NWorkflow is one workflow of an n8n instance (read only).
type N8NWorkflow struct {
	ID     string `json:"id"`
	Name   string `json:"name"`
	Active bool   `json:"active"`
}

// JobStatus of a bot job.
type JobStatus string

const (
	JobPending   JobStatus = "pending"
	JobRunning   JobStatus = "running"
	JobSuccess   JobStatus = "success"
	JobFailed    JobStatus = "failed"
	JobCancelled JobStatus = "cancelled"
)

var jobStatuses = map[JobStatus]bool{JobPending: true, JobRunning: true, JobSuccess: true, JobFailed: true, JobCancelled: true}

// Job is one unit of bot work (a handled command, a scheduled run, an n8n
// execution). Retryable means the adapter can run it again, after confirmation.
type Job struct {
	ID         string     `json:"id"`
	EntityID   string     `json:"entityId"`
	ExternalID string     `json:"externalId"`
	Name       string     `json:"name"`
	Status     JobStatus  `json:"status"`
	Source     string     `json:"source"` // heartbeat | n8n
	StartedAt  *time.Time `json:"startedAt"`
	FinishedAt *time.Time `json:"finishedAt"`
	DurationMs *int64     `json:"durationMs"`
	Result     string     `json:"result"`
	Error      string     `json:"error"`
	Retryable  bool       `json:"retryable"`
	RetryOf    string     `json:"retryOf"`
}

// ActionInfo says whether an action can be requested now and why not.
type ActionInfo struct {
	ID        string `json:"id"` // start | stop | restart | check | job.retry
	Label     string `json:"label"`
	Available bool   `json:"available"`
	Reason    string `json:"reason"`
	Confirm   bool   `json:"confirm"`
	Risk      string `json:"risk"`
}

// Confirmation is a single-use permission for one action on one bot.
type Confirmation struct {
	Token     string    `json:"token"`
	EntityID  string    `json:"entityId"`
	Action    string    `json:"action"`
	JobID     string    `json:"jobId,omitempty"`
	Summary   string    `json:"summary"`
	Risks     []string  `json:"risks"`
	ExpiresAt time.Time `json:"expiresAt"`
}

// ActionRecord is the audit entry of one requested action.
type ActionRecord struct {
	ID             string     `json:"id"`
	EntityID       string     `json:"entityId"`
	Action         string     `json:"action"`
	JobID          string     `json:"jobId"`
	Adapter        string     `json:"adapter"`
	Status         string     `json:"status"` // running | succeeded | failed | rejected
	Message        string     `json:"message"`
	IdempotencyKey string     `json:"idempotencyKey"`
	RequestedAt    time.Time  `json:"requestedAt"`
	FinishedAt     *time.Time `json:"finishedAt"`
	// Replayed: the same Idempotency-Key was seen before; nothing ran again.
	Replayed bool `json:"replayed"`
}

// AdapterInfo describes one registered adapter kind.
type AdapterInfo struct {
	ID           string            `json:"id"`
	Label        string            `json:"label"`
	Description  string            `json:"description"`
	Capabilities []string          `json:"capabilities"` // monitor, logs, control, jobs, retry, check
	Status       string            `json:"status"`       // ok | unavailable | disabled
	Reason       string            `json:"reason"`
	Instances    []AdapterInstance `json:"instances"`
}

// AdapterInstance is one configured target (controller, n8n server, token).
// Paths and secrets are never exposed, only what the owner needs to choose.
type AdapterInstance struct {
	ID     string   `json:"id"`
	Label  string   `json:"label"`
	Target string   `json:"target"`
	Allow  []string `json:"allow,omitempty"`
	UsedBy string   `json:"usedBy,omitempty"`
}
