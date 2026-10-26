package core

import (
	"context"
	"net/http"
	"time"

	"aerhome/core/internal/buildinfo"
	"aerhome/core/internal/foundation/httpapi"
	"aerhome/core/internal/foundation/module"
	"aerhome/core/internal/foundation/storage"
)

// HealthStatus is the payload of GET /health.
type HealthStatus struct {
	Status     string    `json:"status"` // ok | degraded
	Timestamp  time.Time `json:"timestamp"`
	APIVersion string    `json:"apiVersion"`
}

// SystemInfo is the payload of GET /system/info.
type SystemInfo struct {
	CoreVersion       string                   `json:"coreVersion"`
	APIVersion        string                   `json:"apiVersion"`
	Mode              string                   `json:"mode"`
	Demo              bool                     `json:"demo"`
	InstanceID        string                   `json:"instanceId"`
	InstanceCreatedAt string                   `json:"instanceCreatedAt"`
	StartedAt         time.Time                `json:"startedAt"`
	UptimeSeconds     int64                    `json:"uptimeSeconds"`
	Schema            []storage.AppliedVersion `json:"schema"`
	Modules           []module.Status          `json:"modules"`
}

func (c *Core) registerFoundationRoutes() {
	// Public on purpose: clients must tell "Core offline" from "token invalid".
	// It exposes no identifiers, versions of dependencies or data (ADR-007).
	c.router.Handle(http.MethodGet, "/health", c.handleHealth, httpapi.Public())
	c.router.Handle(http.MethodGet, "/system/info", c.handleSystemInfo)
}

func (c *Core) handleHealth(w http.ResponseWriter, r *http.Request) error {
	ctx, cancel := context.WithTimeout(r.Context(), 2*time.Second)
	defer cancel()
	status := "ok"
	if err := c.db.PingContext(ctx); err != nil {
		c.log.Warn("health: database ping failed", "err", err)
		status = "degraded"
	}
	httpapi.WriteData(w, r, http.StatusOK, HealthStatus{
		Status:     status,
		Timestamp:  c.now().UTC(),
		APIVersion: httpapi.APIVersion,
	})
	return nil
}

func (c *Core) handleSystemInfo(w http.ResponseWriter, r *http.Request) error {
	schema, err := storage.AppliedVersions(r.Context(), c.db)
	if err != nil {
		return err
	}
	modules := c.modules
	if modules == nil {
		modules = []module.Status{}
	}
	now := c.now().UTC()
	httpapi.WriteData(w, r, http.StatusOK, SystemInfo{
		CoreVersion:       buildinfo.Version,
		APIVersion:        httpapi.APIVersion,
		Mode:              string(c.cfg.Mode),
		Demo:              c.cfg.IsDemo(),
		InstanceID:        c.instance.ID,
		InstanceCreatedAt: c.instance.CreatedAt,
		StartedAt:         c.startedAt,
		UptimeSeconds:     int64(now.Sub(c.startedAt).Seconds()),
		Schema:            schema,
		Modules:           modules,
	})
	return nil
}
