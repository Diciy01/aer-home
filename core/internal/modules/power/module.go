package power

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"slices"
	"strconv"
	"time"

	"aerhome/core/internal/foundation/httpapi"
	"aerhome/core/internal/foundation/module"
	"aerhome/core/internal/foundation/storage"
	"aerhome/core/internal/modules/monitoring"
	"aerhome/core/internal/modules/registry"
)

// Name is the module name used in config and schema_migrations.
const Name = "power"

// Module plugs Power into Core.
type Module struct{ svc *Service }

var (
	_ module.Module = (*Module)(nil)
	_ module.Runner = (*Module)(nil)
)

// Factory builds the module on top of Registry and Monitoring; n may be nil
// (the real network).
func Factory(reg func() registry.Reader, mon func() *monitoring.Service, now func() time.Time, n Net) module.Factory {
	return func(deps module.Deps) (module.Module, error) {
		r, m := reg(), mon()
		if r == nil || m == nil {
			return nil, errors.New("power needs the registry and monitoring modules")
		}
		return &Module{svc: NewService(deps.DB, r, m, deps.Config.Power, deps.Logger, now, n)}, nil
	}
}

func (m *Module) Name() string                    { return Name }
func (m *Module) Migrations() []storage.Migration { return migrations }

// Service exposes the Power service (tests).
func (m *Module) Service() *Service { return m.svc }

// Run enforces job deadlines and retention.
func (m *Module) Run(ctx context.Context) { m.svc.Run(ctx) }

func (m *Module) RegisterRoutes(r *httpapi.Router) {
	r.Handle(http.MethodGet, "/power/devices", m.devices)
	r.Handle(http.MethodGet, "/power/devices/{id}", m.device)
	r.Handle(http.MethodPut, "/power/devices/{id}/policy", m.setPolicy)
	r.Handle(http.MethodPut, "/power/devices/{id}/wol", m.setWoL)
	r.Handle(http.MethodDelete, "/power/devices/{id}/wol", m.deleteWoL)
	r.Handle(http.MethodPost, "/power/devices/{id}/actions/{action}/confirm", m.confirm)
	r.Handle(http.MethodPost, "/power/devices/{id}/actions/{action}", m.execute)
	r.Handle(http.MethodGet, "/power/jobs", m.jobs)
	r.Handle(http.MethodGet, "/power/jobs/{id}", m.job)
	r.Handle(http.MethodPost, "/power/jobs/{id}/cancel", m.cancel)
	r.Handle(http.MethodGet, "/power/interfaces", m.interfaces)
	// Host agent protocol: the host's own credential (agent kind "power").
	auth := httpapi.Authorize("agent", m.svc.mon.AgentAuthorizer)
	r.Handle(http.MethodPost, "/power/agent/hello", m.agentHello, auth)
	r.Handle(http.MethodGet, "/power/agent/commands", m.agentCommands, auth)
	r.Handle(http.MethodPost, "/power/agent/jobs/{id}/events", m.agentEvent, auth)
}

func apiError(err error) error {
	var ve *ValidationError
	var re *RefusedError
	switch {
	case errors.As(err, &ve):
		return httpapi.NewError(http.StatusUnprocessableEntity, httpapi.CodeValidationFailed, "Проверьте данные").
			WithDetails(map[string]any{"fields": ve.Fields})
	case errors.As(err, &re):
		return httpapi.NewError(re.Status, httpapi.Code(re.Code), re.Message).WithDetails(map[string]any{"reason": re.Reason})
	case errors.Is(err, ErrNotFound):
		return httpapi.NewError(http.StatusNotFound, httpapi.CodeNotFound, "Не найдено")
	}
	return err
}

func decode(r *http.Request, dst any) error {
	dec := json.NewDecoder(http.MaxBytesReader(nil, r.Body, 64<<10))
	dec.DisallowUnknownFields()
	if err := dec.Decode(dst); err != nil && !errors.Is(err, io.EOF) {
		return httpapi.NewError(http.StatusBadRequest, httpapi.CodeBadRequest, "Некорректный JSON: "+err.Error())
	}
	return nil
}

func reply(w http.ResponseWriter, r *http.Request, v any, err error) error {
	if err != nil {
		return apiError(err)
	}
	httpapi.WriteData(w, r, http.StatusOK, v)
	return nil
}

func (m *Module) devices(w http.ResponseWriter, r *http.Request) error {
	d, err := m.svc.Devices(r.Context())
	return reply(w, r, d, err)
}

func (m *Module) device(w http.ResponseWriter, r *http.Request) error {
	d, err := m.svc.Device(r.Context(), r.PathValue("id"))
	return reply(w, r, d, err)
}

