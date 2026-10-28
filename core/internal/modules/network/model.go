// Package network is AER Network + TV (M09, ADR-015): one view of the home
// network and TV streaming. It runs only its own integration checks — the
// internet link (explicit TCP targets), read-only router adapters (UPnP IGD
// when configured) and Sunshine (GameStream serverinfo) — and keeps only
// their current status. Device reachability and latency come from
// Monitoring; history, logs and incidents are written through Monitoring
// hooks. Nothing on the network is changed and nothing is scanned.
package network

import (
	"time"

	"aerhome/core/internal/modules/monitoring"
)

// Status of a check or a device as the network view shows it.
type Status string

const (
	StatusUp           Status = "up"           // Доступен
	StatusDown         Status = "down"         // Недоступен
	StatusError        Status = "error"        // Ошибка проверки
	StatusUnconfigured Status = "unconfigured" // Не настроен
	StatusUnknown      Status = "unknown"      // Ещё не проверялось / нет данных
)

// Check is the current result of one integration check.
type Check struct {
	Key       string     `json:"key"`  // internet | router:<entity> | sunshine:<id>
	Kind      string     `json:"kind"` // internet | router_wan | sunshine
	Name      string     `json:"name"`
	EntityID  string     `json:"entityId"`
	Status    Status     `json:"status"`
	Reason    string     `json:"reason"`
	LatencyMs *float64   `json:"latencyMs"`
	LastCheck *time.Time `json:"lastCheckAt"`
	LastOK    *time.Time `json:"lastOkAt"`
	ChangedAt *time.Time `json:"changedAt"`
	Failures  int        `json:"failures"`
	// Stale: the last check is older than three intervals (Core loop stuck).
	Stale   bool     `json:"stale"`
	Details *Details `json:"details"`
}

// Details are kind-specific facts; only what the interface really reports.
type Details struct {
	Targets []TargetResult `json:"targets,omitempty"`
	// Router WAN (UPnP IGD).
	Connection   string   `json:"connection,omitempty"`
	PhysicalLink string   `json:"physicalLink,omitempty"`
	UptimeSec    *int64   `json:"uptimeSec,omitempty"`
	DownMbps     *float64 `json:"downMbps,omitempty"`
	UpMbps       *float64 `json:"upMbps,omitempty"`
	// Sunshine (serverinfo: state, appversion, currentgame — nothing else is read).
	Streaming    *bool  `json:"streaming,omitempty"`
	Version      string `json:"version,omitempty"`
	CurrentApp   *int   `json:"currentApp,omitempty"`
	WebReachable *bool  `json:"webReachable,omitempty"`
}

// TargetResult is one internet probe target.
type TargetResult struct {
	Target    string   `json:"target"`
	OK        bool     `json:"ok"`
	LatencyMs *float64 `json:"latencyMs"`
	Error     string   `json:"error"`
}

// DeviceView is a Registry device with Monitoring's observation.
type DeviceView struct {
	EntityID         string     `json:"entityId"`
	Name             string     `json:"name"`
	Type             string     `json:"type"`
	Address          string     `json:"address"`
	Status           Status     `json:"status"`
	Reason           string     `json:"reason"`
	MonitoringStatus string     `json:"monitoringStatus"`
	LatencyMs        *float64   `json:"latencyMs"`
	LatencyAt        *time.Time `json:"latencyAt"`
	LastContact      *time.Time `json:"lastContactAt"`
	LastCheck        *time.Time `json:"lastCheckAt"`
	ChangedAt        *time.Time `json:"changedAt"`
	Stale            bool       `json:"stale"`
	OpenIncidents    int        `json:"openIncidents"`
}

// RouterView: a router device and its optional read-only adapter.
type RouterView struct {
	Device DeviceView `json:"device"`
	// Adapter: upnp | none.
	Adapter     string `json:"adapter"`
	AdapterNote string `json:"adapterNote"`
	WAN         *Check `json:"wan"`
}

// SunshineView: a Sunshine server, its host object and its TV (separately).
type SunshineView struct {
	ID     string      `json:"id"`
	Name   string      `json:"name"`
	WebURL string      `json:"webUrl"`
	Check  Check       `json:"check"`
	Entity *DeviceView `json:"entity"`
	TV     *DeviceView `json:"tv"`
}

// Summary is the one-line state of the home network.
type Summary struct {
	// Level: ok | warning | critical | unconfigured.
	Level  string   `json:"level"`
	Title  string   `json:"title"`
	Issues []string `json:"issues"`
}

// Overview is GET /network/overview.
type Overview struct {
	Summary     Summary               `json:"summary"`
	Internet    Check                 `json:"internet"`
	Routers     []RouterView          `json:"routers"`
	Devices     []DeviceView          `json:"devices"`
	TVs         []DeviceView          `json:"tvs"`
	Sunshine    []SunshineView        `json:"sunshine"`
	Incidents   []monitoring.Incident `json:"incidents"`
	Recent      []monitoring.LogEntry `json:"recent"`
	IntervalSec int                   `json:"intervalSec"`
	GeneratedAt time.Time             `json:"generatedAt"`
}
