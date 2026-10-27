//go:build linux

// Command aer-botbench is a SYNTHETIC load benchmark of Bots (M06). Every
// bot, job and log line it creates is generated test data; the numbers
// describe the engine on this machine, not a real home.
//
//	aer-botbench -mode store       # temp DB: 1/5/20/50 bots, 10 000 jobs, 50 000 log lines, concurrency
//	aer-botbench -mode http -core URL -token-file F -core-pid PID -bots 50 -duration 60s
//	                               # synthetic bots against a running isolated Core
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
	"sort"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"aerhome/core/internal/foundation/config"
	"aerhome/core/internal/foundation/module"
	"aerhome/core/internal/foundation/storage"
	"aerhome/core/internal/modules/bots"
	"aerhome/core/internal/modules/monitoring"
	"aerhome/core/internal/modules/registry"
)

var burst *bool

func main() {
	mode := flag.String("mode", "store", "store | http")
	coreURL := flag.String("core", "http://127.0.0.1:18797", "Core URL (http mode)")
	tokenFile := flag.String("token-file", "", "owner token file (http mode)")
	corePID := flag.Int("core-pid", 0, "Core PID for CPU/RSS (http mode)")
	n := flag.Int("bots", 50, "synthetic bots (http mode)")
	duration := flag.Duration("duration", time.Minute, "load duration (http mode)")
	burst = flag.Bool("burst", false, "http mode: all bots report at the same instant (worst case)")
	flag.Parse()
	var err error
	switch *mode {
	case "store":
		err = storeBench()
	case "http":
		err = httpBench(*coreURL, *tokenFile, *corePID, *n, *duration)
	default:
		err = fmt.Errorf("unknown mode %q", *mode)
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "aer-botbench:", err)
		os.Exit(1)
	}
}

func pct(d []time.Duration, p float64) time.Duration {
	if len(d) == 0 {
		return 0
	}
	s := append([]time.Duration(nil), d...)
	sort.Slice(s, func(i, j int) bool { return s[i] < s[j] })
	return s[int(float64(len(s)-1)*p)]
}

func ms(d time.Duration) string { return fmt.Sprintf("%.2f мс", float64(d.Microseconds())/1000) }

func timeIt(reps int, fn func() error) ([]time.Duration, error) {
	out := make([]time.Duration, 0, reps)
	for i := 0; i < reps; i++ {
		t := time.Now()
		if err := fn(); err != nil {
			return out, err
		}
		out = append(out, time.Since(t))
	}
	return out, nil
}

func line(name string, d []time.Duration) {
	fmt.Printf("  %-34s p50 %s · p95 %s · max %s (n=%d)\n", name, ms(pct(d, .5)), ms(pct(d, .95)), ms(pct(d, 1)), len(d))
}

func selfRSS() string {
	b, _ := os.ReadFile("/proc/self/status")
	for _, l := range strings.Split(string(b), "\n") {
		if strings.HasPrefix(l, "VmRSS:") {
			return strings.TrimSpace(strings.TrimPrefix(l, "VmRSS:"))
		}
	}
	return "?"
}

