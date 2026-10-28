package power

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"regexp"
	"slices"
	"time"

	"aerhome/core/internal/modules/monitoring"
)

// Host agent protocol (kind=power): hello with facts and boot inventory,
// long-poll for commands, events per job. The agent re-validates every
// command against its own inventory; Core never sends command text.

// silence: an agent that neither polled nor said hello for this long after
// a shutdown/suspend started is considered gone.
const silence = 45 * time.Second

var (
	uefiEntry   = regexp.MustCompile(`^[0-9A-Fa-f]{4}$`)
	guidEntry   = regexp.MustCompile(`^\{[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\}$`)
	agentAction = []string{"shutdown", "reboot", "suspend", "bootNext"}
)

// ValidEntryID accepts a UEFI Boot#### number or a Windows firmware GUID.
func ValidEntryID(id string) bool { return uefiEntry.MatchString(id) || guidEntry.MatchString(id) }

func validateHello(info *HostInfo) map[string]string {
	v := map[string]string{}
	if info.OS != "linux" && info.OS != "windows" {
		v["os"] = "linux или windows"
	}
	if len(info.BootID) > 100 || len(info.Hostname) > 253 || len(info.OSVersion) > 200 || len(info.Version) > 64 ||
		len(info.BootManager) > 40 {
		v["bootId"] = "Слишком длинные поля"
	}
	enum := func(field, val string, allowed ...string) {
		if !slices.Contains(allowed, val) {
			v[field] = fmt.Sprint("одно из ", allowed)
		}
	}
	enum("firmware", info.Firmware, "uefi", "bios", "unknown")
	enum("secureBoot", info.SecureBoot, "enabled", "disabled", "unknown")
	enum("bitlocker", info.BitLocker, "off", "on", "unknown", "n/a")
	if len(info.BootEntries) > 64 {
		v["bootEntries"] = "Не более 64 записей"
	}
	for _, e := range info.BootEntries {
		if !ValidEntryID(e.ID) || len(e.Label) > 120 || !slices.Contains([]string{"linux", "windows", "bootmanager", "other"}, e.OS) {
			v["bootEntries"] = "Запись: id Boot#### или {GUID}, os linux|windows|bootmanager|other"
			break
		}
	}
	if len(info.MACs) > 32 {
		v["macs"] = "Не более 32"
	}
	for i, m := range info.MACs {
		norm, err := ParseMAC(m)
		if err != nil {
			v["macs"] = err.Error()
			break
		}
		info.MACs[i] = norm
	}
	for k, c := range info.Actions {
		if !slices.Contains(agentAction, k) || len(c.Reason) > 300 {
			v["actions"] = fmt.Sprint("ключи ", agentAction)
		}
	}
	return v
}

func (s *Service) seen(agentID string) {
	s.mu.Lock()
	if s.lastSeen == nil {
		s.lastSeen = map[string]time.Time{}
	}
	s.lastSeen[agentID] = s.now()
	s.mu.Unlock()
}

func (s *Service) lastContact(agentID string) time.Time {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.lastSeen[agentID]
}

// Hello stores the agent's facts and settles jobs that wait for a boot.
func (s *Service) Hello(ctx context.Context, a monitoring.Agent, info HostInfo) (map[string]any, error) {
	if v := validateHello(&info); len(v) > 0 {
		return nil, &ValidationError{Fields: v}
	}
	if info.BootEntries == nil {
		info.BootEntries = []BootEntry{}
	}
	b, _ := json.Marshal(info)
	var prevBoot string
	_ = s.db.QueryRowContext(ctx, `SELECT boot_id FROM power_hosts WHERE agent_id = ?`, a.ID).Scan(&prevBoot)
	if _, err := s.db.ExecContext(ctx, `INSERT INTO power_hosts (agent_id, entity_id, info, boot_id, last_hello) VALUES (?,?,?,?,?)
		ON CONFLICT (agent_id) DO UPDATE SET entity_id = excluded.entity_id, info = excluded.info, boot_id = excluded.boot_id,
		last_hello = excluded.last_hello`, a.ID, a.EntityID, string(b), info.BootID, ms(s.now())); err != nil {
		return nil, err
	}
	s.seen(a.ID)
	if prevBoot != "" && prevBoot != info.BootID {
		s.mon.RecordEvent(ctx, a.EntityID, "power_boot", monitoring.SeverityInfo,
			"Новая загрузка: "+or(osLabels[info.OS], info.OS)+" (агент «"+a.Name+"»)")
	}
	s.evaluate(ctx, a.EntityID)
	return map[string]any{"serverTime": s.now().UTC(), "pollSec": 25, "helloSec": 30}, nil
}

