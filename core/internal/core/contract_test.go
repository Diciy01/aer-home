package core

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"

	"gopkg.in/yaml.v3"

	"aerhome/core/internal/modules"
)

// openAPIPath points at the versioned contract in the repository root.
var openAPIPath = filepath.Join("..", "..", "..", "contracts", "openapi.yaml")

var httpMethods = map[string]bool{"get": true, "post": true, "put": true, "patch": true, "delete": true}

type operation struct {
	Security *[]map[string][]string `yaml:"security"`
	XStatus  string                 `yaml:"x-aer-status"`
}

type schema struct {
	Required   []string             `yaml:"required"`
	Properties map[string]yaml.Node `yaml:"properties"`
}

type openAPIDoc struct {
	Info struct {
		Version string `yaml:"version"`
	} `yaml:"info"`
	Paths      map[string]map[string]yaml.Node `yaml:"paths"`
	Components struct {
		Schemas map[string]schema `yaml:"schemas"`
	} `yaml:"components"`
}

func loadOpenAPI(t *testing.T) openAPIDoc {
	t.Helper()
	raw, err := os.ReadFile(openAPIPath)
	if err != nil {
		t.Fatalf("read contract: %v", err)
	}
	var doc openAPIDoc
	if err := yaml.Unmarshal(raw, &doc); err != nil {
		t.Fatalf("parse contract: %v", err)
	}
	return doc
}

// operations returns "method path" → operation, skipping path-level keys like parameters.
func (d openAPIDoc) operations(t *testing.T) map[string]operation {
	t.Helper()
	out := map[string]operation{}
	for path, item := range d.Paths {
		for method, node := range item {
			if !httpMethods[method] {
				continue
			}
			var op operation
			if err := node.Decode(&op); err != nil {
				t.Fatalf("%s %s: %v", method, path, err)
			}
			out[method+" "+path] = op
		}
	}
	return out
}

// TestImplementedRoutesMatchContract keeps the router and contracts/openapi.yaml in sync:
// every route served must be documented with the same auth requirement, and every
// operation the contract marks "implemented" must be served.
func TestImplementedRoutesMatchContract(t *testing.T) {
	ops := loadOpenAPI(t).operations(t)
	c := newCore(t, testConfig(t, t.TempDir()), modules.All()...)

	served := map[string]bool{}
	for _, r := range c.Routes() {
		key := strings.ToLower(r.Method) + " " + r.Path
		served[key] = true
		op, ok := ops[key]
		if !ok {
			t.Errorf("%s is served but missing from openapi.yaml", key)
			continue
		}
		public := op.Security != nil && len(*op.Security) == 0
		if public != r.Public {
			t.Errorf("%s: contract public=%v, router public=%v", key, public, r.Public)
		}
		if op.XStatus != "implemented" {
			t.Errorf("%s: served but x-aer-status=%q", key, op.XStatus)
		}
	}

	var missing []string
	for key, op := range ops {
		if op.XStatus == "implemented" && !served[key] {
			missing = append(missing, key)
		}
	}
	sort.Strings(missing)
	if len(missing) > 0 {
		t.Errorf("contract marks as implemented but router does not serve: %v", missing)
	}
}

func TestContractVersion(t *testing.T) {
	if v := loadOpenAPI(t).Info.Version; !strings.HasPrefix(v, "0.3.") {
		t.Fatalf("openapi info.version = %q; bump deliberately with an ADR", v)
	}
}

// checkShape verifies a JSON object against a named schema: all required keys
// present and no keys outside the declared properties.
func checkShape(t *testing.T, doc openAPIDoc, name string, raw json.RawMessage) {
	t.Helper()
	s, ok := doc.Components.Schemas[name]
	if !ok {
		t.Fatalf("schema %s missing", name)
	}
	var obj map[string]json.RawMessage
	if err := json.Unmarshal(raw, &obj); err != nil {
		t.Fatalf("%s: not an object: %s", name, raw)
	}
	for _, req := range s.Required {
		if _, ok := obj[req]; !ok {
			t.Errorf("%s: required key %q missing in %s", name, req, raw)
		}
	}
	for key := range obj {
		if _, ok := s.Properties[key]; !ok {
			t.Errorf("%s: key %q not declared in contract", name, key)
		}
	}
}

