package config

import (
	"errors"
	"fmt"
	"net/url"

	"aerhome/core/internal/foundation/netx"
)

// Monitoring configures the M05 Monitoring module. Every interval, limit and
// retention period is adjustable; defaults target a small 4 GB home server.
type Monitoring struct {
	// Availability checks of Registry entities.
	CheckIntervalSec      int `json:"checkIntervalSec"`
	CheckTimeoutSec       int `json:"checkTimeoutSec"`
	MaxConcurrentChecks   int `json:"maxConcurrentChecks"`
	FailuresBeforeOffline int `json:"failuresBeforeOffline"`
	// An agent is considered silent after this long without a report.
	HeartbeatTimeoutSec int `json:"heartbeatTimeoutSec"`

	// Retention (days; 0 keeps forever where noted).
	RawRetentionDays          int `json:"rawRetentionDays"`
	RollupRetentionDays       int `json:"rollupRetentionDays"`
	LogRetentionDays          int `json:"logRetentionDays"`
	LogMaxRows                int `json:"logMaxRows"`
	ResolvedIncidentDays      int `json:"resolvedIncidentDays"` // 0 = forever
	NotificationRetentionDays int `json:"notificationRetentionDays"`
	RetentionIntervalMin      int `json:"retentionIntervalMin"`
	// Per agent/source log intake limit (entries per minute); the excess is
	// dropped and counted, so one source cannot fill the disk.
	LogRatePerMin int `json:"logRatePerMin"`

	Thresholds MonitoringThresholds `json:"thresholds"`
	Docker     DockerMonitoring     `json:"docker"`
	Telegram   TelegramNotify       `json:"telegram"`
	// NotifyRecovery sends a notification when a device recovers.
	NotifyRecovery bool `json:"notifyRecovery"`
}

// MonitoringThresholds turn metrics into incidents.
type MonitoringThresholds struct {
	DiskFreeWarnPercent     float64 `json:"diskFreeWarnPercent"`
	DiskFreeCriticalPercent float64 `json:"diskFreeCriticalPercent"`
	CPUTempWarnC            float64 `json:"cpuTempWarnC"`
	GPUTempWarnC            float64 `json:"gpuTempWarnC"`
	// Readings must breach for this many consecutive reports (debounce).
	ConsecutiveBreaches int `json:"consecutiveBreaches"`
}

// DockerMonitoring is the read-only Docker Engine integration.
type DockerMonitoring struct {
	Enabled bool `json:"enabled"`
	// Socket is the local Docker Engine socket; never a TCP endpoint.
	Socket           string `json:"socket"`
	IntervalSec      int    `json:"intervalSec"`
	StatsIntervalSec int    `json:"statsIntervalSec"`
}

// TelegramNotify is the optional Telegram channel. Disabled by default; the
// bot token is read from a file, never from config or URLs in logs.
type TelegramNotify struct {
	Enabled      bool   `json:"enabled"`
	BotTokenFile string `json:"botTokenFile"`
	ChatID       string `json:"chatId"`
	// MinSeverity: "warning" or "critical".
	MinSeverity string `json:"minSeverity"`
	// APIBase is overridden only by tests.
	APIBase string `json:"apiBase"`
}

// DefaultMonitoring returns the M05 defaults.
func DefaultMonitoring() Monitoring {
	return Monitoring{
		CheckIntervalSec:          30,
		CheckTimeoutSec:           5,
		MaxConcurrentChecks:       8,
		FailuresBeforeOffline:     2,
		HeartbeatTimeoutSec:       60,
		RawRetentionDays:          7,
		RollupRetentionDays:       30,
		LogRetentionDays:          14,
		LogMaxRows:                200_000,
		ResolvedIncidentDays:      365,
		NotificationRetentionDays: 90,
		RetentionIntervalMin:      60,
		LogRatePerMin:             600,
		Thresholds: MonitoringThresholds{
			DiskFreeWarnPercent:     10,
			DiskFreeCriticalPercent: 5,
			CPUTempWarnC:            90,
			GPUTempWarnC:            90,
			ConsecutiveBreaches:     2,
		},
		Docker: DockerMonitoring{
			Enabled:          true,
			Socket:           netx.DefaultDockerSocket,
			IntervalSec:      30,
			StatsIntervalSec: 60,
		},
		Telegram:       TelegramNotify{MinSeverity: "critical", APIBase: "https://api.telegram.org"},
		NotifyRecovery: true,
	}
}

