// Command aer-monbench is a SYNTHETIC load benchmark of Monitoring (M05).
// Its numbers describe the storage engine on this machine, not a real home:
// all devices, metrics and logs it creates are generated test data.
//
//	aer-monbench -mode store            # temp DB, 5/20/100 devices, ≥100k samples, ≥10k logs
//	aer-monbench -mode http -core URL -token-file F -devices 100 -duration 120s
//	                                    # synthetic agents against a running isolated Core
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"sync"
	"time"

	"aerhome/core/internal/foundation/config"
	"aerhome/core/internal/foundation/module"
	"aerhome/core/internal/foundation/storage"
	"aerhome/core/internal/modules/monitoring"
	"aerhome/core/internal/modules/registry"
)

func main() {
	mode := flag.String("mode", "store", "store | http")
	coreURL := flag.String("core", "http://127.0.0.1:18787", "Core URL (http mode)")
	tokenFile := flag.String("token-file", "", "owner token file (http mode)")
	devices := flag.Int("devices", 100, "synthetic agents (http mode)")
	duration := flag.Duration("duration", 2*time.Minute, "load duration (http mode)")
	flag.Parse()
	var err error
	switch *mode {
	case "store":
		err = storeBench()
	case "http":
		err = httpBench(*coreURL, *tokenFile, *devices, *duration)
	default:
		err = fmt.Errorf("unknown mode %q", *mode)
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "aer-monbench:", err)
		os.Exit(1)
	}
}

type clock struct{ t time.Time }

func (c *clock) now() time.Time { return c.t }

func pct(d []time.Duration, p float64) time.Duration {
	if len(d) == 0 {
		return 0
	}
	s := append([]time.Duration(nil), d...)
	sort.Slice(s, func(i, j int) bool { return s[i] < s[j] })
	return s[int(float64(len(s)-1)*p)]
}

func avg(d []time.Duration) time.Duration {
	var t time.Duration
	for _, x := range d {
		t += x
	}
	if len(d) == 0 {
		return 0
	}
	return t / time.Duration(len(d))
}

func ms(d time.Duration) string { return fmt.Sprintf("%.2f ms", float64(d.Microseconds())/1000) }

func rss() string {
	b, _ := os.ReadFile("/proc/self/status")
	for _, l := range strings.Split(string(b), "\n") {
		if strings.HasPrefix(l, "VmRSS:") {
			return strings.TrimSpace(strings.TrimPrefix(l, "VmRSS:"))
		}
	}
	return "?"
}

func dbSize(path string) int64 {
	var total int64
	for _, suf := range []string{"", "-wal", "-shm"} {
		if st, err := os.Stat(path + suf); err == nil {
			total += st.Size()
		}
	}
	return total
}

func v(x float64) *float64 { return &x }

// report builds one synthetic agent report: 20 samples (+ logs).
func report(at time.Time, i, logs int) monitoring.Report {
	var r monitoring.Report
	r.Agent = monitoring.AgentInfo{Version: "bench", OS: "synthetic"}
	add := func(m, label string, val float64) {
		r.Samples = append(r.Samples, monitoring.SampleIn{Metric: m, Label: label, Value: v(val), At: at, Quality: monitoring.QualityOK})
	}
	f := float64(i % 97)
	add("cpu.usage", "", f/2)
	add("mem.used_percent", "", 30+f/10)
	add("mem.used_bytes", "", 4e9+f*1e6)
	add("mem.total_bytes", "", 16e9)
	add("swap.used_percent", "", 1)
	for _, mp := range []string{"/", "/data", "/backup"} {
		add("disk.used_percent", mp, 40+f/20)
		add("disk.free_bytes", mp, 1e11-f*1e6)
	}
	for _, ifc := range []string{"eth0", "wlan0"} {
		add("net.rx_rate", ifc, f*1000)
		add("net.tx_rate", ifc, f*300)
		add("net.errors_rate", ifc, 0)
	}
	add("cpu.temperature", "", 45+f/10)
	add("gpu.usage", "", f/3)
	add("gpu.temperature", "", 50)
	add("process.count", "", 300+f)
	for k := 0; k < logs; k++ {
		r.Logs = append(r.Logs, monitoring.LogIn{At: at, Level: monitoring.LevelWarning, Source: "bench",
			Message: fmt.Sprintf("synthetic warning %d from report %d (test data)", k, i)})
	}
	return r
}

