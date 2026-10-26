package registry

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	"aerhome/core/internal/foundation/storage"
)

// Migrations owned by the registry module. Tables are prefixed registry_ and
// are never read by other modules directly (they use Reader).
var migrations = []storage.Migration{
	{Version: 1, Name: "create_registry", SQL: `
CREATE TABLE registry_entities (
	id          TEXT PRIMARY KEY,
	name        TEXT NOT NULL,
	name_key    TEXT NOT NULL,
	type        TEXT NOT NULL,
	description TEXT NOT NULL DEFAULT '',
	icon        TEXT NOT NULL DEFAULT '',
	parent_id   TEXT REFERENCES registry_entities(id),
	discovery   TEXT NOT NULL,
	address     TEXT,
	secret_refs TEXT NOT NULL DEFAULT '[]',
	attributes  TEXT NOT NULL DEFAULT '{}',
	search_text TEXT NOT NULL,
	revision    INTEGER NOT NULL CHECK (revision >= 1),
	created_at  TEXT NOT NULL,
	updated_at  TEXT NOT NULL,
	archived_at TEXT
);
CREATE INDEX registry_entities_name ON registry_entities(name_key, id);
CREATE INDEX registry_entities_type ON registry_entities(type);
CREATE INDEX registry_entities_parent ON registry_entities(parent_id);

CREATE TABLE registry_entity_tags (
	entity_id TEXT NOT NULL REFERENCES registry_entities(id),
	tag       TEXT NOT NULL,
	PRIMARY KEY (entity_id, tag)
);
CREATE INDEX registry_entity_tags_tag ON registry_entity_tags(tag);

CREATE TABLE registry_entity_capabilities (
	entity_id  TEXT NOT NULL REFERENCES registry_entities(id),
	capability TEXT NOT NULL,
	source     TEXT NOT NULL CHECK (source IN ('type_default', 'user')),
	PRIMARY KEY (entity_id, capability)
);
CREATE INDEX registry_entity_capabilities_cap ON registry_entity_capabilities(capability);

CREATE TABLE registry_relations (
	id         TEXT PRIMARY KEY,
	from_id    TEXT NOT NULL REFERENCES registry_entities(id),
	to_id      TEXT NOT NULL REFERENCES registry_entities(id),
	kind       TEXT NOT NULL,
	label      TEXT NOT NULL DEFAULT '',
	created_at TEXT NOT NULL,
	CHECK (from_id <> to_id),
	UNIQUE (from_id, to_id, kind, label)
);
CREATE INDEX registry_relations_from ON registry_relations(from_id, kind);
CREATE INDEX registry_relations_to ON registry_relations(to_id, kind);
`},
}

// querier is satisfied by *sql.DB and *sql.Tx.
type querier interface {
	ExecContext(ctx context.Context, query string, args ...any) (sql.Result, error)
	QueryContext(ctx context.Context, query string, args ...any) (*sql.Rows, error)
	QueryRowContext(ctx context.Context, query string, args ...any) *sql.Row
}

const entityColumns = `id, name, type, description, icon, parent_id, discovery, address,
	secret_refs, attributes, revision, created_at, updated_at, archived_at`

func formatTime(t time.Time) string { return t.UTC().Format(time.RFC3339Nano) }

func parseTime(s string) (time.Time, error) { return time.Parse(time.RFC3339Nano, s) }

type rowScanner interface{ Scan(dest ...any) error }

func scanEntity(row rowScanner) (Entity, error) {
	var (
		e                  Entity
		parent, addr, arch sql.NullString
		secrets, attrs     string
		created, updated   string
	)
	if err := row.Scan(&e.ID, &e.Name, &e.Type, &e.Description, &e.Icon, &parent, &e.Discovery,
		&addr, &secrets, &attrs, &e.Revision, &created, &updated, &arch); err != nil {
		return Entity{}, err
	}
	if parent.Valid {
		e.ParentID = &parent.String
	}
	if addr.Valid {
		e.Address = &addr.String
	}
	if err := json.Unmarshal([]byte(secrets), &e.SecretRefs); err != nil {
		return Entity{}, fmt.Errorf("entity %s secret_refs: %w", e.ID, err)
	}
	e.Attributes = json.RawMessage(attrs)
	var err error
	if e.CreatedAt, err = parseTime(created); err != nil {
		return Entity{}, err
	}
	if e.UpdatedAt, err = parseTime(updated); err != nil {
		return Entity{}, err
	}
	if arch.Valid {
		t, err := parseTime(arch.String)
		if err != nil {
			return Entity{}, err
		}
		e.Archived, e.ArchivedAt = true, &t
	}
	return e, nil
}

