package monitoring

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
	"aerhome/core/internal/modules/registry"
)

// Name is the module name used in config and schema_migrations.
const Name = "monitoring"

// Module plugs Monitoring into Core.
type Module struct{ svc *Service }

var (
	_ module.Module = (*Module)(nil)
	_ module.Runner = (*Module)(nil)
)

// Factory builds the module on top of the Registry reader.
func Factory(reg func() registry.Reader, now func() time.Time) module.Factory {
	return func(deps module.Deps) (module.Module, error) {
		r := reg()
		if r == nil {
			return nil, errors.New("monitoring needs the registry module")
		}
		return &Module{svc: NewService(deps.DB, r, deps.Config.Monitoring, deps.Logger, now)}, nil
	}
}

func (m *Module) Name() string                    { return Name }
func (m *Module) Migrations() []storage.Migration { return migrations }

// Service exposes the Monitoring service (Core log sink, tests).
func (m *Module) Service() *Service { return m.svc }

// Run starts background checks, Docker polling, retention and dispatch.
func (m *Module) Run(ctx context.Context) { m.svc.Run(ctx) }

func (m *Module) RegisterRoutes(r *httpapi.Router) {
	r.Handle(http.MethodGet, "/monitoring/overview", m.overview)
	r.Handle(http.MethodGet, "/monitoring/metric-types", m.metricTypes)
	r.Handle(http.MethodGet, "/monitoring/states", m.states)
	r.Handle(http.MethodGet, "/monitoring/states/{entityId}", m.oneState)
	r.Handle(http.MethodGet, "/monitoring/states/{entityId}/history", m.history)
	r.Handle(http.MethodGet, "/monitoring/logs", m.logs)
	r.Handle(http.MethodGet, "/monitoring/logs/{id}", m.oneLog)
	r.Handle(http.MethodGet, "/monitoring/events", m.events)
	r.Handle(http.MethodGet, "/monitoring/incidents", m.incidents)
	r.Handle(http.MethodGet, "/monitoring/incidents/{id}", m.oneIncident)
	r.Handle(http.MethodPost, "/monitoring/incidents/{id}/acknowledge", m.acknowledge)
	r.Handle(http.MethodGet, "/monitoring/notifications", m.notifications)
	r.Handle(http.MethodPost, "/monitoring/notifications/read", m.markRead)
	r.Handle(http.MethodGet, "/monitoring/agents", m.agents)
	r.Handle(http.MethodPost, "/monitoring/agents", m.createAgent)
	r.Handle(http.MethodPost, "/monitoring/agents/{id}/revoke", m.revokeAgent)
	r.Handle(http.MethodGet, "/monitoring/docker/containers", m.containers)
	// Agent protocol: per-agent credentials only, never the owner token.
	r.Handle(http.MethodPost, "/monitoring/agent/report", m.report, httpapi.Authorize("agent", m.svc.AgentAuthorizer))
}

