// Package agent is the lightweight AER HOME reporting agent (M05): it
// collects system metrics, service states and warning-level logs on Linux
// and Windows and sends them to Core with a per-agent credential.
//
// The agent never reads user files, browser data or documents; it only
// reads OS counters (/proc, /sys, Win32 APIs), service states and system
// logs at warning level and above. Values it cannot obtain are reported as
// "unsupported"/"unavailable" with a reason — never invented.
package agent

import (
	"encoding/json"
	"time"
)

// Version of the agent build.
const Version = "0.1.0"

// Sample mirrors monitoring.SampleIn (protocol v1).
type Sample struct {
	Metric  string    `json:"metric"`
	Label   string    `json:"label,omitempty"`
	Value   *float64  `json:"value"`
	At      time.Time `json:"at"`
	Quality string    `json:"quality"`
	Reason  string    `json:"reason,omitempty"`
}

// LogLine mirrors monitoring.LogIn.
type LogLine struct {
	At            time.Time       `json:"at"`
	Level         string          `json:"level"`
	Source        string          `json:"source,omitempty"`
	Message       string          `json:"message"`
	CorrelationID string          `json:"correlationId,omitempty"`
	Fields        json.RawMessage `json:"fields,omitempty"`
}

// Info is the heartbeat part of a report.
type Info struct {
	Version    string            `json:"version"`
	OS         string            `json:"os"`
	OSVersion  string            `json:"osVersion"`
	Hostname   string            `json:"hostname"`
	UptimeSec  float64           `json:"uptimeSec"`
	Collectors map[string]string `json:"collectors"`
}

// Report is the payload of POST /api/v1/monitoring/agent/report.
type Report struct {
	Agent   Info      `json:"agent"`
	Samples []Sample  `json:"samples"`
	Logs    []LogLine `json:"logs"`
	Dropped struct {
		Samples int `json:"samples"`
		Logs    int `json:"logs"`
	} `json:"dropped"`
}

func measured(metric, label string, v float64, at time.Time) Sample {
	return Sample{Metric: metric, Label: label, Value: &v, At: at, Quality: "ok"}
}

func unsupported(metric, label, reason string, at time.Time) Sample {
	return Sample{Metric: metric, Label: label, At: at, Quality: "unsupported", Reason: reason}
}

func unavailable(metric, label, reason string, at time.Time) Sample {
	return Sample{Metric: metric, Label: label, At: at, Quality: "unavailable", Reason: reason}
}
