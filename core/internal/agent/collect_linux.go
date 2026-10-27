//go:build linux

package agent

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"
)

// Root lets tests point the collectors at a fake /proc and /sys tree.
var Root = "/"

func read(p string) (string, error) {
	b, err := os.ReadFile(filepath.Join(Root, p))
	return string(b), err
}

// PlatformSources returns the Linux collectors enabled in cfg.
func PlatformSources(cfg Collectors) []Source {
	var out []Source
	if cfg.CPU {
		out = append(out, &cpuSource{})
	}
	if cfg.Memory {
		out = append(out, memSource{})
	}
	if cfg.Disk {
		out = append(out, diskSource{})
	}
	if cfg.Network {
		out = append(out, &netSource{prev: map[string]NetCounters{}})
	}
	if cfg.Temperature {
		out = append(out, tempSource{})
	}
	if cfg.GPU {
		out = append(out, gpuSource{})
	}
	if cfg.Processes {
		out = append(out, procSource{})
	}
	if len(cfg.Services) > 0 {
		out = append(out, serviceSource{units: cfg.Services})
	}
	return out
}

// PlatformInfo describes this host for the heartbeat.
func PlatformInfo(collectors map[string]string) func() Info {
	osr, _ := read("etc/os-release")
	pretty := ParseOSRelease(osr)
	host, _ := os.Hostname()
	return func() Info {
		up := 0.0
		if s, err := read("proc/uptime"); err == nil {
			if f := strings.Fields(s); len(f) > 0 {
				up, _ = strconv.ParseFloat(f[0], 64)
			}
		}
		return Info{Version: Version, OS: "linux", OSVersion: pretty, Hostname: host, UptimeSec: up, Collectors: collectors}
	}
}

type cpuSource struct {
	prev  CPUTimes
	valid bool
}

func (*cpuSource) Name() string { return "cpu" }
func (c *cpuSource) Collect(now time.Time) ([]Sample, []LogLine) {
	s, err := read("proc/stat")
	if err != nil {
		return []Sample{unavailable("cpu.usage", "", "Нет доступа к /proc/stat", now)}, nil
	}
	cur, err := ParseProcStat(s)
	if err != nil {
		return []Sample{unavailable("cpu.usage", "", "Не удалось разобрать /proc/stat", now)}, nil
	}
	prev, valid := c.prev, c.valid
	c.prev, c.valid = cur, true
	if !valid {
		return nil, nil // the first reading only primes the delta
	}
	if p, ok := CPUPercent(prev, cur); ok {
		return []Sample{measured("cpu.usage", "", round1(p), now)}, nil
	}
	return nil, nil
}

type memSource struct{}

func (memSource) Name() string { return "memory" }
func (memSource) Collect(now time.Time) ([]Sample, []LogLine) {
	s, err := read("proc/meminfo")
	if err != nil {
		return []Sample{unavailable("mem.used_percent", "", "Нет доступа к /proc/meminfo", now)}, nil
	}
	m := ParseMeminfo(s)
	total, avail := m["MemTotal"], m["MemAvailable"]
	var out []Sample
	if total > 0 {
		used := total - avail
		out = append(out, measured("mem.used_percent", "", round1(100*used/total), now), measured("mem.used_bytes", "", used, now), measured("mem.total_bytes", "", total, now))
	}
	if st := m["SwapTotal"]; st > 0 {
		out = append(out, measured("swap.used_percent", "", round1(100*(st-m["SwapFree"])/st), now))
	} else {
		out = append(out, unsupported("swap.used_percent", "", "Swap не настроен", now))
	}
	return out, nil
}

type diskSource struct{}

func (diskSource) Name() string { return "disk" }
func (diskSource) Collect(now time.Time) ([]Sample, []LogLine) {
	s, err := read("proc/self/mounts")
	if err != nil {
		return []Sample{unavailable("disk.used_percent", "", "Нет доступа к списку разделов", now)}, nil
	}
	var out []Sample
	for _, mp := range ParseMounts(s) {
		var st syscall.Statfs_t
		if err := syscall.Statfs(filepath.Join(Root, mp), &st); err != nil {
			out = append(out, unavailable("disk.used_percent", mp, "statfs: "+err.Error(), now))
			continue
		}
		total := float64(st.Blocks) * float64(st.Bsize)
		free := float64(st.Bavail) * float64(st.Bsize)
		if total <= 0 {
			continue
		}
		used := total - float64(st.Bfree)*float64(st.Bsize)
		out = append(out, measured("disk.used_percent", mp, round1(100*used/(used+free)), now), measured("disk.free_bytes", mp, free, now))
	}
	return out, nil
}