// Validate rejects out-of-range values instead of silently clamping them.
func (m Monitoring) Validate() error {
	var errs []error
	in := func(name string, v, lo, hi int) {
		if v < lo || v > hi {
			errs = append(errs, fmt.Errorf("monitoring.%s = %d: want %d…%d", name, v, lo, hi))
		}
	}
	in("checkIntervalSec", m.CheckIntervalSec, 5, 3600)
	in("checkTimeoutSec", m.CheckTimeoutSec, 1, 60)
	in("maxConcurrentChecks", m.MaxConcurrentChecks, 1, 64)
	in("failuresBeforeOffline", m.FailuresBeforeOffline, 1, 20)
	in("heartbeatTimeoutSec", m.HeartbeatTimeoutSec, 10, 86400)
	in("rawRetentionDays", m.RawRetentionDays, 1, 365)
	in("rollupRetentionDays", m.RollupRetentionDays, m.RawRetentionDays, 3650)
	in("logRetentionDays", m.LogRetentionDays, 1, 3650)
	in("logMaxRows", m.LogMaxRows, 1000, 50_000_000)
	in("resolvedIncidentDays", m.ResolvedIncidentDays, 0, 36500)
	in("notificationRetentionDays", m.NotificationRetentionDays, 1, 3650)
	in("retentionIntervalMin", m.RetentionIntervalMin, 1, 1440)
	in("logRatePerMin", m.LogRatePerMin, 10, 100_000)
	in("thresholds.consecutiveBreaches", m.Thresholds.ConsecutiveBreaches, 1, 100)
	t := m.Thresholds
	if t.DiskFreeCriticalPercent < 0 || t.DiskFreeCriticalPercent > t.DiskFreeWarnPercent || t.DiskFreeWarnPercent > 100 {
		errs = append(errs, errors.New("monitoring.thresholds: want 0 ≤ diskFreeCriticalPercent ≤ diskFreeWarnPercent ≤ 100"))
	}
	if t.CPUTempWarnC <= 0 || t.GPUTempWarnC <= 0 {
		errs = append(errs, errors.New("monitoring.thresholds: temperatures must be positive"))
	}
	if m.Docker.Enabled {
		if !netx.IsLocalSocket(m.Docker.Socket) {
			errs = append(errs, fmt.Errorf("monitoring.docker.socket %q: want a local unix socket or named pipe (no TCP)", m.Docker.Socket))
		}
		in("docker.intervalSec", m.Docker.IntervalSec, 5, 3600)
		in("docker.statsIntervalSec", m.Docker.StatsIntervalSec, 10, 3600)
	}
	tg := m.Telegram
	if tg.MinSeverity != "warning" && tg.MinSeverity != "critical" {
		errs = append(errs, fmt.Errorf("monitoring.telegram.minSeverity %q: want warning or critical", tg.MinSeverity))
	}
	if u, err := url.Parse(tg.APIBase); err != nil || (u.Scheme != "https" && u.Scheme != "http") {
		errs = append(errs, fmt.Errorf("monitoring.telegram.apiBase %q: want an http(s) URL", tg.APIBase))
	}
	if tg.Enabled && (tg.BotTokenFile == "" || tg.ChatID == "") {
		errs = append(errs, errors.New("monitoring.telegram: enabled needs botTokenFile and chatId"))
	}
	return errors.Join(errs...)
}
