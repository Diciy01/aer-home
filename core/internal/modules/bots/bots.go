package bots

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"regexp"
	"slices"
	"strings"
	"time"

	"aerhome/core/internal/foundation/config"
	"aerhome/core/internal/modules/monitoring"
	"aerhome/core/internal/modules/registry"
)

// NewBot adds a bot: either a new Registry entity or an existing one.
type NewBot struct {
	EntityID    string   `json:"entityId"`
	Name        string   `json:"name"`
	Type        string   `json:"type"`
	Description string   `json:"description"`
	Tags        []string `json:"tags"`
	HostID      string   `json:"hostId"`
	DependsOn   []string `json:"dependsOn"`

	Runtime              string   `json:"runtime"`
	Category             string   `json:"category"`
	ControllerID         string   `json:"controllerId"`
	N8NInstanceID        string   `json:"n8nInstanceId"`
	N8NWorkflowIDs       []string `json:"n8nWorkflowIds"`
	TelegramTokenID      string   `json:"telegramTokenId"`
	Container            string   `json:"container"`
	HeartbeatIntervalSec int      `json:"heartbeatIntervalSec"`
	HeartbeatTimeoutSec  int      `json:"heartbeatTimeoutSec"`
	LogSource            string   `json:"logSource"`
	Notes                string   `json:"notes"`
	// CreateCredential issues a heartbeat credential (token shown once).
	CreateCredential bool `json:"createCredential"`
}

// BotPatch edits a bot; Revision is the bot config revision.
type BotPatch struct {
	Revision    int       `json:"revision"`
	Name        *string   `json:"name"`
	Description *string   `json:"description"`
	Tags        *[]string `json:"tags"`
	HostID      *string   `json:"hostId"`
	DependsOn   *[]string `json:"dependsOn"`

	Runtime              *string   `json:"runtime"`
	Category             *string   `json:"category"`
	ControllerID         *string   `json:"controllerId"`
	N8NInstanceID        *string   `json:"n8nInstanceId"`
	N8NWorkflowIDs       *[]string `json:"n8nWorkflowIds"`
	TelegramTokenID      *string   `json:"telegramTokenId"`
	Container            *string   `json:"container"`
	HeartbeatIntervalSec *int      `json:"heartbeatIntervalSec"`
	HeartbeatTimeoutSec  *int      `json:"heartbeatTimeoutSec"`
	LogSource            *string   `json:"logSource"`
	Notes                *string   `json:"notes"`
}

// Created is the result of adding a bot.
type Created struct {
	Bot Detail `json:"bot"`
	// HeartbeatToken is shown exactly once (when createCredential was set).
	HeartbeatToken string `json:"heartbeatToken,omitempty"`
}

