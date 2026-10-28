package config

import (
	"path/filepath"
	"strings"
	"testing"

	"aerhome/core/internal/testenv"
)

// The shipped examples must stay loadable: they are what owners copy.
func TestDeployExamplesLoad(t *testing.T) {
	testenv.LinuxOnly(t, "deploy/core-*.example.json (Linux server paths)")
	env := func(k string) (string, bool) {
		if k == "HOME" {
			return "/home/example", true // examples may rely on the default data dir
		}
		return "", false
	}
	for _, name := range []string{"core-bots.example.json", "core-monitoring.example.json"} {
		cfg, err := Load(filepath.Join("..", "..", "..", "..", "deploy", name), env)
		if err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		if name == "core-bots.example.json" && (len(cfg.Bots.Controllers) != 3 || len(cfg.Bots.N8N) != 1) {
			t.Errorf("bots example: %+v", cfg.Bots)
		}
	}
}

func TestBotsDefaultsHaveNoControllers(t *testing.T) {
	b := DefaultBots()
	if len(b.Controllers)+len(b.N8N)+len(b.TelegramTokens) != 0 {
		t.Fatal("nothing may be controllable by default")
	}
	if err := b.Validate(); err != nil {
		t.Fatal(err)
	}
	b.Controllers = []BotController{{ID: "a", Kind: "process", Command: []string{testenv.Abs("/bin/true")}, StopTimeoutSec: 1},
		{ID: "a", Kind: "docker", Container: "x"}}
	if err := b.Validate(); err == nil || !strings.Contains(err.Error(), "duplicate") {
		t.Errorf("duplicate ids: %v", err)
	}
}
