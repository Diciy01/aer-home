package power

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"log/slog"
	"regexp"
	"slices"
	"strings"
	"sync"
	"time"

	"aerhome/core/internal/foundation/config"
	"aerhome/core/internal/modules/monitoring"
	"aerhome/core/internal/modules/registry"
)

// Errors mapped to API responses.
var ErrNotFound = errors.New("not found")

// ValidationError lists field problems (422).
type ValidationError struct{ Fields map[string]string }

func (e *ValidationError) Error() string { return "validation failed" }

// RefusedError is a refused operation with a stable reason code.
type RefusedError struct {
	Status  int
	Code    string // CONFLICT | PERMISSION_REQUIRED | UNSUPPORTED | UNAVAILABLE
	Reason  string
	Message string
}

func (e *RefusedError) Error() string { return e.Message }

// Service is the Power control plane.
type Service struct {
	db  *sql.DB
	reg registry.Reader
	mon *monitoring.Service
	cfg config.Power
	log *slog.Logger
	now func() time.Time
	net Net

	createMu sync.Mutex // job admission (busy/limit checks + insert)
	mu       sync.Mutex
	confirms map[string]Confirmation
	queues   map[string]*agentQueue // agentID → commands
	lastSeen map[string]time.Time   // agentID → last hello/poll/event
	macs     map[string]bool        // Core's own MACs (same-machine check)
	macsAt   time.Time
}

type agentQueue struct {
	cmds []Command
	wake chan struct{}
}

// NewService builds the service; now and n may be nil.
func NewService(db *sql.DB, reg registry.Reader, mon *monitoring.Service, cfg config.Power, log *slog.Logger, now func() time.Time, n Net) *Service {
	if now == nil {
		now = time.Now
	}
	if log == nil {
		log = slog.New(slog.DiscardHandler)
	}
	if n == nil {
		n = SystemNet{}
	}
	return &Service{db: db, reg: reg, mon: mon, cfg: cfg, log: log, now: now, net: n,
		confirms: map[string]Confirmation{}, queues: map[string]*agentQueue{}, lastSeen: map[string]time.Time{}}
}

func ms(t time.Time) int64 { return t.UTC().UnixMilli() }

func fromMS(v int64) time.Time { return time.UnixMilli(v).UTC() }

func fromNullMS(v sql.NullInt64) *time.Time {
	if !v.Valid {
		return nil
	}
	t := fromMS(v.Int64)
	return &t
}

func boolInt(b bool) int {
	if b {
		return 1
	}
	return 0
}

func truncate(s string, n int) string {
	if r := []rune(s); len(r) > n {
		return string(r[:n])
	}
	return s
}

var actionLabels = map[string]string{
	ActionWake: "Включить", ActionShutdown: "Выключить", ActionReboot: "Перезагрузить",
	ActionSuspend: "Перевести в сон", ActionSwitchOS: "Сменить ОС", ActionCheck: "Проверить состояние",
}

var osLabels = map[string]string{"linux": "Ubuntu", "windows": "Windows"}

// capFor is the Registry capability an action needs.
var capFor = map[string]string{
	ActionWake: "power.wake", ActionShutdown: "power.shutdown", ActionReboot: "power.reboot",
	ActionSuspend: "power.suspend", ActionSwitchOS: "power.switch_os",
}

func dangerous(a string) bool {
	return a == ActionShutdown || a == ActionReboot || a == ActionSuspend || a == ActionSwitchOS
}

// ---- policy and WoL target ----

// Policy returns the owner's policy for a device (defaults when unset).
func (s *Service) Policy(ctx context.Context, entityID string) (Policy, error) {
	p := DefaultPolicy()
	var en, w, sd, rb, sp, sw, bl int
	err := s.db.QueryRowContext(ctx, `SELECT enabled, wake, shutdown, reboot, suspend, switch_os, allow_bitlocker, revision
		FROM power_policies WHERE entity_id = ?`, entityID).Scan(&en, &w, &sd, &rb, &sp, &sw, &bl, &p.Revision)
	if errors.Is(err, sql.ErrNoRows) {
		return p, nil
	}
	p.Enabled, p.Wake, p.Shutdown, p.Reboot, p.Suspend, p.SwitchOS, p.AllowWithBitLocker =
		en == 1, w == 1, sd == 1, rb == 1, sp == 1, sw == 1, bl == 1
	return p, err
}