// TestResponsesMatchContractSchemas exercises the real server and checks every
// implemented payload shape against contracts/openapi.yaml.
func TestResponsesMatchContractSchemas(t *testing.T) {
	doc := loadOpenAPI(t)
	cfg := testConfig(t, t.TempDir())
	c := newCore(t, cfg, modules.All()...)
	srv := httptest.NewServer(c.Handler())
	defer srv.Close()
	token := readToken(t, cfg)

	call := func(method, path, body string) json.RawMessage {
		t.Helper()
		var rd io.Reader
		if body != "" {
			rd = strings.NewReader(body)
		}
		req, _ := http.NewRequest(method, srv.URL+"/api/v1"+path, rd)
		req.Header.Set("Authorization", "Bearer "+token)
		res, err := srv.Client().Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer res.Body.Close()
		var env map[string]json.RawMessage
		if err := json.NewDecoder(res.Body).Decode(&env); err != nil {
			t.Fatal(err)
		}
		if res.StatusCode >= 300 {
			checkShape(t, doc, "ErrorEnvelope", mustJSON(env))
			checkShape(t, doc, "Error", env["error"])
			return env["error"]
		}
		checkShape(t, doc, "SuccessEnvelope", mustJSON(env))
		checkShape(t, doc, "Meta", env["meta"])
		return env["data"]
	}
	each := func(name string, raw json.RawMessage) {
		t.Helper()
		var items []json.RawMessage
		if err := json.Unmarshal(raw, &items); err != nil || len(items) == 0 {
			t.Fatalf("%s: want non-empty array, got %s", name, raw)
		}
		for _, it := range items {
			checkShape(t, doc, name, it)
		}
	}

	checkShape(t, doc, "Health", call("GET", "/health", ""))
	checkShape(t, doc, "SystemInfo", call("GET", "/system/info", ""))
	each("EntityType", call("GET", "/registry/types", ""))
	each("Capability", call("GET", "/registry/capabilities", ""))
	each("RelationKind", call("GET", "/registry/relation-kinds", ""))

	// TEST DATA
	host := call("POST", "/registry/entities", `{"name":"Сервер (тест)","type":"server",
		"secretRefs":[{"name":"ssh","ref":"keyring:aer/test"}],"attributes":{"os":"linux"}}`)
	checkShape(t, doc, "RegistryEntity", host)
	var hostE struct{ ID string }
	_ = json.Unmarshal(host, &hostE)
	bot := call("POST", "/registry/entities", `{"name":"Бот (тест)","type":"telegram_bot"}`)
	var botE struct{ ID string }
	_ = json.Unmarshal(bot, &botE)

	page := call("GET", "/registry/entities?limit=10", "")
	checkShape(t, doc, "RegistryEntityPage", page)
	checkShape(t, doc, "RegistryEntity", call("PATCH", "/registry/entities/"+hostE.ID, `{"revision":1,"tags":["home"]}`))
	checkShape(t, doc, "RegistryEntity", call("PUT", "/registry/entities/"+hostE.ID+"/capabilities", `{"revision":2,"capabilities":[]}`))
	checkShape(t, doc, "Relation", call("POST", "/registry/entities/"+botE.ID+"/relations", `{"kind":"runs_on","targetId":"`+hostE.ID+`"}`))
	each("RelationView", call("GET", "/registry/entities/"+botE.ID+"/relations", ""))
	checkShape(t, doc, "RegistryEntity", call("POST", "/registry/entities/"+hostE.ID+"/archive", `{"revision":3}`))
	checkShape(t, doc, "RegistryEntity", call("POST", "/registry/entities/"+hostE.ID+"/restore", `{"revision":4}`))
	call("PATCH", "/registry/entities/"+hostE.ID, `{"revision":1}`) // error envelope shape
}

func mustJSON(v any) json.RawMessage {
	b, _ := json.Marshal(v)
	return b
}
