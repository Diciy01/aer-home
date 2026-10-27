// Package modules lists the feature modules compiled into aer-core, in start order.
package modules

import (
	"aerhome/core/internal/foundation/module"
	"aerhome/core/internal/modules/bots"
	"aerhome/core/internal/modules/monitoring"
	"aerhome/core/internal/modules/registry"
	"aerhome/core/internal/modules/remote"
	"aerhome/core/internal/modules/scene"
)

// All returns every built-in module. Each can be switched off in config.
// Monitoring reads Registry only through registry.Reader, handed over here;
// Bots gets the Registry service (validated owner writes) and Monitoring.
func All() []module.Named {
	var reg *registry.Module
	var mon *monitoring.Module
	return []module.Named{
		{Name: registry.Name, New: func(d module.Deps) (module.Module, error) {
			m, err := registry.Factory(registry.DefaultCatalog())(d)
			if err == nil {
				reg, _ = m.(*registry.Module)
			}
			return m, err
		}},
		{Name: scene.Name, New: scene.Factory()},
		{Name: monitoring.Name, New: func(d module.Deps) (module.Module, error) {
			m, err := monitoring.Factory(func() registry.Reader {
				if reg == nil {
					return nil
				}
				return reg.Service()
			}, nil)(d)
			if err == nil {
				mon, _ = m.(*monitoring.Module)
			}
			return m, err
		}},
		{Name: bots.Name, New: bots.Factory(func() bots.RegistryWriter {
			if reg == nil {
				return nil
			}
			return reg.Writer()
		}, func() *monitoring.Service {
			if mon == nil {
				return nil
			}
			return mon.Service()
		}, nil)},
		{Name: remote.Name, New: remote.Factory(func() registry.Reader {
			if reg == nil {
				return nil
			}
			return reg.Service()
		}, func() *monitoring.Service {
			if mon == nil {
				return nil
			}
			return mon.Service()
		}, nil)},
	}
}