func (s *Service) entity(ctx context.Context, id string) (registry.Entity, error) {
	e, err := s.reg.Get(ctx, id)
	if errors.Is(err, registry.ErrNotFound) {
		return e, ErrNotFound
	}
	return e, err
}

// SetPolicy stores the owner's policy; switching an action off withdraws
// its queued (not yet delivered) jobs.
func (s *Service) SetPolicy(ctx context.Context, entityID string, p Policy) (Device, error) {
	if _, err := s.entity(ctx, entityID); err != nil {
		return Device{}, err
	}
	cur, err := s.Policy(ctx, entityID)
	if err != nil {
		return Device{}, err
	}
	if p.Revision != 0 && cur.Revision != 0 && p.Revision != cur.Revision {
		return Device{}, &RefusedError{Status: 409, Code: "CONFLICT", Reason: "revision_mismatch", Message: "Политика изменена в другом окне"}
	}
	if _, err := s.db.ExecContext(ctx, `INSERT INTO power_policies (entity_id, enabled, wake, shutdown, reboot, suspend, switch_os, allow_bitlocker, revision, updated_at)
		VALUES (?,?,?,?,?,?,?,?,1,?) ON CONFLICT (entity_id) DO UPDATE SET enabled = excluded.enabled, wake = excluded.wake,
		shutdown = excluded.shutdown, reboot = excluded.reboot, suspend = excluded.suspend, switch_os = excluded.switch_os,
		allow_bitlocker = excluded.allow_bitlocker, revision = power_policies.revision + 1, updated_at = excluded.updated_at`,
		entityID, boolInt(p.Enabled), boolInt(p.Wake), boolInt(p.Shutdown), boolInt(p.Reboot), boolInt(p.Suspend),
		boolInt(p.SwitchOS), boolInt(p.AllowWithBitLocker), ms(s.now())); err != nil {
		return Device{}, err
	}
	s.mon.RecordEvent(ctx, entityID, "power_policy", monitoring.SeverityInfo, "Изменена политика управления питанием")
	allowed := map[string]bool{ActionWake: p.Wake, ActionShutdown: p.Shutdown, ActionReboot: p.Reboot,
		ActionSuspend: p.Suspend, ActionSwitchOS: p.SwitchOS, ActionCheck: true}
	jobs, err := s.jobs(ctx, `entity_id = ? AND state = 'queued'`, 50, entityID)
	if err != nil {
		return Device{}, err
	}
	for _, j := range jobs {
		if !p.Enabled || !allowed[j.Action] {
			s.withdraw(ctx, j, JobCancelled, "Разрешение отозвано владельцем до передачи команды")
		}
	}
	return s.Device(ctx, entityID)
}

// WoLTargetOf returns the stored WoL target, or nil.
func (s *Service) WoLTargetOf(ctx context.Context, entityID string) (*WoLTarget, error) {
	var t WoLTarget
	err := s.db.QueryRowContext(ctx, `SELECT mac, broadcast, iface, port FROM power_wol WHERE entity_id = ?`, entityID).
		Scan(&t.MAC, &t.Broadcast, &t.Interface, &t.Port)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	return &t, err
}

var ifaceName = regexp.MustCompile(`^[A-Za-z0-9._:@-]{1,32}$`)

// SetWoL validates and stores how to wake a device.
func (s *Service) SetWoL(ctx context.Context, entityID string, t WoLTarget) (Device, error) {
	if _, err := s.entity(ctx, entityID); err != nil {
		return Device{}, err
	}
	v := map[string]string{}
	mac, err := ParseMAC(t.MAC)
	if err != nil {
		v["mac"] = err.Error()
	}
	if t.Broadcast == "" {
		t.Broadcast = "255.255.255.255"
	}
	if _, err := CheckDestination(t.Broadcast); err != nil {
		v["broadcast"] = err.Error()
	}
	if t.Port != 0 && (t.Port < 1 || t.Port > 65535) {
		v["port"] = "Порт UDP 1–65535 (обычно 9)"
	}
	if t.Interface != "" {
		if !ifaceName.MatchString(t.Interface) {
			v["interface"] = "Имя интерфейса"
		} else if ifs, err := s.net.Interfaces(); err == nil && !slices.ContainsFunc(ifs, func(i Interface) bool { return i.Name == t.Interface }) {
			v["interface"] = "Нет такого интерфейса на компьютере с Core"
		}
	}
	if len(v) > 0 {
		return Device{}, &ValidationError{Fields: v}
	}
	if _, err := s.db.ExecContext(ctx, `INSERT INTO power_wol (entity_id, mac, broadcast, iface, port, updated_at) VALUES (?,?,?,?,?,?)
		ON CONFLICT (entity_id) DO UPDATE SET mac = excluded.mac, broadcast = excluded.broadcast, iface = excluded.iface,
		port = excluded.port, updated_at = excluded.updated_at`, entityID, mac, t.Broadcast, t.Interface, t.Port, ms(s.now())); err != nil {
		return Device{}, err
	}
	s.mon.RecordEvent(ctx, entityID, "power_wol", monitoring.SeverityInfo, "Настроено включение по сети (MAC "+mac+")")
	return s.Device(ctx, entityID)
}

