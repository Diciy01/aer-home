package scene

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"time"

	"aerhome/core/internal/foundation/ids"
	"aerhome/core/internal/foundation/storage"
)

// Tables are prefixed scene_ and never shared with Registry.
var migrations = []storage.Migration{
	{Version: 1, Name: "create_scene_documents", SQL: `
CREATE TABLE scene_documents (
	id             TEXT PRIMARY KEY,
	name           TEXT NOT NULL,
	schema_version INTEGER NOT NULL,
	demo           INTEGER NOT NULL,
	revision       INTEGER NOT NULL CHECK (revision >= 1),
	document       TEXT NOT NULL,
	created_at     TEXT NOT NULL,
	updated_at     TEXT NOT NULL
);
CREATE TABLE scene_document_history (
	scene_id TEXT NOT NULL REFERENCES scene_documents(id),
	revision INTEGER NOT NULL,
	document TEXT NOT NULL,
	saved_at TEXT NOT NULL,
	PRIMARY KEY (scene_id, revision)
);
`},
}

// historyDepth is how many previous revisions are kept for recovery (M04 undo/restore).
const historyDepth = 20

var (
	ErrNotFound = errors.New("scene not found")
)

// ConflictError reports a stale revision or a duplicate scene id.
type ConflictError struct {
	Reason          string // revision_mismatch | duplicate
	Message         string
	CurrentRevision int
}

func (e *ConflictError) Error() string { return e.Message }

// Summary is a scene without its document.
type Summary struct {
	ID            string    `json:"id"`
	Name          string    `json:"name"`
	SchemaVersion int       `json:"schemaVersion"`
	Demo          bool      `json:"demo"`
	Revision      int       `json:"revision"`
	CreatedAt     time.Time `json:"createdAt"`
	UpdatedAt     time.Time `json:"updatedAt"`
}

// Record is a stored scene with its document.
type Record struct {
	Summary
	Document json.RawMessage `json:"document"`
}

// Service stores scene documents.
type Service struct {
	db  *sql.DB
	now func() time.Time
}

func NewService(db *sql.DB, now func() time.Time) *Service {
	if now == nil {
		now = time.Now
	}
	return &Service{db: db, now: now}
}

func ts(t time.Time) string { return t.UTC().Format(time.RFC3339Nano) }

func scanSummary(row interface{ Scan(...any) error }, withDoc bool) (Record, error) {
	var r Record
	var demo int
	var created, updated, doc string
	dest := []any{&r.ID, &r.Name, &r.SchemaVersion, &demo, &r.Revision, &created, &updated}
	if withDoc {
		dest = append(dest, &doc)
	}
	if err := row.Scan(dest...); err != nil {
		return Record{}, err
	}
	r.Demo = demo == 1
	var err error
	if r.CreatedAt, err = time.Parse(time.RFC3339Nano, created); err != nil {
		return Record{}, err
	}
	if r.UpdatedAt, err = time.Parse(time.RFC3339Nano, updated); err != nil {
		return Record{}, err
	}
	if withDoc {
		r.Document = json.RawMessage(doc)
	}
	return r, nil
}

const summaryCols = `id, name, schema_version, demo, revision, created_at, updated_at`

