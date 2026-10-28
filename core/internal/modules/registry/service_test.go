package registry

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"path/filepath"
	"testing"
	"time"

	"aerhome/core/internal/foundation/storage"
)

// All names and addresses below are TEST DATA.

func openDB(t *testing.T, path string) *sql.DB {
	t.Helper()
	db, err := storage.Open(context.Background(), path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { db.Close() }) // before TempDir removal: Windows cannot delete an open file
	if _, err := storage.Migrate(context.Background(), db, Name, migrations); err != nil {
		t.Fatal(err)
	}
	return db
}

func newTestService(t *testing.T) *Service {
	t.Helper()
	db := openDB(t, filepath.Join(t.TempDir(), "reg.db"))
	clock := time.Date(2026, 10, 26, 12, 0, 0, 0, time.UTC)
	return NewService(db, DefaultCatalog(), func() time.Time {
		clock = clock.Add(time.Second)
		return clock
	})
}

func mustCreate(t *testing.T, s *Service, in NewEntity) Entity {
	t.Helper()
	e, err := s.Create(context.Background(), in)
	if err != nil {
		t.Fatalf("Create %q: %v", in.Name, err)
	}
	return e
}

func fields(t *testing.T, err error) map[string]string {
	t.Helper()
	var ve *ValidationError
	if !errors.As(err, &ve) {
		t.Fatalf("want ValidationError, got %v", err)
	}
	return ve.Fields
}

func conflict(t *testing.T, err error) *ConflictError {
	t.Helper()
	var ce *ConflictError
	if !errors.As(err, &ce) {
		t.Fatalf("want ConflictError, got %v", err)
	}
	return ce
}

func strp(s string) *string { return &s }

func TestDefaultCatalogIsComplete(t *testing.T) {
	c := DefaultCatalog()
	want := []string{"computer", "server", "router", "television", "mobile_device", "network_device",
		"telegram_bot", "application", "process", "docker_container", "database", "website",
		"service", "automation", "storage", "virtual_object", "custom"}
	for _, id := range want {
		if _, ok := c.Type(id); !ok {
			t.Errorf("type %s missing", id)
		}
	}
	if len(c.Types()) != len(want) {
		t.Errorf("types = %d, want %d", len(c.Types()), len(want))
	}
	for _, id := range []string{"runs_on", "depends_on", "hosted_by", "installed_on", "connected_to", "controls", "custom"} {
		if _, ok := c.RelationKind(id); !ok {
			t.Errorf("relation kind %s missing", id)
		}
	}
}

func TestCatalogIsExtensible(t *testing.T) {
	c := DefaultCatalog()
	if err := c.RegisterCapability(Capability{ID: "printer.queue", Label: "Очередь печати", Module: "integrations"}); err != nil {
		t.Fatal(err)
	}
	if err := c.RegisterType(EntityType{ID: "printer", Label: "Принтер", Group: "hardware", Icon: "printer",
		AddressMode: AddressOptional, DefaultCapabilities: []string{"printer.queue", "network.ping"}}); err != nil {
		t.Fatal(err)
	}
	s := NewService(openDB(t, filepath.Join(t.TempDir(), "x.db")), c, nil)
	e := mustCreate(t, s, NewEntity{Name: "Принтер в кабинете", Type: "printer"})
	if len(e.Capabilities) != 2 || e.Icon != "printer" {
		t.Fatalf("new type not applied: %+v", e)
	}
	if err := c.RegisterType(EntityType{ID: "printer", Label: "dup", AddressMode: AddressNone}); err == nil {
		t.Fatal("duplicate type must be rejected")
	}
	if err := c.RegisterType(EntityType{ID: "scanner", Label: "Сканер", AddressMode: AddressNone,
		DefaultCapabilities: []string{"no.such"}}); err == nil {
		t.Fatal("unknown default capability must be rejected")
	}
}

