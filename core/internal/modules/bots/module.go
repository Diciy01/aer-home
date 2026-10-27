package bots

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strconv"
	"time"

	"aerhome/core/internal/foundation/httpapi"
	"aerhome/core/internal/foundation/module"
	"aerhome/core/internal/foundation/storage"
	"aerhome/core/internal/modules/monitoring"
	"aerhome/core/internal/modules/registry"
)

// Name is the module name used in config and schema_migrations.
const Name = "bots"

// Module plugs Bots into Core.
type Module struct{ svc *Service }

var (
	_ module.Module = (*Module)(nil)
	_ module.Runner = (*Module)(nil)
)

// Factory builds the module on top of Registry and Monitoring.
func Factory(reg func() RegistryWriter, mon func() *monitoring.Service, now func() time.Time) module.Factory {
	return func(deps module.Deps) (module.Module, error) {
		r, m := reg(), mon()
		if r == nil {
			return nil, errors.New("bots needs the registry module")
		}
		if m == nil {
			return nil, errors.New("bots needs the monitoring module (state, logs and incidents live there)")
		}
		return &Module{svc: NewService(deps.DB, r, m, deps.Config.Bots, deps.Logger, now)}, nil
	}
}

func (m *Module) Name() string                    { return Name }
func (m *Module) Migrations() []storage.Migration { return migrations }

// Service exposes the Bots service (tests, benchmarks).
func (m *Module) Service() *Service { return m.svc }

// Run starts adapter sync, process metrics and retention.
func (m *Module) Run(ctx context.Context) { m.svc.Run(ctx) }

func (m *Module) RegisterRoutes(r *httpapi.Router) {
	r.Handle(http.MethodGet, "/bots/adapters", m.adapters)
	r.Handle(http.MethodGet, "/bots", m.list)
	r.Handle(http.MethodPost, "/bots", m.create)
	r.Handle(http.MethodGet, "/bots/{id}", m.get)
	r.Handle(http.MethodPatch, "/bots/{id}", m.update)
	r.Handle(http.MethodPost, "/bots/{id}/archive", m.archive)
	r.Handle(http.MethodPost, "/bots/{id}/restore", m.restore)
	r.Handle(http.MethodPost, "/bots/{id}/credentials", m.credential)
	r.Handle(http.MethodGet, "/bots/{id}/jobs", m.jobs)
	r.Handle(http.MethodGet, "/bots/{id}/logs", m.logs)
	r.Handle(http.MethodGet, "/bots/{id}/activity", m.activity)
	r.Handle(http.MethodGet, "/bots/{id}/actions", m.actions)
	r.Handle(http.MethodPost, "/bots/{id}/actions/{action}/confirm", m.confirm)
	r.Handle(http.MethodPost, "/bots/{id}/actions/{action}", m.execute)
	r.Handle(http.MethodGet, "/bots/{id}/audit", m.audit)
	// Bot protocol: the bot's own heartbeat credential, never the owner token.
	r.Handle(http.MethodPost, "/bots/agent/jobs", m.reportJobs, httpapi.Authorize("agent", m.svc.mon.AgentAuthorizer))
}

