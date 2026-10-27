package bots

import (
	"context"
	"crypto/rand"
	"database/sql"
	"encoding/hex"
	"errors"
	"net/http"
	"slices"
	"strings"
	"time"

	"aerhome/core/internal/foundation/ids"
	"aerhome/core/internal/modules/monitoring"
)

// Actions: start, stop, restart (controller), check (read-only connection
// check) and job.retry (adapter-specific). Every state-changing action
// needs a single-use confirmation token and an Idempotency-Key; each
// request — executed, replayed or refused — leaves an audit record.

var actionLabels = map[string]string{
	"start": "Запустить", "stop": "Остановить", "restart": "Перезапустить",
	"check": "Проверить соединение", "job.retry": "Повторить задание",
}

var actionRisks = map[string]string{
	"start":     "Бот начнёт работать и обрабатывать сообщения/задания",
	"stop":      "Бот перестанет отвечать до следующего запуска",
	"restart":   "Бот будет недоступен несколько секунд; незавершённые операции прервутся",
	"check":     "",
	"job.retry": "Задание выполнится ещё раз со всеми его действиями (сообщения, записи, запросы)",
}

func mutating(action string) bool { return action != "check" }

// actionsFor lists what can be requested for the bot now, and why not.
func (s *Service) actionsFor(b *Bot) []ActionInfo {
	ctl, adapter, hasCtl := s.controllerOf(b.Config)
	out := []ActionInfo{}
	for _, a := range []string{"start", "stop", "restart"} {
		info := ActionInfo{ID: a, Label: actionLabels[a], Confirm: true, Risk: actionRisks[a]}
		switch {
		case b.Archived:
			info.Reason = "Бот в архиве"
		case b.ControllerID == "":
			info.Reason = "Только мониторинг: управляющий адаптер не выбран"
		case !hasCtl:
			info.Reason = "Адаптер «" + b.ControllerID + "» не объявлен в конфигурации Core"
		case !slices.Contains(ctl.Allow, a):
			info.Reason = "Действие не разрешено в конфигурации адаптера (allow)"
		case adapter == nil:
			info.Reason = "Нет адаптера для вида " + ctl.Kind
		case a == "start" && b.RuntimeState != nil && b.RuntimeState.State == "running":
			info.Reason = "Уже запущен"
		case a == "stop" && b.RuntimeState != nil && b.RuntimeState.State == "stopped":
			info.Reason = "Уже остановлен"
		default:
			info.Available = true
		}
		out = append(out, info)
	}
	check := ActionInfo{ID: "check", Label: actionLabels["check"], Available: !b.Archived}
	if b.Archived {
		check.Reason = "Бот в архиве"
	}
	out = append(out, check)
	retry := ActionInfo{ID: "job.retry", Label: actionLabels["job.retry"], Confirm: true, Risk: actionRisks["job.retry"]}
	switch {
	case b.N8NInstanceID == "":
		retry.Reason = "Адаптер бота не поддерживает повтор заданий"
	default:
		inst, ok := s.cfg.N8NByID(b.N8NInstanceID)
		if ok && inst.AllowRetry && !b.Archived {
			retry.Available = true
			retry.Reason = "Для неудачных выполнений n8n"
		} else {
			retry.Reason = "Повтор выключен для экземпляра n8n (bots.n8n.allowRetry)"
		}
	}
	return append(out, retry)
}

func (s *Service) availability(ctx context.Context, b *Bot, action, jobID string) (*Job, error) {
	var info *ActionInfo
	for _, a := range s.actionsFor(b) {
		if a.ID == action {
			info = &a
			break
		}
	}
	if info == nil {
		return nil, &ActionError{Status: http.StatusBadRequest, Code: "UNSUPPORTED", Message: "Неизвестное действие"}
	}
	if !info.Available {
		return nil, &ActionError{Status: http.StatusForbidden, Code: "PERMISSION_REQUIRED", Message: info.Reason}
	}
	if action != "job.retry" {
		return nil, nil
	}
	j, err := s.job(ctx, b.EntityID, jobID)
	if err != nil {
		return nil, &ActionError{Status: http.StatusNotFound, Code: "NOT_FOUND", Message: "Задание не найдено"}
	}
	if ok, why := s.retrier.CanRetry(b, j); !ok {
		return nil, &ActionError{Status: http.StatusForbidden, Code: "PERMISSION_REQUIRED", Message: why}
	}
	return &j, nil
}

