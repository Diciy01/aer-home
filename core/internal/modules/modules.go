// Package modules lists the feature modules compiled into aer-core, in start order.
package modules

import (
	"aerhome/core/internal/foundation/module"
	"aerhome/core/internal/modules/monitoring"
	"aerhome/core/internal/modules/registry"
	"aerhome/core/internal/modules/scene"
)

// All returns every built-in module. Each can be switched off in config.
// Monitoring reads Registry only through registry.Reader, handed over here.
func All() []module.Named {
	var reg *registry.Module
	return []module.Named{
		{Name: registry.Name, New: func(d module.Deps) (module.Module, error) {
			m, err := registry.Factory(registry.DefaultCatalog())(d)
			if err == nil {
				reg, _ = m.(*registry.Module)
			}
			return m, err
		}},
		{Name: scene.Name, New: scene.Factory()},
		{Name: monitoring.Name, New: monitoring.Factory(func() registry.Reader {
			if reg == nil {
				return nil
			}
			return reg.Service()
		}, nil)},
	}
}