func storeBench() error {
	fmt.Println("SYNTHETIC benchmark — generated test data, not measurements of a real home.")
	fmt.Printf("Go %s, %s/%s, %d CPU\n\n", runtime.Version(), runtime.GOOS, runtime.GOARCH, runtime.NumCPU())
	for _, n := range []int{5, 20, 100} {
		if err := storeRun(n); err != nil {
			return err
		}
	}
	return nil
}

func storeRun(n int) error {
	ctx := context.Background()
	dir, err := os.MkdirTemp("", "aer-monbench-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(dir)
	path := filepath.Join(dir, "bench.db")
	db, err := storage.Open(ctx, path)
	if err != nil {
		return err
	}
	defer db.Close()
	rm, err := registry.Factory(registry.DefaultCatalog())(module.Deps{DB: db})
	if err != nil {
		return err
	}
	if _, err := storage.Migrate(ctx, db, registry.Name, rm.Migrations()); err != nil {
		return err
	}
	mm, err := monitoring.Factory(func() registry.Reader { return rm.(*registry.Module).Service() }, nil)(module.Deps{DB: db, Config: config.Default(os.LookupEnv)})
	if err != nil {
		return err
	}
	if _, err := storage.Migrate(ctx, db, monitoring.Name, mm.Migrations()); err != nil {
		return err
	}
	clk := &clock{t: time.Now().UTC().Add(-48 * time.Hour)}
	cfg := config.DefaultMonitoring()
	cfg.LogRatePerMin = 100_000
	svc := monitoring.NewService(db, rm.(*registry.Module).Service(), cfg, nil, clk.now)
	reg := rm.(*registry.Module).Service().(*registry.Service)

	var agents []monitoring.Agent
	for i := 0; i < n; i++ {
		e, err := reg.Create(ctx, registry.NewEntity{Name: fmt.Sprintf("Bench host %03d (тест)", i), Type: "server"})
		if err != nil {
			return err
		}
		c, err := svc.CreateAgent(ctx, e.ID, "bench", "host")
		if err != nil {
			return err
		}
		agents = append(agents, c.Agent)
	}
	const perReport = 20
	rounds := (100_000 + n*perReport - 1) / (n * perReport)
	logsPerRound := (10_000 + rounds - 1) / rounds
	var writes []time.Duration
	start := time.Now()
	var samples, logs int
	for r := 0; r < rounds; r++ {
		for i, a := range agents {
			lc := 0
			if i == 0 {
				lc = logsPerRound
			}
			t0 := time.Now()
			res, err := svc.Ingest(ctx, a, report(clk.t, r*n+i, lc))
			if err != nil {
				return err
			}
			writes = append(writes, time.Since(t0))
			samples += res.AcceptedSamples
			logs += res.AcceptedLogs
		}
		clk.t = clk.t.Add(15 * time.Second)
	}
	total := time.Since(start)
	fmt.Printf("== %d devices: %d samples, %d logs (%d rounds of 15 s = %s of data) ==\n", n, samples, logs, rounds, time.Duration(rounds)*15*time.Second)
	fmt.Printf("ingest: total %s, per report avg %s p95 %s max %s (%.0f samples/s)\n", total.Round(time.Millisecond),
		ms(avg(writes)), ms(pct(writes, 0.95)), ms(pct(writes, 1)), float64(samples)/total.Seconds())

	timeIt := func(label string, reps int, f func() error) error {
		var d []time.Duration
		for i := 0; i < reps; i++ {
			t0 := time.Now()
			if err := f(); err != nil {
				return err
			}
			d = append(d, time.Since(t0))
		}
		fmt.Printf("%-34s avg %s p95 %s\n", label, ms(avg(d)), ms(pct(d, 0.95)))
		return nil
	}
	svc.CheckAll(ctx)
	if err := timeIt("current states (all devices)", 20, func() error { _, err := svc.States(ctx); return err }); err != nil {
		return err
	}
	if err := timeIt("overview", 20, func() error { _, err := svc.Overview(ctx); return err }); err != nil {
		return err
	}
	e0 := agents[0].EntityID
	if err := timeIt("chart 1 h (raw)", 20, func() error {
		_, err := svc.History(ctx, e0, "cpu.usage", "", clk.t.Add(-time.Hour), clk.t)
		return err
	}); err != nil {
		return err
	}
	if err := timeIt("chart whole range (5-min rollups)", 20, func() error {
		_, err := svc.History(ctx, e0, "cpu.usage", "", clk.t.Add(-7*24*time.Hour), clk.t)
		return err
	}); err != nil {
		return err
	}
	if err := timeIt("logs: newest 100", 20, func() error { _, err := svc.Logs(ctx, monitoring.LogFilter{Limit: 100}); return err }); err != nil {
		return err
	}
	if err := timeIt("logs: text search", 20, func() error {
		_, err := svc.Logs(ctx, monitoring.LogFilter{Query: "warning 7", Limit: 100})
		return err
	}); err != nil {
		return err
	}
	fmt.Printf("database size: %.1f MB; process RSS %s\n", float64(dbSize(path))/1e6, rss())

	clk.t = clk.t.Add(8 * 24 * time.Hour)
	t0 := time.Now()
	pr, err := svc.Prune(ctx)
	if err != nil {
		return err
	}
	fmt.Printf("retention after +8 days: %s, removed %d raw samples, %d rollups, %d logs (rollups kept for charts)\n",
		ms(time.Since(t0)), pr.Samples, pr.Rollups, pr.Logs)
	var rollups, latest int
	_ = db.QueryRow(`SELECT COUNT(*) FROM mon_rollups`).Scan(&rollups)
	_ = db.QueryRow(`SELECT COUNT(*) FROM mon_latest`).Scan(&latest)
	fmt.Printf("after retention: %d rollup rows, %d latest values kept; file %.1f MB (space reused by SQLite, no VACUUM)\n\n",
		rollups, latest, float64(dbSize(path))/1e6)
	return nil
}

// httpBench drives a running (isolated!) Core with synthetic agents.
func httpBench(core, tokenFile string, n int, dur time.Duration) error {
	raw, err := os.ReadFile(tokenFile)
	if err != nil {
		return err
	}
	owner := strings.TrimSpace(string(raw))
	client := &http.Client{Timeout: 15 * time.Second}
	call := func(token, method, path string, body any) (map[string]any, error) {
		b, _ := json.Marshal(body)
		req, _ := http.NewRequest(method, core+"/api/v1"+path, bytes.NewReader(b))
		req.Header.Set("Authorization", "Bearer "+token)
		req.Header.Set("Content-Type", "application/json")
		resp, err := client.Do(req)
		if err != nil {
			return nil, err
		}
		defer resp.Body.Close()
		data, _ := io.ReadAll(resp.Body)
		if resp.StatusCode >= 300 {
			return nil, fmt.Errorf("%s %s: %d %s", method, path, resp.StatusCode, data)
		}
		var env struct {
			Data map[string]any `json:"data"`
		}
		_ = json.Unmarshal(data, &env)
		return env.Data, nil
	}
	fmt.Printf("SYNTHETIC: %d agents for %s against %s\n", n, dur, core)
	tokens := make([]string, n)
	for i := range n {
		e, err := call(owner, "POST", "/registry/entities", map[string]any{"name": fmt.Sprintf("Bench host %03d (тест)", i), "type": "server"})
		if err != nil {
			return err
		}
		c, err := call(owner, "POST", "/monitoring/agents", map[string]any{"entityId": e["id"], "name": "bench", "kind": "host"})
		if err != nil {
			return err
		}
		tokens[i] = c["token"].(string)
	}
	var mu sync.Mutex
	var lat []time.Duration
	var errs int
	end := time.Now().Add(dur)
	var wg sync.WaitGroup
	for i, tok := range tokens {
		wg.Add(1)
		go func() {
			defer wg.Done()
			time.Sleep(time.Duration(i) * 15 * time.Second / time.Duration(n)) // spread like real agents
			for k := 0; time.Now().Before(end); k++ {
				t0 := time.Now()
				_, err := call(tok, "POST", "/monitoring/agent/report", report(time.Now().UTC(), k, 0))
				mu.Lock()
				lat = append(lat, time.Since(t0))
				if err != nil {
					errs++
				}
				mu.Unlock()
				time.Sleep(15 * time.Second)
			}
		}()
	}
	wg.Wait()
	fmt.Printf("reports: %d (errors %d), latency avg %s p95 %s max %s\n", len(lat), errs, ms(avg(lat)), ms(pct(lat, 0.95)), ms(pct(lat, 1)))
	for _, p := range []string{"/monitoring/states", "/monitoring/overview"} {
		var d []time.Duration
		for range 10 {
			t0 := time.Now()
			if _, err := call(owner, "GET", p, nil); err != nil && !strings.Contains(err.Error(), "cannot unmarshal") {
				return err
			}
			d = append(d, time.Since(t0))
		}
		fmt.Printf("GET %-22s avg %s p95 %s\n", p, ms(avg(d)), ms(pct(d, 0.95)))
	}
	return nil
}
