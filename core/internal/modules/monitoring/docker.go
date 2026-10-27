package monitoring

import (
	"bufio"
	"context"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"net"
	"net/http"
	"net/url"
	"os"
	"strings"
	"sync"
	"syscall"
	"time"

	"aerhome/core/internal/modules/registry"
)

// DockerWatcher observes the local Docker Engine read-only through its
// socket: list, inspect, stats and the tail of logs on failures. It never
// starts, stops or recreates containers and never exposes the API.
type DockerWatcher struct {
	s      *Service
	client *http.Client

	mu         sync.Mutex
	available  bool
	reason     string
	everOK     bool
	containers map[string]Container // by name
	lastStats  time.Time
	netPrev    map[string]netSample
}

type netSample struct {
	at     time.Time
	rx, tx float64
}

func newDockerWatcher(s *Service) *DockerWatcher {
	sock := s.cfg.Docker.Socket
	tr := &http.Transport{
		DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
			var d net.Dialer
			return d.DialContext(ctx, "unix", sock)
		},
		MaxIdleConns: 2,
	}
	return &DockerWatcher{s: s, client: &http.Client{Transport: tr, Timeout: 15 * time.Second},
		containers: map[string]Container{}, netPrev: map[string]netSample{}}
}

func (d *DockerWatcher) get(ctx context.Context, path string, out any) error {
	req, _ := http.NewRequestWithContext(ctx, http.MethodGet, "http://docker/v1.41"+path, nil)
	resp, err := d.client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("docker API %s: HTTP %d", strings.SplitN(path, "?", 2)[0], resp.StatusCode)
	}
	if out == nil {
		return nil
	}
	return json.NewDecoder(io.LimitReader(resp.Body, 8<<20)).Decode(out)
}

func dockerReason(err error, sock string) string {
	switch {
	case errors.Is(err, fs.ErrNotExist), errors.Is(err, syscall.ENOENT):
		return "Сокет " + sock + " не найден: служба Docker не запущена или не установлена"
	case errors.Is(err, fs.ErrPermission), errors.Is(err, syscall.EACCES):
		return "Нет прав на " + sock + " (нужно членство в группе docker); AER HOME права не меняет"
	case errors.Is(err, syscall.ECONNREFUSED):
		return "Docker не принимает подключения через " + sock
	}
	return "Docker недоступен: " + truncate(Redact(err.Error()), 160)
}

type apiContainer struct {
	ID     string   `json:"Id"`
	Names  []string `json:"Names"`
	Image  string   `json:"Image"`
	State  string   `json:"State"`
	Status string   `json:"Status"`
}

type apiInspect struct {
	RestartCount int `json:"RestartCount"`
	State        struct {
		Status     string `json:"Status"`
		OOMKilled  bool   `json:"OOMKilled"`
		ExitCode   int    `json:"ExitCode"`
		Error      string `json:"Error"`
		StartedAt  string `json:"StartedAt"`
		FinishedAt string `json:"FinishedAt"`
		Health     *struct {
			Status string `json:"Status"`
		} `json:"Health"`
	} `json:"State"`
}

func parseDockerTime(s string) *time.Time {
	t, err := time.Parse(time.RFC3339Nano, s)
	if err != nil || t.Year() < 2000 {
		return nil
	}
	t = t.UTC()
	return &t
}