func cpuTime() time.Duration {
	var ru syscall.Rusage
	_ = syscall.Getrusage(syscall.RUSAGE_SELF, &ru)
	return time.Duration(ru.Utime.Nano() + ru.Stime.Nano())
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

type benchBot struct{ id, token string }

type env struct {
	ctx context.Context
	db  string
	reg *registry.Service
	mon *monitoring.Service
	svc *bots.Service
}

func newEnv(dir string) (*env, error) {
	ctx := context.Background()
	path := filepath.Join(dir, "bench.db")
	db, err := storage.Open(ctx, path)
	if err != nil {
		return nil, err
	}
	mcfg := config.DefaultMonitoring()
	mcfg.Docker.Enabled = false
	mcfg.LogRatePerMin = 100_000
	cfg := config.Config{Monitoring: mcfg, Bots: config.DefaultBots()}
	rm, _ := registry.Factory(registry.DefaultCatalog())(module.Deps{DB: db})
	reg := rm.(*registry.Module).Writer()
	mm, _ := monitoring.Factory(func() registry.Reader { return reg }, nil)(module.Deps{DB: db, Config: cfg})
	mon := mm.(*monitoring.Module).Service()
	bm, _ := bots.Factory(func() bots.RegistryWriter { return reg }, func() *monitoring.Service { return mon }, nil)(module.Deps{DB: db, Config: cfg})
	for _, m := range []module.Module{rm, mm, bm} {
		if _, err := storage.Migrate(ctx, db, m.Name(), m.Migrations()); err != nil {
			return nil, err
		}
	}
	return &env{ctx: ctx, db: path, reg: reg, mon: mon, svc: bm.(*bots.Module).Service()}, nil
}

func storeBench() error {
	fmt.Println("СИНТЕТИКА: боты, задания и логи ниже — сгенерированные тестовые данные.")
	for _, n := range []int{1, 5, 20, 50} {
		dir, _ := os.MkdirTemp("", "aer-botbench-")
		e, err := newEnv(dir)
		if err != nil {
			return err
		}
		var list []benchBot
		for i := 0; i < n; i++ {
			c, err := e.svc.Create(e.ctx, bots.NewBot{Name: fmt.Sprintf("Бот %d (синтетика)", i), Type: "telegram_bot", CreateCredential: true, Category: "bench"})
			if err != nil {
				return err
			}
			list = append(list, benchBot{c.Bot.EntityID, c.HeartbeatToken})
		}
		agents := make([]monitoring.Agent, n)
		for i, x := range list {
			agents[i], _ = e.mon.Authenticate(e.ctx, x.token)
		}
		cpu0 := cpuTime()
		start := time.Now()
		var hb []time.Duration
		for round := 0; round < 20; round++ { // 20 rounds of heartbeats from every bot
			for i := range agents {
				now := time.Now().UTC()
				t := time.Now()
				if _, err := e.mon.Ingest(e.ctx, agents[i], monitoring.Report{Agent: monitoring.AgentInfo{Version: "bench"},
					Bot: &monitoring.BotStatus{StartedAt: &start, LastSuccessAt: &now, Version: "1.0"}}); err != nil {
					return err
				}
				hb = append(hb, time.Since(t))
			}
		}
		hbWall := time.Since(start)
		lst, err := timeIt(30, func() error { _, err := e.svc.List(e.ctx, bots.ListFilter{}); return err })
		if err != nil {
			return err
		}
		get, err := timeIt(30, func() error { _, err := e.svc.Get(e.ctx, list[0].id); return err })
		if err != nil {
			return err
		}
		fmt.Printf("\n== %d ботов ==\n", n)
		fmt.Printf("  массовый heartbeat: %d отчётов за %s (%.0f/с)\n", len(hb), hbWall.Round(time.Millisecond), float64(len(hb))/hbWall.Seconds())
		line("heartbeat (Ingest)", hb)
		line("список ботов (List)", lst)
		line("страница бота (Get)", get)
		fmt.Printf("  CPU процесса: %s · RSS %s · база %.1f МБ\n", (cpuTime() - cpu0).Round(time.Millisecond), selfRSS(), float64(dbSize(e.db))/1e6)

		if n == 50 {
			if err := bigHistory(e, list[0].id, agents[0]); err != nil {
				return err
			}
			if err := concurrency(e, list); err != nil {
				return err
			}
			fmt.Printf("\n  итог: RSS %s · база %.1f МБ\n", selfRSS(), float64(dbSize(e.db))/1e6)
		}
		os.RemoveAll(dir)
	}
	return nil
}

func bigHistory(e *env, id string, a monitoring.Agent) error {
	fmt.Println("\n== История: 10 000 заданий, 50 000 строк логов (один бот) ==")
	start := time.Now()
	base := time.Now().UTC().Add(-20 * 24 * time.Hour)
	for k := 0; k < 50; k++ {
		var r bots.JobReport
		for i := 0; i < 200; i++ {
			j := k*200 + i
			s := base.Add(time.Duration(j) * 2 * time.Minute)
			f := s.Add(1500 * time.Millisecond)
			st := bots.JobSuccess
			errText := ""
			if j%7 == 0 {
				st, errText = bots.JobFailed, "synthetic failure"
			}
			r.Jobs = append(r.Jobs, bots.JobIn{ID: strconv.Itoa(j), Name: fmt.Sprintf("Задание %d (синтетика)", j%13), Status: st,
				StartedAt: &s, FinishedAt: &f, Error: errText})
		}
		if _, err := e.svc.IngestJobs(e.ctx, id, r); err != nil {
			return err
		}
	}
	fmt.Printf("  запись 10 000 заданий: %s\n", time.Since(start).Round(time.Millisecond))
	page, err := timeIt(30, func() error { _, err := e.svc.Jobs(e.ctx, id, "", "", 50); return err })
	if err != nil {
		return err
	}
	line("страница заданий (50)", page)
	failed, _ := timeIt(30, func() error { _, err := e.svc.Jobs(e.ctx, id, "failed", "", 50); return err })
	line("фильтр failed", failed)
	p, _ := e.svc.Jobs(e.ctx, id, "", "", 50)
	deep := p.NextBefore
	for i := 0; i < 100 && deep != nil; i++ { // page 101
		p, _ = e.svc.Jobs(e.ctx, id, "", *deep, 50)
		deep = p.NextBefore
	}
	if deep != nil {
		d, _ := timeIt(30, func() error { _, err := e.svc.Jobs(e.ctx, id, "", *deep, 50); return err })
		line("глубокая страница (≈5000-е)", d)
	}
	get, _ := timeIt(30, func() error { _, err := e.svc.Get(e.ctx, id); return err })
	line("страница бота с историей", get)

	start = time.Now()
	now := time.Now().UTC()
	for k := 0; k < 100; k++ {
		var r monitoring.Report
		for i := 0; i < 500; i++ {
			lvl := monitoring.LevelInfo
			if i%10 == 0 {
				lvl = monitoring.LevelError
			}
			r.Logs = append(r.Logs, monitoring.LogIn{At: now, Level: lvl, Source: "bench", Message: fmt.Sprintf("synthetic line %d/%d telegram update", k, i)})
		}
		if _, err := e.mon.Ingest(e.ctx, a, r); err != nil {
			return err
		}
	}
	fmt.Printf("  запись 50 000 строк логов: %s\n", time.Since(start).Round(time.Millisecond))
	lg, _ := timeIt(30, func() error {
		_, err := e.mon.Logs(e.ctx, monitoring.LogFilter{EntityID: id, Limit: 100})
		return err
	})
	line("логи бота (100)", lg)
	le, _ := timeIt(30, func() error {
		_, err := e.mon.Logs(e.ctx, monitoring.LogFilter{EntityID: id, MinLevel: "error", Limit: 100})
		return err
	})
	line("только ошибки", le)
	lq, _ := timeIt(10, func() error {
		_, err := e.mon.Logs(e.ctx, monitoring.LogFilter{EntityID: id, Query: "telegram 99/4", Limit: 100})
		return err
	})
	line("поиск по тексту", lq)
	return nil
}

func concurrency(e *env, list []benchBot) error {
	fmt.Println("\n== Одновременные запросы состояния: 16 клиентов × 25 запросов (50 ботов) ==")
	var mu sync.Mutex
	var lat []time.Duration
	var wg sync.WaitGroup
	var firstErr error
	start := time.Now()
	for c := 0; c < 16; c++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for i := 0; i < 25; i++ {
				t := time.Now()
				var err error
				if i%5 == 0 {
					_, err = e.svc.List(e.ctx, bots.ListFilter{})
				} else {
					_, err = e.svc.Get(e.ctx, list[(c*25+i)%len(list)].id)
				}
				mu.Lock()
				lat = append(lat, time.Since(t))
				if err != nil && firstErr == nil {
					firstErr = err
				}
				mu.Unlock()
			}
		}()
	}
	wg.Wait()
	fmt.Printf("  400 запросов за %s\n", time.Since(start).Round(time.Millisecond))
	line("Get/List параллельно", lat)
	return firstErr
}

