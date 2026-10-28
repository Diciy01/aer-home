package power

import (
	"context"
	"crypto/rand"
	"database/sql"
	"encoding/hex"
	"errors"
	"fmt"
	"net/http"
	"strings"
	"time"

	"aerhome/core/internal/foundation/ids"
	"aerhome/core/internal/modules/monitoring"
)

// Every state-changing action needs a single-use confirmation token bound
// to (device, action, target OS) and an Idempotency-Key. Each request —
// executed, replayed or refused — leaves an audit record. Nothing is
// retried automatically: a failed reboot is never repeated by Core.

// JobRejected marks a refused request kept for the audit.
const JobRejected JobState = "rejected"

const jobCols = `id, entity_id, action, target_os, entry_id, state, message, idempotency_key, simulated, from_os,
	requested_at, sent_at, finished_at, deadline, from_boot_id, went_offline, exec_at`

type jobRow struct {
	Job
	fromBootID  string
	wentOffline bool
	execAt      *time.Time
}

func scanJob(row interface{ Scan(...any) error }) (jobRow, error) {
	var j jobRow
	var sim, off int
	var req, dl int64
	var sent, fin, exec sql.NullInt64
	err := row.Scan(&j.ID, &j.EntityID, &j.Action, &j.TargetOS, &j.BootEntryID, &j.State, &j.Message, &j.IdempotencyKey,
		&sim, &j.FromOS, &req, &sent, &fin, &dl, &j.fromBootID, &off, &exec)
	j.execAt = fromNullMS(exec)
	j.Simulated, j.wentOffline = sim == 1, off == 1
	j.RequestedAt, j.SentAt, j.FinishedAt, j.Deadline = fromMS(req), fromNullMS(sent), fromNullMS(fin), fromMS(dl)
	return j, err
}

