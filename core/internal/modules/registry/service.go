package registry

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"sort"
	"strings"
	"time"

	"aerhome/core/internal/foundation/ids"
)

// Reader is the stable read-only interface other modules (Scene, Monitoring,
// Remote, Bots, Network, Power, Incidents) use to resolve entities. They keep
// their own data (positions, metrics, sessions) in their own tables, keyed by
// entity ID.
type Reader interface {
	Get(ctx context.Context, id string) (Entity, error)
	List(ctx context.Context, f ListFilter) (Page, error)
	Relations(ctx context.Context, id string) ([]RelationView, error)
	Catalog() *Catalog
}

var _ Reader = (*Service)(nil)

const (
	defaultLimit = 50
	maxLimit     = 200
)

// Service implements Registry business rules on top of SQLite.
type Service struct {
	db  *sql.DB
	cat *Catalog
	now func() time.Time
}

// NewService creates a Registry service.
func NewService(db *sql.DB, cat *Catalog, now func() time.Time) *Service {
	if now == nil {
		now = time.Now
	}
	return &Service{db: db, cat: cat, now: now}
}

// Catalog returns the type/capability/relation catalog.
func (s *Service) Catalog() *Catalog { return s.cat }

func (s *Service) inTx(ctx context.Context, fn func(tx *sql.Tx) error) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if err := fn(tx); err != nil {
		return err
	}
	return tx.Commit()
}

// Create registers a new entity. Capabilities default to the type's defaults.
func (s *Service) Create(ctx context.Context, in NewEntity) (Entity, error) {
	v := &ValidationError{}
	name := validName(v, in.Name)
	t, known := s.cat.Type(in.Type)
	if !known {
		v.add("type", "Неизвестный тип объекта")
	}
	mode := t.AddressMode
	if !known {
		mode = AddressOptional
	}
	icon := validIcon(v, in.Icon)
	if icon == "" {
		icon = t.Icon
	}
	desc := validDescription(v, in.Description)
	tags := validTags(v, in.Tags)
	disc := validDiscovery(v, in.Discovery)
	addr := validAddress(v, in.Address, mode)
	secrets := validSecretRefs(v, in.SecretRefs)
	attrs := validAttributes(v, in.Attributes)
	caps := t.DefaultCapabilities
	if in.Capabilities != nil {
		caps = s.validCapabilities(v, *in.Capabilities)
	}
	if err := v.orNil(); err != nil {
		return Entity{}, err
	}

	id := ids.New()
	now := formatTime(s.now())
	err := s.inTx(ctx, func(tx *sql.Tx) error {
		if err := s.checkParent(ctx, tx, id, in.ParentID); err != nil {
			return err
		}
		secretJSON, _ := json.Marshal(secrets)
		if _, err := tx.ExecContext(ctx, `INSERT INTO registry_entities
			(id, name, name_key, type, description, icon, parent_id, discovery, address,
			 secret_refs, attributes, search_text, revision, created_at, updated_at)
			VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?)`,
			id, name, strings.ToLower(name), in.Type, desc, icon, nullable(in.ParentID), disc, nullable(addr),
			string(secretJSON), string(attrs), searchText(name, desc, addr, tags), now, now); err != nil {
			return err
		}
		if err := writeTags(ctx, tx, id, tags); err != nil {
			return err
		}
		return writeCapabilities(ctx, tx, id, caps, setOf(t.DefaultCapabilities))
	})
	if err != nil {
		return Entity{}, err
	}
	return s.Get(ctx, id)
}

// Get returns one entity, archived or not.
func (s *Service) Get(ctx context.Context, id string) (Entity, error) {
	if !ids.Valid(id) {
		return Entity{}, ErrNotFound
	}
	return loadEntity(ctx, s.db, id)
}