// ---- http mode: synthetic bots against a running isolated Core ----

type client struct {
	base, token string
	h           *http.Client
}

func (c *client) do(method, path, token string, body any, out any) (int, error) {
	var rd io.Reader
	if body != nil {
		b, _ := json.Marshal(body)
		rd = bytes.NewReader(b)
	}
	req, _ := http.NewRequest(method, c.base+"/api/v1"+path, rd)
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Content-Type", "application/json")
	res, err := c.h.Do(req)
	if err != nil {
		return 0, err
	}
	defer res.Body.Close()
	if out != nil {
		var env struct{ Data json.RawMessage }
		if err := json.NewDecoder(res.Body).Decode(&env); err == nil {
			_ = json.Unmarshal(env.Data, out)
		}
	} else {
		_, _ = io.Copy(io.Discard, res.Body)
	}
	return res.StatusCode, nil
}

func procStat(pid int) (cpu time.Duration, rss string) {
	b, err := os.ReadFile(fmt.Sprintf("/proc/%d/stat", pid))
	if err == nil {
		i := bytes.LastIndexByte(b, ')')
		f := strings.Fields(string(b[i+1:]))
		u, _ := strconv.ParseFloat(f[11], 64)
		s, _ := strconv.ParseFloat(f[12], 64)
		cpu = time.Duration((u + s) * float64(time.Second) / 100)
	}
	st, _ := os.ReadFile(fmt.Sprintf("/proc/%d/status", pid))
	for _, l := range strings.Split(string(st), "\n") {
		if strings.HasPrefix(l, "VmRSS:") {
			rss = strings.TrimSpace(strings.TrimPrefix(l, "VmRSS:"))
		}
	}
	return
}

