package core

import (
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"aerhome/core/internal/foundation/config"
	"aerhome/core/internal/modules"
)

// TestNetworkContract checks /network payloads against the contract with a
// Sunshine stub and loopback targets (TEST DATA; no real device).
func TestNetworkContract(t *testing.T) {
	doc := loadOpenAPI(t)
	sun := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprint(w, `<root status_code="200"><appversion>0.0-test</appversion><currentgame>0</currentgame><state>SUNSHINE_SERVER_FREE</state></root>`)
	}))
	defer sun.Close()
	ln, _ := net.Listen("tcp", "127.0.0.1:0")
	defer ln.Close()
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			c.Close()
		}
	}()
	cfg := testConfig(t, t.TempDir())
	cfg.Network.TimeoutSec = 2
	cfg.Network.Internet.Targets = []string{ln.Addr().String()}
	cfg.Network.Sunshine = []config.SunshineInstance{{ID: "pc", Name: "Sunshine (тест)", ServerInfoURL: sun.URL, WebURL: "https://127.0.0.1:1"}}
	c := newCore(t, cfg, modules.All()...)
	srv := httptest.NewServer(c.Handler())
	defer srv.Close()
	owner := readToken(t, cfg)
	call := func(method, path, body string) (int, json.RawMessage) {
		t.Helper()
		var rd io.Reader
		if body != "" {
			rd = strings.NewReader(body)
		}
		req, _ := http.NewRequest(method, srv.URL+"/api/v1"+path, rd)
		req.Header.Set("Authorization", "Bearer "+owner)
		res, err := srv.Client().Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer res.Body.Close()
		var env map[string]json.RawMessage
		_ = json.NewDecoder(res.Body).Decode(&env)
		if res.StatusCode >= 300 {
			checkShape(t, doc, "Error", env["error"])
			return res.StatusCode, env["error"]
		}
		return res.StatusCode, env["data"]
	}
	_, _ = call("POST", "/registry/entities", `{"name":"Роутер (тест)","type":"router","address":"`+ln.Addr().String()+`"}`)
	_, _ = call("POST", "/registry/entities", `{"name":"ТВ (тест)","type":"television"}`)
	var data json.RawMessage
	for range 40 { // the module's first round runs at start
		var code int
		code, data = call("POST", "/network/check", "")
		if code == http.StatusOK && strings.Contains(string(data), `"sunshine:pc"`) && strings.Contains(string(data), `"latencyMs":`) {
			break
		}
		time.Sleep(150 * time.Millisecond)
	}
	if code, _ := call("POST", "/network/check", ""); code != http.StatusConflict {
		t.Fatalf("rate limit: %d", code)
	}
	_, data = call("GET", "/network/overview", "")
	checkShape(t, doc, "NetworkOverview", data)
	var o struct {
		Summary                json.RawMessage
		Internet               json.RawMessage
		Routers, TVs, Sunshine []json.RawMessage
		Incidents, Recent      []json.RawMessage
	}
	_ = json.Unmarshal(data, &o)
	checkShape(t, doc, "NetworkCheck", o.Internet)
	if len(o.Routers) != 1 || len(o.TVs) != 1 || len(o.Sunshine) != 1 {
		t.Fatalf("overview: %s", data)
	}
	checkShape(t, doc, "NetworkRouter", o.Routers[0])
	checkShape(t, doc, "NetworkDevice", o.TVs[0])
	checkShape(t, doc, "NetworkSunshine", o.Sunshine[0])
	var sh struct {
		Check struct {
			Status  string
			Details json.RawMessage
		}
	}
	_ = json.Unmarshal(o.Sunshine[0], &sh)
	if sh.Check.Status != "up" {
		t.Fatalf("sunshine: %s", o.Sunshine[0])
	}
	checkShape(t, doc, "NetworkDetails", sh.Check.Details)
	_, types := call("GET", "/monitoring/metric-types", "")
	if !strings.Contains(string(types), `"net.latency"`) {
		t.Fatal("net.latency metric type")
	}
}
