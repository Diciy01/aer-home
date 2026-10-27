// Package monitoring observes AER HOME infrastructure: agent metrics and
// heartbeats, availability checks of Registry entities, Docker, bots,
// centralized logs, incidents and notifications (M05).
//
// Registry stays the source of truth about objects; Monitoring keeps state,
// metrics and history in its own mon_* tables keyed by entity UUID and reads
// Registry only through registry.Reader.
package monitoring

import (
	"encoding/json"
	"time"
)

// Status is the normalized availability of an entity.
type Status string

const (
	StatusOnline      Status = "online"
	StatusDegraded    Status = "degraded"
	StatusOffline     Status = "offline"
	StatusUnknown     Status = "unknown"
	StatusUnsupported Status = "unsupported"
)

// Quality says whether a metric value is a real measurement.
type Quality string

const (
	QualityOK          Quality = "ok"
	QualityUnsupported Quality = "unsupported" // the platform cannot provide it
	QualityUnavailable Quality = "unavailable" // could not be read this time
)

// Severity of incidents, events and notifications.
type Severity string

const (
	SeverityInfo     Severity = "info"
	SeverityWarning  Severity = "warning"
	SeverityCritical Severity = "critical"
)

var severityRank = map[Severity]int{SeverityInfo: 1, SeverityWarning: 2, SeverityCritical: 3}

// LogLevel of centralized log entries (stored as numbers for range filters).
type LogLevel string

const (
	LevelDebug    LogLevel = "debug"
	LevelInfo     LogLevel = "info"
	LevelWarning  LogLevel = "warning"
	LevelError    LogLevel = "error"
	LevelCritical LogLevel = "critical"
)

var levelNum = map[LogLevel]int{LevelDebug: 10, LevelInfo: 20, LevelWarning: 30, LevelError: 40, LevelCritical: 50}

func levelName(n int) LogLevel {
	for k, v := range levelNum {
		if v == n {
			return k
		}
	}
	return LevelInfo
}

// MetricType describes one metric of the catalog.
type MetricType struct {
	ID          string `json:"id"`
	Label       string `json:"label"`
	Unit        string `json:"unit"`
	Description string `json:"description"`
	// LabelKey names the series label (mount point, interface, unit…), if any.
	LabelKey string `json:"labelKey"`
	// Key metrics are shown on device cards.
	Key bool `json:"key"`
}

// MetricTypes is the catalog of accepted metrics. Agents may not invent
// names; unknown metrics are rejected so arbitrary data is never collected.
var MetricTypes = []MetricType{
	{ID: "cpu.usage", Label: "Загрузка CPU", Unit: "%", Description: "Доля занятого процессорного времени", Key: true},
	{ID: "mem.used_percent", Label: "Память", Unit: "%", Description: "Занятая оперативная память", Key: true},
	{ID: "mem.used_bytes", Label: "Память занято", Unit: "B", Description: "Занятая оперативная память"},
	{ID: "mem.total_bytes", Label: "Память всего", Unit: "B", Description: "Объём оперативной памяти"},
	{ID: "swap.used_percent", Label: "Swap / файл подкачки", Unit: "%", Description: "Занятый swap"},
	{ID: "disk.used_percent", Label: "Заполнение диска", Unit: "%", Description: "Заполнение файловой системы", LabelKey: "mount", Key: true},
	{ID: "disk.free_bytes", Label: "Свободно на диске", Unit: "B", Description: "Свободное место", LabelKey: "mount"},
	{ID: "net.rx_rate", Label: "Сеть: приём", Unit: "B/s", Description: "Входящий трафик", LabelKey: "iface"},
	{ID: "net.tx_rate", Label: "Сеть: передача", Unit: "B/s", Description: "Исходящий трафик", LabelKey: "iface"},
	{ID: "net.errors_rate", Label: "Сеть: ошибки", Unit: "1/s", Description: "Ошибки и отброшенные пакеты", LabelKey: "iface"},
	{ID: "cpu.temperature", Label: "Температура CPU", Unit: "°C", Description: "Датчик процессора", Key: true},
	{ID: "gpu.usage", Label: "Загрузка GPU", Unit: "%", Description: "Если драйвер предоставляет"},
	{ID: "gpu.temperature", Label: "Температура GPU", Unit: "°C", Description: "Если драйвер предоставляет", Key: true},
	{ID: "system.uptime", Label: "Время работы", Unit: "s", Description: "С момента загрузки ОС"},
	{ID: "process.count", Label: "Процессов", Unit: "", Description: "Число процессов в системе"},
	{ID: "service.active", Label: "Служба активна", Unit: "bool", Description: "1 — служба работает, 0 — нет", LabelKey: "unit"},
	{ID: "process.cpu_percent", Label: "CPU процесса", Unit: "%", Description: "Нагрузка процесса (бот, агент)"},
	{ID: "process.rss_bytes", Label: "Память процесса", Unit: "B", Description: "Резидентная память процесса"},
	{ID: "bot.api_ok", Label: "API Telegram доступен", Unit: "bool", Description: "1 — последняя проверка зависимости успешна"},
	{ID: "agent.dropped", Label: "Потеряно агентом", Unit: "", Description: "Записей отброшено из-за переполнения очереди"},
	{ID: "docker.cpu_percent", Label: "CPU контейнера", Unit: "%", Description: "Docker stats"},
	{ID: "docker.mem_bytes", Label: "Память контейнера", Unit: "B", Description: "Docker stats"},
	{ID: "docker.net_rx_rate", Label: "Контейнер: приём", Unit: "B/s", Description: "Docker stats"},
	{ID: "docker.net_tx_rate", Label: "Контейнер: передача", Unit: "B/s", Description: "Docker stats"},
}

