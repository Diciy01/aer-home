package bots

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"net"
	"net/http"
	"net/url"
	"os"
	"syscall"
	"time"

	"aerhome/core/internal/foundation/config"
	"aerhome/core/internal/modules/monitoring"
)

// dockerAdapter starts, stops and restarts exactly the containers declared
// as controllers, through the local socket. Monitoring keeps its own
// read-only watcher; this adapter is the only writer (ADR-012).
type dockerAdapter struct {
	s      *Service
	sock   string
	client *http.Client
}

func newDockerAdapter(s *Service) *dockerAdapter {
	sock := s.cfg.DockerSocket
	tr := &http.Transport{DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
		var d net.Dialer
		return d.DialContext(ctx, "unix", sock)
	}, MaxIdleConns: 1}
	return &dockerAdapter{s: s, sock: sock, client: &http.Client{Transport: tr, Timeout: 60 * time.Second}}
}

func (a *dockerAdapter) Kind() string { return "docker" }

func (a *dockerAdapter) Info(cfg config.Bots) AdapterInfo {
	inst := controllerInstances(cfg, "docker")
	st, reason := instancesStatus(len(inst), "контейнера")
	if st == "ok" {
		if err := a.available(); err != nil {
			st, reason = "unavailable", a.reason(err)
		}
	}
	return AdapterInfo{ID: "docker", Label: "Docker-контейнер", Status: st, Reason: reason,
		Description:  "Старт/стоп/перезапуск объявленного контейнера через локальный сокет Docker; состояние и логи — из Мониторинга",
		Capabilities: []string{"control", "monitor", "logs"}, Instances: inst}
}

func (a *dockerAdapter) available() error {
	_, err := os.Stat(a.sock)
	return err
}

func (a *dockerAdapter) reason(err error) string {
	switch {
	case errors.Is(err, fs.ErrNotExist), errors.Is(err, syscall.ENOENT):
		return "Сокет " + a.sock + " не найден: Docker не запущен или не установлен (AER HOME его не устанавливает)"
	case errors.Is(err, fs.ErrPermission), errors.Is(err, syscall.EACCES):
		return "Нет прав на " + a.sock + " (нужна группа docker); AER HOME права не меняет"
	case errors.Is(err, syscall.ECONNREFUSED):
		return "Docker не принимает подключения"
	}
	return "Docker недоступен: " + monitoring.Redact(err.Error())
}

func (a *dockerAdapter) do(ctx context.Context, method, path string, out any) (int, error) {
	req, _ := http.NewRequestWithContext(ctx, method, "http://docker/v1.41"+path, nil)
	resp, err := a.client.Do(req)
	if err != nil {
		return 0, err
	}
	defer resp.Body.Close()
	if out != nil && resp.StatusCode == http.StatusOK {
		return resp.StatusCode, json.NewDecoder(io.LimitReader(resp.Body, 1<<20)).Decode(out)
	}
	var e struct {
		Message string `json:"message"`
	}
	_ = json.NewDecoder(io.LimitReader(resp.Body, 64<<10)).Decode(&e)
	if resp.StatusCode >= 300 && resp.StatusCode != http.StatusNotModified {
		return resp.StatusCode, fmt.Errorf("Docker API HTTP %d: %s", resp.StatusCode, monitoring.Redact(e.Message))
	}
	return resp.StatusCode, nil
}

func (a *dockerAdapter) Control(ctx context.Context, ctl config.BotController, entityID, action string) (string, error) {
	if err := a.available(); err != nil {
		return "", errors.New(a.reason(err))
	}
	path := "/containers/" + url.PathEscape(ctl.Container) + "/" + action
	if action != "start" {
		path += "?t=10"
	}
	code, err := a.do(ctx, http.MethodPost, path, nil)
	if code == http.StatusNotFound {
		return "", fmt.Errorf("контейнер %s не найден", ctl.Container)
	}
	if err != nil {
		return "", errors.New(a.reason(err))
	}
	msg := "Контейнер " + ctl.Container + ": " + map[string]string{"start": "запущен", "stop": "остановлен", "restart": "перезапущен"}[action]
	if code == http.StatusNotModified {
		msg = "Контейнер " + ctl.Container + " уже в нужном состоянии"
	}
	kind := map[string]string{"start": "bot_started", "stop": "bot_stopped", "restart": "bot_restarted"}[action]
	a.s.mon.RecordEvent(context.WithoutCancel(ctx), entityID, kind, monitoring.SeverityInfo, msg+" (команда владельца)")
	return msg, nil
}

func (a *dockerAdapter) State(ctx context.Context, ctl config.BotController) RuntimeState {
	if err := a.available(); err != nil {
		return RuntimeState{Adapter: "docker", State: "unavailable", Reason: a.reason(err)}
	}
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	var in struct {
		State struct {
			Status    string `json:"Status"`
			Pid       int    `json:"Pid"`
			StartedAt string `json:"StartedAt"`
		} `json:"State"`
	}
	code, err := a.do(ctx, http.MethodGet, "/containers/"+url.PathEscape(ctl.Container)+"/json", &in)
	if code == http.StatusNotFound {
		return RuntimeState{Adapter: "docker", State: "unavailable", Reason: "Контейнер " + ctl.Container + " не найден"}
	}
	if err != nil {
		return RuntimeState{Adapter: "docker", State: "unavailable", Reason: a.reason(err)}
	}
	st := RuntimeState{Adapter: "docker", PID: in.State.Pid, Reason: "Docker: " + in.State.Status}
	switch in.State.Status {
	case "running":
		st.State = "running"
		if t, err := time.Parse(time.RFC3339Nano, in.State.StartedAt); err == nil && t.Year() > 2000 {
			t = t.UTC()
			st.Since = &t
		}
	case "restarting", "created":
		st.State = "starting"
	case "exited", "dead", "paused":
		st.State = "stopped"
	default:
		st.State = "unknown"
	}
	return st
}