func (s *Service) enqueue(agentID string, c Command) {
	s.mu.Lock()
	q := s.queue(agentID)
	if c.Action == "inventory" && slices.ContainsFunc(q.cmds, func(x Command) bool { return x.Action == "inventory" }) {
		s.mu.Unlock() // one pending refresh is enough
		return
	}
	q.cmds = append(q.cmds, c)
	select {
	case q.wake <- struct{}{}:
	default:
	}
	s.mu.Unlock()
}

func (s *Service) queue(agentID string) *agentQueue {
	q := s.queues[agentID]
	if q == nil {
		q = &agentQueue{wake: make(chan struct{}, 1)}
		s.queues[agentID] = q
	}
	return q
}

// Commands long-polls the agent's queue. A job command is delivered only
// if its job moves queued → sent here (a cancelled job never reaches it).
func (s *Service) Commands(ctx context.Context, a monitoring.Agent, wait time.Duration) []Command {
	// Only the start of a poll counts as contact: a poll cut off by the
	// host shutting down must not look like the host is still there.
	s.seen(a.ID)
	deadline := time.NewTimer(wait)
	defer deadline.Stop()
	for {
		s.mu.Lock()
		q := s.queue(a.ID)
		cmds := q.cmds
		q.cmds = nil
		wake := q.wake
		s.mu.Unlock()
		out := []Command{}
		for _, c := range cmds {
			if s.now().After(c.ExpiresAt) {
				continue
			}
			if c.JobID != "" && !s.deliver(ctx, c.JobID) {
				continue
			}
			out = append(out, c)
		}
		if len(out) > 0 {
			return out
		}
		select {
		case <-wake:
		case <-deadline.C:
			return out
		case <-ctx.Done():
			return out
		}
	}
}

func (s *Service) deliver(ctx context.Context, jobID string) bool {
	now := s.now()
	dl := now.Add(time.Duration(s.cfg.PickupTimeoutSec) * time.Second)
	res, err := s.db.ExecContext(context.WithoutCancel(ctx), `UPDATE power_jobs SET state = 'sent', sent_at = ?, deadline = ?,
		message = 'Команда передана агенту' WHERE id = ? AND state = 'queued'`, ms(now), ms(dl), jobID)
	if err != nil {
		return false
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return false
	}
	s.audit(ctx, jobID, "delivered", "Агент забрал команду")
	return true
}

// OnAgentEvent records the agent's report on a job of its own device.
func (s *Service) OnAgentEvent(ctx context.Context, a monitoring.Agent, jobID string, ev AgentEvent) (Job, error) {
	s.seen(a.ID)
	rows, err := s.jobRows(ctx, `id = ?`, 1, jobID)
	if err != nil {
		return Job{}, err
	}
	if len(rows) == 0 || rows[0].EntityID != a.EntityID {
		return Job{}, ErrNotFound
	}
	j := rows[0]
	if j.State.Terminal() || j.State == JobRejected || j.State == JobQueued {
		return Job{}, &RefusedError{Status: http.StatusConflict, Code: "CONFLICT", Reason: "not_active", Message: "Задание не ожидает событий агента"}
	}
	msg := truncate(ev.Message, 500)
	switch ev.Kind {
	case "accepted":
		s.audit(ctx, j.ID, "accepted", or(msg, "Агент принял команду"))
	case "executing":
		now := s.now()
		timeout := s.cfg.BootTimeoutSec
		if j.Action == ActionShutdown || j.Action == ActionSuspend {
			timeout = s.cfg.OfflineTimeoutSec
		}
		if _, err := s.db.ExecContext(ctx, `UPDATE power_jobs SET state = 'waiting', exec_at = ?, deadline = ?, message = ?
			WHERE id = ? AND state IN ('sent','waiting')`, ms(now), ms(now.Add(time.Duration(timeout)*time.Second)),
			waitingMessage(j.Action), j.ID); err != nil {
			return Job{}, err
		}
		s.audit(ctx, j.ID, "executing", or(msg, "Агент выполняет команду"))
	case "simulated":
		if _, err := s.db.ExecContext(ctx, `UPDATE power_jobs SET simulated = 1 WHERE id = ?`, j.ID); err != nil {
			return Job{}, err
		}
		s.finish(ctx, j.ID, JobSimulated, "SIMULATED — агент в режиме проверки, ничего не выполнено. "+msg)
	case "failed":
		s.finish(ctx, j.ID, JobFailed, "Агент: "+or(msg, "ошибка без описания"))
	default:
		return Job{}, &ValidationError{Fields: map[string]string{"kind": "accepted, executing, simulated или failed"}}
	}
	return s.Job(ctx, j.ID)
}