func apiError(err error) error {
	var ve *ValidationError
	var rve *registry.ValidationError
	var ce *ConflictError
	var rce *registry.ConflictError
	var ae *ActionError
	switch {
	case errors.As(err, &ve):
		return httpapi.NewError(http.StatusUnprocessableEntity, httpapi.CodeValidationFailed, "Проверьте введённые данные").
			WithDetails(map[string]any{"fields": ve.Fields})
	case errors.As(err, &rve):
		return httpapi.NewError(http.StatusUnprocessableEntity, httpapi.CodeValidationFailed, "Registry отклонил данные").
			WithDetails(map[string]any{"fields": rve.Fields})
	case errors.As(err, &ce):
		d := map[string]any{"reason": ce.Reason}
		if ce.CurrentRevision > 0 {
			d["currentRevision"] = ce.CurrentRevision
		}
		return httpapi.NewError(http.StatusConflict, httpapi.CodeConflict, ce.Message).WithDetails(d)
	case errors.As(err, &rce):
		return httpapi.NewError(http.StatusConflict, httpapi.CodeConflict, rce.Message).WithDetails(map[string]any{"reason": rce.Reason})
	case errors.As(err, &ae):
		return httpapi.NewError(ae.Status, httpapi.Code(ae.Code), ae.Message)
	case errors.Is(err, ErrNotFound), errors.Is(err, registry.ErrNotFound):
		return httpapi.NewError(http.StatusNotFound, httpapi.CodeNotFound, "Бот не найден")
	case errors.Is(err, ErrNotABot):
		return httpapi.NewError(http.StatusNotFound, httpapi.CodeNotFound, "Объект этих учётных данных не настроен как бот")
	}
	var me *monitoring.ValidationError
	if errors.As(err, &me) {
		return httpapi.NewError(http.StatusUnprocessableEntity, httpapi.CodeValidationFailed, "Данные не прошли проверку").
			WithDetails(map[string]any{"fields": me.Fields})
	}
	return err
}

func decode(r *http.Request, dst any) error {
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	if err := dec.Decode(dst); err != nil && !errors.Is(err, io.EOF) {
		var tooBig *http.MaxBytesError
		if errors.As(err, &tooBig) {
			return httpapi.NewError(http.StatusRequestEntityTooLarge, httpapi.CodePayloadTooLarge, "Слишком большой запрос")
		}
		return httpapi.NewError(http.StatusBadRequest, httpapi.CodeBadRequest, "Некорректный JSON: "+err.Error())
	}
	return nil
}

func ok(w http.ResponseWriter, r *http.Request, data any) error {
	httpapi.WriteData(w, r, http.StatusOK, data)
	return nil
}

func qInt(r *http.Request, key string) int {
	n, _ := strconv.Atoi(r.URL.Query().Get(key))
	return n
}

func (m *Module) adapters(w http.ResponseWriter, r *http.Request) error {
	return ok(w, r, m.svc.Adapters(r.Context()))
}

func (m *Module) list(w http.ResponseWriter, r *http.Request) error {
	q := r.URL.Query()
	b, err := m.svc.List(r.Context(), ListFilter{Query: q.Get("q"), Status: q.Get("status"), Runtime: q.Get("runtime"),
		Category: q.Get("category"), Archived: q.Get("archived")})
	if err != nil {
		return apiError(err)
	}
	return ok(w, r, b)
}

func (m *Module) create(w http.ResponseWriter, r *http.Request) error {
	var in NewBot
	if err := decode(r, &in); err != nil {
		return err
	}
	c, err := m.svc.Create(r.Context(), in)
	if err != nil {
		return apiError(err)
	}
	httpapi.WriteData(w, r, http.StatusCreated, c)
	return nil
}

func (m *Module) get(w http.ResponseWriter, r *http.Request) error {
	d, err := m.svc.Get(r.Context(), r.PathValue("id"))
	if err != nil {
		return apiError(err)
	}
	return ok(w, r, d)
}

func (m *Module) update(w http.ResponseWriter, r *http.Request) error {
	var p BotPatch
	if err := decode(r, &p); err != nil {
		return err
	}
	d, err := m.svc.Update(r.Context(), r.PathValue("id"), p)
	if err != nil {
		return apiError(err)
	}
	return ok(w, r, d)
}

func (m *Module) archive(w http.ResponseWriter, r *http.Request) error {
	d, err := m.svc.SetArchived(r.Context(), r.PathValue("id"), true)
	if err != nil {
		return apiError(err)
	}
	return ok(w, r, d)
}

