// Package registry is the single source of truth about AER HOME objects:
// devices, services, bots and other entities, their capabilities and relations.
//
// Registry describes objects only. It never monitors or controls them, holds
// no scene coordinates, no metrics and no remote-session state, and stores
// secret references instead of secret values.
package registry

import (
	"encoding/json"
	"errors"
	"fmt"
	"time"
)

// Discovery says how an entity entered the Registry.
type Discovery string

const (
	DiscoveryManual      Discovery = "manual"
	DiscoveryAgent       Discovery = "agent"
	DiscoveryDocker      Discovery = "docker"
	DiscoveryNetworkScan Discovery = "network_scan"
	DiscoveryImport      Discovery = "import"
	DiscoveryExternal    Discovery = "external"
)

var discoveries = map[Discovery]bool{
	DiscoveryManual: true, DiscoveryAgent: true, DiscoveryDocker: true,
	DiscoveryNetworkScan: true, DiscoveryImport: true, DiscoveryExternal: true,
}

// SecretRef points at a secret kept outside the Registry (env var, OS keyring, file).
type SecretRef struct {
	Name string `json:"name"`
	Ref  string `json:"ref"`
}

// Entity is one registered object.
type Entity struct {
	ID           string          `json:"id"`
	Name         string          `json:"name"`
	Type         string          `json:"type"`
	Description  string          `json:"description"`
	Icon         string          `json:"icon"`
	Tags         []string        `json:"tags"`
	ParentID     *string         `json:"parentId"`
	Discovery    Discovery       `json:"discovery"`
	Address      *string         `json:"address"`
	SecretRefs   []SecretRef     `json:"secretRefs"`
	Attributes   json.RawMessage `json:"attributes"`
	Capabilities []string        `json:"capabilities"`
	Revision     int             `json:"revision"`
	CreatedAt    time.Time       `json:"createdAt"`
	UpdatedAt    time.Time       `json:"updatedAt"`
	Archived     bool            `json:"archived"`
	ArchivedAt   *time.Time      `json:"archivedAt"`
}

// EntitySummary is the short form used in relation listings.
type EntitySummary struct {
	ID       string `json:"id"`
	Name     string `json:"name"`
	Type     string `json:"type"`
	Archived bool   `json:"archived"`
}

// Relation is a typed, directed edge: From <Kind> To ("bot runs_on server").
type Relation struct {
	ID        string    `json:"id"`
	FromID    string    `json:"fromId"`
	ToID      string    `json:"toId"`
	Kind      string    `json:"kind"`
	Label     string    `json:"label"`
	CreatedAt time.Time `json:"createdAt"`
}

// RelationView is a relation seen from one entity, with the peer summarised.
type RelationView struct {
	Relation
	Direction string        `json:"direction"` // outgoing | incoming
	Peer      EntitySummary `json:"peer"`
}

// NewEntity is the create request. Only Name and Type are required.
type NewEntity struct {
	Name         string          `json:"name"`
	Type         string          `json:"type"`
	Description  string          `json:"description"`
	Icon         string          `json:"icon"`
	Tags         []string        `json:"tags"`
	ParentID     *string         `json:"parentId"`
	Discovery    Discovery       `json:"discovery"`
	Address      *string         `json:"address"`
	SecretRefs   []SecretRef     `json:"secretRefs"`
	Attributes   json.RawMessage `json:"attributes"`
	Capabilities *[]string       `json:"capabilities"` // nil → type defaults
}

// EntityPatch changes selected fields. Revision is mandatory (optimistic locking).
// A field set to JSON null clears it where that makes sense (parentId, address).
type EntityPatch struct {
	Revision    int
	Name        *string
	Type        *string
	Description *string
	Icon        *string
	Tags        *[]string
	ParentID    **string
	Discovery   *Discovery
	Address     **string
	SecretRefs  *[]SecretRef
	Attributes  *json.RawMessage
}

// ListFilter selects entities.
type ListFilter struct {
	Query      string
	Types      []string
	Tag        string
	Capability string
	ParentID   string
	Archived   ArchivedFilter
	Limit      int
	Offset     int
}

// ArchivedFilter selects active, archived or all entities.
type ArchivedFilter string

const (
	ArchivedExclude ArchivedFilter = "false"
	ArchivedOnly    ArchivedFilter = "true"
	ArchivedAll     ArchivedFilter = "all"
)

// Page is one page of a listing.
type Page struct {
	Items  []Entity `json:"items"`
	Total  int      `json:"total"`
	Limit  int      `json:"limit"`
	Offset int      `json:"offset"`
}

// Domain errors, mapped to HTTP by the module.
var ErrNotFound = errors.New("entity not found")

// ValidationError carries per-field messages for forms.
type ValidationError struct{ Fields map[string]string }

func (e *ValidationError) Error() string { return fmt.Sprintf("validation failed: %v", e.Fields) }

func (e *ValidationError) add(field, msg string) {
	if e.Fields == nil {
		e.Fields = map[string]string{}
	}
	if _, exists := e.Fields[field]; !exists {
		e.Fields[field] = msg
	}
}

func (e *ValidationError) orNil() error {
	if len(e.Fields) == 0 {
		return nil
	}
	return e
}

// ConflictError reports a stale revision or a state that forbids the change.
type ConflictError struct {
	Reason          string // revision_mismatch | archived | duplicate | cycle
	Message         string
	CurrentRevision int
}

func (e *ConflictError) Error() string { return e.Message }
