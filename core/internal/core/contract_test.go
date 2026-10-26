package core

import (
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"

	"gopkg.in/yaml.v3"
)

// openAPIPath points at the versioned contract in the repository root.
var openAPIPath = filepath.Join("..", "..", "..", "contracts", "openapi.yaml")

type openAPIDoc struct {
	Info struct {
		Version string `yaml:"version"`
	} `yaml:"info"`
	Paths map[string]map[string]struct {
		Security *[]map[string][]string `yaml:"security"`
		XStatus  string                 `yaml:"x-aer-status"`
	} `yaml:"paths"`
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

// TestImplementedRoutesMatchContract keeps the router and contracts/openapi.yaml in sync:
// every route served must be documented with the same auth requirement, and every
// operation the contract marks "implemented" must be served.
func TestImplementedRoutesMatchContract(t *testing.T) {
	doc := loadOpenAPI(t)
	c := newCore(t, testConfig(t, t.TempDir()))

	served := map[string]bool{}
	for _, r := range c.Routes() {
		key := strings.ToLower(r.Method) + " " + r.Path
		served[key] = true
		op, ok := doc.Paths[r.Path][strings.ToLower(r.Method)]
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
	for path, ops := range doc.Paths {
		for method, op := range ops {
			key := method + " " + path
			if op.XStatus == "implemented" && !served[key] {
				missing = append(missing, key)
			}
		}
	}
	sort.Strings(missing)
	if len(missing) > 0 {
		t.Errorf("contract marks as implemented but router does not serve: %v", missing)
	}
}

func TestContractVersion(t *testing.T) {
	if v := loadOpenAPI(t).Info.Version; !strings.HasPrefix(v, "0.2.") {
		t.Fatalf("openapi info.version = %q; bump deliberately with an ADR", v)
	}
}