func waitingMessage(action string) string {
	switch action {
	case ActionShutdown:
		return "Выключается: ожидание, когда устройство перестанет отвечать"
	case ActionSuspend:
		return "Засыпает: ожидание, когда устройство перестанет отвечать"
	case ActionSwitchOS:
		return "Перезагружается: ожидание агента целевой ОС"
	}
	return "Перезагружается: ожидание новой загрузки"
}

// evaluate settles a device's waiting jobs against what is known now.
func (s *Service) evaluate(ctx context.Context, entityID string) {
	rows, err := s.jobRows(ctx, `entity_id = ? AND state = 'waiting'`, 10, entityID)
	if err != nil || len(rows) == 0 {
		return
	}
	agents, err := s.agents(ctx, entityID)
	if err != nil {
		return
	}
	var mon *monitoring.DeviceState
	if st, err := s.mon.State(ctx, entityID); err == nil {
		mon = &st
	}
	for _, j := range rows {
		s.evaluateJob(ctx, j, agents, mon)
	}
}

func (s *Service) evaluateJob(ctx context.Context, j jobRow, agents []AgentView, mon *monitoring.DeviceState) {
	switch j.Action {
	case ActionWake:
		since := j.RequestedAt
		if j.SentAt != nil {
			since = *j.SentAt
		}
		for _, a := range agents {
			if a.Active && a.LastHello.After(since) {
				s.finish(ctx, j.ID, JobSucceeded, "Устройство появилось в сети: агент "+or(osLabels[a.Info.OS], a.Info.OS)+" на связи")
				return
			}
		}
		if mon != nil && (mon.Status == monitoring.StatusOnline || mon.Status == monitoring.StatusDegraded) &&
			mon.LastContactAt != nil && mon.LastContactAt.After(since) {
			s.finish(ctx, j.ID, JobSucceeded, "Устройство появилось в сети (Мониторинг: "+mon.Reason+")")
		}
	case ActionShutdown, ActionSuspend:
		if j.execAt == nil {
			return
		}
		last := time.Time{}
		for _, a := range agents {
			if t := s.lastContact(a.AgentID); t.After(last) {
				last = t
			}
			if a.LastHello.After(last) {
				last = a.LastHello
			}
		}
		gone := !last.After(*j.execAt) && s.now().Sub(*j.execAt) >= silence
		if gone || (mon != nil && mon.Status == monitoring.StatusOffline && mon.LastContactAt != nil && !mon.LastContactAt.After(*j.execAt)) {
			what := "выключено"
			if j.Action == ActionSuspend {
				what = "в спящем режиме"
			}
			s.finish(ctx, j.ID, JobSucceeded, "Устройство перестало отвечать — по-видимому, "+what+
				" (подтверждения от выключенного устройства быть не может)")
		}
	case ActionReboot, ActionSwitchOS:
		if j.execAt == nil {
			return
		}
		for _, a := range agents {
			if !a.LastHello.After(*j.execAt) || a.Info.BootID == "" || a.Info.BootID == j.fromBootID {
				continue
			}
			if j.Action == ActionReboot {
				s.finish(ctx, j.ID, JobSucceeded, "Новая загрузка подтверждена агентом ("+or(osLabels[a.Info.OS], a.Info.OS)+")")
				return
			}
			if a.Info.OS == j.TargetOS {
				s.finish(ctx, j.ID, JobSucceeded, "Загружена "+osLabels[j.TargetOS]+": подтверждено агентом")
			} else {
				s.finish(ctx, j.ID, JobFailed, "Загрузилась "+or(osLabels[a.Info.OS], a.Info.OS)+" вместо "+osLabels[j.TargetOS]+
					": одноразовая загрузка не сработала. Постоянный порядок загрузки не менялся; повторять — только вручную")
			}
			return
		}
	}
}