func loadEntity(ctx context.Context, q querier, id string) (Entity, error) {
	e, err := scanEntity(q.QueryRowContext(ctx, `SELECT `+entityColumns+` FROM registry_entities WHERE id = ?`, id))
	if errors.Is(err, sql.ErrNoRows) {
		return Entity{}, ErrNotFound
	}
	if err != nil {
		return Entity{}, err
	}
	list := []Entity{e}
	if err := attachChildren(ctx, q, list); err != nil {
		return Entity{}, err
	}
	return list[0], nil
}

// attachChildren loads tags and capabilities for a batch of entities.
func attachChildren(ctx context.Context, q querier, list []Entity) error {
	if len(list) == 0 {
		return nil
	}
	index := make(map[string]int, len(list))
	args := make([]any, len(list))
	for i := range list {
		list[i].Tags, list[i].Capabilities = []string{}, []string{}
		index[list[i].ID] = i
		args[i] = list[i].ID
	}
	in := placeholders(len(list))
	load := func(query string, add func(e *Entity, v string)) error {
		rows, err := q.QueryContext(ctx, query, args...)
		if err != nil {
			return err
		}
		defer rows.Close()
		for rows.Next() {
			var id, v string
			if err := rows.Scan(&id, &v); err != nil {
				return err
			}
			add(&list[index[id]], v)
		}
		return rows.Err()
	}
	if err := load(`SELECT entity_id, tag FROM registry_entity_tags WHERE entity_id IN (`+in+`) ORDER BY tag`,
		func(e *Entity, v string) { e.Tags = append(e.Tags, v) }); err != nil {
		return err
	}
	return load(`SELECT entity_id, capability FROM registry_entity_capabilities WHERE entity_id IN (`+in+`) ORDER BY capability`,
		func(e *Entity, v string) { e.Capabilities = append(e.Capabilities, v) })
}

func placeholders(n int) string { return strings.TrimSuffix(strings.Repeat("?,", n), ",") }

func writeTags(ctx context.Context, q querier, id string, tags []string) error {
	if _, err := q.ExecContext(ctx, `DELETE FROM registry_entity_tags WHERE entity_id = ?`, id); err != nil {
		return err
	}
	for _, t := range tags {
		if _, err := q.ExecContext(ctx, `INSERT INTO registry_entity_tags (entity_id, tag) VALUES (?, ?)`, id, t); err != nil {
			return err
		}
	}
	return nil
}

func writeCapabilities(ctx context.Context, q querier, id string, caps []string, defaults map[string]bool) error {
	if _, err := q.ExecContext(ctx, `DELETE FROM registry_entity_capabilities WHERE entity_id = ?`, id); err != nil {
		return err
	}
	for _, c := range caps {
		source := "user"
		if defaults[c] {
			source = "type_default"
		}
		if _, err := q.ExecContext(ctx,
			`INSERT INTO registry_entity_capabilities (entity_id, capability, source) VALUES (?, ?, ?)`,
			id, c, source); err != nil {
			return err
		}
	}
	return nil
}

func nullable(s *string) any {
	if s == nil {
		return nil
	}
	return *s
}

// reachable reports whether target can be reached from start by following
// edges of the given kinds (from_id → to_id).
func reachable(ctx context.Context, q querier, start, target string, kinds []string) (bool, error) {
	args := []any{start}
	for _, k := range kinds {
		args = append(args, k)
	}
	args = append(args, target)
	var found int
	err := q.QueryRowContext(ctx, `
WITH RECURSIVE reach(id) AS (
	SELECT ?
	UNION
	SELECT r.to_id FROM registry_relations r JOIN reach ON r.from_id = reach.id
	WHERE r.kind IN (`+placeholders(len(kinds))+`)
)
SELECT COUNT(*) FROM reach WHERE id = ?`, args...).Scan(&found)
	return found > 0, err
}

// parentChainContains reports whether walking up from start via parent_id reaches target.
func parentChainContains(ctx context.Context, q querier, start, target string) (bool, error) {
	var found int
	err := q.QueryRowContext(ctx, `
WITH RECURSIVE up(id) AS (
	SELECT ?
	UNION
	SELECT e.parent_id FROM registry_entities e JOIN up ON e.id = up.id WHERE e.parent_id IS NOT NULL
)
SELECT COUNT(*) FROM up WHERE id = ?`, start, target).Scan(&found)
	return found > 0, err
}
