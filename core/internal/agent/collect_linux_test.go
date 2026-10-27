//go:build linux

package agent

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

func write(t *testing.T, root, p, s string) {
	t.Helper()
	full := filepath.Join(root, p)
	if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(full, []byte(s), 0o644); err != nil {
		t.Fatal(err)
	}
}

func byMetric(ss []Sample) map[string]Sample {
	m := map[string]Sample{}
	for _, s := range ss {
		m[s.Metric+"|"+s.Label] = s
	}
	return m
}

func TestLinuxCollectorsOnFakeTree(t *testing.T) {
	root := t.TempDir()
	old := Root
	Root = root
	defer func() { Root = old }()
	write(t, root, "proc/stat", "cpu  100 0 100 700 100 0 0 0 0 0\n")
	write(t, root, "proc/meminfo", "MemTotal: 1000 kB\nMemAvailable: 250 kB\nSwapTotal: 0 kB\nSwapFree: 0 kB\n")
	write(t, root, "proc/net/dev", "h\nh\n eth0: 1000 1 0 0 0 0 0 0 2000 1 0 0 0 0 0 0\n")
	write(t, root, "sys/class/hwmon/hwmon1/name", "k10temp\n")
	write(t, root, "sys/class/hwmon/hwmon1/temp1_input", "52125\n")
	write(t, root, "sys/class/hwmon/hwmon1/temp1_label", "Tctl\n")
	write(t, root, "proc/123/status", "")
	write(t, root, "proc/456/status", "")
	now := time.Now()
	cpu := &cpuSource{}
	if s, _ := cpu.Collect(now); len(s) != 0 {
		t.Fatal("first CPU reading only primes")
	}
	write(t, root, "proc/stat", "cpu  150 0 150 800 100 0 0 0 0 0\n")
	s, _ := cpu.Collect(now.Add(15 * time.Second))
	if len(s) != 1 || *s[0].Value != 50 {
		t.Fatalf("cpu: %+v", s)
	}
	mem := byMetric(func() []Sample { s, _ := memSource{}.Collect(now); return s }())
	if *mem["mem.used_percent|"].Value != 75 || mem["swap.used_percent|"].Quality != "unsupported" {
		t.Fatalf("mem: %+v", mem)
	}
	tmp, _ := tempSource{}.Collect(now)
	if *tmp[0].Value != 52.1 {
		t.Fatalf("temp: %+v", tmp)
	}
	gpu, _ := gpuSource{}.Collect(now)
	for _, g := range gpu {
		if g.Quality != "unsupported" || g.Reason == "" {
			t.Fatalf("no GPU data → unsupported with reason: %+v", g)
		}
	}
	ns := &netSource{prev: map[string]NetCounters{}}
	ns.Collect(now)
	write(t, root, "proc/net/dev", "h\nh\n eth0: 4000 1 0 0 0 0 0 0 2600 1 0 0 0 0 0 0\n")
	net := byMetric(func() []Sample { s, _ := ns.Collect(now.Add(10 * time.Second)); return s }())
	if *net["net.rx_rate|eth0"].Value != 300 || *net["net.tx_rate|eth0"].Value != 60 {
		t.Fatalf("net: %+v", net)
	}
	p, _ := procSource{}.Collect(now)
	if *p[0].Value != 2 {
		t.Fatalf("processes: %+v", p)
	}
	// No /proc access → explained absence, not a zero.
	Root = filepath.Join(root, "missing")
	m2, _ := memSource{}.Collect(now)
	if m2[0].Quality != "unavailable" || m2[0].Value != nil {
		t.Fatalf("unavailable: %+v", m2)
	}
}
