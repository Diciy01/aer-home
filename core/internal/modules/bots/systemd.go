package bots

import (
	"bufio"
	"bytes"
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"time"

	"aerhome/core/internal/foundation/config"
	"aerhome/core/internal/modules/monitoring"
)

// systemdAdapter manages one user unit per controller through
// `systemctl --user` with a fixed argv: the unit name comes from config
// (validated), never from a request. System units are out of scope.
type systemdAdapter struct {
	s   *Service
	run func(ctx context.Context, args ...string) ([]byte, error)
}

func newSystemdAdapter(s *Service) *systemdAdapter {
	return &systemdAdapter{s: s, run: func(ctx context.Context, args ...string) ([]byte, error) {
		cmd := exec.CommandContext(ctx, "systemctl", append([]string{"--user", "--no-pager"}, args...)...)
		cmd.Env = minimalEnvWith("XDG_RUNTIME_DIR", "DBUS_SESSION_BUS_ADDRESS")
		var out bytes.Buffer
		cmd.Stdout, cmd.Stderr = &out, &out
		err := cmd.Run()
		return out.Bytes(), err
	}}
}

func minimalEnvWith(keys ...string) []string {
	env := minimalEnv()
	for _, k := range keys {
		if v, ok := os.LookupEnv(k); ok {
			env = append(env, k+"="+v)
		}
	}
	return env
}

func (a *systemdAdapter) Kind() string { return "systemd_user" }

func (a *systemdAdapter) Info(cfg config.Bots) AdapterInfo {
	inst := controllerInstances(cfg, "systemd_user")
	st, reason := instancesStatus(len(inst), "пользовательского юнита systemd")
	return AdapterInfo{ID: "systemd_user", Label: "Служба systemd (пользовательская)", Status: st, Reason: reason,
		Description:  "systemctl --user start/stop/restart для объявленного юнита; системные службы не затрагиваются",
		Capabilities: []string{"control", "monitor"}, Instances: inst}
}

func (a *systemdAdapter) Control(ctx context.Context, ctl config.BotController, entityID, action string) (string, error) {
	out, err := a.run(ctx, action, ctl.Unit)
	if err != nil {
		return "", fmt.Errorf("systemctl --user %s %s: %s", action, ctl.Unit, firstLine(out, err))
	}
	st := a.State(ctx, ctl)
	kind := map[string]string{"start": "bot_started", "stop": "bot_stopped", "restart": "bot_restarted"}[action]
	a.s.mon.RecordEvent(context.WithoutCancel(ctx), entityID, kind, monitoring.SeverityInfo,
		fmt.Sprintf("Юнит %s: %s по команде владельца, сейчас %s", ctl.Unit, action, st.State))
	return "Юнит " + ctl.Unit + ": " + st.State, nil
}

func (a *systemdAdapter) State(ctx context.Context, ctl config.BotController) RuntimeState {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	out, err := a.run(ctx, "show", "--property=ActiveState,SubState,MainPID,ActiveEnterTimestampMonotonic,LoadState", ctl.Unit)
	if err != nil {
		return RuntimeState{Adapter: "systemd_user", State: "unavailable", Reason: "systemctl --user недоступен: " + firstLine(out, err)}
	}
	p := map[string]string{}
	sc := bufio.NewScanner(bytes.NewReader(out))
	for sc.Scan() {
		if k, v, ok := strings.Cut(sc.Text(), "="); ok {
			p[k] = v
		}
	}
	if p["LoadState"] == "not-found" {
		return RuntimeState{Adapter: "systemd_user", State: "unavailable", Reason: "Юнит " + ctl.Unit + " не найден"}
	}
	st := RuntimeState{Adapter: "systemd_user", Reason: "ActiveState=" + p["ActiveState"] + ", SubState=" + p["SubState"]}
	switch p["ActiveState"] {
	case "active", "reloading":
		st.State = "running"
	case "activating":
		st.State = "starting"
	case "inactive", "failed", "deactivating":
		st.State = "stopped"
	default:
		st.State = "unknown"
	}
	fmt.Sscan(p["MainPID"], &st.PID)
	return st
}

func firstLine(out []byte, err error) string {
	s := strings.TrimSpace(string(out))
	if i := strings.IndexByte(s, '\n'); i > 0 {
		s = s[:i]
	}
	if s == "" && err != nil {
		var ee *exec.Error
		if errors.As(err, &ee) {
			return "команда systemctl не найдена"
		}
		s = err.Error()
	}
	return monitoring.Redact(s)
}