// Poll refreshes containers, detects state changes and records them.
func (d *DockerWatcher) Poll(ctx context.Context) {
	ctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	sock := d.s.cfg.Docker.Socket
	if _, err := os.Stat(sock); err != nil {
		d.setAvailable(ctx, false, dockerReason(err, sock))
		return
	}
	var list []apiContainer
	if err := d.get(ctx, "/containers/json?all=1", &list); err != nil {
		d.setAvailable(ctx, false, dockerReason(err, sock))
		return
	}
	d.setAvailable(ctx, true, fmt.Sprintf("%d контейнеров", len(list)))
	bound := d.boundEntities(ctx)
	now := d.s.now().UTC()
	doStats := now.Sub(d.lastStats) >= time.Duration(d.s.cfg.Docker.StatsIntervalSec)*time.Second
	if doStats {
		d.lastStats = now
	}
	seen := map[string]bool{}
	for _, c := range list {
		name := strings.TrimPrefix(firstOr(c.Names, c.ID[:min(12, len(c.ID))]), "/")
		seen[name] = true
		var in apiInspect
		if err := d.get(ctx, "/containers/"+url.PathEscape(c.ID)+"/json", &in); err != nil {
			continue
		}
		cur := Container{ID: c.ID, Name: name, Image: c.Image, State: in.State.Status, RestartCount: in.RestartCount,
			StartedAt: parseDockerTime(in.State.StartedAt), FinishedAt: parseDockerTime(in.State.FinishedAt),
			OOMKilled: in.State.OOMKilled, Error: truncate(Redact(in.State.Error), 300), ChangedAt: now}
		if in.State.Health != nil {
			cur.Health = in.State.Health.Status
		}
		if cur.State != "running" {
			code := in.State.ExitCode
			cur.ExitCode = &code
		}
		if e, ok := bound[name]; ok {
			cur.EntityID = strPtr(e.ID)
		}
		d.mu.Lock()
		prev, known := d.containers[name]
		d.mu.Unlock()
		if known {
			cur.CPUPercent, cur.MemBytes, cur.LastErrors = prev.CPUPercent, prev.MemBytes, prev.LastErrors
			if prev.State == cur.State && prev.Health == cur.Health {
				cur.ChangedAt = prev.ChangedAt
			}
		}
		if doStats && cur.State == "running" {
			d.stats(ctx, &cur, now)
		}
		if known && (prev.State != cur.State || prev.Health != cur.Health) {
			d.transition(ctx, prev, &cur)
		}
		d.mu.Lock()
		d.containers[name] = cur
		d.mu.Unlock()
		data, _ := json.Marshal(cur)
		_, _ = d.s.db.ExecContext(ctx, `INSERT INTO mon_containers (id, name, data, changed_at, seen_at) VALUES (?,?,?,?,?)
			ON CONFLICT (id) DO UPDATE SET name = excluded.name, data = excluded.data, changed_at = excluded.changed_at, seen_at = excluded.seen_at`,
			c.ID, name, string(data), ms(cur.ChangedAt), ms(now))
		if cur.EntityID != nil {
			d.s.RefreshEntity(ctx, *cur.EntityID)
		}
	}
	d.mu.Lock()
	for name := range d.containers {
		if !seen[name] {
			delete(d.containers, name)
		}
	}
	d.mu.Unlock()
}

func firstOr(xs []string, def string) string {
	if len(xs) > 0 {
		return xs[0]
	}
	return def
}

func (d *DockerWatcher) setAvailable(ctx context.Context, ok bool, reason string) {
	d.mu.Lock()
	was, ever := d.available, d.everOK
	d.available, d.reason = ok, reason
	if ok {
		d.everOK = true
	}
	d.mu.Unlock()
	st := IntegrationStatus{ID: "docker", Label: "Docker", Status: "ok", Reason: reason}
	if !ok {
		st.Status = "unavailable"
	}
	d.s.setIntegration(st)
	switch {
	case !ok && was && ever:
		d.s.openIncident(ctx, incidentSpec{key: "integration:docker", title: "Core потерял связь с Docker", source: "integration/docker",
			severity: SeverityWarning, message: reason})
	case ok && !was && ever:
		d.s.resolveIncident(ctx, "integration:docker", "Связь с Docker восстановлена")
	}
}

// boundEntities maps container names to Registry docker_container entities.
func (d *DockerWatcher) boundEntities(ctx context.Context) map[string]registry.Entity {
	out := map[string]registry.Entity{}
	p, err := d.s.reg.List(ctx, registry.ListFilter{Types: []string{"docker_container"}, Limit: 200})
	if err != nil {
		return out
	}
	for _, e := range p.Items {
		name := settingsOf(e).Container
		if name == "" {
			name = e.Name
		}
		out[name] = e
	}
	return out
}

