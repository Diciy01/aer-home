package registry

import (
	"aerhome/core/internal/foundation/module"
	"aerhome/core/internal/foundation/storage"
)

// Name is the module name used in config and schema_migrations.
const Name = "registry"

// Module plugs the Registry into Core.
type Module struct {
	svc *Service
}

var _ module.Module = (*Module)(nil)

// Factory builds the module with the given catalog.
func Factory(cat *Catalog) module.Factory {
	return func(deps module.Deps) (module.Module, error) {
		return &Module{svc: NewService(deps.DB, cat, nil)}, nil
	}
}

func (m *Module) Name() string                    { return Name }
func (m *Module) Migrations() []storage.Migration { return migrations }

// Service exposes the Registry to other modules through the Reader interface.
func (m *Module) Service() Reader { return m.svc }