var (
	containerRe = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$`)
	workflowRe  = regexp.MustCompile(`^[A-Za-z0-9_-]{1,40}$`)
)

func defaultRuntime(typ string, c Config) string {
	switch {
	case typ == "telegram_bot":
		return "telegram"
	case typ == "docker_container" || c.Container != "":
		return "docker"
	case c.N8NInstanceID != "":
		return "n8n"
	case typ == "service":
		return "service"
	case typ == "process":
		return "python"
	}
	return "custom"
}

func (s *Service) defaultLogSource(c Config) string {
	if c.N8NInstanceID != "" {
		return "n8n"
	}
	if ctl, ok := s.cfg.Controller(c.ControllerID); ok && ctl.Kind == "process" {
		return "controller"
	}
	if c.Runtime == "docker" {
		return "docker"
	}
	return "heartbeat"
}

// validate checks a config against the declared adapters.
func (s *Service) validate(ctx context.Context, c *Config, v *ValidationError) {
	if !slices.Contains(Runtimes, c.Runtime) {
		v.add("runtime", "python, docker, telegram, n8n, service или custom")
	}
	c.Category = strings.TrimSpace(c.Category)
	if len([]rune(c.Category)) > 40 {
		v.add("category", "Категория до 40 символов")
	}
	if c.ControllerID != "" {
		if _, ok := s.cfg.Controller(c.ControllerID); !ok {
			v.add("controllerId", "Такого управляющего адаптера нет в конфигурации Core")
		} else if other, err := s.controllerUser(ctx, c.ControllerID, c.EntityID); err == nil && other != "" {
			v.add("controllerId", "Адаптер уже используется ботом «"+other+"»")
		}
	}
	if c.N8NInstanceID != "" {
		if _, ok := s.cfg.N8NByID(c.N8NInstanceID); !ok {
			v.add("n8nInstanceId", "Такого экземпляра n8n нет в конфигурации Core")
		}
	}
	if len(c.N8NWorkflowIDs) > 50 {
		v.add("n8nWorkflowIds", "Не больше 50 workflows")
	}
	for _, w := range c.N8NWorkflowIDs {
		if !workflowRe.MatchString(w) {
			v.add("n8nWorkflowIds", "Идентификатор workflow: латиница, цифры, _ и -")
		}
	}
	if c.TelegramTokenID != "" {
		if _, ok := s.cfg.TelegramTokenByID(c.TelegramTokenID); !ok {
			v.add("telegramTokenId", "Такого файла токена нет в конфигурации Core")
		}
	}
	if c.Container != "" && !containerRe.MatchString(c.Container) {
		v.add("container", "Имя контейнера: латиница, цифры, _ . -")
	}
	if c.HeartbeatIntervalSec < 5 || c.HeartbeatIntervalSec > 3600 {
		v.add("heartbeatIntervalSec", "От 5 до 3600 секунд")
	}
	if c.HeartbeatTimeoutSec < 10 || c.HeartbeatTimeoutSec > 86400 || c.HeartbeatTimeoutSec < 2*c.HeartbeatIntervalSec {
		v.add("heartbeatTimeoutSec", "От 10 до 86400 секунд и не меньше двух интервалов heartbeat")
	}
	if !slices.Contains(LogSources, c.LogSource) {
		v.add("logSource", "heartbeat, controller, docker, n8n или none")
	}
	if len([]rune(c.Notes)) > 1000 {
		v.add("notes", "Заметка до 1000 символов")
	}
}

// controllerUser names another active bot using the controller.
func (s *Service) controllerUser(ctx context.Context, ctlID, self string) (string, error) {
	rows, err := s.db.QueryContext(ctx, `SELECT entity_id FROM bot_configs WHERE controller_id = ? AND entity_id != ?`, ctlID, self)
	if err != nil {
		return "", err
	}
	var ids []string
	for rows.Next() {
		var id string
		if rows.Scan(&id) == nil {
			ids = append(ids, id)
		}
	}
	rows.Close()
	for _, id := range ids {
		if e, err := s.reg.Get(ctx, id); err == nil && !e.Archived {
			return e.Name, nil
		}
	}
	return "", nil
}

// Create adds a bot. A new Registry entity is created first (Registry
// validates it), then the bot config; if the latter fails the new entity
// is archived so no half-made bot remains visible.
func (s *Service) Create(ctx context.Context, in NewBot) (Created, error) {
	v := &ValidationError{}
	c := Config{EntityID: in.EntityID, Runtime: in.Runtime, Category: in.Category, ControllerID: in.ControllerID,
		N8NInstanceID: in.N8NInstanceID, N8NWorkflowIDs: nonNil(in.N8NWorkflowIDs), TelegramTokenID: in.TelegramTokenID,
		Container: strings.TrimSpace(in.Container), HeartbeatIntervalSec: in.HeartbeatIntervalSec,
		HeartbeatTimeoutSec: in.HeartbeatTimeoutSec, LogSource: in.LogSource, Notes: in.Notes}
	typ := in.Type
	var existing *registry.Entity
	if in.EntityID != "" {
		e, err := s.reg.Get(ctx, in.EntityID)
		if errors.Is(err, registry.ErrNotFound) {
			v.add("entityId", "Объект Registry не найден")
			return Created{}, v
		}
		if err != nil {
			return Created{}, err
		}
		if e.Archived {
			v.add("entityId", "Объект в архиве Registry")
		}
		if _, err := s.config(ctx, e.ID); err == nil {
			return Created{}, &ConflictError{Reason: "duplicate", Message: "Этот объект уже добавлен как бот"}
		}
		typ, existing = e.Type, &e
	}
	if !slices.Contains(BotTypes, typ) {
		v.add("type", "Тип бота: telegram_bot, process, service, automation, application или docker_container")
	}
	if c.Runtime == "" {
		c.Runtime = defaultRuntime(typ, c)
	}
	if c.HeartbeatIntervalSec == 0 {
		c.HeartbeatIntervalSec = 15
	}
	if c.HeartbeatTimeoutSec == 0 {
		c.HeartbeatTimeoutSec = max(60, 4*c.HeartbeatIntervalSec)
	}
	if c.LogSource == "" {
		c.LogSource = s.defaultLogSource(c)
	}
	s.validate(ctx, &c, v)
	s.checkRefs(ctx, in.HostID, in.DependsOn, in.EntityID, v)
	if err := v.orNil(); err != nil {
		return Created{}, err
	}

	var e registry.Entity
	if existing == nil {
		attrs, _ := json.Marshal(map[string]any{"monitoring": s.monitoringAttrs(c)})
		created, err := s.reg.Create(ctx, registry.NewEntity{Name: in.Name, Type: typ, Description: in.Description,
			Tags: in.Tags, Discovery: registry.DiscoveryManual, Attributes: attrs})
		if err != nil {
			return Created{}, err
		}
		e = created
	} else {
		updated, err := s.syncAttributes(ctx, *existing, c)
		if err != nil {
			return Created{}, err
		}
		e = updated
	}
	c.EntityID = e.ID
	now := s.now().UTC().Truncate(time.Millisecond)
	c.Revision, c.CreatedAt, c.UpdatedAt = 1, now, now
	wf, _ := json.Marshal(c.N8NWorkflowIDs)
	if _, err := s.db.ExecContext(ctx, `INSERT INTO bot_configs (entity_id, runtime, category, controller_id, n8n_instance_id, n8n_workflow_ids,
		telegram_token_id, container, heartbeat_interval, heartbeat_timeout, log_source, notes, revision, created_at, updated_at)
		VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)`,
		c.EntityID, c.Runtime, c.Category, c.ControllerID, c.N8NInstanceID, string(wf), c.TelegramTokenID, c.Container,
		c.HeartbeatIntervalSec, c.HeartbeatTimeoutSec, c.LogSource, c.Notes, c.Revision, ms(now), ms(now)); err != nil {
		if existing == nil {
			_, _ = s.reg.Archive(context.WithoutCancel(ctx), e.ID, e.Revision)
		}
		return Created{}, err
	}
	if err := s.setRelations(ctx, e.ID, &in.HostID, &in.DependsOn); err != nil {
		s.log.Warn("bot relations", "err", err)
	}
	s.mon.RecordEvent(ctx, e.ID, "bot_added", monitoring.SeverityInfo, "Добавлен бот «"+e.Name+"» ("+c.Runtime+")")
	var out Created
	if in.CreateCredential {
		cr, err := s.mon.CreateAgent(ctx, e.ID, "heartbeat "+truncate(e.Name, 60), "bot")
		if err != nil {
			return Created{}, err
		}
		out.HeartbeatToken = cr.Token
	}
	s.mon.RefreshEntity(ctx, e.ID)
	s.invalidateList()
	d, err := s.Get(ctx, e.ID)
	out.Bot = d
	return out, err
}

func nonNil(xs []string) []string {
	if xs == nil {
		return []string{}
	}
	return xs
}

func truncate(s string, n int) string {
	r := []rune(s)
	if len(r) <= n {
		return s
	}
	return string(r[:n])
}

func (s *Service) checkRefs(ctx context.Context, host string, deps []string, self string, v *ValidationError) {
	if host != "" {
		if e, err := s.reg.Get(ctx, host); err != nil || e.Archived {
			v.add("hostId", "Сервер не найден в Registry")
		} else if host == self {
			v.add("hostId", "Бот не может работать сам на себе")
		}
	}
	if len(deps) > 20 {
		v.add("dependsOn", "Не больше 20 зависимостей")
	}
	for _, d := range deps {
		if _, err := s.reg.Get(ctx, d); err != nil || d == self {
			v.add("dependsOn", "Зависимость не найдена в Registry")
		}
	}
}

// monitoringAttrs are the Registry attributes Monitoring reads for a bot.
func (s *Service) monitoringAttrs(c Config) map[string]any {
	m := map[string]any{"heartbeatTimeoutSec": c.HeartbeatTimeoutSec}
	ctr := c.Container
	if ctl, ok := s.cfg.Controller(c.ControllerID); ok && ctl.Kind == "docker" && ctr == "" {
		ctr = ctl.Container
	}
	if ctr != "" {
		m["container"] = ctr
	}
	if inst, ok := s.cfg.N8NByID(c.N8NInstanceID); ok {
		m["url"] = strings.TrimRight(inst.BaseURL, "/") + "/healthz"
	}
	return m
}

// syncAttributes merges the bot's monitoring settings into the entity's
// attributes.monitoring, keeping every other attribute as it is.
func (s *Service) syncAttributes(ctx context.Context, e registry.Entity, c Config) (registry.Entity, error) {
	attrs := map[string]any{}
	_ = json.Unmarshal(e.Attributes, &attrs)
	mon, _ := attrs["monitoring"].(map[string]any)
	if mon == nil {
		mon = map[string]any{}
	}
	for _, k := range []string{"heartbeatTimeoutSec", "container", "url"} {
		delete(mon, k)
	}
	for k, val := range s.monitoringAttrs(c) {
		mon[k] = val
	}
	attrs["monitoring"] = mon
	raw, _ := json.Marshal(attrs)
	if jsonEqual(raw, e.Attributes) {
		return e, nil
	}
	r := json.RawMessage(raw)
	return s.reg.Update(ctx, e.ID, registry.EntityPatch{Revision: e.Revision, Attributes: &r})
}

func jsonEqual(a, b []byte) bool {
	var x, y any
	if json.Unmarshal(a, &x) != nil || json.Unmarshal(b, &y) != nil {
		return false
	}
	ja, _ := json.Marshal(x)
	jb, _ := json.Marshal(y)
	return string(ja) == string(jb)
}

var placementKinds = []string{"runs_on", "hosted_by", "installed_on"}

// setRelations makes Registry relations match the host and dependencies.
func (s *Service) setRelations(ctx context.Context, id string, host *string, deps *[]string) error {
	rels, err := s.reg.Relations(ctx, id)
	if err != nil {
		return err
	}
	if host != nil {
		have := ""
		for _, r := range rels {
			if r.Relation.FromID == id && r.Relation.Kind == "runs_on" {
				if r.Relation.ToID == *host {
					have = *host
					continue
				}
				if err := s.reg.DeleteRelation(ctx, r.Relation.ID); err != nil {
					return err
				}
			}
		}
		if *host != "" && have == "" {
			if _, err := s.reg.AddRelation(ctx, id, "runs_on", *host, ""); err != nil {
				return err
			}
		}
	}
	if deps != nil {
		want := map[string]bool{}
		for _, d := range *deps {
			want[d] = true
		}
		for _, r := range rels {
			if r.Relation.FromID == id && r.Relation.Kind == "depends_on" {
				if want[r.Relation.ToID] {
					delete(want, r.Relation.ToID)
					continue
				}
				if err := s.reg.DeleteRelation(ctx, r.Relation.ID); err != nil {
					return err
				}
			}
		}
		for _, d := range *deps {
			if want[d] {
				if _, err := s.reg.AddRelation(ctx, id, "depends_on", d, ""); err != nil {
					return err
				}
				delete(want, d)
			}
		}
	}
	return nil
}

// Update edits the bot config and the Registry fields it shows.
func (s *Service) Update(ctx context.Context, id string, p BotPatch) (Detail, error) {
	c, err := s.config(ctx, id)
	if err != nil {
		return Detail{}, err
	}
	if p.Revision != c.Revision {
		return Detail{}, &ConflictError{Reason: "revision_mismatch", Message: "Бот изменён в другом окне — обновите данные", CurrentRevision: c.Revision}
	}
	e, err := s.reg.Get(ctx, id)
	if err != nil {
		return Detail{}, err
	}
	set := func(dst *string, src *string) {
		if src != nil {
			*dst = strings.TrimSpace(*src)
		}
	}
	set(&c.Runtime, p.Runtime)
	set(&c.Category, p.Category)
	set(&c.ControllerID, p.ControllerID)
	set(&c.N8NInstanceID, p.N8NInstanceID)
	set(&c.TelegramTokenID, p.TelegramTokenID)
	set(&c.Container, p.Container)
	set(&c.LogSource, p.LogSource)
	if p.Notes != nil {
		c.Notes = *p.Notes
	}
	if p.N8NWorkflowIDs != nil {
		c.N8NWorkflowIDs = nonNil(*p.N8NWorkflowIDs)
	}
	if p.HeartbeatIntervalSec != nil {
		c.HeartbeatIntervalSec = *p.HeartbeatIntervalSec
	}
	if p.HeartbeatTimeoutSec != nil {
		c.HeartbeatTimeoutSec = *p.HeartbeatTimeoutSec
	}
	v := &ValidationError{}
	s.validate(ctx, &c, v)
	var host string
	var deps []string
	if p.HostID != nil {
		host = *p.HostID
	}
	if p.DependsOn != nil {
		deps = *p.DependsOn
	}
	s.checkRefs(ctx, host, deps, id, v)
	if err := v.orNil(); err != nil {
		return Detail{}, err
	}
	if p.Name != nil || p.Description != nil || p.Tags != nil {
		if e, err = s.reg.Update(ctx, id, registry.EntityPatch{Revision: e.Revision, Name: p.Name, Description: p.Description, Tags: p.Tags}); err != nil {
			return Detail{}, err
		}
	}
	if _, err := s.syncAttributes(ctx, e, c); err != nil {
		return Detail{}, err
	}
	now := s.now().UTC()
	wf, _ := json.Marshal(c.N8NWorkflowIDs)
	res, err := s.db.ExecContext(ctx, `UPDATE bot_configs SET runtime = ?, category = ?, controller_id = ?, n8n_instance_id = ?, n8n_workflow_ids = ?,
		telegram_token_id = ?, container = ?, heartbeat_interval = ?, heartbeat_timeout = ?, log_source = ?, notes = ?,
		revision = revision + 1, updated_at = ? WHERE entity_id = ? AND revision = ?`,
		c.Runtime, c.Category, c.ControllerID, c.N8NInstanceID, string(wf), c.TelegramTokenID, c.Container,
		c.HeartbeatIntervalSec, c.HeartbeatTimeoutSec, c.LogSource, c.Notes, ms(now), id, p.Revision)
	if err != nil {
		return Detail{}, err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return Detail{}, &ConflictError{Reason: "revision_mismatch", Message: "Бот изменён в другом окне — обновите данные"}
	}
	if err := s.setRelations(ctx, id, p.HostID, p.DependsOn); err != nil {
		return Detail{}, err
	}
	s.mon.RecordEvent(ctx, id, "bot_updated", monitoring.SeverityInfo, "Настройки бота «"+e.Name+"» изменены")
	s.mon.RefreshEntity(ctx, id)
	s.invalidateList()
	return s.Get(ctx, id)
}

// SetArchived archives or restores the bot's Registry entity. Archiving
// stops nothing: a running process keeps running until the owner stops it.
func (s *Service) SetArchived(ctx context.Context, id string, archive bool) (Detail, error) {
	if _, err := s.config(ctx, id); err != nil {
		return Detail{}, err
	}
	e, err := s.reg.Get(ctx, id)
	if err != nil {
		return Detail{}, err
	}
	if e.Archived != archive {
		if archive {
			_, err = s.reg.Archive(ctx, id, e.Revision)
		} else {
			_, err = s.reg.Restore(ctx, id, e.Revision)
		}
		if err != nil {
			return Detail{}, err
		}
		msg := "Бот «" + e.Name + "» перенесён в архив"
		if !archive {
			msg = "Бот «" + e.Name + "» восстановлен из архива"
		}
		s.mon.RecordEvent(ctx, id, "bot_archived", monitoring.SeverityInfo, msg)
		s.invalidateList()
	}
	return s.Get(ctx, id)
}

// IssueCredential creates a heartbeat credential for the bot (token once).
func (s *Service) IssueCredential(ctx context.Context, id string) (monitoring.CreatedAgent, error) {
	if _, err := s.config(ctx, id); err != nil {
		return monitoring.CreatedAgent{}, err
	}
	e, err := s.reg.Get(ctx, id)
	if err != nil {
		return monitoring.CreatedAgent{}, err
	}
	return s.mon.CreateAgent(ctx, id, "heartbeat "+truncate(e.Name, 60), "bot")
}

const configCols = `entity_id, runtime, category, controller_id, n8n_instance_id, n8n_workflow_ids, telegram_token_id, container,
	heartbeat_interval, heartbeat_timeout, log_source, notes, revision, created_at, updated_at`

func scanConfig(row interface{ Scan(...any) error }) (Config, error) {
	var c Config
	var wf string
	var created, updated int64
	err := row.Scan(&c.EntityID, &c.Runtime, &c.Category, &c.ControllerID, &c.N8NInstanceID, &wf, &c.TelegramTokenID, &c.Container,
		&c.HeartbeatIntervalSec, &c.HeartbeatTimeoutSec, &c.LogSource, &c.Notes, &c.Revision, &created, &updated)
	if err != nil {
		return c, err
	}
	_ = json.Unmarshal([]byte(wf), &c.N8NWorkflowIDs)
	c.N8NWorkflowIDs = nonNil(c.N8NWorkflowIDs)
	c.CreatedAt, c.UpdatedAt = fromMS(created), fromMS(updated)
	return c, nil
}

func (s *Service) config(ctx context.Context, id string) (Config, error) {
	c, err := scanConfig(s.db.QueryRowContext(ctx, `SELECT `+configCols+` FROM bot_configs WHERE entity_id = ?`, id))
	if errors.Is(err, sql.ErrNoRows) {
		return c, ErrNotFound
	}
	return c, err
}

// configs lists bot configs; where is a fixed SQL condition from this package.
func (s *Service) configs(ctx context.Context, where string) ([]Config, error) {
	q := `SELECT ` + configCols + ` FROM bot_configs`
	if where != "" {
		q += ` WHERE ` + where
	}
	rows, err := s.db.QueryContext(ctx, q+` ORDER BY created_at`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Config
	for rows.Next() {
		c, err := scanConfig(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, c)
	}
	return out, rows.Err()
}

// controllerOf returns the bot's declared controller and its adapter.
func (s *Service) controllerOf(c Config) (config.BotController, Controller, bool) {
	ctl, ok := s.cfg.Controller(c.ControllerID)
	if !ok {
		return ctl, nil, false
	}
	a, ok := s.controllers[ctl.Kind]
	return ctl, a, ok
}