// DeleteWoL forgets the WoL target.
func (s *Service) DeleteWoL(ctx context.Context, entityID string) (Device, error) {
	if _, err := s.entity(ctx, entityID); err != nil {
		return Device{}, err
	}
	if _, err := s.db.ExecContext(ctx, `DELETE FROM power_wol WHERE entity_id = ?`, entityID); err != nil {
		return Device{}, err
	}
	return s.Device(ctx, entityID)
}

// Interfaces lists Core's own network interfaces (WoL sending side).
func (s *Service) Interfaces() ([]Interface, error) { return s.net.Interfaces() }

// ---- devices ----

var powerCaps = []string{"power.wake", "power.shutdown", "power.reboot", "power.suspend", "power.switch_os"}

// Devices lists entities that declare power capabilities, have a power
// agent or a WoL target.
func (s *Service) Devices(ctx context.Context) ([]Device, error) {
	seen := map[string]bool{}
	var idList []string
	add := func(id string) {
		if !seen[id] {
			seen[id] = true
			idList = append(idList, id)
		}
	}
	for _, c := range powerCaps {
		for offset := 0; ; offset += 200 {
			p, err := s.reg.List(ctx, registry.ListFilter{Capability: c, Limit: 200, Offset: offset})
			if err != nil {
				return nil, err
			}
			for _, e := range p.Items {
				add(e.ID)
			}
			if offset+len(p.Items) >= p.Total || len(p.Items) == 0 {
				break
			}
		}
	}
	for _, q := range []string{`SELECT DISTINCT entity_id FROM power_hosts`, `SELECT entity_id FROM power_wol`} {
		rows, err := s.db.QueryContext(ctx, q)
		if err != nil {
			return nil, err
		}
		for rows.Next() {
			var id string
			if rows.Scan(&id) == nil {
				add(id)
			}
		}
		rows.Close()
	}
	out := []Device{}
	for _, id := range idList {
		d, err := s.Device(ctx, id)
		if errors.Is(err, ErrNotFound) {
			continue
		}
		if err != nil {
			return nil, err
		}
		if d.Type == "" {
			continue
		}
		out = append(out, d)
	}
	slices.SortFunc(out, func(a, b Device) int { return strings.Compare(a.Name, b.Name) })
	return out, nil
}

func (s *Service) agents(ctx context.Context, entityID string) ([]AgentView, error) {
	revoked := map[string]bool{}
	names := map[string]string{}
	if list, err := s.mon.ListAgents(ctx, entityID); err == nil {
		for _, a := range list {
			revoked[a.ID] = a.RevokedAt != nil
			names[a.ID] = a.Name
		}
	}
	rows, err := s.db.QueryContext(ctx, `SELECT agent_id, info, last_hello FROM power_hosts WHERE entity_id = ? ORDER BY last_hello DESC`, entityID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []AgentView{}
	timeout := time.Duration(s.cfg.AgentTimeoutSec) * time.Second
	for rows.Next() {
		var a AgentView
		var info string
		var last int64
		if err := rows.Scan(&a.AgentID, &info, &last); err != nil {
			return nil, err
		}
		_ = json.Unmarshal([]byte(info), &a.Info)
		a.LastHello = fromMS(last)
		a.Name = names[a.AgentID]
		a.Active = !revoked[a.AgentID] && s.now().Sub(a.LastHello) <= timeout
		out = append(out, a)
	}
	return out, rows.Err()
}

func activeAgent(list []AgentView) *AgentView {
	for i := range list {
		if list[i].Active {
			return &list[i]
		}
	}
	return nil
}

// coreMACs lists Core's own NICs, re-read at most every 30 s (listing
// interfaces is a netlink round trip per call).
func (s *Service) coreMACs() map[string]bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.macs == nil || time.Since(s.macsAt) > 30*time.Second {
		s.macs, s.macsAt = localMACs(s.net), time.Now()
	}
	return s.macs
}

