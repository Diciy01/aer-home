package agent

import (
	"bufio"
	"encoding/json"
	"encoding/xml"
	"errors"
	"io"
	"strconv"
	"strings"
	"time"
	"unicode/utf16"
)

// Parsers are platform-neutral so both the Linux and the Windows sources
// are unit-tested on any build machine.

// CPUTimes is the aggregate line of /proc/stat.
type CPUTimes struct{ Idle, Total float64 }

// ParseProcStat reads the first "cpu" line of /proc/stat.
func ParseProcStat(s string) (CPUTimes, error) {
	for _, line := range strings.Split(s, "\n") {
		f := strings.Fields(line)
		if len(f) < 5 || f[0] != "cpu" {
			continue
		}
		var t CPUTimes
		for i, v := range f[1:] {
			n, err := strconv.ParseFloat(v, 64)
			if err != nil {
				return CPUTimes{}, err
			}
			// guest/guest_nice are already included in user/nice.
			if i >= 8 {
				break
			}
			t.Total += n
			if i == 3 || i == 4 { // idle + iowait
				t.Idle += n
			}
		}
		return t, nil
	}
	return CPUTimes{}, errors.New("no cpu line")
}

// CPUPercent between two readings.
func CPUPercent(prev, cur CPUTimes) (float64, bool) {
	dt := cur.Total - prev.Total
	if dt <= 0 {
		return 0, false
	}
	return 100 * (1 - (cur.Idle-prev.Idle)/dt), true
}

// ParseMeminfo returns /proc/meminfo values in bytes.
func ParseMeminfo(s string) map[string]float64 {
	out := map[string]float64{}
	for _, line := range strings.Split(s, "\n") {
		k, v, ok := strings.Cut(line, ":")
		if !ok {
			continue
		}
		f := strings.Fields(v)
		if len(f) == 0 {
			continue
		}
		n, err := strconv.ParseFloat(f[0], 64)
		if err != nil {
			continue
		}
		if len(f) > 1 && f[1] == "kB" {
			n *= 1024
		}
		out[strings.TrimSpace(k)] = n
	}
	return out
}

// NetCounters of one interface.
type NetCounters struct{ RX, TX, Errors float64 }

// ParseNetDev reads /proc/net/dev; loopback and virtual bridges are skipped.
func ParseNetDev(s string) map[string]NetCounters {
	out := map[string]NetCounters{}
	for _, line := range strings.Split(s, "\n") {
		name, rest, ok := strings.Cut(line, ":")
		if !ok {
			continue
		}
		name = strings.TrimSpace(name)
		if name == "lo" || strings.HasPrefix(name, "veth") || strings.HasPrefix(name, "docker") || strings.HasPrefix(name, "br-") {
			continue
		}
		f := strings.Fields(rest)
		if len(f) < 16 {
			continue
		}
		num := func(i int) float64 { n, _ := strconv.ParseFloat(f[i], 64); return n }
		out[name] = NetCounters{RX: num(0), TX: num(8), Errors: num(2) + num(3) + num(10) + num(11)}
	}
	return out
}

// realFS are file systems that hold user data (pseudo/snap/tmpfs skipped).
var realFS = map[string]bool{"ext2": true, "ext3": true, "ext4": true, "xfs": true, "btrfs": true, "zfs": true,
	"vfat": true, "exfat": true, "ntfs": true, "ntfs3": true, "fuseblk": true, "f2fs": true}

// ParseMounts lists mount points of real file systems from /proc/self/mounts.
func ParseMounts(s string) []string {
	seen := map[string]bool{}
	var out []string
	for _, line := range strings.Split(s, "\n") {
		f := strings.Fields(line)
		if len(f) < 3 || !realFS[f[2]] {
			continue
		}
		mp := strings.ReplaceAll(f[1], `\040`, " ")
		if strings.HasPrefix(mp, "/snap/") || seen[mp] {
			continue
		}
		seen[mp] = true
		out = append(out, mp)
	}
	return out
}

// ParseOSRelease returns PRETTY_NAME.
func ParseOSRelease(s string) string {
	for _, line := range strings.Split(s, "\n") {
		if v, ok := strings.CutPrefix(line, "PRETTY_NAME="); ok {
			return strings.Trim(v, `"`)
		}
	}
	return ""
}

// JournalEntry is one line of `journalctl -o json`.
type JournalEntry struct {
	Line   LogLine
	Cursor string
}