func TestCreateMinimalAppliesDefaults(t *testing.T) {
	s := newTestService(t)
	e := mustCreate(t, s, NewEntity{Name: "  PICO  ", Type: "telegram_bot"})
	if e.Name != "PICO" || e.Revision != 1 || e.Archived || e.Discovery != DiscoveryManual || e.Icon != "bot" {
		t.Fatalf("defaults not applied: %+v", e)
	}
	if string(e.Attributes) != "{}" || len(e.Tags) != 0 || len(e.SecretRefs) != 0 || e.Address != nil {
		t.Fatalf("empty fields wrong: %+v", e)
	}
	if want := []string{"bot.tasks", "monitoring.heartbeat", "monitoring.logs"}; !equal(e.Capabilities, want) {
		t.Fatalf("capabilities = %v, want %v", e.Capabilities, want)
	}
	if !e.CreatedAt.Equal(e.UpdatedAt) {
		t.Fatal("createdAt != updatedAt on create")
	}
}

func TestCreateFullEntity(t *testing.T) {
	s := newTestService(t)
	host := mustCreate(t, s, NewEntity{Name: "Сервер (тест)", Type: "server"})
	caps := []string{"docker.manage", "monitoring.logs"}
	e := mustCreate(t, s, NewEntity{
		Name: "postgres-test", Type: "database", Description: "Тестовая БД", Icon: "custom/pg",
		Tags: []string{"Prod", "db", "prod"}, ParentID: &host.ID, Discovery: DiscoveryDocker,
		Address:      strp("192.0.2.10:5432"),
		SecretRefs:   []SecretRef{{Name: "password", Ref: "env:TEST_PG_PASSWORD"}},
		Attributes:   json.RawMessage(`{"engine":"postgresql","version":"16"}`),
		Capabilities: &caps,
	})
	if !equal(e.Tags, []string{"db", "prod"}) || *e.ParentID != host.ID || *e.Address != "192.0.2.10:5432" {
		t.Fatalf("fields not stored: %+v", e)
	}
	if !equal(e.Capabilities, caps) || e.SecretRefs[0].Ref != "env:TEST_PG_PASSWORD" {
		t.Fatalf("caps/secrets wrong: %+v", e)
	}
}

func TestCreateValidation(t *testing.T) {
	s := newTestService(t)
	cases := map[string]struct {
		in    NewEntity
		field string
	}{
		"no name":              {NewEntity{Type: "server"}, "name"},
		"long name":            {NewEntity{Name: string(make([]rune, 121)), Type: "server"}, "name"},
		"unknown type":         {NewEntity{Name: "x", Type: "toaster"}, "type"},
		"website needs URL":    {NewEntity{Name: "x", Type: "website"}, "address"},
		"bot has no address":   {NewEntity{Name: "x", Type: "telegram_bot", Address: strp("198.51.100.1")}, "address"},
		"credentials in URL":   {NewEntity{Name: "x", Type: "website", Address: strp("https://u:p@example.org")}, "address"},
		"credentials in host":  {NewEntity{Name: "x", Type: "database", Address: strp("admin@db:5432")}, "address"},
		"space in address":     {NewEntity{Name: "x", Type: "server", Address: strp("a b")}, "address"},
		"bad tag":              {NewEntity{Name: "x", Type: "server", Tags: []string{"no spaces allowed"}}, "tags"},
		"bad discovery":        {NewEntity{Name: "x", Type: "server", Discovery: "telepathy"}, "discovery"},
		"raw secret":           {NewEntity{Name: "x", Type: "server", SecretRefs: []SecretRef{{Name: "token", Ref: "123456:ABC-real-token"}}}, "secretRefs"},
		"secret in attributes": {NewEntity{Name: "x", Type: "server", Attributes: json.RawMessage(`{"ssh":{"Private-Key":"x"}}`)}, "attributes"},
		"attributes not obj":   {NewEntity{Name: "x", Type: "server", Attributes: json.RawMessage(`[1,2]`)}, "attributes"},
		"unknown capability":   {NewEntity{Name: "x", Type: "server", Capabilities: &[]string{"teleport"}}, "capabilities"},
		"bad icon":             {NewEntity{Name: "x", Type: "server", Icon: "Icon With Spaces"}, "icon"},
		"missing parent":       {NewEntity{Name: "x", Type: "server", ParentID: strp("00000000-0000-4000-8000-000000000000")}, "parentId"},
	}
	for name, tc := range cases {
		t.Run(name, func(t *testing.T) {
			_, err := s.Create(context.Background(), tc.in)
			if f := fields(t, err); f[tc.field] == "" {
				t.Fatalf("want error on %s, got %v", tc.field, f)
			}
		})
	}
	page, _ := s.List(context.Background(), ListFilter{Archived: ArchivedAll})
	if page.Total != 0 {
		t.Fatalf("invalid creates must not persist anything, got %d", page.Total)
	}
}

