package storage

import (
	"context"
	"database/sql"
	"errors"
	"path/filepath"
	"testing"
)

var testMigrations = []Migration{
	{Version: 1, Name: "create_items", SQL: `CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT NOT NULL)`},
	{Version: 2, Name: "add_note", SQL: `ALTER TABLE items ADD COLUMN note TEXT`},
}

func openTemp(t *testing.T) (string, func() *testDB) {
	t.Helper()
	path := filepath.Join(t.TempDir(), "nested", "test.db")
	return path, func() *testDB {
		db, err := Open(context.Background(), path)
		if err != nil {
			t.Fatalf("Open: %v", err)
		}
		t.Cleanup(func() { db.Close() })
		return &testDB{db}
	}
}

type sqlDB = sql.DB

type testDB struct{ *sqlDB }

func TestOpenUsesWAL(t *testing.T) {
	_, open := openTemp(t)
	db := open()
	var mode string
	if err := db.QueryRow(`PRAGMA journal_mode`).Scan(&mode); err != nil {
		t.Fatal(err)
	}
	if mode != "wal" {
		t.Fatalf("journal_mode = %q, want wal", mode)
	}
}

func TestMigrateIsIdempotent(t *testing.T) {
	ctx := context.Background()
	_, open := openTemp(t)
	db := open()

	n, err := Migrate(ctx, db.sqlDB, "items", testMigrations)
	if err != nil || n != 2 {
		t.Fatalf("first run: n=%d err=%v", n, err)
	}
	n, err = Migrate(ctx, db.sqlDB, "items", testMigrations)
	if err != nil || n != 0 {
		t.Fatalf("second run: n=%d err=%v", n, err)
	}
	if _, err := db.Exec(`INSERT INTO items (name, note) VALUES ('a', 'b')`); err != nil {
		t.Fatalf("schema not applied: %v", err)
	}
}

func TestDataSurvivesReopen(t *testing.T) {
	ctx := context.Background()
	_, open := openTemp(t)
	first := open()
	if _, err := Migrate(ctx, first.sqlDB, "items", testMigrations); err != nil {
		t.Fatal(err)
	}
	if _, err := first.Exec(`INSERT INTO items (name) VALUES ('persisted')`); err != nil {
		t.Fatal(err)
	}
	first.Close()

	second := open()
	if n, err := Migrate(ctx, second.sqlDB, "items", testMigrations); err != nil || n != 0 {
		t.Fatalf("reopen migrate: n=%d err=%v", n, err)
	}
	var name string
	if err := second.QueryRow(`SELECT name FROM items`).Scan(&name); err != nil || name != "persisted" {
		t.Fatalf("row lost after reopen: %q %v", name, err)
	}
}

func TestIncrementalMigration(t *testing.T) {
	ctx := context.Background()
	_, open := openTemp(t)
	db := open()
	if n, err := Migrate(ctx, db.sqlDB, "items", testMigrations[:1]); err != nil || n != 1 {
		t.Fatalf("v1: n=%d err=%v", n, err)
	}
	if n, err := Migrate(ctx, db.sqlDB, "items", testMigrations); err != nil || n != 1 {
		t.Fatalf("v2: n=%d err=%v", n, err)
	}
	versions, err := AppliedVersions(ctx, db.sqlDB)
	if err != nil || len(versions) != 1 || versions[0] != (AppliedVersion{"items", 2}) {
		t.Fatalf("AppliedVersions = %+v, %v", versions, err)
	}
}

func TestModulesAreIndependent(t *testing.T) {
	ctx := context.Background()
	_, open := openTemp(t)
	db := open()
	if _, err := Migrate(ctx, db.sqlDB, "a", testMigrations[:1]); err != nil {
		t.Fatal(err)
	}
	other := []Migration{{Version: 1, Name: "create_other", SQL: `CREATE TABLE other (id INTEGER)`}}
	if n, err := Migrate(ctx, db.sqlDB, "b", other); err != nil || n != 1 {
		t.Fatalf("module b: n=%d err=%v", n, err)
	}
}

func TestRefusesNewerSchema(t *testing.T) {
	ctx := context.Background()
	_, open := openTemp(t)
	db := open()
	if _, err := Migrate(ctx, db.sqlDB, "items", testMigrations); err != nil {
		t.Fatal(err)
	}
	_, err := Migrate(ctx, db.sqlDB, "items", testMigrations[:1])
	if !errors.Is(err, ErrSchemaNewer) {
		t.Fatalf("want ErrSchemaNewer, got %v", err)
	}
}

func TestRejectsRenamedMigration(t *testing.T) {
	ctx := context.Background()
	_, open := openTemp(t)
	db := open()
	if _, err := Migrate(ctx, db.sqlDB, "items", testMigrations[:1]); err != nil {
		t.Fatal(err)
	}
	renamed := []Migration{{Version: 1, Name: "something_else", SQL: "SELECT 1"}}
	if _, err := Migrate(ctx, db.sqlDB, "items", renamed); err == nil {
		t.Fatal("expected mismatch error")
	}
}

func TestFailedMigrationRollsBack(t *testing.T) {
	ctx := context.Background()
	_, open := openTemp(t)
	db := open()
	bad := []Migration{
		{Version: 1, Name: "ok", SQL: `CREATE TABLE t1 (id INTEGER)`},
		{Version: 2, Name: "broken", SQL: `CREATE TABLE t2 (id INTEGER); THIS IS NOT SQL`},
	}
	if _, err := Migrate(ctx, db.sqlDB, "m", bad); err == nil {
		t.Fatal("expected failure")
	}
	versions, _ := AppliedVersions(ctx, db.sqlDB)
	if len(versions) != 1 || versions[0].Version != 1 {
		t.Fatalf("want only v1 recorded, got %+v", versions)
	}
}

func TestRejectsGappedVersions(t *testing.T) {
	_, open := openTemp(t)
	db := open()
	gapped := []Migration{{Version: 2, Name: "x", SQL: "SELECT 1"}}
	if _, err := Migrate(context.Background(), db.sqlDB, "m", gapped); err == nil {
		t.Fatal("expected version gap to be rejected")
	}
}
