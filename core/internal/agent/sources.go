package agent

import "time"

// Disabled lists collectors switched off in cfg (reported in the heartbeat).
func Disabled(c Collectors) []string {
	var out []string
	for name, on := range map[string]bool{"cpu": c.CPU, "memory": c.Memory, "disk": c.Disk, "network": c.Network,
		"temperature": c.Temperature, "gpu": c.GPU, "processes": c.Processes, "systemLogs": c.SystemLogs} {
		if !on {
			out = append(out, name)
		}
	}
	return out
}

// SystemLogSource is journald on Linux and the Event Log on Windows.
func SystemLogSource(every time.Duration) Source { return newSystemLogSource(every) }