// ParseJournalJSON converts journalctl JSON lines into log lines. Only
// warning (4) and more severe priorities are passed on.
func ParseJournalJSON(s string) []JournalEntry {
	var out []JournalEntry
	sc := bufio.NewScanner(strings.NewReader(s))
	sc.Buffer(make([]byte, 64<<10), 1<<20)
	for sc.Scan() {
		var m map[string]any
		if json.Unmarshal(sc.Bytes(), &m) != nil {
			continue
		}
		msg, ok := m["MESSAGE"].(string)
		if !ok || strings.TrimSpace(msg) == "" {
			continue // binary messages arrive as arrays: skip
		}
		prio, _ := strconv.Atoi(str(m["PRIORITY"]))
		lvl := ""
		switch {
		case prio <= 2:
			lvl = "critical"
		case prio == 3:
			lvl = "error"
		case prio == 4:
			lvl = "warning"
		default:
			continue
		}
		us, _ := strconv.ParseInt(str(m["__REALTIME_TIMESTAMP"]), 10, 64)
		src := str(m["_SYSTEMD_UNIT"])
		if src == "" {
			src = str(m["SYSLOG_IDENTIFIER"])
		}
		if src == "" {
			src = str(m["_TRANSPORT"])
		}
		out = append(out, JournalEntry{
			Line:   LogLine{At: time.UnixMicro(us).UTC(), Level: lvl, Source: "journal/" + src, Message: msg},
			Cursor: str(m["__CURSOR"]),
		})
	}
	return out
}

func str(v any) string {
	s, _ := v.(string)
	return s
}

type wevtEvent struct {
	System struct {
		Provider struct {
			Name string `xml:"Name,attr"`
		} `xml:"Provider"`
		EventID     string `xml:"EventID"`
		Level       int    `xml:"Level"`
		TimeCreated struct {
			SystemTime string `xml:"SystemTime,attr"`
		} `xml:"TimeCreated"`
		EventRecordID int64  `xml:"EventRecordID"`
		Channel       string `xml:"Channel"`
	} `xml:"System"`
	RenderingInfo struct {
		Message string `xml:"Message"`
	} `xml:"RenderingInfo"`
}

// ParseWevtutilXML reads `wevtutil qe <log> /f:RenderedXml /e:Events`
// output. Levels: 1 critical, 2 error, 3 warning.
func ParseWevtutilXML(s string) ([]LogLine, int64, error) {
	dec := xml.NewDecoder(strings.NewReader(s))
	var out []LogLine
	var maxID int64
	for {
		var ev wevtEvent
		err := dec.Decode(&ev)
		if err != nil {
			if errors.Is(err, io.EOF) {
				break
			}
			var se *xml.SyntaxError
			if errors.As(err, &se) {
				return out, maxID, err
			}
			break
		}
		lvl := map[int]string{1: "critical", 2: "error", 3: "warning"}[ev.System.Level]
		if lvl == "" {
			continue
		}
		at, _ := time.Parse(time.RFC3339Nano, ev.System.TimeCreated.SystemTime)
		msg := strings.TrimSpace(ev.RenderingInfo.Message)
		if msg == "" {
			msg = "Событие " + ev.System.EventID
		}
		if ev.System.EventRecordID > maxID {
			maxID = ev.System.EventRecordID
		}
		out = append(out, LogLine{At: at.UTC(), Level: lvl, Source: "eventlog/" + ev.System.Channel + "/" + ev.System.Provider.Name,
			Message: msg, Fields: json.RawMessage(`{"eventId":"` + strings.TrimSpace(ev.System.EventID) + `"}`)})
	}
	return out, maxID, nil
}

// NvidiaReading is one GPU line of nvidia-smi CSV output.
type NvidiaReading struct{ Util, Temp float64 }

// ParseNvidiaSMI reads `nvidia-smi --query-gpu=utilization.gpu,temperature.gpu --format=csv,noheader,nounits`.
func ParseNvidiaSMI(s string) []NvidiaReading {
	var out []NvidiaReading
	for _, line := range strings.Split(strings.TrimSpace(s), "\n") {
		f := strings.Split(line, ",")
		if len(f) != 2 {
			continue
		}
		u, err1 := strconv.ParseFloat(strings.TrimSpace(f[0]), 64)
		t, err2 := strconv.ParseFloat(strings.TrimSpace(f[1]), 64)
		if err1 == nil && err2 == nil {
			out = append(out, NvidiaReading{Util: u, Temp: t})
		}
	}
	return out
}

// ParseMultiSZ splits a Windows REG_MULTI_SZ-style UTF-16 buffer (e.g. from
// GetLogicalDriveStrings: "C:\␀D:\␀␀") into its strings. UTF16ToString
// would stop at the first NUL and keep only the first entry.
func ParseMultiSZ(buf []uint16) []string {
	var out []string
	for _, s := range strings.Split(string(utf16.Decode(buf)), "\x00") {
		if s != "" {
			out = append(out, s)
		}
	}
	return out
}
