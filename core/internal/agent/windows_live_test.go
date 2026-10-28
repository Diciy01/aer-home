//go:build windows

package agent_test

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
	"time"

	"aerhome/core/internal/agent"
	"aerhome/core/internal/core"
	"aerhome/core/internal/foundation/config"
	"aerhome/core/internal/modules"
)

// Real Windows collectors -> real agent loop -> isolated real Core. No
// system logs, installed services, existing Core or external devices touched.
func TestWindowsLiveCollectorsAgainstCore(t *testing.T) {
	ctx, cancelCore := context.WithCancel(context.Background())
	defer cancelCore()
	cfg := config.Default(func(string) (string, bool) { return "", false })
	cfg.DataDir = t.TempDir()
	cfg.Monitoring.Docker.Enabled = false
	c, err := core.New(ctx, core.Options{Config: cfg, Logger: slog.New(slog.DiscardHandler), Modules: modules.All()})
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	srv := httptest.NewServer(c.Handler())
	defer srv.Close()
	ownerBytes, err := os.ReadFile(cfg.TokenPath())
	if err != nil {
		t.Fatal(err)
	}
	owner := strings.TrimSpace(string(ownerBytes))
	call := func(method, path string, body any, out any) {
		t.Helper()
		raw, _ := json.Marshal(body)
		req, _ := http.NewRequest(method, srv.URL+"/api/v1"+path, bytes.NewReader(raw))
		req.Header.Set("Authorization", "Bearer "+owner)
		req.Header.Set("Content-Type", "application/json")
		res, err := srv.Client().Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer res.Body.Close()
		if res.StatusCode >= 300 {
			t.Fatalf("%s %s: HTTP %d", method, path, res.StatusCode)
		}
		var envelope struct{ Data json.RawMessage }
		if err := json.NewDecoder(res.Body).Decode(&envelope); err != nil {
			t.Fatal(err)
		}
		if out != nil {
			if err := json.Unmarshal(envelope.Data, out); err != nil {
				t.Fatal(err)
			}
		}
	}
	var entity struct{ ID string }
	call("POST", "/registry/entities", map[string]string{"name": "Windows live test", "type": "computer"}, &entity)
	var identity struct {
		Token string
		Agent struct{ ID string }
	}
	call("POST", "/monitoring/agents", map[string]string{"entityId": entity.ID, "name": "Windows test agent", "kind": "host"}, &identity)
	tokenPath := filepath.Join(t.TempDir(), "agent.token")
	if err := os.WriteFile(tokenPath, []byte(identity.Token), 0600); err != nil {
		t.Fatal(err)
	}
	ac := agent.DefaultConfig()
	ac.CoreURL, ac.TokenFile, ac.IntervalSec = srv.URL, tokenPath, 5
	ac.Collectors.SystemLogs = false
	ac.Collectors.Services = []string{"Spooler"}
	var logs bytes.Buffer
	a := agent.New(ac, agent.PlatformSources(ac.Collectors), agent.PlatformInfo(nil), slog.New(slog.NewTextHandler(&logs, nil)))
	agentCtx, stop := context.WithCancel(ctx)
	defer stop()
	done := make(chan error, 1)
	go func() { done <- a.Run(agentCtx) }()
	var state struct {
		Status        string
		LastContactAt *time.Time
		KeyMetrics    []struct {
			Metric, Label, Quality string
			Value                  *float64
		}
	}
	deadline := time.Now().Add(20 * time.Second)
	for {
		call("GET", "/monitoring/states/"+entity.ID, nil, &state)
		metrics := map[string]bool{}
		for _, m := range state.KeyMetrics {
			if m.Quality == "ok" && m.Value != nil {
				metrics[m.Metric] = true
			}
		}
		if state.Status == "online" && state.LastContactAt != nil && metrics["cpu.usage"] && metrics["mem.used_percent"] && metrics["disk.used_percent"] {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("real Windows heartbeat/CPU/RAM/disks did not reach Core")
		}
		time.Sleep(100 * time.Millisecond)
	}
	var drives []string
	for _, m := range state.KeyMetrics {
		if m.Metric == "disk.used_percent" {
			drives = append(drives, m.Label)
		}
	}
	sort.Strings(drives)
	t.Logf("real Windows heartbeat, CPU, RAM, disks %v reached isolated Core", drives)
	stop()
	select {
	case err := <-done:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("agent did not stop after cancellation")
	}
	if strings.Contains(logs.String(), identity.Token) || strings.Contains(logs.String(), owner) {
		t.Fatal("credential leaked in agent logs")
	}
	call("POST", "/monitoring/agents/"+identity.Agent.ID+"/revoke", map[string]any{}, nil)
	// Verify revocation with the same identity without logging its value.
	req, _ := http.NewRequest("POST", srv.URL+"/api/v1/monitoring/agent/report", strings.NewReader(`{"agent":{"os":"windows"}}`))
	req.Header.Set("Authorization", "Bearer "+identity.Token)
	res, err := srv.Client().Do(req)
	if err != nil {
		t.Fatal(err)
	}
	io.Copy(io.Discard, res.Body)
	res.Body.Close()
	if res.StatusCode != 401 {
		t.Fatalf("revoked credential: HTTP %d", res.StatusCode)
	}
}
