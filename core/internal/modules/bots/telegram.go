package bots

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"os"
	"strings"
	"time"

	"aerhome/core/internal/foundation/config"
	"aerhome/core/internal/modules/monitoring"
)

// telegramAdapter: Telegram bots are watched through their heartbeat
// (no token needed). Only the optional connection check calls getMe, and
// only with a token file declared in config; the token never leaves Core
// and never appears in logs or errors.
type telegramAdapter struct {
	s      *Service
	client *http.Client
}

func newTelegramAdapter(s *Service) *telegramAdapter {
	return &telegramAdapter{s: s, client: &http.Client{Timeout: 10 * time.Second,
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}}
}

func (a *telegramAdapter) Info(cfg config.Bots) AdapterInfo {
	inst := []AdapterInstance{}
	for _, t := range cfg.TelegramTokens {
		inst = append(inst, AdapterInstance{ID: t.ID, Label: t.ID, Target: "файл токена на сервере"})
	}
	return AdapterInfo{ID: "telegram", Label: "Telegram", Status: "ok",
		Description:  "Heartbeat, ошибки API Telegram и задания — без токена; проверка getMe — только с объявленным файлом токена",
		Capabilities: []string{"monitor", "logs", "jobs", "check"}, Instances: inst}
}

func (a *telegramAdapter) Check(ctx context.Context, b *Bot) (CheckResult, bool) {
	if b.Type != "telegram_bot" && b.Runtime != "telegram" {
		return CheckResult{}, false
	}
	if b.TelegramTokenID == "" {
		return CheckResult{}, false
	}
	tok, ok := a.s.cfg.TelegramTokenByID(b.TelegramTokenID)
	if !ok {
		return CheckResult{Message: "Файл токена «" + b.TelegramTokenID + "» не объявлен в конфигурации Core"}, true
	}
	raw, err := os.ReadFile(tok.File)
	if err != nil {
		return CheckResult{Message: "Файл токена недоступен (права или путь)"}, true
	}
	token := strings.TrimSpace(string(raw))
	req, _ := http.NewRequestWithContext(ctx, http.MethodGet, strings.TrimRight(a.s.cfg.TelegramAPIBase, "/")+"/bot"+token+"/getMe", nil)
	resp, err := a.client.Do(req)
	now := a.s.now().UTC()
	okv := 0.0
	defer func() {
		_ = a.s.mon.StoreSamples(context.WithoutCancel(ctx), b.EntityID, "core.bots/telegram",
			[]monitoring.SampleIn{{Metric: "bot.api_ok", Value: &okv, At: now, Quality: monitoring.QualityOK}})
	}()
	if err != nil {
		// The error text contains the URL with the token: never use it.
		return CheckResult{Message: "API Telegram не отвечает (" + netKind(err) + ")"}, true
	}
	defer resp.Body.Close()
	var body struct {
		OK          bool   `json:"ok"`
		Description string `json:"description"`
		Result      struct {
			Username string `json:"username"`
		} `json:"result"`
	}
	_ = json.NewDecoder(io.LimitReader(resp.Body, 64<<10)).Decode(&body)
	if !body.OK {
		return CheckResult{Message: "API Telegram: " + monitoring.Redact(body.Description) + " (HTTP " + http.StatusText(resp.StatusCode) + ")"}, true
	}
	okv = 1
	return CheckResult{OK: true, Message: "API Telegram отвечает, бот @" + body.Result.Username}, true
}

func netKind(err error) string {
	s := err.Error()
	switch {
	case strings.Contains(s, "timeout"), strings.Contains(s, "deadline"):
		return "тайм-аут"
	case strings.Contains(s, "no such host"):
		return "DNS"
	case strings.Contains(s, "refused"):
		return "соединение отклонено"
	}
	return "сетевая ошибка"
}