// List returns a filtered, paginated listing sorted by name.
func (s *Service) List(ctx context.Context, f ListFilter) (Page, error) {
	v := &ValidationError{}
	if f.Limit == 0 {
		f.Limit = defaultLimit
	}
	if f.Limit < 1 || f.Limit > maxLimit {
		v.add("limit", "limit должен быть от 1 до 200")
	}
	if f.Offset < 0 {
		v.add("offset", "offset не может быть отрицательным")
	}
	if f.Archived == "" {
		f.Archived = ArchivedExclude
	}
	if f.Archived != ArchivedExclude && f.Archived != ArchivedOnly && f.Archived != ArchivedAll {
		v.add("archived", "archived: false, true или all")
	}
	if f.ParentID != "" && !ids.Valid(f.ParentID) {
		v.add("parentId", "parentId должен быть UUID")
	}
	if err := v.orNil(); err != nil {
		return Page{}, err
	}

	var where []string
	var args []any
	switch f.Archived {
	case ArchivedExclude:
		where = append(where, "e.archived_at IS NULL")
	case ArchivedOnly:
		where = append(where, "e.archived_at IS NOT NULL")
	}
	if len(f.Types) > 0 {
		where = append(where, "e.type IN ("+placeholders(len(f.Types))+")")
		for _, t := range f.Types {
			args = append(args, t)
		}
	}
	if f.Tag != "" {
		where = append(where, "EXISTS (SELECT 1 FROM registry_entity_tags t WHERE t.entity_id = e.id AND t.tag = ?)")
		args = append(args, strings.ToLower(strings.TrimSpace(f.Tag)))
	}
	if f.Capability != "" {
		where = append(where, "EXISTS (SELECT 1 FROM registry_entity_capabilities c WHERE c.entity_id = e.id AND c.capability = ?)")
		args = append(args, f.Capability)
	}
	if f.ParentID != "" {
		where = append(where, "e.parent_id = ?")
		args = append(args, f.ParentID)
	}
	for _, term := range strings.Fields(strings.ToLower(f.Query)) {
		where = append(where, `e.search_text LIKE ? ESCAPE '\'`)
		args = append(args, "%"+escapeLike(term)+"%")
	}
	cond := ""
	if len(where) > 0 {
		cond = " WHERE " + strings.Join(where, " AND ")
	}

	page := Page{Items: []Entity{}, Limit: f.Limit, Offset: f.Offset}
	if err := s.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM registry_entities e`+cond, args...).Scan(&page.Total); err != nil {
		return Page{}, err
	}
	rows, err := s.db.QueryContext(ctx, `SELECT `+prefixed(entityColumns)+` FROM registry_entities e`+cond+
		` ORDER BY e.name_key, e.id LIMIT ? OFFSET ?`, append(args, f.Limit, f.Offset)...)
	if err != nil {
		return Page{}, err
	}
	for rows.Next() {
		e, err := scanEntity(rows)
		if err != nil {
			rows.Close()
			return Page{}, err
		}
		page.Items = append(page.Items, e)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return Page{}, err
	}
	return page, attachChildren(ctx, s.db, page.Items)
}

// Update applies a patch if p.Revision matches the stored revision.
func (s *Service) Update(ctx context.Context, id string, p EntityPatch) (Entity, error) {
	err := s.mutate(ctx, id, p.Revision, func(tx *sql.Tx, e *Entity) error {
		v := &ValidationError{}
		name, typ := e.Name, e.Type
		if p.Name != nil {
			name = validName(v, *p.Name)
		}
		if p.Type != nil && *p.Type != e.Type {
			if _, ok := s.cat.Type(*p.Type); !ok {
				v.add("type", "Неизвестный тип объекта")
			}
			typ = *p.Type
		}
		mode := AddressOptional
		if t, ok := s.cat.Type(typ); ok {
			mode = t.AddressMode
		}
		desc, icon, tags, disc := e.Description, e.Icon, e.Tags, e.Discovery
		if p.Description != nil {
			desc = validDescription(v, *p.Description)
		}
		if p.Icon != nil {
			icon = validIcon(v, *p.Icon)
		}
		if p.Tags != nil {
			tags = validTags(v, *p.Tags)
		}
		if p.Discovery != nil {
			disc = validDiscovery(v, *p.Discovery)
		}
		addr := e.Address
		if p.Address != nil {
			addr = *p.Address
		}
		addr = validAddress(v, addr, mode)
		secrets := e.SecretRefs
		if p.SecretRefs != nil {
			secrets = validSecretRefs(v, *p.SecretRefs)
		}
		attrs := e.Attributes
		if p.Attributes != nil {
			attrs = validAttributes(v, *p.Attributes)
		}
		parent := e.ParentID
		if p.ParentID != nil {
			parent = *p.ParentID
		}
		if err := v.orNil(); err != nil {
			return err
		}
		if p.ParentID != nil {
			if err := s.checkParent(ctx, tx, id, parent); err != nil {
				return err
			}
		}
		secretJSON, _ := json.Marshal(secrets)
		if _, err := tx.ExecContext(ctx, `UPDATE registry_entities SET
			name = ?, name_key = ?, type = ?, description = ?, icon = ?, parent_id = ?, discovery = ?,
			address = ?, secret_refs = ?, attributes = ?, search_text = ?
			WHERE id = ?`,
			name, strings.ToLower(name), typ, desc, icon, nullable(parent), disc, nullable(addr),
			string(secretJSON), string(attrs), searchText(name, desc, addr, tags), id); err != nil {
			return err
		}
		return writeTags(ctx, tx, id, tags)
	})
	if err != nil {
		return Entity{}, err
	}
	return s.Get(ctx, id)
}

// SetCapabilities replaces the declared capabilities of an entity.
func (s *Service) SetCapabilities(ctx context.Context, id string, revision int, caps []string) (Entity, error) {
	v := &ValidationError{}
	caps = s.validCapabilities(v, caps)
	if err := v.orNil(); err != nil {
		return Entity{}, err
	}
	err := s.mutate(ctx, id, revision, func(tx *sql.Tx, e *Entity) error {
		t, _ := s.cat.Type(e.Type)
		return writeCapabilities(ctx, tx, id, caps, setOf(t.DefaultCapabilities))
	})
	if err != nil {
		return Entity{}, err
	}
	return s.Get(ctx, id)
}

// Archive hides an entity from default listings without deleting it.
func (s *Service) Archive(ctx context.Context, id string, revision int) (Entity, error) {
	return s.setArchived(ctx, id, revision, true)
}

// Restore brings an archived entity back.
func (s *Service) Restore(ctx context.Context, id string, revision int) (Entity, error) {
	return s.setArchived(ctx, id, revision, false)
}

func (s *Service) setArchived(ctx context.Context, id string, revision int, archive bool) (Entity, error) {
	err := s.inTx(ctx, func(tx *sql.Tx) error {
		e, err := s.lockFor(ctx, tx, id, revision)
		if err != nil {
			return err
		}
		if e.Archived == archive {
			msg := "Объект уже в архиве"
			if !archive {
				msg = "Объект не в архиве"
			}
			return &ConflictError{Reason: "state", Message: msg, CurrentRevision: e.Revision}
		}
		var at any
		if archive {
			at = formatTime(s.now())
		}
		_, err = tx.ExecContext(ctx, `UPDATE registry_entities SET archived_at = ?, revision = revision + 1, updated_at = ?
			WHERE id = ? AND revision = ?`, at, formatTime(s.now()), id, revision)
		return err
	})
	if err != nil {
		return Entity{}, err
	}
	return s.Get(ctx, id)
}

// mutate loads the entity, enforces revision and active state, runs fn and bumps the revision.
func (s *Service) mutate(ctx context.Context, id string, revision int, fn func(tx *sql.Tx, e *Entity) error) error {
	return s.inTx(ctx, func(tx *sql.Tx) error {
		e, err := s.lockFor(ctx, tx, id, revision)
		if err != nil {
			return err
		}
		if e.Archived {
			return &ConflictError{Reason: "archived", Message: "Объект в архиве: сначала восстановите его", CurrentRevision: e.Revision}
		}
		if err := fn(tx, &e); err != nil {
			return err
		}
		res, err := tx.ExecContext(ctx, `UPDATE registry_entities SET revision = revision + 1, updated_at = ?
			WHERE id = ? AND revision = ?`, formatTime(s.now()), id, revision)
		if err != nil {
			return err
		}
		if n, _ := res.RowsAffected(); n != 1 {
			return &ConflictError{Reason: "revision_mismatch", Message: "Объект изменён параллельно", CurrentRevision: e.Revision}
		}
		return nil
	})
}

func (s *Service) lockFor(ctx context.Context, tx *sql.Tx, id string, revision int) (Entity, error) {
	if !ids.Valid(id) {
		return Entity{}, ErrNotFound
	}
	if revision < 1 {
		return Entity{}, &ValidationError{Fields: map[string]string{"revision": "Укажите текущую версию записи"}}
	}
	e, err := loadEntity(ctx, tx, id)
	if err != nil {
		return Entity{}, err
	}
	if e.Revision != revision {
		return Entity{}, &ConflictError{
			Reason:          "revision_mismatch",
			Message:         "Объект был изменён: обновите данные и повторите",
			CurrentRevision: e.Revision,
		}
	}
	return e, nil
}

func (s *Service) checkParent(ctx context.Context, tx *sql.Tx, id string, parent *string) error {
	if parent == nil {
		return nil
	}
	if *parent == id {
		return &ValidationError{Fields: map[string]string{"parentId": "Объект не может быть родителем самого себя"}}
	}
	if !ids.Valid(*parent) {
		return &ValidationError{Fields: map[string]string{"parentId": "Родительский объект не найден"}}
	}
	// Always read through tx: the pool has a single connection.
	p, err := loadEntity(ctx, tx, *parent)
	if errors.Is(err, ErrNotFound) {
		return &ValidationError{Fields: map[string]string{"parentId": "Родительский объект не найден"}}
	}
	if err != nil {
		return err
	}
	if p.Archived {
		return &ValidationError{Fields: map[string]string{"parentId": "Родительский объект в архиве"}}
	}
	cycle, err := parentChainContains(ctx, tx, *parent, id)
	if err != nil {
		return err
	}
	if cycle {
		return &ConflictError{Reason: "cycle", Message: "Такой родитель создаст цикл в иерархии"}
	}
	return nil
}

func (s *Service) validCapabilities(v *ValidationError, caps []string) []string {
	seen := map[string]bool{}
	out := []string{}
	for _, c := range caps {
		if seen[c] {
			continue
		}
		if _, ok := s.cat.Capability(c); !ok {
			v.add("capabilities", "Неизвестная возможность «"+c+"»")
			continue
		}
		seen[c] = true
		out = append(out, c)
	}
	sort.Strings(out)
	return out
}

// Relations lists outgoing and incoming relations of an entity.
func (s *Service) Relations(ctx context.Context, id string) ([]RelationView, error) {
	if _, err := s.Get(ctx, id); err != nil {
		return nil, err
	}
	rows, err := s.db.QueryContext(ctx, `
SELECT r.id, r.from_id, r.to_id, r.kind, r.label, r.created_at, 'outgoing',
       p.id, p.name, p.type, p.archived_at IS NOT NULL
FROM registry_relations r JOIN registry_entities p ON p.id = r.to_id WHERE r.from_id = ?
UNION ALL
SELECT r.id, r.from_id, r.to_id, r.kind, r.label, r.created_at, 'incoming',
       p.id, p.name, p.type, p.archived_at IS NOT NULL
FROM registry_relations r JOIN registry_entities p ON p.id = r.from_id WHERE r.to_id = ?
ORDER BY 7 DESC, 4, 9`, id, id)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []RelationView{}
	for rows.Next() {
		var rv RelationView
		var created string
		if err := rows.Scan(&rv.ID, &rv.FromID, &rv.ToID, &rv.Kind, &rv.Label, &created, &rv.Direction,
			&rv.Peer.ID, &rv.Peer.Name, &rv.Peer.Type, &rv.Peer.Archived); err != nil {
			return nil, err
		}
		if rv.CreatedAt, err = parseTime(created); err != nil {
			return nil, err
		}
		out = append(out, rv)
	}
	return out, rows.Err()
}

// AddRelation creates "from <kind> to". Acyclic kinds reject cycles within their group.
func (s *Service) AddRelation(ctx context.Context, fromID, kind, toID, label string) (Relation, error) {
	v := &ValidationError{}
	k, ok := s.cat.RelationKind(kind)
	if !ok {
		v.add("kind", "Неизвестный вид связи")
	}
	if !ids.Valid(toID) {
		v.add("targetId", "Укажите объект для связи")
	} else if toID == fromID {
		v.add("targetId", "Объект не может быть связан сам с собой")
	}
	label = validRelationLabel(v, kind, label)
	if err := v.orNil(); err != nil {
		return Relation{}, err
	}

	rel := Relation{ID: ids.New(), FromID: fromID, ToID: toID, Kind: kind, Label: label, CreatedAt: s.now().UTC()}
	err := s.inTx(ctx, func(tx *sql.Tx) error {
		from, err := loadEntity(ctx, tx, fromID)
		if err != nil {
			return err
		}
		to, err := loadEntity(ctx, tx, toID)
		if errors.Is(err, ErrNotFound) {
			return &ValidationError{Fields: map[string]string{"targetId": "Объект для связи не найден"}}
		}
		if err != nil {
			return err
		}
		if from.Archived || to.Archived {
			return &ConflictError{Reason: "archived", Message: "Нельзя связывать объекты из архива"}
		}
		var dup int
		if err := tx.QueryRowContext(ctx, `SELECT COUNT(*) FROM registry_relations
			WHERE from_id = ? AND to_id = ? AND kind = ? AND label = ?`, fromID, toID, kind, label).Scan(&dup); err != nil {
			return err
		}
		if dup > 0 {
			return &ConflictError{Reason: "duplicate", Message: "Такая связь уже есть"}
		}
		if k.Acyclic {
			cycle, err := reachable(ctx, tx, toID, fromID, s.cat.CycleGroupKinds(k.CycleGroup))
			if err != nil {
				return err
			}
			if cycle {
				return &ConflictError{Reason: "cycle", Message: "Связь «" + k.Label + "» создаст циклическую зависимость"}
			}
		}
		_, err = tx.ExecContext(ctx, `INSERT INTO registry_relations (id, from_id, to_id, kind, label, created_at)
			VALUES (?, ?, ?, ?, ?, ?)`, rel.ID, fromID, toID, kind, label, formatTime(rel.CreatedAt))
		return err
	})
	if err != nil {
		return Relation{}, err
	}
	return rel, nil
}

// ErrRelationNotFound is returned when deleting an unknown relation.
var ErrRelationNotFound = errors.New("relation not found")

// DeleteRelation removes a relation (relations are links, not objects).
func (s *Service) DeleteRelation(ctx context.Context, id string) error {
	if !ids.Valid(id) {
		return ErrRelationNotFound
	}
	res, err := s.db.ExecContext(ctx, `DELETE FROM registry_relations WHERE id = ?`, id)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return ErrRelationNotFound
	}
	return nil
}

func setOf(items []string) map[string]bool {
	m := make(map[string]bool, len(items))
	for _, i := range items {
		m[i] = true
	}
	return m
}

func escapeLike(s string) string {
	return strings.NewReplacer(`\`, `\\`, `%`, `\%`, `_`, `\_`).Replace(s)
}

func prefixed(cols string) string {
	parts := strings.Split(cols, ",")
	for i, p := range parts {
		parts[i] = "e." + strings.TrimSpace(p)
	}
	return strings.Join(parts, ", ")
}
