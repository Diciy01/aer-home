package bots

import (
	"context"
	"path/filepath"
	"strings"

	"aerhome/core/internal/foundation/config"
)

// Adapters are pluggable integration kinds. Every adapter describes itself;
// the optional interfaces below add management, checks, sync and retry.
// A new runtime (another language, another supervisor) is a new adapter,
// not a change in the service.
type Adapter interface {
	Info(cfg config.Bots) AdapterInfo
}

// Controller manages one declared controller (process, unit, container).
type Controller interface {
	Adapter
	Kind() string
	// Control runs start, stop or restart. entityID is the bot it belongs to.
	Control(ctx context.Context, ctl config.BotController, entityID, action string) (string, error)
	State(ctx context.Context, ctl config.BotController) RuntimeState
}

// Checker verifies the connection of a bot through an integration.
type Checker interface {
	Check(ctx context.Context, b *Bot) (CheckResult, bool)
}

// Syncer pulls data periodically (n8n executions, process metrics).
type Syncer interface {
	Sync(ctx context.Context)
}

// Retrier re-runs a finished job.
type Retrier interface {
	CanRetry(b *Bot, j Job) (bool, string)
	Retry(ctx context.Context, b *Bot, j Job, idempotencyKey string) (string, error)
}

// CheckResult of a connection check.
type CheckResult struct {
	OK      bool
	Message string
}

// heartbeatAdapter is monitoring-only: the bot reports itself through the
// agent protocol (tools/bot-heartbeat). It never controls anything.
type heartbeatAdapter struct{}

func (heartbeatAdapter) Info(config.Bots) AdapterInfo {
	return AdapterInfo{ID: "heartbeat", Label: "Heartbeat", Status: "ok",
		Description:  "Бот сам сообщает «я жив», ошибки и задания (Python-библиотека aer_heartbeat или любой HTTP-клиент)",
		Capabilities: []string{"monitor", "logs", "jobs"}, Instances: []AdapterInstance{}}
}

func controllerInstances(cfg config.Bots, kind string) []AdapterInstance {
	out := []AdapterInstance{}
	for _, c := range cfg.Controllers {
		if c.Kind != kind {
			continue
		}
		target := c.Unit + c.Container
		if kind == "process" && len(c.Command) > 0 {
			// Only the program name: full paths stay on the server.
			target = filepath.Base(c.Command[0])
			if len(c.Command) > 1 {
				target += " " + filepath.Base(c.Command[1])
			}
		}
		label := c.Label
		if label == "" {
			label = c.ID
		}
		out = append(out, AdapterInstance{ID: c.ID, Label: label, Target: target, Allow: append([]string{}, c.Allow...)})
	}
	return out
}

func instancesStatus(n int, what string) (string, string) {
	if n == 0 {
		return "disabled", "Не объявлено ни одного " + what + " в разделе bots конфигурации Core"
	}
	return "ok", ""
}

func joinNonEmpty(sep string, xs ...string) string {
	var out []string
	for _, x := range xs {
		if strings.TrimSpace(x) != "" {
			out = append(out, x)
		}
	}
	return strings.Join(out, sep)
}