func (d *DockerWatcher) transition(ctx context.Context, prev Container, cur *Container) {
	msg := fmt.Sprintf("Контейнер %s: %s → %s", cur.Name, prev.State, cur.State)
	cause := ""
	if cur.State != "running" && cur.ExitCode != nil {
		msg += fmt.Sprintf(", код завершения %d", *cur.ExitCode)
		cause = fmt.Sprintf("Docker: код завершения %d", *cur.ExitCode)
		if cur.OOMKilled {
			cause += ", остановлен из-за нехватки памяти (OOMKilled)"
		}
		if cur.Error != "" {
			cause += ", " + cur.Error
		}
		cur.LastErrors = d.tailErrors(ctx, cur.ID)
	}
	if cur.Health != "" && cur.Health != prev.Health {
		msg += ", health: " + cur.Health
	}
	sev := SeverityInfo
	if cur.State != "running" {
		sev = SeverityWarning
	}
	d.s.event(ctx, cur.EntityID, "container_state", sev, msg, nil)
	lvl := LevelInfo
	if sev == SeverityWarning {
		lvl = LevelWarning
	}
	_, _ = d.s.db.ExecContext(ctx, `INSERT INTO mon_logs (ts, entity_id, source, level, message) VALUES (?,?,?,?,?)`,
		ms(d.s.now()), nullStr(cur.EntityID), "docker:"+cur.Name, levelNum[lvl], truncate(msg, 2000))
	for _, line := range cur.LastErrors {
		_, _ = d.s.db.ExecContext(ctx, `INSERT INTO mon_logs (ts, entity_id, source, level, message) VALUES (?,?,?,?,?)`,
			ms(d.s.now()), nullStr(cur.EntityID), "docker:"+cur.Name+"/stderr", levelNum[LevelWarning], cleanMessage(line))
	}
	if cur.EntityID != nil {
		return // bound containers: the availability incident carries this
	}
	key := "container:" + cur.Name
	if cur.State == "running" && (cur.Health == "" || cur.Health == "healthy") {
		d.s.resolveIncident(ctx, key, "Контейнер снова работает")
		return
	}
	if cur.State == "exited" || cur.State == "dead" || cur.Health == "unhealthy" {
		d.s.openIncident(ctx, incidentSpec{key: key, title: "Контейнер " + cur.Name + " остановлен", source: "integration/docker",
			severity: SeverityWarning, cause: cause, message: msg})
	}
}

// tailErrors reads the last stderr lines of a stopped container.
func (d *DockerWatcher) tailErrors(ctx context.Context, id string) []string {
	req, _ := http.NewRequestWithContext(ctx, http.MethodGet, "http://docker/v1.41/containers/"+url.PathEscape(id)+"/logs?stderr=1&stdout=0&tail=10", nil)
	resp, err := d.client.Do(req)
	if err != nil {
		return nil
	}
	defer resp.Body.Close()
	return demuxLines(io.LimitReader(resp.Body, 64<<10), 10)
}

// demuxLines reads Docker's multiplexed log stream (8-byte frame headers);
// a TTY container sends plain text, which is handled too.
func demuxLines(r io.Reader, max int) []string {
	br := bufio.NewReader(r)
	var text strings.Builder
	head, err := br.Peek(8)
	if err == nil && (head[0] == 1 || head[0] == 2) && head[1] == 0 && head[2] == 0 && head[3] == 0 {
		for {
			var h [8]byte
			if _, err := io.ReadFull(br, h[:]); err != nil {
				break
			}
			n := binary.BigEndian.Uint32(h[4:])
			if _, err := io.CopyN(&text, br, int64(n)); err != nil {
				break
			}
		}
	} else {
		_, _ = io.Copy(&text, br)
	}
	var out []string
	for _, l := range strings.Split(text.String(), "\n") {
		if l = strings.TrimSpace(l); l != "" {
			out = append(out, truncate(Redact(l), 500))
		}
	}
	if len(out) > max {
		out = out[len(out)-max:]
	}
	return out
}

type apiStats struct {
	CPU struct {
		Usage struct {
			Total float64 `json:"total_usage"`
		} `json:"cpu_usage"`
		System float64 `json:"system_cpu_usage"`
		Online float64 `json:"online_cpus"`
	} `json:"cpu_stats"`
	PreCPU struct {
		Usage struct {
			Total float64 `json:"total_usage"`
		} `json:"cpu_usage"`
		System float64 `json:"system_cpu_usage"`
	} `json:"precpu_stats"`
	Memory struct {
		Usage float64            `json:"usage"`
		Stats map[string]float64 `json:"stats"`
	} `json:"memory_stats"`
	Networks map[string]struct {
		RX float64 `json:"rx_bytes"`
		TX float64 `json:"tx_bytes"`
	} `json:"networks"`
}

