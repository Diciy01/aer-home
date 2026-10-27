//go:build windows

package agent

import (
	"context"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"time"
	"unsafe"

	"golang.org/x/sys/windows"
)

// Windows collectors use Win32 APIs only (no WMI, no PowerShell per tick).
// Temperatures need vendor drivers or admin WMI and are reported as
// unsupported rather than guessed.

var (
	kernel32            = windows.NewLazySystemDLL("kernel32.dll")
	procGetSystemTimes  = kernel32.NewProc("GetSystemTimes")
	procGlobalMemStatus = kernel32.NewProc("GlobalMemoryStatusEx")
	procGetTickCount64  = kernel32.NewProc("GetTickCount64")
)

type memoryStatusEx struct {
	Length               uint32
	MemoryLoad           uint32
	TotalPhys            uint64
	AvailPhys            uint64
	TotalPageFile        uint64
	AvailPageFile        uint64
	TotalVirtual         uint64
	AvailVirtual         uint64
	AvailExtendedVirtual uint64
}

func filetime(ft windows.Filetime) float64 {
	return float64(uint64(ft.HighDateTime)<<32 | uint64(ft.LowDateTime))
}

// PlatformSources returns the Windows collectors enabled in cfg.
func PlatformSources(cfg Collectors) []Source {
	var out []Source
	if cfg.CPU {
		out = append(out, &winCPU{})
	}
	if cfg.Memory {
		out = append(out, winMem{})
	}
	if cfg.Disk {
		out = append(out, winDisk{})
	}
	if cfg.Network {
		out = append(out, &winNet{prev: map[string]NetCounters{}})
	}
	if cfg.Temperature {
		out = append(out, winTemp{})
	}
	if cfg.GPU {
		out = append(out, winGPU{})
	}
	if cfg.Processes {
		out = append(out, winProc{})
	}
	if len(cfg.Services) > 0 {
		out = append(out, winServices{names: cfg.Services})
	}
	return out
}

// PlatformInfo describes this host for the heartbeat.
func PlatformInfo(collectors map[string]string) func() Info {
	v := windows.RtlGetVersion()
	osv := "Windows " + strconv.Itoa(int(v.MajorVersion)) + "." + strconv.Itoa(int(v.MinorVersion)) + " build " + strconv.Itoa(int(v.BuildNumber))
	host, _ := os.Hostname()
	return func() Info {
		ms, _, _ := procGetTickCount64.Call()
		return Info{Version: Version, OS: "windows", OSVersion: osv, Hostname: host, UptimeSec: float64(ms) / 1000, Collectors: collectors}
	}
}

type winCPU struct {
	prev  CPUTimes
	valid bool
}

func (*winCPU) Name() string { return "cpu" }
func (c *winCPU) Collect(now time.Time) ([]Sample, []LogLine) {
	var idle, kernel, user windows.Filetime
	r, _, err := procGetSystemTimes.Call(uintptr(unsafe.Pointer(&idle)), uintptr(unsafe.Pointer(&kernel)), uintptr(unsafe.Pointer(&user)))
	if r == 0 {
		return []Sample{unavailable("cpu.usage", "", "GetSystemTimes: "+err.Error(), now)}, nil
	}
	// Kernel time includes idle time.
	cur := CPUTimes{Idle: filetime(idle), Total: filetime(kernel) + filetime(user)}
	prev, valid := c.prev, c.valid
	c.prev, c.valid = cur, true
	if !valid {
		return nil, nil
	}
	if p, good := CPUPercent(prev, cur); good {
		return []Sample{measured("cpu.usage", "", round1(p), now)}, nil
	}
	return nil, nil
}

type winMem struct{}