func (s *Service) jobRows(ctx context.Context, where string, limit int, args ...any) ([]jobRow, error) {
	rows, err := s.db.QueryContext(ctx, `SELECT `+jobCols+` FROM power_jobs WHERE `+where+
		` ORDER BY requested_at DESC, id DESC LIMIT ?`, append(args, limit)...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []jobRow{}
	for rows.Next() {
		j, err := scanJob(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, j)
	}
	return out, rows.Err()
}

func (s *Service) jobs(ctx context.Context, where string, limit int, args ...any) ([]Job, error) {
	rows, err := s.jobRows(ctx, where, limit, args...)
	out := make([]Job, 0, len(rows))
	for _, r := range rows {
		r.DeviceName = s.name(ctx, r.EntityID)
		out = append(out, r.Job)
	}
	return out, err
}

func (s *Service) name(ctx context.Context, id string) string {
	if e, err := s.reg.Get(ctx, id); err == nil {
		return e.Name
	}
	return ""
}

// Jobs lists jobs, newest first (optionally of one device).
func (s *Service) Jobs(ctx context.Context, entityID string, limit int) ([]Job, error) {
	if limit <= 0 || limit > 200 {
		limit = 50
	}
	if entityID != "" {
		return s.jobs(ctx, `entity_id = ?`, limit, entityID)
	}
	return s.jobs(ctx, `1 = 1`, limit)
}

// Job returns one job with its audit trail.
func (s *Service) Job(ctx context.Context, id string) (Job, error) {
	list, err := s.jobs(ctx, `id = ?`, 1, id)
	if err != nil {
		return Job{}, err
	}
	if len(list) == 0 {
		return Job{}, ErrNotFound
	}
	j := list[0]
	rows, err := s.db.QueryContext(ctx, `SELECT ts, kind, message FROM power_events WHERE job_id = ? ORDER BY id`, id)
	if err != nil {
		return Job{}, err
	}
	defer rows.Close()
	j.Events = []Event{}
	for rows.Next() {
		var e Event
		var ts int64
		if err := rows.Scan(&ts, &e.Kind, &e.Message); err != nil {
			return Job{}, err
		}
		e.At = fromMS(ts)
		j.Events = append(j.Events, e)
	}
	return j, rows.Err()
}

func (s *Service) audit(ctx context.Context, jobID, kind, msg string) {
	if _, err := s.db.ExecContext(context.WithoutCancel(ctx), `INSERT INTO power_events (job_id, ts, kind, message) VALUES (?,?,?,?)`,
		jobID, ms(s.now()), kind, truncate(monitoring.Redact(msg), 500)); err != nil {
		s.log.Warn("power audit", "err", err)
	}
}

// ---- confirmation ----

func (s *Service) action(d *Device, a string) (ActionInfo, error) {
	for _, x := range d.Actions {
		if x.ID == a {
			return x, nil
		}
	}
	return ActionInfo{}, &RefusedError{Status: http.StatusBadRequest, Code: "UNSUPPORTED", Reason: "unknown_action", Message: "Неизвестное действие"}
}

func pickTarget(info ActionInfo, targetOS string) (Target, error) {
	for _, t := range info.Targets {
		if t.OS == targetOS {
			if !t.Available {
				return t, &RefusedError{Status: http.StatusConflict, Code: "UNAVAILABLE", Reason: "target_unavailable", Message: t.Reason}
			}
			return t, nil
		}
	}
	return Target{}, &ValidationError{Fields: map[string]string{"targetOs": "linux или windows"}}
}

// Prepare evaluates preconditions and issues a single-use confirmation.
func (s *Service) Prepare(ctx context.Context, entityID, action, targetOS string) (Confirmation, error) {
	d, err := s.Device(ctx, entityID)
	if err != nil {
		return Confirmation{}, err
	}
	info, err := s.action(&d, action)
	if err != nil {
		return Confirmation{}, err
	}
	if action == ActionCheck {
		return Confirmation{}, &RefusedError{Status: http.StatusBadRequest, Code: "UNSUPPORTED", Reason: "no_confirmation", Message: "Проверка состояния не требует подтверждения"}
	}
	if !info.Available {
		return Confirmation{}, &RefusedError{Status: http.StatusForbidden, Code: "PERMISSION_REQUIRED", Reason: "unavailable", Message: info.Reason}
	}
	var target Target
	if action == ActionSwitchOS {
		if target, err = pickTarget(info, targetOS); err != nil {
			return Confirmation{}, err
		}
	} else {
		targetOS = ""
	}
	tok := make([]byte, 16)
	_, _ = rand.Read(tok)
	c := Confirmation{Token: hex.EncodeToString(tok), EntityID: entityID, Action: action, TargetOS: targetOS,
		Summary:   actionLabels[action] + " «" + d.Name + "»",
		ExpiresAt: s.now().UTC().Add(time.Duration(s.cfg.ConfirmTTLSec) * time.Second).Truncate(time.Second),
		Risks:     []string{}, Checks: s.checks(&d, action, target)}
	if action == ActionSwitchOS {
		c.Summary = "Перезагрузить «" + d.Name + "» в " + target.Label + " (одноразово)"
	}
	c.Risks = s.risks(&d, action, target)
	s.mu.Lock()
	s.confirms[c.Token] = c
	s.mu.Unlock()
	return c, nil
}

func (s *Service) checks(d *Device, action string, target Target) []Check {
	act := activeAgent(d.Agents)
	var out []Check
	add := func(name string, ok bool, msg string) { out = append(out, Check{Name: name, OK: ok, Message: msg}) }
	if action == ActionWake {
		w := d.WoL
		add("mac", true, "MAC "+w.MAC)
		port := w.Port
		if port == 0 {
			port = s.cfg.WoL.Port
		}
		add("destination", true, fmt.Sprintf("Пакет на %s:%d", w.Broadcast, port))
		if w.Interface != "" {
			add("interface", true, "Через интерфейс "+w.Interface)
		} else {
			add("interface", true, "Интерфейс выбирает система")
		}
		add("state", true, "Сейчас: "+d.StateReason)
		return out
	}
	add("agent", act != nil, "Агент: "+act.Info.Hostname+" ("+or(osLabels[act.Info.OS], act.Info.OS)+")")
	if act.Info.DryRun {
		add("dry_run", false, "Агент в режиме проверки: команда не будет выполнена (SIMULATED)")
	}
	if action == ActionSwitchOS {
		add("target", true, "Загрузочная запись "+target.EntryID+" → "+target.Label)
		add("firmware", act.Info.Firmware == "uefi", "Прошивка: "+or(act.Info.Firmware, "unknown"))
		add("secure_boot", true, "Secure Boot: "+or(act.Info.SecureBoot, "unknown"))
		bl := bitlocker(d.Agents)
		add("bitlocker", bl == "off", "BitLocker: "+bl)
		add("method", true, "Способ: одноразовая загрузка UEFI BootNext; постоянный порядок не меняется")
	}
	return out
}

func (s *Service) risks(d *Device, action string, target Target) []string {
	act := activeAgent(d.Agents)
	var r []string
	switch action {
	case ActionWake:
		r = append(r, "Пакет Wake-on-LAN не подтверждает включение: результат проверяется по появлению устройства в сети (до "+
			fmt.Sprint(s.cfg.BootTimeoutSec)+" с)",
			"Wake-on-LAN должен быть разрешён в UEFI и в драйвере сетевой карты обеих ОС — AER HOME эти настройки не меняет")
	case ActionShutdown, ActionSuspend:
		r = append(r, "Несохранённые данные в открытых программах могут быть потеряны")
		if d.WoL == nil || d.SameMachine || !s.cfg.WoL.Enabled {
			r = append(r, "Включить компьютер удалённо после этого не получится (Wake-on-LAN не настроен или недоступен)")
		}
	case ActionReboot:
		r = append(r, "Несохранённые данные в открытых программах могут быть потеряны",
			"При сбое загрузки Core не повторяет перезагрузку автоматически")
	case ActionSwitchOS:
		r = append(r, "Компьютер перезагрузится; несохранённые данные могут быть потеряны",
			"Одноразовая загрузка: если "+target.Label+" не загрузится, следующая обычная загрузка вернётся к прежнему порядку",
			"Если в "+target.Label+" не запущен агент AER, результат останется неподтверждённым (тайм-аут)")
		if act != nil && act.Info.SecureBoot == "enabled" {
			r = append(r, "Secure Boot включён: BootNext его не отключает; загрузчик цели должен быть подписан")
		}
		switch bitlocker(d.Agents) {
		case "on":
			r = append(r, "BitLocker включён: может потребоваться ключ восстановления")
		case "unknown":
			r = append(r, "Состояние BitLocker неизвестно: держите ключ восстановления под рукой")
		}
	}
	if d.SameMachine && dangerous(action) {
		r = append(r, "AER Core работает на этом компьютере и остановится вместе с ним; результат будет записан после запуска Core")
	}
	if act != nil && act.Info.DryRun && action != ActionWake {
		r = append(r, "Агент в режиме проверки: ничего не выполнится, результат — SIMULATED")
	}
	return r
}

func (s *Service) consume(token, entityID, action, targetOS string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	c, ok := s.confirms[token]
	if !ok {
		return false
	}
	delete(s.confirms, token) // single use, even when it does not match
	return c.EntityID == entityID && c.Action == action && c.TargetOS == targetOS && s.now().Before(c.ExpiresAt)
}

func (s *Service) gcConfirmations() {
	s.mu.Lock()
	defer s.mu.Unlock()
	for k, c := range s.confirms {
		if s.now().After(c.ExpiresAt) {
			delete(s.confirms, k)
		}
	}
}

// ---- execute ----

func (s *Service) jobByKey(ctx context.Context, key string) (*Job, error) {
	list, err := s.jobs(ctx, `idempotency_key = ?`, 1, key)
	if err != nil || len(list) == 0 {
		return nil, err
	}
	return &list[0], nil
}

// Execute starts an action once per Idempotency-Key. It returns the job;
// its outcome arrives asynchronously (poll GET /power/jobs/{id}).
func (s *Service) Execute(ctx context.Context, entityID, action, key string, req ActionRequest) (Job, error) {
	if l := len(key); l < 8 || l > 100 || strings.ContainsAny(key, " \t\r\n") {
		return Job{}, &ValidationError{Fields: map[string]string{"Idempotency-Key": "Заголовок Idempotency-Key: 8–100 символов без пробелов"}}
	}
	s.createMu.Lock()
	defer s.createMu.Unlock()
	if j, err := s.jobByKey(ctx, key); err != nil {
		return Job{}, err
	} else if j != nil {
		if j.EntityID != entityID || j.Action != action {
			return Job{}, &RefusedError{Status: http.StatusConflict, Code: "CONFLICT", Reason: "key_reused", Message: "Этот Idempotency-Key уже использован для другой операции"}
		}
		j.Replayed = true
		return *j, nil
	}
	d, err := s.Device(ctx, entityID)
	if err != nil {
		return Job{}, err
	}
	info, err := s.action(&d, action)
	if err != nil {
		return Job{}, err
	}
	now := s.now().UTC().Truncate(time.Millisecond)
	j := jobRow{Job: Job{ID: ids.New(), EntityID: entityID, DeviceName: d.Name, Action: action, IdempotencyKey: key,
		RequestedAt: now, Deadline: now, FromOS: d.CurrentOS}}
	act := activeAgent(d.Agents)
	if act != nil {
		j.fromBootID = act.Info.BootID
	}
	reject := func(e *RefusedError) (Job, error) {
		j.State, j.Message = JobRejected, e.Message
		j.FinishedAt = &now
		if err := s.insertJob(ctx, &j); err != nil {
			return Job{}, err
		}
		s.audit(ctx, j.ID, "rejected", e.Message)
		return j.Job, e
	}
	if !info.Available {
		return reject(&RefusedError{Status: http.StatusForbidden, Code: "PERMISSION_REQUIRED", Reason: "unavailable", Message: info.Reason})
	}
	if action == ActionSwitchOS {
		t, err := pickTarget(info, req.TargetOS)
		if err != nil {
			var re *RefusedError
			if errors.As(err, &re) {
				return reject(re)
			}
			return Job{}, err
		}
		j.TargetOS, j.BootEntryID = t.OS, t.EntryID
	}
	if action != ActionCheck && !s.consume(req.ConfirmationToken, entityID, action, j.TargetOS) {
		return reject(&RefusedError{Status: http.StatusForbidden, Code: "PERMISSION_REQUIRED", Reason: "confirmation_required",
			Message: "Нужно подтверждение: запросите его заново (токен одноразовый и действует ограниченное время)"})
	}
	var active int
	if err := s.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM power_jobs WHERE state IN ('queued','sent','waiting')`).Scan(&active); err != nil {
		return Job{}, err
	}
	if active >= s.cfg.MaxActiveJobs {
		return reject(&RefusedError{Status: http.StatusServiceUnavailable, Code: "UNAVAILABLE", Reason: "limit", Message: "Слишком много команд питания выполняется одновременно"})
	}

	switch action {
	case ActionCheck:
		return s.runCheck(ctx, &j, act)
	case ActionWake:
		return s.runWake(ctx, &j, d.WoL)
	}
	j.State, j.Message = JobQueued, "Ожидает агента"
	j.Deadline = now.Add(time.Duration(s.cfg.PickupTimeoutSec) * time.Second)
	if err := s.insertJob(ctx, &j); err != nil {
		return Job{}, err
	}
	s.audit(ctx, j.ID, "requested", s.describe(&j.Job))
	s.enqueue(act.AgentID, Command{ID: ids.New(), JobID: j.ID, Action: action, EntryID: j.BootEntryID, TargetOS: j.TargetOS, ExpiresAt: j.Deadline})
	return j.Job, nil
}

func (s *Service) describe(j *Job) string {
	m := actionLabels[j.Action]
	if j.Action == ActionSwitchOS {
		m += ": " + or(osLabels[j.FromOS], j.FromOS) + " → " + osLabels[j.TargetOS] + " (запись " + j.BootEntryID + ")"
	}
	return m
}

func (s *Service) runCheck(ctx context.Context, j *jobRow, act *AgentView) (Job, error) {
	s.mon.RefreshEntity(ctx, j.EntityID)
	msg := "Мониторинг обновлён"
	if st, err := s.mon.State(ctx, j.EntityID); err == nil {
		msg = "Мониторинг: " + string(st.Status) + " — " + st.Reason
	}
	if act != nil {
		s.enqueue(act.AgentID, Command{ID: ids.New(), Action: "inventory", ExpiresAt: s.now().Add(time.Minute)})
		msg += ". Агент обновит сведения о загрузке"
	}
	now := s.now().UTC()
	j.State, j.Message, j.FinishedAt = JobSucceeded, msg, &now
	if err := s.insertJob(ctx, j); err != nil {
		return Job{}, err
	}
	s.audit(ctx, j.ID, "checked", msg)
	return j.Job, nil
}

func (s *Service) runWake(ctx context.Context, j *jobRow, w *WoLTarget) (Job, error) {
	j.State, j.Message = JobSent, "Отправка пакета Wake-on-LAN"
	if err := s.insertJob(ctx, j); err != nil {
		return Job{}, err
	}
	s.audit(ctx, j.ID, "requested", "Включить по сети: MAC "+w.MAC)
	dst, err := CheckDestination(w.Broadcast)
	var pkt []byte
	if err == nil {
		pkt, err = MagicPacket(w.MAC)
	}
	port := w.Port
	if port == 0 {
		port = s.cfg.WoL.Port
	}
	sctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 5*time.Second)
	defer cancel()
	for i := 0; err == nil && i < s.cfg.WoL.Repeat; i++ {
		if i > 0 {
			select {
			case <-time.After(100 * time.Millisecond):
			case <-sctx.Done():
			}
		}
		err = s.net.Send(sctx, w.Interface, dst, port, pkt)
	}
	if err != nil {
		s.finish(ctx, j.ID, JobFailed, "Не удалось отправить пакет: "+err.Error())
		return s.Job(ctx, j.ID)
	}
	now := s.now().UTC()
	dl := now.Add(time.Duration(s.cfg.BootTimeoutSec) * time.Second)
	if _, err := s.db.ExecContext(ctx, `UPDATE power_jobs SET state = 'waiting', message = ?, sent_at = ?, deadline = ? WHERE id = ?`,
		"Пакет отправлен, ожидание появления устройства в сети", ms(now), ms(dl), j.ID); err != nil {
		return Job{}, err
	}
	s.audit(ctx, j.ID, "sent", fmt.Sprintf("Отправлено пакетов: %d на %s:%d", s.cfg.WoL.Repeat, dst, port))
	return s.Job(ctx, j.ID)
}

func (s *Service) insertJob(ctx context.Context, j *jobRow) error {
	var fin, sent any
	if j.FinishedAt != nil {
		fin = ms(*j.FinishedAt)
	}
	if j.SentAt != nil {
		sent = ms(*j.SentAt)
	}
	_, err := s.db.ExecContext(ctx, `INSERT INTO power_jobs (id, entity_id, action, target_os, entry_id, state, message, idempotency_key,
		simulated, from_os, from_boot_id, requested_at, sent_at, finished_at, deadline) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)`,
		j.ID, j.EntityID, j.Action, j.TargetOS, j.BootEntryID, string(j.State), truncate(j.Message, 1000), j.IdempotencyKey,
		boolInt(j.Simulated), j.FromOS, j.fromBootID, ms(j.RequestedAt), sent, fin, ms(j.Deadline))
	return err
}

// finish moves a job to a terminal state once (returns false if it already was).
func (s *Service) finish(ctx context.Context, id string, st JobState, msg string) bool {
	return s.finishFrom(ctx, id, `'queued','sent','waiting'`, st, msg)
}

// finishFrom finishes a job only while it is in one of the from states;
// the conditional UPDATE is what makes cancel and agent delivery exclusive.
func (s *Service) finishFrom(ctx context.Context, id, from string, st JobState, msg string) bool {
	ctx = context.WithoutCancel(ctx)
	res, err := s.db.ExecContext(ctx, `UPDATE power_jobs SET state = ?, message = ?, finished_at = ?
		WHERE id = ? AND state IN (`+from+`)`, string(st), truncate(monitoring.Redact(msg), 1000), ms(s.now()), id)
	if err != nil {
		s.log.Warn("power job", "err", err)
		return false
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return false
	}
	s.audit(ctx, id, string(st), msg)
	j, err := s.Job(ctx, id)
	if err != nil {
		return true
	}
	label := actionLabels[j.Action]
	key := "power:" + j.EntityID + ":" + j.Action
	switch st {
	case JobSucceeded:
		s.mon.RecordEvent(ctx, j.EntityID, "power_job", monitoring.SeverityInfo, label+": выполнено. "+msg)
		s.mon.ResolveIncident(ctx, key, label+": следующая попытка выполнена")
	case JobSimulated, JobCancelled:
		s.mon.RecordEvent(ctx, j.EntityID, "power_job", monitoring.SeverityInfo, label+": "+msg)
	default:
		s.mon.RecordEvent(ctx, j.EntityID, "power_job", monitoring.SeverityWarning, label+": "+msg)
		s.mon.RaiseIncident(ctx, key, "Питание: «"+label+"» не выполнено", "power", j.EntityID,
			monitoring.SeverityWarning, string(st), msg)
	}
	return true
}

// withdraw finishes a job that is still queued and drops its command.
func (s *Service) withdraw(ctx context.Context, j Job, st JobState, msg string) bool {
	if !s.finishFrom(ctx, j.ID, `'queued'`, st, msg) {
		return false
	}
	s.mu.Lock()
	for _, q := range s.queues {
		kept := q.cmds[:0]
		for _, c := range q.cmds {
			if c.JobID != j.ID {
				kept = append(kept, c)
			}
		}
		q.cmds = kept
	}
	s.mu.Unlock()
	return true
}

// Cancel withdraws a job the agent has not taken yet.
func (s *Service) Cancel(ctx context.Context, id string) (Job, error) {
	s.createMu.Lock()
	defer s.createMu.Unlock()
	j, err := s.Job(ctx, id)
	if err != nil {
		return Job{}, err
	}
	if j.State != JobQueued {
		msg := "Команда уже передана — отменить нельзя"
		if j.State.Terminal() || j.State == JobRejected {
			msg = "Задание уже завершено"
		}
		return Job{}, &RefusedError{Status: http.StatusConflict, Code: "CONFLICT", Reason: "not_cancellable", Message: msg}
	}
	if !s.withdraw(ctx, j, JobCancelled, "Отменено владельцем до передачи агенту") {
		return Job{}, &RefusedError{Status: http.StatusConflict, Code: "CONFLICT", Reason: "not_cancellable", Message: "Команда уже передана — отменить нельзя"}
	}
	return s.Job(ctx, id)
}