type netSource struct {
	prev   map[string]NetCounters
	prevAt time.Time
}

func (*netSource) Name() string { return "network" }
func (n *netSource) Collect(now time.Time) ([]Sample, []LogLine) {
	s, err := read("proc/net/dev")
	if err != nil {
		return []Sample{unavailable("net.rx_rate", "", "Нет доступа к /proc/net/dev", now)}, nil
	}
	cur := ParseNetDev(s)
	var out []Sample
	if !n.prevAt.IsZero() {
		sec := now.Sub(n.prevAt).Seconds()
		for name, c := range cur {
			p, ok2 := n.prev[name]
			if !ok2 || sec <= 0 || c.RX < p.RX || c.TX < p.TX {
				continue // counter reset or new interface
			}
			out = append(out, measured("net.rx_rate", name, round1((c.RX-p.RX)/sec), now), measured("net.tx_rate", name, round1((c.TX-p.TX)/sec), now),
				measured("net.errors_rate", name, round1(max(0, c.Errors-p.Errors)/sec), now))
		}
	}
	n.prev, n.prevAt = cur, now
	return out, nil
}

// hwmonTemps returns temperatures (°C) by hwmon driver name and label.
func hwmonTemps() map[string]map[string]float64 {
	out := map[string]map[string]float64{}
	dirs, _ := filepath.Glob(filepath.Join(Root, "sys/class/hwmon/hwmon*"))
	for _, d := range dirs {
		name, err := os.ReadFile(filepath.Join(d, "name"))
		if err != nil {
			continue
		}
		inputs, _ := filepath.Glob(filepath.Join(d, "temp*_input"))
		for _, in := range inputs {
			raw, err := os.ReadFile(in)
			if err != nil {
				continue
			}
			v, err := strconv.ParseFloat(strings.TrimSpace(string(raw)), 64)
			if err != nil {
				continue
			}
			label := strings.TrimSuffix(filepath.Base(in), "_input")
			if l, err := os.ReadFile(strings.TrimSuffix(in, "_input") + "_label"); err == nil {
				label = strings.TrimSpace(string(l))
			}
			n := strings.TrimSpace(string(name))
			if out[n] == nil {
				out[n] = map[string]float64{}
			}
			out[n][label] = v / 1000
		}
	}
	return out
}

type tempSource struct{}

func (tempSource) Name() string { return "temperature" }
func (tempSource) Collect(now time.Time) ([]Sample, []LogLine) {
	t := hwmonTemps()
	// AMD: k10temp/zenpower Tctl or Tdie; Intel: coretemp "Package id 0".
	for _, c := range []struct{ drv, label string }{{"k10temp", "Tdie"}, {"k10temp", "Tctl"}, {"zenpower", "Tdie"}, {"coretemp", "Package id 0"}, {"cpu_thermal", "temp1"}} {
		if v, ok2 := t[c.drv][c.label]; ok2 {
			return []Sample{measured("cpu.temperature", "", round1(v), now)}, nil
		}
	}
	return []Sample{unsupported("cpu.temperature", "", "Датчик процессора не найден в /sys/class/hwmon", now)}, nil
}

type gpuSource struct{}