func seed(t *testing.T, s *Service) map[string]Entity {
	t.Helper()
	m := map[string]Entity{}
	m["pc"] = mustCreate(t, s, NewEntity{Name: "Основной ПК", Type: "computer", Tags: []string{"home", "dualboot"}, Address: strp("192.0.2.154")})
	m["server"] = mustCreate(t, s, NewEntity{Name: "Сервер", Type: "server", Tags: []string{"home"}})
	m["bot"] = mustCreate(t, s, NewEntity{Name: "PICO бот", Type: "telegram_bot", Description: "Отвечает в Telegram"})
	m["db"] = mustCreate(t, s, NewEntity{Name: "postgres", Type: "database"})
	m["tv"] = mustCreate(t, s, NewEntity{Name: "Mini TV", Type: "television", Tags: []string{"media"}})
	return m
}

func names(p Page) []string {
	out := []string{}
	for _, e := range p.Items {
		out = append(out, e.Name)
	}
	return out
}

func TestListFilterSearchPaginate(t *testing.T) {
	s := newTestService(t)
	ctx := context.Background()
	m := seed(t, s)

	all, err := s.List(ctx, ListFilter{})
	if err != nil || all.Total != 5 {
		t.Fatalf("list all: %v %+v", err, all)
	}
	if want := []string{"Mini TV", "PICO бот", "postgres", "Основной ПК", "Сервер"}; !equal(names(all), want) {
		t.Fatalf("order = %v, want %v", names(all), want)
	}

	checks := []struct {
		f    ListFilter
		want []string
	}{
		{ListFilter{Types: []string{"computer", "server"}}, []string{"Основной ПК", "Сервер"}},
		{ListFilter{Tag: "HOME"}, []string{"Основной ПК", "Сервер"}},
		{ListFilter{Capability: "power.reboot"}, []string{"Основной ПК", "Сервер"}},
		{ListFilter{Capability: "bot.tasks"}, []string{"PICO бот"}},
		{ListFilter{Query: "основной"}, []string{"Основной ПК"}},    // Cyrillic, case-insensitive
		{ListFilter{Query: "TELEGRAM"}, []string{"PICO бот"}},       // description
		{ListFilter{Query: "192.0.2.154"}, []string{"Основной ПК"}}, // address
		{ListFilter{Query: "media"}, []string{"Mini TV"}},           // tag
		{ListFilter{Query: "pico отвечает"}, []string{"PICO бот"}},  // all terms must match
		{ListFilter{Query: "%"}, []string{}},                        // LIKE wildcards escaped
		{ListFilter{Limit: 2, Offset: 2}, []string{"postgres", "Основной ПК"}},
	}
	for _, c := range checks {
		p, err := s.List(ctx, c.f)
		if err != nil {
			t.Fatalf("%+v: %v", c.f, err)
		}
		if !equal(names(p), c.want) {
			t.Errorf("%+v: got %v, want %v", c.f, names(p), c.want)
		}
	}

	paged, _ := s.List(ctx, ListFilter{Limit: 2, Offset: 4})
	if paged.Total != 5 || len(paged.Items) != 1 {
		t.Fatalf("last page: %+v", paged)
	}

	child := mustCreate(t, s, NewEntity{Name: "Ubuntu", Type: "virtual_object", ParentID: strp(m["pc"].ID)})
	byParent, _ := s.List(ctx, ListFilter{ParentID: m["pc"].ID})
	if len(byParent.Items) != 1 || byParent.Items[0].ID != child.ID {
		t.Fatalf("parent filter: %v", names(byParent))
	}

	for _, bad := range []ListFilter{{Limit: 500}, {Offset: -1}, {Archived: "maybe"}, {ParentID: "nope"}} {
		if _, err := s.List(ctx, bad); err == nil {
			t.Errorf("%+v should fail validation", bad)
		}
	}
}

