package scene

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"aerhome/core/internal/foundation/httpapi"
	"aerhome/core/internal/foundation/storage"
)

// The demo scene shipped in examples/ is the reference document for both
// Core and the desktop codec.
var examplePath = filepath.Join("..", "..", "..", "..", "examples", "home.scene.json")

func example(t *testing.T) []byte {
	t.Helper()
	raw, err := os.ReadFile(examplePath)
	if err != nil {
		t.Fatal(err)
	}
	return raw
}

// mutate decodes the example into a generic map, applies fn and re-encodes.
func mutate(t *testing.T, fn func(doc map[string]any)) []byte {
	t.Helper()
	var doc map[string]any
	if err := json.Unmarshal(example(t), &doc); err != nil {
		t.Fatal(err)
	}
	fn(doc)
	b, _ := json.Marshal(doc)
	return b
}

func obj(doc map[string]any, i int) map[string]any {
	return doc["objects"].([]any)[i].(map[string]any)
}

func issues(t *testing.T, err error) Issues {
	t.Helper()
	var ve *ValidationError
	if !errors.As(err, &ve) {
		t.Fatalf("want ValidationError, got %v", err)
	}
	return ve.Issues
}

func TestExampleSceneIsValid(t *testing.T) {
	doc, err := Decode(example(t))
	if err != nil {
		t.Fatalf("examples/home.scene.json must be valid: %v", err)
	}
	if len(doc.Rooms) != 5 || len(doc.Objects) < 30 || !doc.Demo {
		t.Fatalf("unexpected example: %d rooms, %d objects", len(doc.Rooms), len(doc.Objects))
	}
	kinds := map[string]bool{}
	for _, r := range doc.Rooms {
		kinds[r.Kind] = true
	}
	for _, k := range []string{"office", "server", "living", "network", "automation"} {
		if !kinds[k] {
			t.Errorf("room kind %s missing", k)
		}
	}
}

func TestCanonicalRoundTrip(t *testing.T) {
	doc, err := Decode(example(t))
	if err != nil {
		t.Fatal(err)
	}
	again, err := Decode(doc.Canonical())
	if err != nil {
		t.Fatalf("canonical form must stay valid: %v", err)
	}
	if string(again.Canonical()) != string(doc.Canonical()) {
		t.Fatal("canonical encoding is not stable")
	}
}

func TestValidationRules(t *testing.T) {
	cases := map[string]struct {
		fn   func(map[string]any)
		path string
	}{
		"future version":    {func(d map[string]any) { d["schemaVersion"] = 2 }, "schemaVersion"},
		"zero version":      {func(d map[string]any) { d["schemaVersion"] = 0 }, "schemaVersion"},
		"scene id not uuid": {func(d map[string]any) { d["sceneId"] = "home-1" }, "sceneId"},
		"empty name":        {func(d map[string]any) { d["name"] = "" }, "name"},
		"projection":        {func(d map[string]any) { d["projection"] = "top-down" }, "projection"},
		"room id not uuid":  {func(d map[string]any) { d["rooms"].([]any)[0].(map[string]any)["id"] = "room-office" }, "rooms[0].id"},
		"room overlap": {func(d map[string]any) {
			d["rooms"].([]any)[1].(map[string]any)["origin"] = map[string]any{"x": 5, "y": 0}
		}, "rooms[1]"},
		"room size": {func(d map[string]any) {
			d["rooms"].([]any)[0].(map[string]any)["size"] = map[string]any{"w": 0, "d": 4}
		}, "rooms[0].size.w"},
		"unknown floor": {func(d map[string]any) {
			d["rooms"].([]any)[0].(map[string]any)["style"] = map[string]any{"floor": "lava", "wall": "cream"}
		}, "rooms[0].style.floor"},
		"object id not uuid":  {func(d map[string]any) { obj(d, 0)["id"] = "visual-pc" }, "objects[0].id"},
		"duplicate object id": {func(d map[string]any) { obj(d, 1)["id"] = obj(d, 0)["id"] }, "objects[1].id"},
		"unknown room":        {func(d map[string]any) { obj(d, 0)["roomId"] = "00000000-0000-4000-8000-000000000000" }, "objects[0].roomId"},
		"unknown asset":       {func(d map[string]any) { obj(d, 0)["assetId"] = "cozy/piano" }, "objects[0].assetId"},
		"rotation":            {func(d map[string]any) { obj(d, 0)["rotation"] = 45 }, "objects[0].rotation"},
		"scale":               {func(d map[string]any) { obj(d, 0)["scale"] = 10 }, "objects[0].scale"},
		"negative x":          {func(d map[string]any) { obj(d, 0)["position"] = map[string]any{"x": -1, "y": 0, "z": 0} }, "objects[0].position.x"},
		"outside room":        {func(d map[string]any) { obj(d, 0)["position"] = map[string]any{"x": 9.5, "y": 0, "z": 0} }, "objects[0].position"},
		"layer":               {func(d map[string]any) { obj(d, 0)["layer"] = "sky" }, "objects[0].layer"},
		"binding not uuid": {func(d map[string]any) {
			obj(d, 0)["entityBinding"] = map[string]any{"entityId": "pc", "role": "primary"}
		}, "objects[0].entityBinding.entityId"},
		"binding role": {func(d map[string]any) {
			obj(d, 0)["entityBinding"] = map[string]any{"entityId": "00000000-0000-4000-8000-000000000001", "role": "owner"}
		}, "objects[0].entityBinding.role"},
		"demo state + binding": {func(d map[string]any) {
			o := obj(d, 4)
			o["entityBinding"] = map[string]any{"entityId": "00000000-0000-4000-8000-000000000001", "role": "primary"}
		}, "objects[4].visualState"},
		"demo state, real home": {func(d map[string]any) { d["demo"] = false }, "objects[4].visualState"},
		"unknown demo state":    {func(d map[string]any) { obj(d, 4)["visualState"] = map[string]any{"demo": "fine"} }, "objects[4].visualState.demo"},
		"bad asset id":          {func(d map[string]any) { d["assets"].([]any)[0].(map[string]any)["id"] = "Cozy Desk" }, "assets[0].id"},
		"asset height":          {func(d map[string]any) { d["assets"].([]any)[0].(map[string]any)["height"] = 0 }, "assets[0].height"},
		"no rooms":              {func(d map[string]any) { d["rooms"] = []any{}; d["objects"] = []any{} }, "rooms"},
	}
	for name, tc := range cases {
		t.Run(name, func(t *testing.T) {
			_, err := Decode(mutate(t, tc.fn))
			got := issues(t, err)
			if got[tc.path] == "" {
				t.Fatalf("want issue at %q, got %v", tc.path, got)
			}
		})
	}
}