func timeoutMessage(j jobRow, s *Service) string {
	switch j.State {
	case JobQueued:
		return fmt.Sprintf("Агент не забрал команду за %d с — команда отозвана, ничего не выполнено", s.cfg.PickupTimeoutSec)
	case JobSent:
		return "Агент забрал команду, но не сообщил о выполнении — результат неизвестен"
	}
	switch j.Action {
	case ActionWake:
		return fmt.Sprintf("Устройство не появилось в сети за %d с. Возможные причины: Wake-on-LAN выключен в UEFI или драйвере, "+
			"неверный MAC или широковещательный адрес, нет дежурного питания сетевой карты, нет агента/мониторинга на устройстве", s.cfg.BootTimeoutSec)
	case ActionShutdown, ActionSuspend:
		return "Устройство продолжает отвечать — выключение не подтверждено, состояние неизвестно"
	case ActionSwitchOS:
		return "Агент целевой ОС не появился: ОС могла не загрузиться или агент в ней не запущен. Автоматического повтора нет"
	}
	return "Новая загрузка не подтверждена за отведённое время — состояние неизвестно, автоматического повтора нет"
}

// Sweep evaluates waiting jobs and enforces deadlines.
func (s *Service) Sweep(ctx context.Context) {
	s.gcConfirmations()
	rows, err := s.jobRows(ctx, `state IN ('queued','sent','waiting')`, 500)
	if err != nil {
		s.log.Warn("power sweep", "err", err)
		return
	}
	seen := map[string]bool{}
	for _, j := range rows {
		if j.State == JobWaiting && !seen[j.EntityID] {
			seen[j.EntityID] = true
			s.evaluate(ctx, j.EntityID)
		}
	}
	now := s.now()
	for _, j := range rows {
		if !now.After(j.Deadline) {
			continue
		}
		cur, err := s.jobRows(ctx, `id = ? AND state IN ('queued','sent','waiting')`, 1, j.ID)
		if err != nil || len(cur) == 0 {
			continue
		}
		msg := timeoutMessage(cur[0], s)
		if cur[0].State == JobQueued {
			s.withdraw(ctx, cur[0].Job, JobFailed, msg)
		} else {
			s.finish(ctx, j.ID, JobTimeout, msg)
		}
	}
}

// Recover runs once at start: queued commands lived only in memory, so
// they are failed rather than re-sent (no automatic repeat of power ops).
func (s *Service) Recover(ctx context.Context) {
	rows, err := s.jobRows(ctx, `state = 'queued'`, 500)
	if err != nil {
		return
	}
	for _, j := range rows {
		s.finishFrom(ctx, j.ID, `'queued'`, JobFailed, "Core перезапущен до передачи команды агенту — команда не отправлялась")
	}
}

// Prune deletes finished jobs past retention.
func (s *Service) Prune(ctx context.Context) error {
	cut := ms(s.now().Add(-time.Duration(s.cfg.RetentionDays) * 24 * time.Hour))
	if _, err := s.db.ExecContext(ctx, `DELETE FROM power_events WHERE job_id IN
		(SELECT id FROM power_jobs WHERE finished_at IS NOT NULL AND finished_at < ?)`, cut); err != nil {
		return err
	}
	_, err := s.db.ExecContext(ctx, `DELETE FROM power_jobs WHERE finished_at IS NOT NULL AND finished_at < ?`, cut)
	return err
}

// Run enforces deadlines and retention.
func (s *Service) Run(ctx context.Context) {
	s.Recover(ctx)
	sweep := time.NewTicker(2 * time.Second)
	defer sweep.Stop()
	prune := time.NewTicker(time.Hour)
	defer prune.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-sweep.C:
			s.Sweep(ctx)
		case <-prune.C:
			if err := s.Prune(ctx); err != nil {
				s.log.Warn("power retention", "err", err)
			}
		}
	}
}
