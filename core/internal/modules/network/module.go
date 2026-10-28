package network

import (
	"context"
	"errors"
	"net/http"
	"time"

	"aerhome/core/internal/foundation/httpapi"
	"aerhome/core/internal/foundation/module"
	"aerhome/core/internal/foundation/storage"
	"aerhome/core/internal/modules/monitoring"
	"aerhome/core/internal/modules/registry"
)

// Name is the module name used in config and schema_migrations.
const Name = "network"

// Module plugs Network + TV into Core.
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
			return nil, errors.New("network needs the registry and monitoring modules")
		}
		return &Module{svc: NewService(deps.DB, r, m, deps.Config.Network, deps.Config.Monitoring, deps.Logger, now)}, nil
	}
}

func (m *Module) Name() string                    { return Name }
func (m *Module) Migrations() []storage.Migration { return migrations }

// Service exposes the service (tests).
func (m *Module) Service() *Service { return m.svc }

// Run performs the periodic checks.
func (m *Module) Run(ctx context.Context) { m.svc.Run(ctx) }

func (m *Module) RegisterRoutes(r *httpapi.Router) {
	r.Handle(http.MethodGet, "/network/overview", m.overview)
	r.Handle(http.MethodPost, "/network/check", m.checkNow)
}

func (m *Module) overview(w http.ResponseWriter, r *http.Request) error {
	o, err := m.svc.Overview(r.Context())
	if err != nil {
		return err
	}
	httpapi.WriteData(w, r, http.StatusOK, o)
	return nil
}

func (m *Module) checkNow(w http.ResponseWriter, r *http.Request) error {
	if err := m.svc.CheckNow(r.Context()); errors.Is(err, ErrTooSoon) {
		return httpapi.NewError(http.StatusConflict, httpapi.Code("CONFLICT"), "Проверка уже выполнялась несколько секунд назад").
			WithDetails(map[string]any{"reason": "too_soon"})
	}
	return m.overview(w, r)
}