var metricByID = func() map[string]MetricType {
	m := map[string]MetricType{}
	for _, t := range MetricTypes {
		m[t.ID] = t
	}
	return m
}()

// MetricValue is one measurement (or an explained absence of it).
type MetricValue struct {
	Metric  string    `json:"metric"`
	Label   string    `json:"label"`
	Value   *float64  `json:"value"`
	Unit    string    `json:"unit"`
	At      time.Time `json:"at"`
	Source  string    `json:"source"`
	Quality Quality   `json:"quality"`
	Reason  string    `json:"reason"`
}

// AgentInfo is what an agent says about itself in each report.
type AgentInfo struct {
	Version    string            `json:"version"`
	OS         string            `json:"os"`
	OSVersion  string            `json:"osVersion"`
	Hostname   string            `json:"hostname"`
	UptimeSec  float64           `json:"uptimeSec"`
	Collectors map[string]string `json:"collectors"`
}

// BotStatus is the optional heartbeat payload of a bot (real signals the
// bot reports about itself, not just "process exists").
type BotStatus struct {
	LastSuccessAt *time.Time `json:"lastSuccessAt"`
	LastError     string     `json:"lastError"`
	LastErrorAt   *time.Time `json:"lastErrorAt"`
	LastRestartAt *time.Time `json:"lastRestartAt"`
	StartedAt     *time.Time `json:"startedAt"`
	APIOK         *bool      `json:"apiOk"`
	// Version is the bot's own version (not the heartbeat library's).
	Version string `json:"version,omitempty"`
}

// Agent is a registered reporting identity (OS agent or bot heartbeat).
type Agent struct {
	ID         string     `json:"id"`
	EntityID   string     `json:"entityId"`
	Name       string     `json:"name"`
	Kind       string     `json:"kind"` // host | bot
	CreatedAt  time.Time  `json:"createdAt"`
	RevokedAt  *time.Time `json:"revokedAt"`
	LastSeenAt *time.Time `json:"lastSeenAt"`
	Info       *AgentInfo `json:"info"`
	Bot        *BotStatus `json:"bot"`
	// Active: reported within the heartbeat timeout.
	Active bool `json:"active"`
}

// DeviceState is the current state of one Registry entity.
type DeviceState struct {
	EntityID      string        `json:"entityId"`
	Name          string        `json:"name"`
	Type          string        `json:"type"`
	Status        Status        `json:"status"`
	Reason        string        `json:"reason"`
	CheckKind     string        `json:"checkKind"`
	LastContactAt *time.Time    `json:"lastContactAt"`
	LastCheckAt   *time.Time    `json:"lastCheckAt"`
	ChangedAt     *time.Time    `json:"changedAt"`
	KeyMetrics    []MetricValue `json:"keyMetrics"`
	OpenIncidents int           `json:"openIncidents"`
	WorstSeverity *Severity     `json:"worstSeverity"`
	Agents        []Agent       `json:"agents"`
}

// Point is one chart point; Value is null where no data exists (a gap,
// never a zero).
type Point struct {
	T     time.Time `json:"t"`
	Value *float64  `json:"value"`
	Min   *float64  `json:"min"`
	Max   *float64  `json:"max"`
}

// Series is a metric history.
type Series struct {
	EntityID   string    `json:"entityId"`
	Metric     string    `json:"metric"`
	Label      string    `json:"label"`
	Unit       string    `json:"unit"`
	From       time.Time `json:"from"`
	To         time.Time `json:"to"`
	Resolution string    `json:"resolution"` // raw | 5m
	StepSec    int       `json:"stepSec"`
	Points     []Point   `json:"points"`
}

