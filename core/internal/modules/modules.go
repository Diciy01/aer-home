// Package modules lists the feature modules compiled into aer-core, in start order.
package modules

import (
	"aerhome/core/internal/foundation/module"
	"aerhome/core/internal/modules/registry"
	"aerhome/core/internal/modules/scene"
)

// All returns every built-in module. Each can be switched off in config.
func All() []module.Named {
	return []module.Named{
		{Name: registry.Name, New: registry.Factory(registry.DefaultCatalog())},
		{Name: scene.Name, New: scene.Factory()},
	}
}