// sameMachine: the device's NIC is one of Core's own (Core runs on it).
func (s *Service) sameMachine(wol *WoLTarget, agents []AgentView) bool {
	local := s.coreMACs()
	if wol != nil && local[strings.ToLower(wol.MAC)] {
		return true
	}
	for _, a := range agents {
		for _, m := range a.Info.MACs {
			if local[strings.ToLower(m)] {
				return true
			}
		}
	}
	return false
}

// Device is the detail view of one device.
func (s *Service) Device(ctx context.Context, entityID string) (Device, error) {
	e, err := s.entity(ctx, entityID)
	if err != nil {
		return Device{}, err
	}
	d := Device{EntityID: e.ID, Name: e.Name, Type: e.Type, Declared: []string{}, Agents: []AgentView{}}
	for _, c := range e.Capabilities {
		if slices.Contains(powerCaps, c) {
			d.Declared = append(d.Declared, c)
		}
	}
	if d.Policy, err = s.Policy(ctx, entityID); err != nil {
		return Device{}, err
	}
	if d.WoL, err = s.WoLTargetOf(ctx, entityID); err != nil {
		return Device{}, err
	}
	if d.Agents, err = s.agents(ctx, entityID); err != nil {
		return Device{}, err
	}
	if st, err := s.mon.State(ctx, entityID); err == nil {
		d.MonitoringStatus = string(st.Status)
		d.LastContact = st.LastContactAt
	}
	act := activeAgent(d.Agents)
	if act != nil {
		d.CurrentOS = act.Info.OS
		if d.LastContact == nil || act.LastHello.After(*d.LastContact) {
			t := act.LastHello
			d.LastContact = &t
		}
	}
	d.SameMachine = s.sameMachine(d.WoL, d.Agents)
	if d.SameMachine {
		d.SameMachineNote = "AER Core работает на этом же компьютере: выключенный компьютер не может включить сам себя, " +
			"а после выключения Core тоже остановится. Для Wake-on-LAN нужен постоянно включённый сервер с Core (этап M13)."
	}
	if jobs, err := s.jobs(ctx, `entity_id = ? AND state IN ('queued','sent','waiting')`, 1, entityID); err == nil && len(jobs) > 0 {
		d.ActiveJob = &jobs[0]
	}
	if jobs, err := s.jobs(ctx, `entity_id = ?`, 1, entityID); err == nil && len(jobs) > 0 {
		d.LastJob = &jobs[0]
	}
	d.State, d.StateReason = s.state(d, act)
	d.Actions = s.actionsFor(&d, e)
	return d, nil
}

var jobStates = map[string]string{
	ActionWake: "waking", ActionShutdown: "shutting_down", ActionReboot: "rebooting",
	ActionSuspend: "suspending", ActionSwitchOS: "switching",
}

func (s *Service) state(d Device, act *AgentView) (string, string) {
	if j := d.ActiveJob; j != nil && jobStates[j.Action] != "" {
		return jobStates[j.Action], "Выполняется «" + actionLabels[j.Action] + "»: " + j.Message
	}
	switch {
	case act != nil:
		return "online", "Агент питания на связи (" + or(osLabels[act.Info.OS], act.Info.OS) + ")"
	case d.MonitoringStatus == string(monitoring.StatusOnline) || d.MonitoringStatus == string(monitoring.StatusDegraded):
		return "online", "Мониторинг: устройство на связи"
	case d.MonitoringStatus == string(monitoring.StatusOffline):
		return "offline", "Не отвечает: выключено, спит, загружает другую ОС без агента или нет сети"
	}
	return "unknown", "Нет данных: агент питания не подключён, мониторинг не настроен"
}

func or(a, b string) string {
	if a != "" {
		return a
	}
	return b
}

func online(d *Device, act *AgentView) bool {
	return act != nil || d.MonitoringStatus == string(monitoring.StatusOnline) || d.MonitoringStatus == string(monitoring.StatusDegraded)
}