func (d *DockerWatcher) stats(ctx context.Context, c *Container, now time.Time) {
	var st apiStats
	if err := d.get(ctx, "/containers/"+url.PathEscape(c.ID)+"/stats?stream=false", &st); err != nil {
		return
	}
	var samples []SampleIn
	if dc, ds := st.CPU.Usage.Total-st.PreCPU.Usage.Total, st.CPU.System-st.PreCPU.System; dc >= 0 && ds > 0 {
		online := st.CPU.Online
		if online == 0 {
			online = 1
		}
		v := dc / ds * online * 100
		c.CPUPercent = &v
		samples = append(samples, SampleIn{Metric: "docker.cpu_percent", Value: &v, At: now, Quality: QualityOK})
	}
	mem := st.Memory.Usage - st.Memory.Stats["inactive_file"]
	if mem > 0 {
		c.MemBytes = &mem
		samples = append(samples, SampleIn{Metric: "docker.mem_bytes", Value: &mem, At: now, Quality: QualityOK})
	}
	var rx, tx float64
	for _, n := range st.Networks {
		rx += n.RX
		tx += n.TX
	}
	if p, ok := d.netPrev[c.ID]; ok && now.After(p.at) && rx >= p.rx && tx >= p.tx {
		sec := now.Sub(p.at).Seconds()
		r, t := (rx-p.rx)/sec, (tx-p.tx)/sec
		samples = append(samples, SampleIn{Metric: "docker.net_rx_rate", Value: &r, At: now, Quality: QualityOK},
			SampleIn{Metric: "docker.net_tx_rate", Value: &t, At: now, Quality: QualityOK})
	}
	d.netPrev[c.ID] = netSample{at: now, rx: rx, tx: tx}
	if c.EntityID != nil && len(samples) > 0 {
		_ = d.s.storeSamples(ctx, *c.EntityID, "docker", samples)
	}
}

// observe gives the availability of a Docker-backed Registry entity.
func (d *DockerWatcher) observe(name string) observation {
	if !d.s.cfg.Docker.Enabled {
		return observation{status: StatusUnknown, kind: "docker", reason: "Интеграция Docker выключена в конфигурации"}
	}
	d.mu.Lock()
	ok, reason, c, found := d.available, d.reason, Container{}, false
	if ok {
		c, found = d.containers[name]
	}
	d.mu.Unlock()
	switch {
	case !ok && reason == "":
		return observation{status: StatusUnknown, kind: "docker", reason: "Docker ещё не опрошен"}
	case !ok:
		return observation{status: StatusUnknown, kind: "docker", reason: reason}
	case !found:
		return observation{status: StatusUnknown, kind: "docker", reason: "Контейнер «" + name + "» не найден в Docker"}
	}
	now := d.s.now().UTC()
	switch {
	case c.State == "running" && c.Health == "unhealthy":
		return observation{status: StatusDegraded, kind: "docker", reachable: true, contact: &now, reason: "Работает, но health-check: unhealthy"}
	case c.State == "running":
		return observation{status: StatusOnline, kind: "docker", reachable: true, contact: &now, reason: "Работает (" + c.Image + ")"}
	case c.State == "restarting" || c.State == "paused":
		return observation{status: StatusDegraded, kind: "docker", reachable: true, contact: &now, reason: "Состояние: " + c.State}
	}
	cause := ""
	if c.ExitCode != nil {
		cause = fmt.Sprintf("Docker: код завершения %d", *c.ExitCode)
		if c.OOMKilled {
			cause += " (OOMKilled)"
		}
	}
	return observation{failure: true, kind: "docker", reachable: true, cause: cause, reason: "Контейнер в состоянии " + c.State}
}

// Containers returns the last known containers and whether Docker answers now.
func (s *Service) Containers(ctx context.Context) ([]Container, IntegrationStatus, error) {
	rows, err := s.db.QueryContext(ctx, `SELECT data FROM mon_containers ORDER BY name`)
	if err != nil {
		return nil, IntegrationStatus{}, err
	}
	defer rows.Close()
	out := []Container{}
	for rows.Next() {
		var raw string
		if rows.Scan(&raw) != nil {
			continue
		}
		var c Container
		if json.Unmarshal([]byte(raw), &c) == nil {
			if c.LastErrors == nil {
				c.LastErrors = []string{}
			}
			out = append(out, c)
		}
	}
	s.mu.Lock()
	st := s.integrations["docker"]
	s.mu.Unlock()
	if st.ID == "" {
		st = IntegrationStatus{ID: "docker", Label: "Docker", Status: "unavailable", Reason: "Docker ещё не опрошен"}
	}
	return out, st, rows.Err()
}