func (m *Module) setPolicy(w http.ResponseWriter, r *http.Request) error {
	var p Policy
	if err := decode(r, &p); err != nil {
		return err
	}
	d, err := m.svc.SetPolicy(r.Context(), r.PathValue("id"), p)
	return reply(w, r, d, err)
}

func (m *Module) setWoL(w http.ResponseWriter, r *http.Request) error {
	var t WoLTarget
	if err := decode(r, &t); err != nil {
		return err
	}
	d, err := m.svc.SetWoL(r.Context(), r.PathValue("id"), t)
	return reply(w, r, d, err)
}

func (m *Module) deleteWoL(w http.ResponseWriter, r *http.Request) error {
	d, err := m.svc.DeleteWoL(r.Context(), r.PathValue("id"))
	return reply(w, r, d, err)
}

func knownAction(a string) error {
	if !slices.Contains(AllActions, a) {
		return httpapi.NewError(http.StatusBadRequest, httpapi.Code("UNSUPPORTED"), "Неизвестное действие: допустимы "+
			"wake, shutdown, reboot, suspend, switch_os, check")
	}
	return nil
}

func (m *Module) confirm(w http.ResponseWriter, r *http.Request) error {
	if err := knownAction(r.PathValue("action")); err != nil {
		return err
	}
	var in struct {
		TargetOS string `json:"targetOs"`
	}
	if err := decode(r, &in); err != nil {
		return err
	}
	w.Header().Set("Cache-Control", "no-store")
	c, err := m.svc.Prepare(r.Context(), r.PathValue("id"), r.PathValue("action"), in.TargetOS)
	return reply(w, r, c, err)
}

func (m *Module) execute(w http.ResponseWriter, r *http.Request) error {
	if err := knownAction(r.PathValue("action")); err != nil {
		return err
	}
	var in ActionRequest
	if err := decode(r, &in); err != nil {
		return err
	}
	j, err := m.svc.Execute(r.Context(), r.PathValue("id"), r.PathValue("action"), r.Header.Get("Idempotency-Key"), in)
	if err != nil {
		return apiError(err)
	}
	code := http.StatusAccepted
	if j.Replayed {
		code = http.StatusOK
	}
	httpapi.WriteData(w, r, code, j)
	return nil
}

func (m *Module) jobs(w http.ResponseWriter, r *http.Request) error {
	n, _ := strconv.Atoi(r.URL.Query().Get("limit"))
	j, err := m.svc.Jobs(r.Context(), r.URL.Query().Get("entityId"), n)
	return reply(w, r, j, err)
}

func (m *Module) job(w http.ResponseWriter, r *http.Request) error {
	j, err := m.svc.Job(r.Context(), r.PathValue("id"))
	return reply(w, r, j, err)
}

func (m *Module) cancel(w http.ResponseWriter, r *http.Request) error {
	j, err := m.svc.Cancel(r.Context(), r.PathValue("id"))
	return reply(w, r, j, err)
}

func (m *Module) interfaces(w http.ResponseWriter, r *http.Request) error {
	i, err := m.svc.Interfaces()
	return reply(w, r, map[string]any{"interfaces": i, "wolEnabled": m.svc.cfg.WoL.Enabled, "defaultPort": m.svc.cfg.WoL.Port}, err)
}

func powerAgent(r *http.Request) (monitoring.Agent, error) {
	a, found := monitoring.AgentFromContext(r.Context())
	if !found || a.Kind != "power" {
		return a, httpapi.NewError(http.StatusForbidden, httpapi.CodeForbidden, "Нужны учётные данные агента питания (kind=power)")
	}
	return a, nil
}

func (m *Module) agentHello(w http.ResponseWriter, r *http.Request) error {
	a, err := powerAgent(r)
	if err != nil {
		return err
	}
	var info HostInfo
	if err := decode(r, &info); err != nil {
		return err
	}
	res, err := m.svc.Hello(r.Context(), a, info)
	return reply(w, r, res, err)
}

func (m *Module) agentCommands(w http.ResponseWriter, r *http.Request) error {
	a, err := powerAgent(r)
	if err != nil {
		return err
	}
	wait, _ := strconv.Atoi(r.URL.Query().Get("wait"))
	wait = max(0, min(wait, 25))
	return reply(w, r, map[string]any{"commands": m.svc.Commands(r.Context(), a, time.Duration(wait)*time.Second)}, nil)
}

func (m *Module) agentEvent(w http.ResponseWriter, r *http.Request) error {
	a, err := powerAgent(r)
	if err != nil {
		return err
	}
	var ev AgentEvent
	if err := decode(r, &ev); err != nil {
		return err
	}
	j, err := m.svc.OnAgentEvent(r.Context(), a, r.PathValue("id"), ev)
	if err != nil {
		return apiError(err)
	}
	return reply(w, r, map[string]any{"state": j.State}, nil)
}