func apiError(err error) error {
	var ve *ValidationError
	switch {
	case errors.As(err, &ve):
		return httpapi.NewError(http.StatusUnprocessableEntity, httpapi.CodeValidationFailed, "Данные не прошли проверку").
			WithDetails(map[string]any{"fields": ve.Fields})
	case errors.Is(err, ErrNotFound):
		return httpapi.NewError(http.StatusNotFound, httpapi.CodeNotFound, "Не найдено")
	case errors.Is(err, ErrEntityMissing):
		return httpapi.NewError(http.StatusNotFound, httpapi.CodeNotFound, "Объект Registry не найден")
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

func queryTime(r *http.Request, key string) (*time.Time, error) {
	v := r.URL.Query().Get(key)
	if v == "" {
		return nil, nil
	}
	t, err := time.Parse(time.RFC3339, v)
	if err != nil {
		return nil, &ValidationError{Fields: map[string]string{key: "Время в формате RFC 3339"}}
	}
	return &t, nil
}

func queryInt(r *http.Request, key string) int64 {
	n, _ := strconv.ParseInt(r.URL.Query().Get(key), 10, 64)
	return n
}

func (m *Module) overview(w http.ResponseWriter, r *http.Request) error {
	o, err := m.svc.Overview(r.Context())
	if err != nil {
		return err
	}
	return ok(w, r, o)
}

func (m *Module) metricTypes(w http.ResponseWriter, r *http.Request) error {
	return ok(w, r, MetricTypes)
}

func (m *Module) states(w http.ResponseWriter, r *http.Request) error {
	st, err := m.svc.States(r.Context())
	if err != nil {
		return err
	}
	return ok(w, r, st)
}

func (m *Module) oneState(w http.ResponseWriter, r *http.Request) error {
	st, err := m.svc.State(r.Context(), r.PathValue("entityId"))
	if err != nil {
		return apiError(err)
	}
	return ok(w, r, st)
}

func (m *Module) history(w http.ResponseWriter, r *http.Request) error {
	q := r.URL.Query()
	from, err := queryTime(r, "from")
	if err != nil {
		return apiError(err)
	}
	to, err := queryTime(r, "to")
	if err != nil {
		return apiError(err)
	}
	now := m.svc.now()
	if to == nil {
		to = &now
	}
	if from == nil {
		f := to.Add(-time.Hour)
		from = &f
	}
	ser, err := m.svc.History(r.Context(), r.PathValue("entityId"), q.Get("metric"), q.Get("label"), *from, *to)
	if err != nil {
		return apiError(err)
	}
	return ok(w, r, ser)
}

func (m *Module) logs(w http.ResponseWriter, r *http.Request) error {
	q := r.URL.Query()
	from, err := queryTime(r, "from")
	if err != nil {
		return apiError(err)
	}
	to, err := queryTime(r, "to")
	if err != nil {
		return apiError(err)
	}
	page, err := m.svc.Logs(r.Context(), LogFilter{Query: q.Get("q"), EntityID: q.Get("entityId"), Source: q.Get("source"),
		MinLevel: q.Get("level"), IncidentID: q.Get("incidentId"), From: from, To: to,
		Before: queryInt(r, "before"), Limit: int(queryInt(r, "limit"))})
	if err != nil {
		return apiError(err)
	}
	return ok(w, r, page)
}

func (m *Module) oneLog(w http.ResponseWriter, r *http.Request) error {
	id, _ := strconv.ParseInt(r.PathValue("id"), 10, 64)
	l, err := m.svc.Log(r.Context(), id)
	if err != nil {
		return apiError(err)
	}
	return ok(w, r, l)
}

func (m *Module) events(w http.ResponseWriter, r *http.Request) error {
	ev, err := m.svc.Events(r.Context(), r.URL.Query().Get("entityId"), queryInt(r, "before"), int(queryInt(r, "limit")))
	if err != nil {
		return err
	}
	return ok(w, r, ev)
}

func (m *Module) incidents(w http.ResponseWriter, r *http.Request) error {
	q := r.URL.Query()
	p, err := m.svc.Incidents(r.Context(), IncidentFilter{Status: q.Get("status"), Severity: q.Get("severity"),
		EntityID: q.Get("entityId"), Limit: int(queryInt(r, "limit")), Offset: int(queryInt(r, "offset"))})
	if err != nil {
		return apiError(err)
	}
	return ok(w, r, p)
}

func (m *Module) oneIncident(w http.ResponseWriter, r *http.Request) error {
	in, err := m.svc.Incident(r.Context(), r.PathValue("id"))
	if err != nil {
		return apiError(err)
	}
	return ok(w, r, in)
}

func (m *Module) acknowledge(w http.ResponseWriter, r *http.Request) error {
	var body struct {
		Note string `json:"note"`
	}
	if err := decode(r, &body); err != nil {
		return err
	}
	in, err := m.svc.Acknowledge(r.Context(), r.PathValue("id"), body.Note)
	if err != nil {
		return apiError(err)
	}
	return ok(w, r, in)
}

func (m *Module) notifications(w http.ResponseWriter, r *http.Request) error {
	items, unread, err := m.svc.Notifications(r.Context(), r.URL.Query().Get("unread") == "true", int(queryInt(r, "limit")))
	if err != nil {
		return err
	}
	return ok(w, r, map[string]any{"items": items, "unread": unread})
}

func (m *Module) markRead(w http.ResponseWriter, r *http.Request) error {
	var body struct {
		IDs []string `json:"ids"`
	}
	if err := decode(r, &body); err != nil {
		return err
	}
	n, err := m.svc.MarkRead(r.Context(), body.IDs)
	if err != nil {
		return err
	}
	return ok(w, r, map[string]any{"marked": n})
}

func (m *Module) agents(w http.ResponseWriter, r *http.Request) error {
	a, err := m.svc.ListAgents(r.Context(), r.URL.Query().Get("entityId"))
	if err != nil {
		return err
	}
	return ok(w, r, a)
}

func (m *Module) createAgent(w http.ResponseWriter, r *http.Request) error {
	var body struct {
		EntityID string `json:"entityId"`
		Name     string `json:"name"`
		Kind     string `json:"kind"`
	}
	if err := decode(r, &body); err != nil {
		return err
	}
	c, err := m.svc.CreateAgent(r.Context(), body.EntityID, body.Name, body.Kind)
	if err != nil {
		return apiError(err)
	}
	httpapi.WriteData(w, r, http.StatusCreated, c)
	return nil
}

func (m *Module) revokeAgent(w http.ResponseWriter, r *http.Request) error {
	a, err := m.svc.RevokeAgent(r.Context(), r.PathValue("id"))
	if err != nil {
		return apiError(err)
	}
	return ok(w, r, a)
}

func (m *Module) containers(w http.ResponseWriter, r *http.Request) error {
	c, st, err := m.svc.Containers(r.Context())
	if err != nil {
		return err
	}
	return ok(w, r, map[string]any{"integration": st, "items": c})
}

func (m *Module) report(w http.ResponseWriter, r *http.Request) error {
	a, found := AgentFromContext(r.Context())
	if !found {
		return httpapi.NewError(http.StatusUnauthorized, httpapi.CodeUnauthorized, "agent credential required")
	}
	var rep Report
	if err := decode(r, &rep); err != nil {
		return err
	}
	res, err := m.svc.Ingest(r.Context(), a, rep)
	if err != nil {
		return apiError(err)
	}
	return ok(w, r, res)
}