func httpBench(base, tokenFile string, pid, n int, dur time.Duration) error {
	raw, err := os.ReadFile(tokenFile)
	if err != nil {
		return err
	}
	c := &client{base: strings.TrimRight(base, "/"), token: strings.TrimSpace(string(raw)), h: &http.Client{Timeout: 10 * time.Second}}
	fmt.Printf("СИНТЕТИКА: %d ботов «(синтетика)» против изолированного Core %s\n", n, base)
	tokens := make([]string, n)
	for i := 0; i < n; i++ {
		var cr struct {
			HeartbeatToken string `json:"heartbeatToken"`
		}
		code, err := c.do("POST", "/bots", c.token, map[string]any{"name": fmt.Sprintf("Бот %d (синтетика)", i), "type": "telegram_bot",
			"category": "bench", "createCredential": true, "tags": []string{"bench"}}, &cr)
		if err != nil || code != 201 {
			return fmt.Errorf("create bot %d: %d %v", i, code, err)
		}
		tokens[i] = cr.HeartbeatToken
	}
	cpu0, rss0 := procStat(pid)
	stop := time.After(dur)
	done := make(chan struct{})
	var mu sync.Mutex
	var hb, list, get []time.Duration
	var wg sync.WaitGroup
	for i := range tokens {
		wg.Add(1)
		go func() { // each bot: heartbeat every 5 s + a job every 10 s
			defer wg.Done()
			if !*burst { // real bots are not synchronized: spread the phase
				select {
				case <-done:
					return
				case <-time.After(time.Duration(i) * 5 * time.Second / time.Duration(len(tokens))):
				}
			}
			t := time.NewTicker(5 * time.Second)
			defer t.Stop()
			k := 0
			for {
				select {
				case <-done:
					return
				case <-t.C:
				}
				now := time.Now().UTC()
				s := time.Now()
				code, _ := c.do("POST", "/monitoring/agent/report", tokens[i], map[string]any{"agent": map[string]any{"version": "bench"},
					"bot": map[string]any{"lastSuccessAt": now, "version": "1.0"}}, nil)
				d := time.Since(s)
				if k%2 == 0 {
					_, _ = c.do("POST", "/bots/agent/jobs", tokens[i], map[string]any{"jobs": []map[string]any{{"id": fmt.Sprint(k), "name": "Задание (синтетика)",
						"status": "success", "startedAt": now.Add(-time.Second), "finishedAt": now}}}, nil)
				}
				k++
				if code == 200 {
					mu.Lock()
					hb = append(hb, d)
					mu.Unlock()
				}
			}
		}()
	}
	var ids []struct {
		EntityID string `json:"entityId"`
	}
	_, _ = c.do("GET", "/bots", c.token, nil, &ids)
	for r := 0; r < 4; r++ { // 4 UI clients polling list + one bot page every 2 s
		wg.Add(1)
		go func() {
			defer wg.Done()
			t := time.NewTicker(2 * time.Second)
			defer t.Stop()
			for i := 0; ; i++ {
				select {
				case <-done:
					return
				case <-t.C:
				}
				s := time.Now()
				_, _ = c.do("GET", "/bots", c.token, nil, nil)
				l := time.Since(s)
				s = time.Now()
				_, _ = c.do("GET", "/bots/"+ids[(i+r)%len(ids)].EntityID, c.token, nil, nil)
				g := time.Since(s)
				mu.Lock()
				list, get = append(list, l), append(get, g)
				mu.Unlock()
			}
		}()
	}
	<-stop
	close(done)
	wg.Wait()
	cpu1, rss1 := procStat(pid)
	fmt.Printf("  длительность %s; CPU Core %.1f %% одного ядра; RSS Core %s → %s\n", dur,
		float64(cpu1-cpu0)/float64(dur)*100, rss0, rss1)
	line("heartbeat POST", hb)
	line("GET /bots (весь список)", list)
	line("GET /bots/{id}", get)
	return nil
}