func TestRejectsCorruptAndUnknownFields(t *testing.T) {
	for name, raw := range map[string]string{
		"truncated":       string(example(t)[:200]),
		"not an object":   `[1,2,3]`,
		"metrics leaked":  string(mutate(t, func(d map[string]any) { obj(d, 0)["cpuLoad"] = 0.9 })),
		"top-level extra": string(mutate(t, func(d map[string]any) { d["token"] = "x" })),
	} {
		t.Run(name, func(t *testing.T) {
			if _, err := Decode([]byte(raw)); err == nil {
				t.Fatal("expected rejection")
			} else {
				issues(t, err)
			}
		})
	}
}

func TestRotatedFootprint(t *testing.T) {
	a := Asset{Footprint: Size2{W: 2, D: 1}}
	o := Object{Rotation: 90, Scale: 1.5}
	if fp := o.Footprint(a); fp.W != 1.5 || fp.D != 3 {
		t.Fatalf("footprint = %+v", fp)
	}
}

func newService(t *testing.T, path string) *Service {
	t.Helper()
	db, err := storage.Open(context.Background(), path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { db.Close() })
	if _, err := storage.Migrate(context.Background(), db, Name, migrations); err != nil {
		t.Fatal(err)
	}
	return NewService(db, nil)
}