func (winMem) Name() string { return "memory" }
func (winMem) Collect(now time.Time) ([]Sample, []LogLine) {
	m := memoryStatusEx{Length: uint32(unsafe.Sizeof(memoryStatusEx{}))}
	r, _, err := procGlobalMemStatus.Call(uintptr(unsafe.Pointer(&m)))
	if r == 0 {
		return []Sample{unavailable("mem.used_percent", "", "GlobalMemoryStatusEx: "+err.Error(), now)}, nil
	}
	total, used := float64(m.TotalPhys), float64(m.TotalPhys-m.AvailPhys)
	out := []Sample{measured("mem.used_percent", "", round1(100*used/total), now), measured("mem.used_bytes", "", used, now), measured("mem.total_bytes", "", total, now)}
	// The commit limit includes RAM; the page file share is the excess.
	pf := float64(m.TotalPageFile) - total
	if pf > 0 {
		pfUsed := float64(m.TotalPageFile-m.AvailPageFile) - used
		out = append(out, measured("swap.used_percent", "", round1(100*max(0, pfUsed)/pf), now))
	} else {
		out = append(out, unsupported("swap.used_percent", "", "Файл подкачки не настроен", now))
	}
	return out, nil
}

type winDisk struct{}

func (winDisk) Name() string { return "disk" }
func (winDisk) Collect(now time.Time) ([]Sample, []LogLine) {
	buf := make([]uint16, 256)
	n, err := windows.GetLogicalDriveStrings(uint32(len(buf)), &buf[0])
	if err != nil {
		return []Sample{unavailable("disk.used_percent", "", "GetLogicalDriveStrings: "+err.Error(), now)}, nil
	}
	var out []Sample
	for _, d := range strings.Split(windows.UTF16ToString(buf[:n]), "\x00") {
		if d == "" {
			continue
		}
		p, _ := windows.UTF16PtrFromString(d)
		if windows.GetDriveType(p) != windows.DRIVE_FIXED {
			continue
		}
		var avail, total, free uint64
		if err := windows.GetDiskFreeSpaceEx(p, &avail, &total, &free); err != nil || total == 0 {
			continue
		}
		label := strings.TrimSuffix(d, `\`)
		out = append(out, measured("disk.used_percent", label, round1(100*float64(total-free)/float64(total)), now),
			measured("disk.free_bytes", label, float64(avail), now))
	}
	return out, nil
}

type winNet struct {
	prev   map[string]NetCounters
	prevAt time.Time
}

func (*winNet) Name() string { return "network" }
func (n *winNet) Collect(now time.Time) ([]Sample, []LogLine) {
	var t *windows.MibIfTable2
	if err := windows.GetIfTable2Ex(windows.MibIfTableNormal, &t); err != nil {
		return []Sample{unavailable("net.rx_rate", "", "GetIfTable2Ex: "+err.Error(), now)}, nil
	}
	defer windows.FreeMibTable(unsafe.Pointer(t))
	rows := unsafe.Slice(&t.Table[0], t.NumEntries)
	cur := map[string]NetCounters{}
	for _, r := range rows {
		// Physical, connected interfaces only (filter flags bit 0 = HardwareInterface).
		if r.Type == windows.IF_TYPE_SOFTWARE_LOOPBACK || r.OperStatus != windows.IfOperStatusUp || r.InterfaceAndOperStatusFlags&1 == 0 {
			continue
		}
		name := windows.UTF16ToString(r.Alias[:])
		cur[name] = NetCounters{RX: float64(r.InOctets), TX: float64(r.OutOctets), Errors: float64(r.InErrors + r.OutErrors + r.InDiscards + r.OutDiscards)}
	}
	var out []Sample
	if !n.prevAt.IsZero() {
		sec := now.Sub(n.prevAt).Seconds()
		for name, c := range cur {
			p, found := n.prev[name]
			if !found || sec <= 0 || c.RX < p.RX || c.TX < p.TX {
				continue
			}
			out = append(out, measured("net.rx_rate", name, round1((c.RX-p.RX)/sec), now), measured("net.tx_rate", name, round1((c.TX-p.TX)/sec), now),
				measured("net.errors_rate", name, round1(max(0, c.Errors-p.Errors)/sec), now))
		}
	}
	n.prev, n.prevAt = cur, now
	return out, nil
}

type winTemp struct{}

func (winTemp) Name() string { return "temperature" }
func (winTemp) Collect(now time.Time) ([]Sample, []LogLine) {
	return []Sample{unsupported("cpu.temperature", "", "Windows не даёт температуру CPU без драйвера производителя или прав администратора (WMI)", now)}, nil
}

type winGPU struct{}

func (winGPU) Name() string { return "gpu" }
func (winGPU) Collect(now time.Time) ([]Sample, []LogLine) {
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	raw, err := exec.CommandContext(ctx, "nvidia-smi", "--query-gpu=utilization.gpu,temperature.gpu", "--format=csv,noheader,nounits").Output()
	if r := ParseNvidiaSMI(string(raw)); err == nil && len(r) > 0 {
		return []Sample{measured("gpu.usage", "", r[0].Util, now), measured("gpu.temperature", "", r[0].Temp, now)}, nil
	}
	return []Sample{unsupported("gpu.usage", "", "Нет nvidia-smi; для AMD/Intel нужен драйвер производителя", now),
		unsupported("gpu.temperature", "", "Нет данных о GPU", now)}, nil
}

type winProc struct{}

func (winProc) Name() string { return "processes" }
func (winProc) Collect(now time.Time) ([]Sample, []LogLine) {
	snap, err := windows.CreateToolhelp32Snapshot(windows.TH32CS_SNAPPROCESS, 0)
	if err != nil {
		return []Sample{unavailable("process.count", "", "Toolhelp32: "+err.Error(), now)}, nil
	}
	defer windows.CloseHandle(snap)
	var e windows.ProcessEntry32
	e.Size = uint32(unsafe.Sizeof(e))
	n := 0
	for err := windows.Process32First(snap, &e); err == nil; err = windows.Process32Next(snap, &e) {
		n++
	}
	return []Sample{measured("process.count", "", float64(n), now)}, nil
}

type winServices struct{ names []string }

func (winServices) Name() string { return "services" }
func (s winServices) Collect(now time.Time) ([]Sample, []LogLine) {
	var out []Sample
	for _, name := range s.names {
		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		raw, _ := exec.CommandContext(ctx, "sc", "query", name).Output()
		cancel()
		running, state, err := ParseSCQuery(string(raw))
		switch {
		case err != nil:
			out = append(out, unavailable("service.active", name, "sc query: служба не найдена или нет доступа", now))
		case running:
			out = append(out, measured("service.active", name, 1, now))
		default:
			_ = state
			out = append(out, measured("service.active", name, 0, now))
		}
	}
	return out, nil
}

// EventLogSource reads Critical/Error/Warning events of the System and
// Application logs newer than the last seen record (wevtutil, built in).
type EventLogSource struct {
	every time.Duration
	last  time.Time
	seen  map[string]int64
}

// NewEventLogSource reads at most every `every`.
func NewEventLogSource(every time.Duration) *EventLogSource {
	return &EventLogSource{every: every, seen: map[string]int64{}}
}

func (*EventLogSource) Name() string { return "systemLogs" }
func (s *EventLogSource) Collect(now time.Time) ([]Sample, []LogLine) {
	if now.Sub(s.last) < s.every {
		return nil, nil
	}
	s.last = now
	var out []LogLine
	for _, ch := range []string{"System", "Application"} {
		q := "*[System[(Level=1 or Level=2 or Level=3) and TimeCreated[timediff(@SystemTime) <= 300000]]]"
		if id := s.seen[ch]; id > 0 {
			q = "*[System[(Level=1 or Level=2 or Level=3) and EventRecordID > " + strconv.FormatInt(id, 10) + "]]"
		}
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		raw, err := exec.CommandContext(ctx, "wevtutil", "qe", ch, "/q:"+q, "/f:RenderedXml", "/e:Events", "/c:100").Output()
		cancel()
		if err != nil {
			continue
		}
		lines, maxID, _ := ParseWevtutilXML(string(raw))
		if maxID > s.seen[ch] {
			s.seen[ch] = maxID
		}
		out = append(out, lines...)
	}
	return nil, out
}

func round1(v float64) float64 { return float64(int64(v*10+0.5)) / 10 }