func TestUpdateAndOptimisticLocking(t *testing.T) {
	s := newTestService(t)
	ctx := context.Background()
	e := mustCreate(t, s, NewEntity{Name: "Сервер", Type: "server", Address: strp("192.0.2.1")})

	updated, err := s.Update(ctx, e.ID, EntityPatch{Revision: 1, Name: strp("Домашний сервер"), Tags: &[]string{"Core"}})
	if err != nil {
		t.Fatal(err)
	}
	if updated.Revision != 2 || updated.Name != "Домашний сервер" || !equal(updated.Tags, []string{"core"}) {
		t.Fatalf("update not applied: %+v", updated)
	}
	if !updated.UpdatedAt.After(e.UpdatedAt) || !updated.CreatedAt.Equal(e.CreatedAt) {
		t.Fatal("timestamps wrong")
	}
	if *updated.Address != "192.0.2.1" {
		t.Fatal("absent field must stay unchanged")
	}

	// Second writer still holds revision 1.
	_, err = s.Update(ctx, e.ID, EntityPatch{Revision: 1, Name: strp("Чужая правка")})
	if ce := conflict(t, err); ce.Reason != "revision_mismatch" || ce.CurrentRevision != 2 {
		t.Fatalf("conflict = %+v", ce)
	}

	var cleared *string
	cleared2, err := s.Update(ctx, e.ID, EntityPatch{Revision: 2, Address: &cleared})
	if err != nil || cleared2.Address != nil {
		t.Fatalf("clear address: %v %+v", err, cleared2.Address)
	}

	if _, err := s.Update(ctx, e.ID, EntityPatch{Revision: 3, Name: strp("")}); fields(t, err)["name"] == "" {
		t.Fatal("empty name must be rejected")
	}
	if _, err := s.Update(ctx, e.ID, EntityPatch{Revision: 3, Type: strp("website")}); fields(t, err)["address"] == "" {
		t.Fatal("type change must re-validate address rules")
	}
	if _, err := s.Update(ctx, "00000000-0000-4000-8000-000000000000", EntityPatch{Revision: 1}); !errors.Is(err, ErrNotFound) {
		t.Fatalf("unknown id: %v", err)
	}
	if _, err := s.Update(ctx, e.ID, EntityPatch{}); fields(t, err)["revision"] == "" {
		t.Fatal("missing revision must be rejected")
	}
}

func TestArchiveAndRestore(t *testing.T) {
	s := newTestService(t)
	ctx := context.Background()
	e := mustCreate(t, s, NewEntity{Name: "Старый роутер", Type: "router"})

	arch, err := s.Archive(ctx, e.ID, 1)
	if err != nil || !arch.Archived || arch.ArchivedAt == nil || arch.Revision != 2 {
		t.Fatalf("archive: %v %+v", err, arch)
	}
	if p, _ := s.List(ctx, ListFilter{}); p.Total != 0 {
		t.Fatal("archived entity must be hidden by default")
	}
	if p, _ := s.List(ctx, ListFilter{Archived: ArchivedOnly}); p.Total != 1 {
		t.Fatal("archived entity must be listed with archived=true")
	}
	if got, err := s.Get(ctx, e.ID); err != nil || !got.Archived {
		t.Fatal("archived entity must still be readable by id")
	}
	if _, err := s.Update(ctx, e.ID, EntityPatch{Revision: 2, Name: strp("x")}); conflict(t, err).Reason != "archived" {
		t.Fatal("archived entity must not be editable")
	}
	if _, err := s.Archive(ctx, e.ID, 2); conflict(t, err).Reason != "state" {
		t.Fatal("double archive must conflict")
	}
	if _, err := s.Restore(ctx, e.ID, 1); conflict(t, err).Reason != "revision_mismatch" {
		t.Fatal("stale restore must conflict")
	}
	restored, err := s.Restore(ctx, e.ID, 2)
	if err != nil || restored.Archived || restored.ArchivedAt != nil || restored.Revision != 3 {
		t.Fatalf("restore: %v %+v", err, restored)
	}
}