// bitlocker is the most specific BitLocker state any agent of the device reported.
func bitlocker(agents []AgentView) string {
	st := "unknown"
	for _, a := range agents {
		switch a.Info.BitLocker {
		case "on":
			return "on"
		case "off":
			st = "off"
		}
	}
	return st
}

func (s *Service) actionsFor(d *Device, e registry.Entity) []ActionInfo {
	act := activeAgent(d.Agents)
	out := []ActionInfo{}
	for _, a := range AllActions {
		info := ActionInfo{ID: a, Label: actionLabels[a], Dangerous: dangerous(a)}
		reason := s.unavailable(d, e, act, a)
		if a == ActionSwitchOS {
			info.Targets = s.targets(d, act)
			if reason == "" && !slices.ContainsFunc(info.Targets, func(t Target) bool { return t.Available }) {
				reason = "Нет доступной другой ОС для загрузки"
				for _, t := range info.Targets {
					if t.Reason != "" && t.OS != d.CurrentOS {
						reason = t.Reason
						break
					}
				}
			}
		}
		info.Available, info.Reason = reason == "", reason
		out = append(out, info)
	}
	return out
}

func policyAllows(p Policy, a string) bool {
	switch a {
	case ActionWake:
		return p.Wake
	case ActionShutdown:
		return p.Shutdown
	case ActionReboot:
		return p.Reboot
	case ActionSuspend:
		return p.Suspend
	case ActionSwitchOS:
		return p.SwitchOS
	}
	return true
}

var agentActionKey = map[string]string{ActionShutdown: "shutdown", ActionReboot: "reboot", ActionSuspend: "suspend", ActionSwitchOS: "bootNext"}

func (s *Service) unavailable(d *Device, e registry.Entity, act *AgentView, a string) string {
	if e.Archived {
		return "Устройство в архиве Registry"
	}
	if a == ActionCheck {
		return ""
	}
	if !d.Policy.Enabled {
		return "Управление питанием выключено владельцем"
	}
	if c := capFor[a]; !slices.Contains(e.Capabilities, c) {
		return "В Registry у устройства нет возможности «" + c + "»"
	}
	if !policyAllows(d.Policy, a) {
		return "Действие запрещено политикой устройства"
	}
	if j := d.ActiveJob; j != nil {
		return "Уже выполняется «" + actionLabels[j.Action] + "»"
	}
	if a == ActionWake {
		switch {
		case d.SameMachine:
			return "Core работает на этом же компьютере — включить его по сети некому"
		case d.WoL == nil:
			return "Не настроен MAC-адрес для Wake-on-LAN"
		case !s.cfg.WoL.Enabled:
			return "Отправка Wake-on-LAN выключена в конфигурации Core (power.wol.enabled)"
		case online(d, act):
			return "Компьютер уже включён"
		}
		return ""
	}
	if act == nil {
		if d.MonitoringStatus == string(monitoring.StatusOffline) {
			return "Компьютер не отвечает — команду некому выполнить"
		}
		return "Агент питания (aer-power-host) не на связи"
	}
	if c, ok := act.Info.Actions[agentActionKey[a]]; !ok || !c.Supported {
		if ok && c.Reason != "" {
			return c.Reason
		}
		return "Агент не поддерживает это действие на " + or(osLabels[act.Info.OS], act.Info.OS)
	}
	if a == ActionSwitchOS && bitlocker(d.Agents) == "on" && !d.Policy.AllowWithBitLocker {
		return "BitLocker включён: смена загрузки может запросить ключ восстановления. Разрешите в политике, когда ключ под рукой"
	}
	return ""
}

func (s *Service) targets(d *Device, act *AgentView) []Target {
	out := []Target{}
	if act == nil {
		return out
	}
	for _, osID := range []string{"linux", "windows"} {
		t := Target{OS: osID, Label: osLabels[osID]}
		var found []BootEntry
		for _, e := range act.Info.BootEntries {
			if e.OS == osID {
				found = append(found, e)
			}
		}
		switch {
		case osID == act.Info.OS:
			t.Reason = "Уже загружена"
		case len(found) == 0:
			t.Reason = "Загрузочная запись " + osLabels[osID] + " не найдена"
		case len(found) > 1:
			t.Reason = "Несколько загрузочных записей " + osLabels[osID] + " — выбор неоднозначен"
		default:
			t.EntryID, t.Available = found[0].ID, true
		}
		out = append(out, t)
	}
	return out
}