func (gpuSource) Name() string { return "gpu" }
func (gpuSource) Collect(now time.Time) ([]Sample, []LogLine) {
	// AMD (amdgpu) exposes load and temperature in sysfs.
	if busy, _ := filepath.Glob(filepath.Join(Root, "sys/class/drm/card*/device/gpu_busy_percent")); len(busy) > 0 {
		var out []Sample
		if raw, err := os.ReadFile(busy[0]); err == nil {
			if v, err := strconv.ParseFloat(strings.TrimSpace(string(raw)), 64); err == nil {
				out = append(out, measured("gpu.usage", "", v, now))
			}
		}
		if v, ok2 := hwmonTemps()["amdgpu"]["edge"]; ok2 {
			out = append(out, measured("gpu.temperature", "", round1(v), now))
		} else {
			out = append(out, unsupported("gpu.temperature", "", "Драйвер amdgpu не сообщает температуру", now))
		}
		return out, nil
	}
	if r, err := nvidiaSMI(); err == nil && len(r) > 0 {
		return []Sample{measured("gpu.usage", "", r[0].Util, now), measured("gpu.temperature", "", r[0].Temp, now)}, nil
	}
	return []Sample{unsupported("gpu.usage", "", "Нет данных о GPU (нет amdgpu sysfs и nvidia-smi)", now),
		unsupported("gpu.temperature", "", "Нет данных о GPU", now)}, nil
}

func nvidiaSMI() ([]NvidiaReading, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, "nvidia-smi", "--query-gpu=utilization.gpu,temperature.gpu", "--format=csv,noheader,nounits").Output()
	if err != nil {
		return nil, err
	}
	return ParseNvidiaSMI(string(out)), nil
}

type procSource struct{}

func (procSource) Name() string { return "processes" }
func (procSource) Collect(now time.Time) ([]Sample, []LogLine) {
	ents, err := os.ReadDir(filepath.Join(Root, "proc"))
	if err != nil {
		return []Sample{unavailable("process.count", "", "Нет доступа к /proc", now)}, nil
	}
	n := 0
	for _, e := range ents {
		if _, err := strconv.Atoi(e.Name()); err == nil && e.IsDir() {
			n++
		}
	}
	out := []Sample{measured("process.count", "", float64(n), now)}
	if s, err := read("proc/self/status"); err == nil {
		if m := ParseMeminfo(s); m["VmRSS"] > 0 {
			out = append(out, measured("process.rss_bytes", "aer-agent", m["VmRSS"], now))
		}
	}
	return out, nil
}

type serviceSource struct{ units []string }

func (serviceSource) Name() string { return "services" }
func (s serviceSource) Collect(now time.Time) ([]Sample, []LogLine) {
	var out []Sample
	for _, u := range s.units {
		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		raw, _ := exec.CommandContext(ctx, "systemctl", "is-active", "--", u).Output()
		cancel()
		state := strings.TrimSpace(string(raw))
		switch state {
		case "active":
			out = append(out, measured("service.active", u, 1, now))
		case "inactive", "failed", "deactivating":
			out = append(out, measured("service.active", u, 0, now))
		default:
			out = append(out, unavailable("service.active", u, "systemctl: "+orDash(state), now))
		}
	}
	return out, nil
}

func orDash(s string) string {
	if s == "" {
		return "нет ответа"
	}
	return s
}

// JournalSource reads warning+ entries of the system journal since the last
// cursor (needs membership in systemd-journal or adm to see system logs).
type JournalSource struct {
	cursor string
	every  time.Duration
	last   time.Time
}

// NewJournalSource reads at most every `every`.
func NewJournalSource(every time.Duration) *JournalSource { return &JournalSource{every: every} }

func (*JournalSource) Name() string { return "systemLogs" }
func (j *JournalSource) Collect(now time.Time) ([]Sample, []LogLine) {
	if now.Sub(j.last) < j.every {
		return nil, nil
	}
	j.last = now
	args := []string{"-p", "warning", "-o", "json", "--no-pager", "-n", "200"}
	if j.cursor != "" {
		args = append(args, "--after-cursor", j.cursor)
	} else {
		args = append(args, "--since", "-5min")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	raw, err := exec.CommandContext(ctx, "journalctl", args...).Output()
	if err != nil {
		return nil, nil
	}
	entries := ParseJournalJSON(string(raw))
	out := make([]LogLine, 0, len(entries))
	for _, e := range entries {
		out = append(out, e.Line)
		if e.Cursor != "" {
			j.cursor = e.Cursor
		}
	}
	return nil, out
}

func round1(v float64) float64 { return float64(int64(v*10+0.5)) / 10 }