func TestCapabilitiesAreSeparateFromType(t *testing.T) {
	s := newTestService(t)
	ctx := context.Background()
	e := mustCreate(t, s, NewEntity{Name: "ПК", Type: "computer"})
	got, err := s.SetCapabilities(ctx, e.ID, 1, []string{"power.wake", "power.switch_os", "power.wake"})
	if err != nil || !equal(got.Capabilities, []string{"power.switch_os", "power.wake"}) || got.Revision != 2 {
		t.Fatalf("set caps: %v %+v", err, got)
	}
	if got.Type != "computer" {
		t.Fatal("type must not change")
	}
	if _, err := s.SetCapabilities(ctx, e.ID, 2, []string{"warp.drive"}); fields(t, err)["capabilities"] == "" {
		t.Fatal("unknown capability accepted")
	}
	if _, err := s.SetCapabilities(ctx, e.ID, 1, nil); conflict(t, err).Reason != "revision_mismatch" {
		t.Fatal("stale capabilities write accepted")
	}
	none, err := s.SetCapabilities(ctx, e.ID, 2, []string{})
	if err != nil || len(none.Capabilities) != 0 {
		t.Fatalf("clear caps: %v %+v", err, none)
	}
}

func TestRelations(t *testing.T) {
	s := newTestService(t)
	ctx := context.Background()
	m := seed(t, s)

	r1, err := s.AddRelation(ctx, m["bot"].ID, "runs_on", m["server"].ID, "")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.AddRelation(ctx, m["bot"].ID, "depends_on", m["db"].ID, ""); err != nil {
		t.Fatal(err)
	}
	if _, err := s.AddRelation(ctx, m["tv"].ID, "connected_to", m["pc"].ID, ""); err != nil {
		t.Fatal(err)
	}

	rels, err := s.Relations(ctx, m["bot"].ID)
	if err != nil || len(rels) != 2 {
		t.Fatalf("bot relations: %v %+v", err, rels)
	}
	for _, r := range rels {
		if r.Direction != "outgoing" || r.Peer.Name == "" {
			t.Fatalf("bad view %+v", r)
		}
	}
	srv, _ := s.Relations(ctx, m["server"].ID)
	if len(srv) != 1 || srv[0].Direction != "incoming" || srv[0].Peer.ID != m["bot"].ID {
		t.Fatalf("server relations: %+v", srv)
	}

	_, err = s.AddRelation(ctx, m["bot"].ID, "runs_on", m["server"].ID, "")
	if conflict(t, err).Reason != "duplicate" {
		t.Fatal("duplicate relation accepted")
	}
	for name, tc := range map[string][3]string{
		"self":           {m["bot"].ID, "runs_on", m["bot"].ID},
		"unknown kind":   {m["bot"].ID, "loves", m["db"].ID},
		"missing target": {m["bot"].ID, "runs_on", "00000000-0000-4000-8000-000000000000"},
		"custom label":   {m["bot"].ID, "custom", m["db"].ID},
	} {
		if _, err := s.AddRelation(ctx, tc[0], tc[1], tc[2], ""); err == nil {
			t.Errorf("%s: accepted", name)
		} else {
			fields(t, err)
		}
	}
	if _, err := s.AddRelation(ctx, "00000000-0000-4000-8000-000000000000", "runs_on", m["db"].ID, ""); !errors.Is(err, ErrNotFound) {
		t.Fatalf("missing source: %v", err)
	}
	if _, err := s.AddRelation(ctx, m["bot"].ID, "custom", m["db"].ID, "пишет логи в"); err != nil {
		t.Fatalf("custom with label: %v", err)
	}

	if err := s.DeleteRelation(ctx, r1.ID); err != nil {
		t.Fatal(err)
	}
	if err := s.DeleteRelation(ctx, r1.ID); !errors.Is(err, ErrRelationNotFound) {
		t.Fatalf("second delete: %v", err)
	}
	if _, err := s.Get(ctx, m["server"].ID); err != nil {
		t.Fatal("deleting a relation must not touch entities")
	}
}