func (m *Module) restore(w http.ResponseWriter, r *http.Request) error {
	d, err := m.svc.SetArchived(r.Context(), r.PathValue("id"), false)
	if err != nil {
		return apiError(err)
	}
	return ok(w, r, d)
}

func (m *Module) credential(w http.ResponseWriter, r *http.Request) error {
	c, err := m.svc.IssueCredential(r.Context(), r.PathValue("id"))
	if err != nil {
		return apiError(err)
	}
	httpapi.WriteData(w, r, http.StatusCreated, c)
	return nil
}

func (m *Module) jobs(w http.ResponseWriter, r *http.Request) error {
	q := r.URL.Query()
	p, err := m.svc.Jobs(r.Context(), r.PathValue("id"), q.Get("status"), q.Get("before"), qInt(r, "limit"))
	if err != nil {
		return apiError(err)
	}
	return ok(w, r, p)
}

// logs is the bot's slice of Monitoring's centralized logs.
func (m *Module) logs(w http.ResponseWriter, r *http.Request) error {
	id := r.PathValue("id")
	if _, err := m.svc.config(r.Context(), id); err != nil {
		return apiError(err)
	}
	q := r.URL.Query()
	before, _ := strconv.ParseInt(q.Get("before"), 10, 64)
	p, err := m.svc.mon.Logs(r.Context(), monitoring.LogFilter{EntityID: id, Query: q.Get("q"), MinLevel: q.Get("level"),
		Before: before, Limit: qInt(r, "limit")})
	if err != nil {
		return apiError(err)
	}
	return ok(w, r, p)
}

func (m *Module) activity(w http.ResponseWriter, r *http.Request) error {
	id := r.PathValue("id")
	if _, err := m.svc.config(r.Context(), id); err != nil {
		return apiError(err)
	}
	before, _ := strconv.ParseInt(r.URL.Query().Get("before"), 10, 64)
	ev, err := m.svc.mon.Events(r.Context(), id, before, qInt(r, "limit"))
	if err != nil {
		return err
	}
	return ok(w, r, ev)
}

func (m *Module) actions(w http.ResponseWriter, r *http.Request) error {
	d, err := m.svc.Get(r.Context(), r.PathValue("id"))
	if err != nil {
		return apiError(err)
	}
	return ok(w, r, d.Actions)
}

func (m *Module) confirm(w http.ResponseWriter, r *http.Request) error {
	var body struct {
		JobID string `json:"jobId"`
	}
	if err := decode(r, &body); err != nil {
		return err
	}
	c, err := m.svc.Prepare(r.Context(), r.PathValue("id"), r.PathValue("action"), body.JobID)
	if err != nil {
		return apiError(err)
	}
	return ok(w, r, c)
}

func (m *Module) execute(w http.ResponseWriter, r *http.Request) error {
	var body ActionRequest
	if err := decode(r, &body); err != nil {
		return err
	}
	rec, err := m.svc.Execute(r.Context(), r.PathValue("id"), r.PathValue("action"), r.Header.Get("Idempotency-Key"), body)
	if err != nil {
		return apiError(err)
	}
	return ok(w, r, rec)
}

func (m *Module) audit(w http.ResponseWriter, r *http.Request) error {
	a, err := m.svc.Audit(r.Context(), r.PathValue("id"), qInt(r, "limit"))
	if err != nil {
		return err
	}
	return ok(w, r, a)
}

func (m *Module) reportJobs(w http.ResponseWriter, r *http.Request) error {
	a, found := monitoring.AgentFromContext(r.Context())
	if !found || a.Kind != "bot" {
		return httpapi.NewError(http.StatusForbidden, httpapi.CodeForbidden, "Нужны учётные данные бота (kind=bot)")
	}
	var rep JobReport
	if err := decode(r, &rep); err != nil {
		return err
	}
	n, err := m.svc.IngestJobs(r.Context(), a.EntityID, rep)
	if err != nil {
		return apiError(err)
	}
	return ok(w, r, map[string]any{"accepted": n})
}