// Prepare issues a confirmation for one action (shown to the owner).
func (s *Service) Prepare(ctx context.Context, id, action, jobID string) (Confirmation, error) {
	d, err := s.Get(ctx, id)
	if err != nil {
		return Confirmation{}, err
	}
	j, err := s.availability(ctx, &d.Bot, action, jobID)
	if err != nil {
		return Confirmation{}, err
	}
	tok := make([]byte, 16)
	_, _ = rand.Read(tok)
	c := Confirmation{Token: hex.EncodeToString(tok), EntityID: id, Action: action, JobID: jobID,
		ExpiresAt: s.now().UTC().Add(time.Duration(s.cfg.ConfirmTTLSec) * time.Second).Truncate(time.Second), Risks: []string{}}
	c.Summary = actionLabels[action] + " «" + d.Name + "»"
	if ctl, _, ok := s.controllerOf(d.Config); ok && action != "check" && action != "job.retry" {
		c.Summary += " через " + ctl.Kind + " «" + ctl.ID + "»"
	}
	if j != nil {
		c.Summary += ": «" + j.Name + "»"
	}
	if r := actionRisks[action]; r != "" {
		c.Risks = append(c.Risks, r)
	}
	if d.RuntimeState != nil && d.RuntimeState.State == "stopped" && action == "stop" {
		c.Risks = append(c.Risks, "Сейчас адаптер считает бота остановленным — действие ничего не изменит")
	}
	s.mu.Lock()
	s.confirms[c.Token] = c
	s.mu.Unlock()
	return c, nil
}

func (s *Service) consume(token, id, action, jobID string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	c, ok := s.confirms[token]
	if !ok {
		return false
	}
	delete(s.confirms, token) // single use, even when it does not match
	return c.EntityID == id && c.Action == action && c.JobID == jobID && s.now().Before(c.ExpiresAt)
}

func (s *Service) gcConfirmations() {
	s.mu.Lock()
	defer s.mu.Unlock()
	now := s.now()
	for k, c := range s.confirms {
		if now.After(c.ExpiresAt) {
			delete(s.confirms, k)
		}
	}
}

// ActionRequest is the body of POST /bots/{id}/actions/{action}.
type ActionRequest struct {
	ConfirmationToken string `json:"confirmationToken"`
	JobID             string `json:"jobId"`
}

// Execute runs an action once per idempotency key.
func (s *Service) Execute(ctx context.Context, id, action, key string, req ActionRequest) (ActionRecord, error) {
	if l := len(key); l < 8 || l > 100 || strings.ContainsAny(key, " \t\r\n") {
		return ActionRecord{}, &ValidationError{Fields: map[string]string{"Idempotency-Key": "Заголовок Idempotency-Key: 8–100 символов без пробелов"}}
	}
	if rec, err := s.actionByKey(ctx, key); err == nil {
		if rec.EntityID != id || rec.Action != action {
			return ActionRecord{}, &ActionError{Status: http.StatusConflict, Code: "CONFLICT", Message: "Этот Idempotency-Key уже использован для другой операции"}
		}
		rec.Replayed = true
		return rec, nil
	} else if !errors.Is(err, sql.ErrNoRows) {
		return ActionRecord{}, err
	}
	d, err := s.Get(ctx, id)
	if err != nil {
		return ActionRecord{}, err
	}
	rec := ActionRecord{ID: ids.New(), EntityID: id, Action: action, JobID: req.JobID, IdempotencyKey: key,
		RequestedAt: s.now().UTC().Truncate(time.Millisecond), Status: "running"}
	if ctl, _, ok := s.controllerOf(d.Config); ok {
		rec.Adapter = ctl.Kind + ":" + ctl.ID
	}
	if (action == "job.retry" || action == "check") && d.N8NInstanceID != "" {
		rec.Adapter = "n8n:" + d.N8NInstanceID
	}
	reject := func(e *ActionError) (ActionRecord, error) {
		rec.Status, rec.Message = "rejected", e.Message
		if err := s.insertAction(ctx, &rec, true); err != nil {
			return ActionRecord{}, err
		}
		return rec, e
	}
	job, err := s.availability(ctx, &d.Bot, action, req.JobID)
	if err != nil {
		var ae *ActionError
		if errors.As(err, &ae) {
			return reject(ae)
		}
		return ActionRecord{}, err
	}
	if mutating(action) && !s.consume(req.ConfirmationToken, id, action, req.JobID) {
		return reject(&ActionError{Status: http.StatusForbidden, Code: "PERMISSION_REQUIRED",
			Message: "Нужно подтверждение: запросите его заново (токен одноразовый и действует ограниченное время)"})
	}
	s.mu.Lock()
	if running, busy := s.busy[id]; busy {
		s.mu.Unlock()
		return reject(&ActionError{Status: http.StatusConflict, Code: "CONFLICT", Message: "Для этого бота уже выполняется «" + actionLabels[running] + "»"})
	}
	s.busy[id] = action
	s.mu.Unlock()
	defer func() {
		s.mu.Lock()
		delete(s.busy, id)
		s.mu.Unlock()
	}()
	if err := s.insertAction(ctx, &rec, false); err != nil {
		if again, e2 := s.actionByKey(ctx, key); e2 == nil { // lost a race on the same key
			again.Replayed = true
			return again, nil
		}
		return ActionRecord{}, err
	}

	select {
	case s.ops <- struct{}{}:
	case <-ctx.Done():
		s.finish(&rec, "failed", "Отменено: очередь операций занята")
		return rec, nil
	}
	defer func() { <-s.ops }()
	// The operation is not tied to the HTTP request: a closed client
	// must not leave a half-done stop/start behind.
	octx, cancel := context.WithTimeout(context.WithoutCancel(ctx), time.Duration(s.cfg.OpTimeoutSec)*time.Second)
	defer cancel()
	msg, opErr := s.perform(octx, &d.Bot, action, job, key)
	if opErr != nil {
		s.finish(&rec, "failed", monitoring.Redact(opErr.Error()))
	} else {
		s.finish(&rec, "succeeded", msg)
	}
	s.mu.Lock()
	if ctl, _, ok := s.controllerOf(d.Config); ok {
		delete(s.rtCache, ctl.ID)
	}
	s.mu.Unlock()
	s.invalidateList()
	sev := monitoring.SeverityInfo
	if rec.Status == "failed" {
		sev = monitoring.SeverityWarning
	}
	s.mon.RecordEvent(context.WithoutCancel(ctx), id, "bot_action", sev, actionLabels[action]+": "+rec.Message)
	return rec, nil
}

