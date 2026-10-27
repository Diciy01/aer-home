package remote

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
const Name = "remote"

// Module plugs Remote into Core.
type Module struct{ svc *Service }

var (
	_ module.Module = (*Module)(nil)
	_ module.Runner = (*Module)(nil)
)

// Factory builds the module on top of Registry and Monitoring.
func Factory(reg func() registry.Reader, mon func() *monitoring.Service, now func() time.Time) module.Factory {
	return func(deps module.Deps) (module.Module, error) {
		r, m := reg(), mon()
		if r == nil || m == nil {
			return nil, errors.New("remote needs the registry and monitoring modules")
		}
		return &Module{svc: NewService(deps.DB, r, m, deps.Config.Remote, deps.Logger, now)}, nil
	}
}

func (m *Module) Name() string                    { return Name }
func (m *Module) Migrations() []storage.Migration { return migrations }

// Service exposes the Remote service (tests).
func (m *Module) Service() *Service { return m.svc }

// Run enforces session timeouts and retention.
func (m *Module) Run(ctx context.Context) { m.svc.Run(ctx) }

func (m *Module) RegisterRoutes(r *httpapi.Router) {
	r.Handle(http.MethodGet, "/remote/hosts", m.hosts)
	r.Handle(http.MethodGet, "/remote/hosts/{id}", m.host)
	r.Handle(http.MethodPut, "/remote/hosts/{id}/policy", m.setPolicy)
	r.Handle(http.MethodPost, "/remote/hosts/{id}/revoke-sessions", m.revokeHost)
	r.Handle(http.MethodGet, "/remote/hosts/{id}/apps", m.apps)
	r.Handle(http.MethodGet, "/remote/sessions", m.sessions)
	r.Handle(http.MethodPost, "/remote/sessions", m.create)
	r.Handle(http.MethodGet, "/remote/sessions/{id}", m.session)
	r.Handle(http.MethodPost, "/remote/sessions/{id}/grant", m.grant)
	r.Handle(http.MethodPost, "/remote/sessions/{id}/end", m.end)
	r.Handle(http.MethodPost, "/remote/sessions/{id}/revoke", m.revoke)
	// Host agent protocol: the host's own credential (agent kind "remote").
	auth := httpapi.Authorize("agent", m.svc.mon.AgentAuthorizer)
	r.Handle(http.MethodPost, "/remote/agent/hello", m.agentHello, auth)
	r.Handle(http.MethodGet, "/remote/agent/commands", m.agentCommands, auth)
	r.Handle(http.MethodPost, "/remote/agent/sessions/{id}/events", m.agentEvent, auth)
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

func ok(w http.ResponseWriter, r *http.Request, v any) error {
	httpapi.WriteData(w, r, http.StatusOK, v)
	return nil
}

func (m *Module) hosts(w http.ResponseWriter, r *http.Request) error {
	h, err := m.svc.Hosts(r.Context())
	if err != nil {
		return apiError(err)
	}
	return ok(w, r, h)
}

func (m *Module) host(w http.ResponseWriter, r *http.Request) error {
	h, err := m.svc.Host(r.Context(), r.PathValue("id"))
	if err != nil {
		return apiError(err)
	}
	return ok(w, r, h)
}

func (m *Module) setPolicy(w http.ResponseWriter, r *http.Request) error {
	var p Policy
	if err := decode(r, &p); err != nil {
		return err
	}
	h, err := m.svc.SetPolicy(r.Context(), r.PathValue("id"), p)
	if err != nil {
		return apiError(err)
	}
	return ok(w, r, h)
}

func (m *Module) revokeHost(w http.ResponseWriter, r *http.Request) error {
	h, err := m.svc.RevokeHost(r.Context(), r.PathValue("id"))
	if err != nil {
		return apiError(err)
	}
	return ok(w, r, h)
}

func (m *Module) apps(w http.ResponseWriter, r *http.Request) error {
	a, err := m.svc.Apps(r.Context(), r.PathValue("id"))
	if err != nil {
		return apiError(err)
	}
	return ok(w, r, a)
}

func (m *Module) sessions(w http.ResponseWriter, r *http.Request) error {
	n, _ := strconv.Atoi(r.URL.Query().Get("limit"))
	x, err := m.svc.Sessions(r.Context(), r.URL.Query().Get("entityId"), n)
	if err != nil {
		return apiError(err)
	}
	return ok(w, r, x)
}

func (m *Module) create(w http.ResponseWriter, r *http.Request) error {
	var in NewSession
	if err := decode(r, &in); err != nil {
		return err
	}
	key := r.Header.Get("Idempotency-Key")
	if len(key) > 100 {
		return httpapi.NewError(http.StatusUnprocessableEntity, httpapi.CodeValidationFailed, "Idempotency-Key до 100 символов")
	}
	x, err := m.svc.Create(r.Context(), in, key)
	if err != nil {
		return apiError(err)
	}
	httpapi.WriteData(w, r, http.StatusCreated, x)
	return nil
}

func (m *Module) session(w http.ResponseWriter, r *http.Request) error {
	x, err := m.svc.Session(r.Context(), r.PathValue("id"))
	if err != nil {
		return apiError(err)
	}
	return ok(w, r, x)
}

func (m *Module) grant(w http.ResponseWriter, r *http.Request) error {
	w.Header().Set("Cache-Control", "no-store")
	g, err := m.svc.Grant(r.Context(), r.PathValue("id"))
	if err != nil {
		return apiError(err)
	}
	return ok(w, r, g)
}

func (m *Module) end(w http.ResponseWriter, r *http.Request) error {
	x, err := m.svc.End(r.Context(), r.PathValue("id"))
	if err != nil {
		return apiError(err)
	}
	return ok(w, r, x)
}

func (m *Module) revoke(w http.ResponseWriter, r *http.Request) error {
	x, err := m.svc.Revoke(r.Context(), r.PathValue("id"))
	if err != nil {
		return apiError(err)
	}
	return ok(w, r, x)
}

func remoteAgent(r *http.Request) (monitoring.Agent, error) {
	a, found := monitoring.AgentFromContext(r.Context())
	if !found || a.Kind != "remote" {
		return a, httpapi.NewError(http.StatusForbidden, httpapi.CodeForbidden, "Нужны учётные данные агента удалённого доступа (kind=remote)")
	}
	return a, nil
}

func (m *Module) agentHello(w http.ResponseWriter, r *http.Request) error {
	a, err := remoteAgent(r)
	if err != nil {
		return err
	}
	var info HostInfo
	if err := decode(r, &info); err != nil {
		return err
	}
	res, err := m.svc.Hello(r.Context(), a, info)
	if err != nil {
		return apiError(err)
	}
	return ok(w, r, res)
}

func (m *Module) agentCommands(w http.ResponseWriter, r *http.Request) error {
	a, err := remoteAgent(r)
	if err != nil {
		return err
	}
	wait, _ := strconv.Atoi(r.URL.Query().Get("wait"))
	wait = max(0, min(wait, 25))
	return ok(w, r, map[string]any{"commands": m.svc.Commands(r.Context(), a, time.Duration(wait)*time.Second)})
}

func (m *Module) agentEvent(w http.ResponseWriter, r *http.Request) error {
	a, err := remoteAgent(r)
	if err != nil {
		return err
	}
	var ev AgentEvent
	if err := decode(r, &ev); err != nil {
		return err
	}
	x, err := m.svc.OnAgentEvent(r.Context(), a, r.PathValue("id"), ev)
	if err != nil {
		return apiError(err)
	}
	return ok(w, r, map[string]any{"state": x.State})
}