// List returns all scenes, most recently updated first.
func (s *Service) List(ctx context.Context) ([]Summary, error) {
	rows, err := s.db.QueryContext(ctx, `SELECT `+summaryCols+` FROM scene_documents ORDER BY updated_at DESC, id`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Summary{}
	for rows.Next() {
		r, err := scanSummary(rows, false)
		if err != nil {
			return nil, err
		}
		out = append(out, r.Summary)
	}
	return out, rows.Err()
}

// Get returns one scene with its document.
func (s *Service) Get(ctx context.Context, id string) (Record, error) {
	if !ids.Valid(id) {
		return Record{}, ErrNotFound
	}
	r, err := scanSummary(s.db.QueryRowContext(ctx,
		`SELECT `+summaryCols+`, document FROM scene_documents WHERE id = ?`, id), true)
	if errors.Is(err, sql.ErrNoRows) {
		return Record{}, ErrNotFound
	}
	return r, err
}

// Create validates and stores a new scene (its sceneId becomes the record id).
func (s *Service) Create(ctx context.Context, raw []byte) (Record, error) {
	doc, err := Decode(raw)
	if err != nil {
		return Record{}, err
	}
	now := ts(s.now())
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return Record{}, err
	}
	defer tx.Rollback()
	var exists int
	if err := tx.QueryRowContext(ctx, `SELECT COUNT(*) FROM scene_documents WHERE id = ?`, doc.SceneID).Scan(&exists); err != nil {
		return Record{}, err
	}
	if exists > 0 {
		return Record{}, &ConflictError{Reason: "duplicate", Message: "Сцена с таким sceneId уже сохранена"}
	}
	if _, err := tx.ExecContext(ctx, `INSERT INTO scene_documents
		(id, name, schema_version, demo, revision, document, created_at, updated_at)
		VALUES (?, ?, ?, ?, 1, ?, ?, ?)`,
		doc.SceneID, doc.Name, doc.SchemaVersion, boolInt(doc.Demo), string(doc.Canonical()), now, now); err != nil {
		return Record{}, err
	}
	if err := tx.Commit(); err != nil {
		return Record{}, err
	}
	return s.Get(ctx, doc.SceneID)
}

// Replace stores a new revision if revision matches. The previous revision is
// kept in history; a failed validation never touches stored data.
func (s *Service) Replace(ctx context.Context, id string, revision int, raw []byte) (Record, error) {
	if !ids.Valid(id) {
		return Record{}, ErrNotFound
	}
	doc, err := Decode(raw)
	if err != nil {
		return Record{}, err
	}
	if doc.SceneID != id {
		return Record{}, &ValidationError{Issues{"sceneId": "sceneId документа не совпадает с адресом"}}
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return Record{}, err
	}
	defer tx.Rollback()
	var current int
	var previous string
	err = tx.QueryRowContext(ctx, `SELECT revision, document FROM scene_documents WHERE id = ?`, id).Scan(&current, &previous)
	if errors.Is(err, sql.ErrNoRows) {
		return Record{}, ErrNotFound
	}
	if err != nil {
		return Record{}, err
	}
	if current != revision {
		return Record{}, &ConflictError{Reason: "revision_mismatch",
			Message: "Сцена изменена в другом месте: загрузите актуальную версию", CurrentRevision: current}
	}
	now := ts(s.now())
	if _, err := tx.ExecContext(ctx, `INSERT INTO scene_document_history (scene_id, revision, document, saved_at)
		VALUES (?, ?, ?, ?)`, id, current, previous, now); err != nil {
		return Record{}, err
	}
	if _, err := tx.ExecContext(ctx, `DELETE FROM scene_document_history WHERE scene_id = ? AND revision <= ?`,
		id, current-historyDepth); err != nil {
		return Record{}, err
	}
	if _, err := tx.ExecContext(ctx, `UPDATE scene_documents SET name = ?, schema_version = ?, demo = ?,
		revision = revision + 1, document = ?, updated_at = ? WHERE id = ? AND revision = ?`,
		doc.Name, doc.SchemaVersion, boolInt(doc.Demo), string(doc.Canonical()), now, id, revision); err != nil {
		return Record{}, err
	}
	if err := tx.Commit(); err != nil {
		return Record{}, err
	}
	return s.Get(ctx, id)
}

// HistoryRevisions lists stored previous revisions (newest first).
func (s *Service) HistoryRevisions(ctx context.Context, id string) ([]int, error) {
	rows, err := s.db.QueryContext(ctx,
		`SELECT revision FROM scene_document_history WHERE scene_id = ? ORDER BY revision DESC`, id)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []int{}
	for rows.Next() {
		var r int
		if err := rows.Scan(&r); err != nil {
			return nil, err
		}
		out = append(out, r)
	}
	return out, rows.Err()
}

func boolInt(b bool) int {
	if b {
		return 1
	}
	return 0
}
