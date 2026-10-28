package core

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"aerhome/core/internal/foundation/config"
	"aerhome/core/internal/modules"
	"aerhome/core/internal/testenv"
)

// TestBotsContract checks Bots payloads against the contract, the split of
// owner and bot credentials, confirmations and idempotency over HTTP.
func TestBotsContract(t *testing.T) {
	doc := loadOpenAPI(t)
	cfg := testConfig(t, t.TempDir())
	// TEST DATA: an isolated test process, the only controller of this Core.
	cfg.Bots.Controllers = []config.BotController{{ID: "testproc", Kind: "process",
		Command: []string{testenv.Shell(t), "-c", "while true; do sleep 0.1; done"}, StopTimeoutSec: 2, Allow: []string{"start", "stop", "restart"}}}
	c := newCore(t, cfg, modules.All()...)
	srv := httptest.NewServer(c.Handler())
	defer srv.Close()
	owner := readToken(t, cfg)

	do := func(method, path, token, body string, hdr ...string) (int, map[string]json.RawMessage) {
		t.Helper()
		var rd io.Reader
		if body != "" {
			rd = strings.NewReader(body)
		}
		req, _ := http.NewRequest(method, srv.URL+"/api/v1"+path, rd)
		req.Header.Set("Authorization", "Bearer "+token)
		for i := 0; i+1 < len(hdr); i += 2 {
			req.Header.Set(hdr[i], hdr[i+1])
		}
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
			checkShape(t, doc, "Error", env["error"])
		}
		return res.StatusCode, env
	}
	call := func(method, path, token, body string, hdr ...string) json.RawMessage {
		t.Helper()
		code, env := do(method, path, token, body, hdr...)
		if code >= 300 {
			t.Fatalf("%s %s: %d %s", method, path, code, env["error"])
		}
		return env["data"]
	}
	each := func(name string, raw json.RawMessage) []json.RawMessage {
		t.Helper()
		var items []json.RawMessage
		if err := json.Unmarshal(raw, &items); err != nil {
			t.Fatalf("%s: %s", name, raw)
		}
		for _, it := range items {
			checkShape(t, doc, name, it)
		}
		return items
	}

	each("BotAdapter", call("GET", "/bots/adapters", owner, ""))
	created := call("POST", "/bots", owner, `{"name":"Тестовый бот","type":"process","controllerId":"testproc","createCredential":true,"tags":["test"]}`)
	checkShape(t, doc, "CreatedBot", created)
	var cb struct {
		Bot            json.RawMessage
		HeartbeatToken string
	}
	_ = json.Unmarshal(created, &cb)
	checkShape(t, doc, "BotDetail", cb.Bot)
	var b struct{ EntityID string }
	_ = json.Unmarshal(cb.Bot, &b)
	id := b.EntityID

	// Separation of credentials.
	jobs := `{"jobs":[{"id":"j1","name":"Рассылка","status":"success","startedAt":"` + time.Now().UTC().Add(-time.Minute).Format(time.RFC3339) +
		`","finishedAt":"` + time.Now().UTC().Format(time.RFC3339) + `"}]}`
	if code, _ := do("POST", "/bots/agent/jobs", owner, jobs); code != http.StatusUnauthorized {
		t.Fatalf("owner token on the bot route: %d", code)
	}
	if code, _ := do("GET", "/bots", cb.HeartbeatToken, ""); code != http.StatusUnauthorized {
		t.Fatalf("bot token on an owner route: %d", code)
	}
	call("POST", "/bots/agent/jobs", cb.HeartbeatToken, jobs)
	var host struct{ ID string }
	_ = json.Unmarshal(call("POST", "/registry/entities", owner, `{"name":"Сервер (тест)","type":"server"}`), &host)
	var ha struct{ Token string }
	_ = json.Unmarshal(call("POST", "/monitoring/agents", owner, `{"entityId":"`+host.ID+`","name":"host","kind":"host"}`), &ha)
	if code, _ := do("POST", "/bots/agent/jobs", ha.Token, jobs); code != http.StatusForbidden {
		t.Fatalf("host agent reporting bot jobs: %d", code)
	}

	each("Bot", call("GET", "/bots?q=тест", owner, ""))
	checkShape(t, doc, "BotDetail", call("GET", "/bots/"+id, owner, ""))
	checkShape(t, doc, "BotDetail", call("PATCH", "/bots/"+id, owner, `{"revision":1,"category":"тест","hostId":"`+host.ID+`"}`))
	if code, env := do("PATCH", "/bots/"+id, owner, `{"revision":1}`); code != http.StatusConflict {
		t.Fatalf("stale revision: %d %s", code, env["error"])
	}
	jp := call("GET", "/bots/"+id+"/jobs", owner, "")
	checkShape(t, doc, "BotJobPage", jp)
	var page struct{ Items []json.RawMessage }
	_ = json.Unmarshal(jp, &page)
	for _, j := range page.Items {
		checkShape(t, doc, "BotJob", j)
	}
	checkShape(t, doc, "LogPage", call("GET", "/bots/"+id+"/logs", owner, ""))
	each("MonitoringEvent", call("GET", "/bots/"+id+"/activity", owner, ""))
	each("BotAction", call("GET", "/bots/"+id+"/actions", owner, ""))

	if code, _ := do("POST", "/bots/"+id+"/actions/start", owner, `{}`); code != http.StatusUnprocessableEntity {
		t.Fatalf("missing Idempotency-Key: %d", code)
	}
	if code, _ := do("POST", "/bots/"+id+"/actions/start", owner, `{}`, "Idempotency-Key", "contract-0"); code != http.StatusForbidden {
		t.Fatalf("no confirmation: %d", code)
	}
	conf := call("POST", "/bots/"+id+"/actions/start/confirm", owner, `{}`)
	checkShape(t, doc, "BotConfirmation", conf)
	var cf struct{ Token string }
	_ = json.Unmarshal(conf, &cf)
	rec := call("POST", "/bots/"+id+"/actions/start", owner, `{"confirmationToken":"`+cf.Token+`"}`, "Idempotency-Key", "contract-1")
	checkShape(t, doc, "BotActionRecord", rec)
	again := call("POST", "/bots/"+id+"/actions/start", owner, `{}`, "Idempotency-Key", "contract-1")
	var r1, r2 struct {
		ID       string
		Status   string
		Replayed bool
	}
	_ = json.Unmarshal(rec, &r1)
	_ = json.Unmarshal(again, &r2)
	if r1.Status != "succeeded" || !r2.Replayed || r1.ID != r2.ID {
		t.Fatalf("idempotent replay: %s / %s", rec, again)
	}
	_ = json.Unmarshal(call("POST", "/bots/"+id+"/actions/stop/confirm", owner, `{}`), &cf)
	call("POST", "/bots/"+id+"/actions/stop", owner, `{"confirmationToken":"`+cf.Token+`"}`, "Idempotency-Key", "contract-2")
	if len(each("BotActionRecord", call("GET", "/bots/"+id+"/audit", owner, ""))) != 3 {
		t.Fatal("audit must hold the refused, the started and the stopped request")
	}
	checkShape(t, doc, "CreatedAgent", call("POST", "/bots/"+id+"/credentials", owner, ""))
	checkShape(t, doc, "BotDetail", call("POST", "/bots/"+id+"/archive", owner, ""))
	checkShape(t, doc, "BotDetail", call("POST", "/bots/"+id+"/restore", owner, ""))
	if code, _ := do("POST", "/bots", owner, `{"name":"","type":"server"}`); code != 422 {
		t.Fatalf("validation: %d", code)
	}
	if code, _ := do("GET", "/bots/"+host.ID, owner, ""); code != 404 {
		t.Fatalf("non-bot entity: %d", code)
	}
}