// LogEntry is one centralized log record.
type LogEntry struct {
	ID            int64           `json:"id"`
	At            time.Time       `json:"at"`
	EntityID      *string         `json:"entityId"`
	Source        string          `json:"source"`
	Level         LogLevel        `json:"level"`
	Message       string          `json:"message"`
	CorrelationID string          `json:"correlationId"`
	Fields        json.RawMessage `json:"fields"`
	IncidentID    *string         `json:"incidentId"`
}

// IncidentStatus lifecycle.
type IncidentStatus string

const (
	IncidentOpen         IncidentStatus = "open"
	IncidentAcknowledged IncidentStatus = "acknowledged"
	IncidentResolved     IncidentStatus = "resolved"
)

// Incident groups repeated observations of one problem.
type Incident struct {
	ID             string         `json:"id"`
	Key            string         `json:"key"`
	Title          string         `json:"title"`
	Source         string         `json:"source"`
	EntityID       *string        `json:"entityId"`
	Severity       Severity       `json:"severity"`
	Status         IncidentStatus `json:"status"`
	OpenedAt       time.Time      `json:"openedAt"`
	UpdatedAt      time.Time      `json:"updatedAt"`
	AcknowledgedAt *time.Time     `json:"acknowledgedAt"`
	ResolvedAt     *time.Time     `json:"resolvedAt"`
	// Cause is set only from direct evidence (exit code, HTTP status…).
	Cause string `json:"cause"`
	// Related lists correlated incidents; correlation is not a cause.
	Related     []string        `json:"related"`
	Occurrences int             `json:"occurrences"`
	LastMessage string          `json:"lastMessage"`
	Timeline    []IncidentEvent `json:"timeline,omitempty"`
}

// IncidentEvent is one change in an incident's history.
type IncidentEvent struct {
	At      time.Time `json:"at"`
	Kind    string    `json:"kind"` // opened | repeated | acknowledged | resolved | note
	Message string    `json:"message"`
}

// Event is one entry of the event history (state changes, integration events).
type Event struct {
	ID         int64     `json:"id"`
	At         time.Time `json:"at"`
	EntityID   *string   `json:"entityId"`
	Kind       string    `json:"kind"`
	Severity   Severity  `json:"severity"`
	Message    string    `json:"message"`
	IncidentID *string   `json:"incidentId"`
}

// Notification is an entry of the in-app notification center.
type Notification struct {
	ID         string     `json:"id"`
	At         time.Time  `json:"at"`
	Kind       string     `json:"kind"`
	Severity   Severity   `json:"severity"`
	Title      string     `json:"title"`
	Body       string     `json:"body"`
	EntityID   *string    `json:"entityId"`
	IncidentID *string    `json:"incidentId"`
	ReadAt     *time.Time `json:"readAt"`
	// Telegram: disabled | pending | sent | skipped | failed
	Telegram string `json:"telegram"`
}

// IntegrationStatus explains whether an integration works and why not.
type IntegrationStatus struct {
	ID        string     `json:"id"`
	Label     string     `json:"label"`
	Status    string     `json:"status"` // ok | unavailable | disabled
	Reason    string     `json:"reason"`
	CheckedAt *time.Time `json:"checkedAt"`
}

// Container is the last known state of a Docker container.
type Container struct {
	ID           string     `json:"id"`
	Name         string     `json:"name"`
	Image        string     `json:"image"`
	State        string     `json:"state"`
	Health       string     `json:"health"`
	StartedAt    *time.Time `json:"startedAt"`
	FinishedAt   *time.Time `json:"finishedAt"`
	ExitCode     *int       `json:"exitCode"`
	OOMKilled    bool       `json:"oomKilled"`
	Error        string     `json:"error"`
	RestartCount int        `json:"restartCount"`
	ChangedAt    time.Time  `json:"changedAt"`
	EntityID     *string    `json:"entityId"`
	CPUPercent   *float64   `json:"cpuPercent"`
	MemBytes     *float64   `json:"memBytes"`
	LastErrors   []string   `json:"lastErrors"`
}

// Overview is the dashboard summary.
type Overview struct {
	GeneratedAt   time.Time           `json:"generatedAt"`
	Devices       int                 `json:"devices"`
	ByStatus      map[Status]int      `json:"byStatus"`
	OpenIncidents int                 `json:"openIncidents"`
	CriticalOpen  int                 `json:"criticalOpen"`
	UnreadNotices int                 `json:"unreadNotifications"`
	Integrations  []IntegrationStatus `json:"integrations"`
	RecentEvents  []Event             `json:"recentEvents"`
}