func TestCycleDetection(t *testing.T) {
	s := newTestService(t)
	ctx := context.Background()
	a := mustCreate(t, s, NewEntity{Name: "A", Type: "service"})
	b := mustCreate(t, s, NewEntity{Name: "B", Type: "service"})
	c := mustCreate(t, s, NewEntity{Name: "C", Type: "service"})

	mustRel := func(from, kind, to string) {
		t.Helper()
		if _, err := s.AddRelation(ctx, from, kind, to, ""); err != nil {
			t.Fatalf("%s: %v", kind, err)
		}
	}
	mustRel(a.ID, "depends_on", b.ID)
	mustRel(b.ID, "depends_on", c.ID)
	_, err := s.AddRelation(ctx, c.ID, "depends_on", a.ID, "")
	if conflict(t, err).Reason != "cycle" {
		t.Fatal("dependency cycle accepted")
	}

	// Placement kinds share a cycle group: runs_on + hosted_by may not loop either.
	mustRel(a.ID, "runs_on", b.ID)
	if _, err := s.AddRelation(ctx, b.ID, "hosted_by", a.ID, ""); conflict(t, err).Reason != "cycle" {
		t.Fatal("placement cycle across kinds accepted")
	}
	// Different groups do not interact, and cyclic kinds allow loops.
	mustRel(c.ID, "runs_on", a.ID)
	mustRel(a.ID, "connected_to", b.ID)
	mustRel(b.ID, "connected_to", a.ID)
}

func TestParentHierarchy(t *testing.T) {
	s := newTestService(t)
	ctx := context.Background()
	pc := mustCreate(t, s, NewEntity{Name: "Физический ПК", Type: "computer"})
	ubuntu := mustCreate(t, s, NewEntity{Name: "Ubuntu", Type: "virtual_object", ParentID: &pc.ID})
	windows := mustCreate(t, s, NewEntity{Name: "Windows", Type: "virtual_object", ParentID: &pc.ID})
	if *ubuntu.ParentID != pc.ID || *windows.ParentID != pc.ID {
		t.Fatal("parent not stored")
	}
	parent := &ubuntu.ID
	if _, err := s.Update(ctx, pc.ID, EntityPatch{Revision: 1, ParentID: &parent}); conflict(t, err).Reason != "cycle" {
		t.Fatal("parent cycle accepted")
	}
	self := &pc.ID
	if _, err := s.Update(ctx, pc.ID, EntityPatch{Revision: 1, ParentID: &self}); fields(t, err)["parentId"] == "" {
		t.Fatal("self parent accepted")
	}
	if _, err := s.Archive(ctx, pc.ID, 1); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Create(ctx, NewEntity{Name: "x", Type: "service", ParentID: &pc.ID}); fields(t, err)["parentId"] == "" {
		t.Fatal("archived parent accepted for new child")
	}
	if _, err := s.AddRelation(ctx, ubuntu.ID, "connected_to", pc.ID, ""); conflict(t, err).Reason != "archived" {
		t.Fatal("relation to archived entity accepted")
	}
}

func TestPersistsAcrossReopen(t *testing.T) {
	ctx := context.Background()
	path := filepath.Join(t.TempDir(), "reg.db")
	db := openDB(t, path)
	s := NewService(db, DefaultCatalog(), nil)
	a := mustCreate(t, s, NewEntity{Name: "Бот", Type: "telegram_bot", Tags: []string{"pico"}})
	b := mustCreate(t, s, NewEntity{Name: "Сервер", Type: "server"})
	if _, err := s.AddRelation(ctx, a.ID, "runs_on", b.ID, ""); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Archive(ctx, b.ID, 1); err != nil {
		t.Fatal(err)
	}
	db.Close()

	db2 := openDB(t, path)
	defer db2.Close()
	s2 := NewService(db2, DefaultCatalog(), nil)
	got, err := s2.Get(ctx, a.ID)
	if err != nil || got.Name != "Бот" || !equal(got.Tags, []string{"pico"}) || len(got.Capabilities) != 3 {
		t.Fatalf("entity after reopen: %v %+v", err, got)
	}
	if arch, _ := s2.Get(ctx, b.ID); !arch.Archived {
		t.Fatal("archive flag lost")
	}
	rels, _ := s2.Relations(ctx, a.ID)
	if len(rels) != 1 || rels[0].Kind != "runs_on" || !rels[0].Peer.Archived {
		t.Fatalf("relations after reopen: %+v", rels)
	}
}

func TestMigrationIsIdempotent(t *testing.T) {
	path := filepath.Join(t.TempDir(), "reg.db")
	db := openDB(t, path)
	defer db.Close()
	n, err := storage.Migrate(context.Background(), db, Name, migrations)
	if err != nil || n != 0 {
		t.Fatalf("re-run: n=%d err=%v", n, err)
	}
}

func equal(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}
