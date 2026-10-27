package monitoring

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"strings"
	"time"

	"aerhome/core/internal/foundation/ids"
)

// Notifier writes in-app notifications and, only when explicitly enabled,
// forwards them to Telegram. One notification per incident open/recovery —
// never per measurement; pending Telegram messages are grouped per dispatch.
type Notifier struct {
	s      *Service
	client *http.Client
}

func newNotifier(s *Service) *Notifier {
	return &Notifier{s: s, client: &http.Client{Timeout: 10 * time.Second}}
}

func (n *Notifier) telegramState(sev Severity) string {
	tg := n.s.cfg.Telegram
	switch {
	case !tg.Enabled:
		return "disabled"
	case severityRank[sev] < severityRank[Severity(tg.MinSeverity)] && sev != SeverityInfo:
		return "skipped"
	case sev == SeverityInfo && !n.s.cfg.NotifyRecovery:
		return "skipped"
	}
	return "pending"
}

func (n *Notifier) describe() {
	tg := n.s.cfg.Telegram
	if !tg.Enabled {
		n.s.setIntegration(IntegrationStatus{ID: "telegram", Label: "Уведомления в Telegram", Status: "disabled",
			Reason: "Выключено: включите monitoring.telegram в конфигурации Core (нужны файл с токеном бота и chatId)"})
		return
	}
	if _, err := os.Stat(tg.BotTokenFile); err != nil {
		n.s.setIntegration(IntegrationStatus{ID: "telegram", Label: "Уведомления в Telegram", Status: "unavailable",
			Reason: "Файл с токеном бота не найден"})
		return
	}
	n.s.setIntegration(IntegrationStatus{ID: "telegram", Label: "Уведомления в Telegram", Status: "ok", Reason: "Включено"})
}

func (n *Notifier) create(ctx context.Context, kind string, sev Severity, title, body string, entityID, incidentID *string) {
	_, err := n.s.db.ExecContext(ctx, `INSERT INTO mon_notifications (id, ts, kind, severity, title, body, entity_id, incident_id, telegram)
		VALUES (?,?,?,?,?,?,?,?,?)`, ids.New(), ms(n.s.now()), kind, string(sev), truncate(title, 200), truncate(Redact(body), 1000),
		nullStr(entityID), nullStr(incidentID), n.telegramState(sev))
	if err != nil {
		n.s.log.Warn("notification insert", "err", err)
	}
}

// Dispatch sends pending Telegram notifications as one grouped message.
func (n *Notifier) Dispatch(ctx context.Context) {
	tg := n.s.cfg.Telegram
	if !tg.Enabled {
		return
	}
	rows, err := n.s.db.QueryContext(ctx, `SELECT id, severity, title FROM mon_notifications WHERE telegram = 'pending' ORDER BY ts LIMIT 50`)
	if err != nil {
		return
	}
	var idsList []string
	var lines []string
	for rows.Next() {
		var id, sev, title string
		if rows.Scan(&id, &sev, &title) == nil {
			idsList = append(idsList, id)
			mark := "•"
			switch Severity(sev) {
			case SeverityCritical:
				mark = "🔴"
			case SeverityWarning:
				mark = "🟠"
			case SeverityInfo:
				mark = "🟢"
			}
			lines = append(lines, mark+" "+title)
		}
	}
	rows.Close()
	if len(idsList) == 0 {
		return
	}
	text := "AER HOME\n" + strings.Join(lines, "\n")
	if len(lines) > 1 {
		text = fmt.Sprintf("AER HOME: %d событий\n", len(lines)) + strings.Join(lines, "\n")
	}
	status := "sent"
	if err := n.sendTelegram(ctx, text); err != nil {
		// Never log the URL: it contains the bot token.
		n.s.log.Warn("telegram send failed", "err", Redact(err.Error()))
		status = "failed"
		n.s.setIntegration(IntegrationStatus{ID: "telegram", Label: "Уведомления в Telegram", Status: "unavailable", Reason: "Ошибка отправки"})
	} else {
		n.s.setIntegration(IntegrationStatus{ID: "telegram", Label: "Уведомления в Telegram", Status: "ok", Reason: "Последняя отправка успешна"})
	}
	for _, id := range idsList {
		_, _ = n.s.db.ExecContext(ctx, `UPDATE mon_notifications SET telegram = ? WHERE id = ?`, status, id)
	}
}

func (n *Notifier) sendTelegram(ctx context.Context, text string) error {
	tg := n.s.cfg.Telegram
	raw, err := os.ReadFile(tg.BotTokenFile)
	if err != nil {
		return fmt.Errorf("read token file: %w", err)
	}
	token := strings.TrimSpace(string(raw))
	body, _ := json.Marshal(map[string]any{"chat_id": tg.ChatID, "text": text, "disable_web_page_preview": true})
	// Telegram's Bot API takes the token in the path; it is never logged.
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, strings.TrimRight(tg.APIBase, "/")+"/bot"+token+"/sendMessage", bytes.NewReader(body))
	if err != nil {
		return fmt.Errorf("build request")
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := n.client.Do(req)
	if err != nil {
		return fmt.Errorf("telegram request failed")
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("telegram answered HTTP %d", resp.StatusCode)
	}
	return nil
}

// Notifications lists recent notifications.
func (s *Service) Notifications(ctx context.Context, unreadOnly bool, limit int) ([]Notification, int, error) {
	if limit <= 0 || limit > 200 {
		limit = 50
	}
	q := `SELECT id, ts, kind, severity, title, body, entity_id, incident_id, read_at, telegram FROM mon_notifications`
	if unreadOnly {
		q += ` WHERE read_at IS NULL`
	}
	rows, err := s.db.QueryContext(ctx, q+` ORDER BY ts DESC LIMIT ?`, limit)
	if err != nil {
		return nil, 0, err
	}
	defer rows.Close()
	out := []Notification{}
	for rows.Next() {
		var nt Notification
		var ts int64
		var sev string
		var ent, inc sql.NullString
		var read sql.NullInt64
		if err := rows.Scan(&nt.ID, &ts, &nt.Kind, &sev, &nt.Title, &nt.Body, &ent, &inc, &read, &nt.Telegram); err != nil {
			return nil, 0, err
		}
		nt.At, nt.Severity, nt.ReadAt = fromMS(ts), Severity(sev), fromNullMS(read)
		if ent.Valid {
			nt.EntityID = &ent.String
		}
		if inc.Valid {
			nt.IncidentID = &inc.String
		}
		out = append(out, nt)
	}
	var unread int
	_ = s.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM mon_notifications WHERE read_at IS NULL`).Scan(&unread)
	return out, unread, rows.Err()
}

// MarkRead marks notifications read (all when ids is empty).
func (s *Service) MarkRead(ctx context.Context, idsList []string) (int, error) {
	now := ms(s.now())
	if len(idsList) == 0 {
		res, err := s.db.ExecContext(ctx, `UPDATE mon_notifications SET read_at = ? WHERE read_at IS NULL`, now)
		if err != nil {
			return 0, err
		}
		n, _ := res.RowsAffected()
		return int(n), nil
	}
	total := 0
	for _, id := range idsList {
		res, err := s.db.ExecContext(ctx, `UPDATE mon_notifications SET read_at = ? WHERE id = ? AND read_at IS NULL`, now, id)
		if err != nil {
			return total, err
		}
		n, _ := res.RowsAffected()
		total += int(n)
	}
	return total, nil
}
