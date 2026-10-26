package core

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	"aerhome/core/internal/foundation/config"
	"aerhome/core/internal/foundation/httpapi"
	"aerhome/core/internal/foundation/module"
	"aerhome/core/internal/foundation/storage"
)

// fakeModule is a TEST-ONLY module used to exercise the module lifecycle.
type fakeModule struct{ name string }

func (f fakeModule) Name() string { return f.name }
func (f fakeModule) Migrations() []storage.Migration {
	return []storage.Migration{{Version: 1, Name: "create_fake", SQL: `CREATE TABLE ` + f.name + `_items (id INTEGER)`}}
}
func (f fakeModule) RegisterRoutes(r *httpapi.Router) {
	r.Handle(http.MethodGet, "/"+f.name+"/ping", func(w http.ResponseWriter, r *http.Request) error {
		httpapi.WriteData(w, r, http.StatusOK, "pong")
		return nil
	})
}

func testConfig(t *testing.T, dataDir string) config.Config {
	t.Helper()
	cfg := config.Default(func(string) (string, bool) { return "", false })
	cfg.DataDir = dataDir
	if err := cfg.Validate(); err != nil {
		t.Fatal(err)
	}
	return cfg
}

func newCore(t *testing.T, cfg config.Config, mods ...module.Named) *Core {
	t.Helper()
	c, err := New(context.Background(), Options{
		Config:  cfg,
		Logger:  slog.New(slog.NewTextHandler(io.Discard, nil)),
		Modules: mods,
	})
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	t.Cleanup(func() { c.Close() })
	return c
}

func readToken(t *testing.T, cfg config.Config) string {
	t.Helper()
	raw, err := os.ReadFile(cfg.TokenPath())
	if err != nil {
		t.Fatal(err)
	}
	return strings.TrimSpace(string(raw))
}

func get(t *testing.T, srv *httptest.Server, path, token string, out any) int {
	t.Helper()
	req, _ := http.NewRequest(http.MethodGet, srv.URL+path, nil)
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	res, err := srv.Client().Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	if out != nil {
		if err := json.NewDecoder(res.Body).Decode(out); err != nil {
			t.Fatalf("decode %s: %v", path, err)
		}
	}
	return res.StatusCode
}

func TestHealthIsPublic(t *testing.T) {
	c := newCore(t, testConfig(t, t.TempDir()))
	srv := httptest.NewServer(c.Handler())
	defer srv.Close()

	var env struct{ Data HealthStatus }
	if code := get(t, srv, "/api/v1/health", "", &env); code != 200 {
		t.Fatalf("status %d", code)
	}
	if env.Data.Status != "ok" || env.Data.APIVersion != "v1" || time.Since(env.Data.Timestamp) > time.Minute {
		t.Fatalf("health = %+v", env.Data)
	}
}

func TestSystemInfoRequiresToken(t *testing.T) {
	cfg := testConfig(t, t.TempDir())
	c := newCore(t, cfg)
	srv := httptest.NewServer(c.Handler())
	defer srv.Close()

	if code := get(t, srv, "/api/v1/system/info", "", nil); code != 401 {
		t.Fatalf("without token: %d", code)
	}
	var env struct{ Data SystemInfo }
	if code := get(t, srv, "/api/v1/system/info", readToken(t, cfg), &env); code != 200 {
		t.Fatalf("with token: %d", code)
	}
	if env.Data.Mode != "development" || !env.Data.Demo || env.Data.InstanceID != c.InstanceID() {
		t.Fatalf("info = %+v", env.Data)
	}
	if len(env.Data.Schema) != 1 || env.Data.Schema[0] != (storage.AppliedVersion{Module: "foundation", Version: 1}) {
		t.Fatalf("schema = %+v", env.Data.Schema)
	}
}

func TestStateSurvivesRestart(t *testing.T) {
	cfg := testConfig(t, t.TempDir())
	first := newCore(t, cfg)
	id, token := first.InstanceID(), readToken(t, cfg)
	if !first.TokenCreated() {
		t.Fatal("first start should create the token")
	}
	first.Close()

	second := newCore(t, cfg)
	if second.InstanceID() != id {
		t.Fatalf("instance id changed across restart: %s -> %s", id, second.InstanceID())
	}
	if second.TokenCreated() || readToken(t, cfg) != token {
		t.Fatal("token must be reused across restart")
	}
}

func TestModuleLifecycle(t *testing.T) {
	cfg := testConfig(t, t.TempDir())
	cfg.Modules = map[string]bool{"off": false}
	broken := module.Named{Name: "broken", New: func(module.Deps) (module.Module, error) {
		return nil, errors.New("adapter unreachable")
	}}
	c := newCore(t, cfg,
		module.Named{Name: "fake", New: func(module.Deps) (module.Module, error) { return fakeModule{"fake"}, nil }},
		module.Named{Name: "off", New: func(module.Deps) (module.Module, error) { return fakeModule{"off"}, nil }},
		broken,
	)
	srv := httptest.NewServer(c.Handler())
	defer srv.Close()
	token := readToken(t, cfg)

	if code := get(t, srv, "/api/v1/fake/ping", token, nil); code != 200 {
		t.Fatalf("enabled module route: %d", code)
	}
	if code := get(t, srv, "/api/v1/off/ping", token, nil); code != 404 {
		t.Fatalf("disabled module route should not exist: %d", code)
	}

	var env struct{ Data SystemInfo }
	get(t, srv, "/api/v1/system/info", token, &env)
	want := map[string]module.Status{
		"fake":   {Name: "fake", Enabled: true},
		"off":    {Name: "off", Enabled: false},
		"broken": {Name: "broken", Enabled: true, Error: "adapter unreachable"},
	}
	if len(env.Data.Modules) != len(want) {
		t.Fatalf("modules = %+v", env.Data.Modules)
	}
	for _, m := range env.Data.Modules {
		if want[m.Name] != m {
			t.Fatalf("module %s = %+v, want %+v", m.Name, m, want[m.Name])
		}
	}
	// Health stays ok: one broken module must not take Core down.
	var health struct{ Data HealthStatus }
	get(t, srv, "/api/v1/health", "", &health)
	if health.Data.Status != "ok" {
		t.Fatalf("health = %+v", health.Data)
	}
}