func TestServiceLifecycle(t *testing.T) {
	ctx := context.Background()
	path := filepath.Join(t.TempDir(), "scene.db")
	s := newService(t, path)

	rec, err := s.Create(ctx, example(t))
	if err != nil {
		t.Fatal(err)
	}
	if rec.Revision != 1 || !rec.Demo || rec.Name == "" {
		t.Fatalf("created = %+v", rec.Summary)
	}
	if _, err := s.Create(ctx, example(t)); err == nil {
		t.Fatal("duplicate sceneId accepted")
	}

	renamed := mutate(t, func(d map[string]any) { d["name"] = "Наш дом" })
	rec2, err := s.Replace(ctx, rec.ID, 1, renamed)
	if err != nil || rec2.Revision != 2 || rec2.Name != "Наш дом" {
		t.Fatalf("replace: %v %+v", err, rec2.Summary)
	}

	_, err = s.Replace(ctx, rec.ID, 1, renamed)
	var ce *ConflictError
	if !errors.As(err, &ce) || ce.Reason != "revision_mismatch" || ce.CurrentRevision != 2 {
		t.Fatalf("stale replace: %v", err)
	}

	// A broken document must not touch the stored one.
	broken := mutate(t, func(d map[string]any) { obj(d, 0)["rotation"] = 33 })
	if _, err := s.Replace(ctx, rec.ID, 2, broken); err == nil {
		t.Fatal("invalid document accepted")
	}
	got, _ := s.Get(ctx, rec.ID)
	if got.Revision != 2 || got.Name != "Наш дом" {
		t.Fatalf("stored scene changed by failed save: %+v", got.Summary)
	}
	if _, err := s.Replace(ctx, rec.ID, 2, mutate(t, func(d map[string]any) {
		d["sceneId"] = "00000000-0000-4000-8000-000000000009"
	})); err == nil {
		t.Fatal("sceneId mismatch accepted")
	}

	list, err := s.List(ctx)
	if err != nil || len(list) != 1 || list[0].Revision != 2 {
		t.Fatalf("list: %v %+v", err, list)
	}
	hist, _ := s.HistoryRevisions(ctx, rec.ID)
	if len(hist) != 1 || hist[0] != 1 {
		t.Fatalf("history = %v", hist)
	}

	// Persistence across reopen.
	s2 := newService(t, path)
	again, err := s2.Get(ctx, rec.ID)
	if err != nil || again.Revision != 2 {
		t.Fatalf("after reopen: %v %+v", err, again.Summary)
	}
	if _, err := Decode(again.Document); err != nil {
		t.Fatalf("stored document no longer valid: %v", err)
	}
	if _, err := s2.Get(ctx, "00000000-0000-4000-8000-000000000000"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("missing scene: %v", err)
	}
}

func TestHistoryIsBounded(t *testing.T) {
	ctx := context.Background()
	s := newService(t, filepath.Join(t.TempDir(), "scene.db"))
	rec, err := s.Create(ctx, example(t))
	if err != nil {
		t.Fatal(err)
	}
	for rev := 1; rev <= historyDepth+5; rev++ {
		if _, err := s.Replace(ctx, rec.ID, rev, example(t)); err != nil {
			t.Fatalf("rev %d: %v", rev, err)
		}
	}
	hist, _ := s.HistoryRevisions(ctx, rec.ID)
	if len(hist) != historyDepth {
		t.Fatalf("history kept %d revisions, want %d", len(hist), historyDepth)
	}
}

func TestHTTP(t *testing.T) {
	s := newService(t, filepath.Join(t.TempDir(), "scene.db"))
	rt := httpapi.NewRouter(slog.New(slog.NewTextHandler(io.Discard, nil)), func(string) bool { return true })
	(&Module{svc: s}).RegisterRoutes(rt)
	srv := httptest.NewServer(rt)
	defer srv.Close()

	do := func(method, path, body string) (int, map[string]json.RawMessage) {
		req, _ := http.NewRequest(method, srv.URL+"/api/v1"+path, strings.NewReader(body))
		req.Header.Set("Authorization", "Bearer x")
		res, err := srv.Client().Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer res.Body.Close()
		var env map[string]json.RawMessage
		_ = json.NewDecoder(res.Body).Decode(&env)
		return res.StatusCode, env
	}

	code, env := do("GET", "/scenes", "")
	if code != 200 || string(env["data"]) != "[]" {
		t.Fatalf("empty list: %d %s", code, env["data"])
	}
	code, env = do("POST", "/scenes", string(example(t)))
	if code != 201 {
		t.Fatalf("create: %d %s", code, env["error"])
	}
	var rec Record
	_ = json.Unmarshal(env["data"], &rec)

	code, env = do("POST", "/scenes", string(mutate(t, func(d map[string]any) { obj(d, 0)["rotation"] = 1 })))
	if code != 422 || !strings.Contains(string(env["error"]), "objects[0].rotation") {
		t.Fatalf("invalid create: %d %s", code, env["error"])
	}
	code, _ = do("GET", "/scenes/"+rec.ID, "")
	if code != 200 {
		t.Fatalf("get: %d", code)
	}
	body, _ := json.Marshal(map[string]any{"revision": 1, "document": json.RawMessage(example(t))})
	if code, env = do("PUT", "/scenes/"+rec.ID, string(body)); code != 200 {
		t.Fatalf("put: %d %s", code, env["error"])
	}
	if code, env = do("PUT", "/scenes/"+rec.ID, string(body)); code != 409 || !strings.Contains(string(env["error"]), "revision_mismatch") {
		t.Fatalf("stale put: %d %s", code, env["error"])
	}
	if code, _ = do("GET", "/scenes/not-a-uuid", ""); code != 404 {
		t.Fatalf("bad id: %d", code)
	}
}