func (s *Service) perform(ctx context.Context, b *Bot, action string, job *Job, key string) (string, error) {
	switch action {
	case "start", "stop", "restart":
		ctl, adapter, _ := s.controllerOf(b.Config)
		return adapter.Control(ctx, ctl, b.EntityID, action)
	case "job.retry":
		return s.retrier.Retry(ctx, b, *job, key)
	case "check":
		return s.check(ctx, b)
	}
	return "", errors.New("неизвестное действие")
}

// check is read-only: it refreshes Monitoring and asks integrations.
func (s *Service) check(ctx context.Context, b *Bot) (string, error) {
	s.mon.RefreshEntity(ctx, b.EntityID)
	var parts []string
	ok := true
	if st, err := s.mon.State(ctx, b.EntityID); err == nil {
		parts = append(parts, "Мониторинг: "+string(st.Status)+" — "+st.Reason)
		ok = st.Status == monitoring.StatusOnline
	}
	if ctl, adapter, has := s.controllerOf(b.Config); has {
		rt := adapter.State(ctx, ctl)
		parts = append(parts, "Адаптер "+ctl.Kind+": "+rt.State+" ("+rt.Reason+")")
	}
	for _, c := range s.checkers {
		if r, applies := c.Check(ctx, b); applies {
			parts = append(parts, r.Message)
			ok = ok && r.OK
		}
	}
	msg := strings.Join(parts, ". ")
	if !ok {
		return "", errors.New(msg)
	}
	return msg, nil
}

func (s *Service) insertAction(ctx context.Context, r *ActionRecord, done bool) error {
	var fin any
	if done {
		t := s.now().UTC().Truncate(time.Millisecond)
		r.FinishedAt = &t
		fin = ms(t)
	}
	_, err := s.db.ExecContext(ctx, `INSERT INTO bot_actions (id, entity_id, action, job_id, adapter, status, message, idempotency_key, requested_at, finished_at)
		VALUES (?,?,?,?,?,?,?,?,?,?)`, r.ID, r.EntityID, r.Action, r.JobID, r.Adapter, r.Status, truncate(r.Message, 1000),
		r.IdempotencyKey, ms(r.RequestedAt), fin)
	return err
}

func (s *Service) finish(r *ActionRecord, status, msg string) {
	t := s.now().UTC().Truncate(time.Millisecond)
	r.Status, r.Message, r.FinishedAt = status, truncate(msg, 1000), &t
	if _, err := s.db.Exec(`UPDATE bot_actions SET status = ?, message = ?, finished_at = ? WHERE id = ?`, status, r.Message, ms(t), r.ID); err != nil {
		s.log.Warn("bot action audit", "err", err)
	}
}

const actionCols = `id, entity_id, action, job_id, adapter, status, message, idempotency_key, requested_at, finished_at`

func scanAction(row interface{ Scan(...any) error }) (ActionRecord, error) {
	var r ActionRecord
	var req int64
	var fin sql.NullInt64
	err := row.Scan(&r.ID, &r.EntityID, &r.Action, &r.JobID, &r.Adapter, &r.Status, &r.Message, &r.IdempotencyKey, &req, &fin)
	r.RequestedAt, r.FinishedAt = fromMS(req), fromNullMS(fin)
	return r, err
}

func (s *Service) actionByKey(ctx context.Context, key string) (ActionRecord, error) {
	return scanAction(s.db.QueryRowContext(ctx, `SELECT `+actionCols+` FROM bot_actions WHERE idempotency_key = ?`, key))
}

// Audit lists the bot's action records, newest first.
func (s *Service) Audit(ctx context.Context, id string, limit int) ([]ActionRecord, error) {
	if limit <= 0 || limit > 200 {
		limit = 50
	}
	rows, err := s.db.QueryContext(ctx, `SELECT `+actionCols+` FROM bot_actions WHERE entity_id = ? ORDER BY requested_at DESC, id DESC LIMIT ?`, id, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []ActionRecord{}
	for rows.Next() {
		r, err := scanAction(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, r)
	}
	return out, rows.Err()
}
