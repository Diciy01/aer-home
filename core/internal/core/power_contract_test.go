package core

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"aerhome/core/internal/modules"
	"aerhome/core/internal/modules/power"
)

// TestPowerContract checks Power payloads against the contract, the split
// of credentials (owner token for clients, kind=power agents only on agent
// routes) and delivers a real magic packet to a test UDP receiver on
// 127.0.0.1 through the HTTP API. No packet reaches the LAN; the agent here
// is the test itself (SIMULATED execution).
func TestPowerContract(t *testing.T) {
	doc := loadOpenAPI(t)
	cfg := testConfig(t, t.TempDir())
	cfg.Power.WoL.Enabled = true
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
		_ = json.NewDecoder(res.Body).Decode(&env)
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
	each := func(name string, raw json.RawMessage) {
		t.Helper()
		var items []json.RawMessage
		_ = json.Unmarshal(raw, &items)
		if len(items) == 0 {
			t.Fatalf("%s: empty", name)
		}
		for _, it := range items {
			checkShape(t, doc, name, it)
		}
	}

	// TEST DATA: documentation MAC range (RFC 7042), loopback receiver.
	rx, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	defer rx.Close()
	port := rx.LocalAddr().(*net.UDPAddr).Port
	var pc struct{ ID string }
	_ = json.Unmarshal(call("POST", "/registry/entities", owner, `{"name":"ПК (тест)","type":"computer",
		"capabilities":["power.wake","power.shutdown","power.reboot","power.suspend","power.switch_os"]}`), &pc)
	var ifs struct {
		Interfaces []json.RawMessage
		WolEnabled bool
	}
	_ = json.Unmarshal(call("GET", "/power/interfaces", owner, ""), &ifs)
	if !ifs.WolEnabled || len(ifs.Interfaces) == 0 {
		t.Fatalf("interfaces: %+v", ifs)
	}
	checkShape(t, doc, "PowerInterface", ifs.Interfaces[0])
	if code, _ := do("PUT", "/power/devices/"+pc.ID+"/wol", owner, `{"mac":"00:00:5e:00:53:aa","broadcast":"203.0.113.255"}`); code != 422 {
		t.Fatalf("internet destination: %d", code)
	}
	checkShape(t, doc, "PowerDevice", call("PUT", "/power/devices/"+pc.ID+"/wol", owner,
		fmt.Sprintf(`{"mac":"00:00:5e:00:53:aa","broadcast":"127.0.0.1","port":%d}`, port)))
	each("PowerDevice", call("GET", "/power/devices", owner, ""))

	conf := call("POST", "/power/devices/"+pc.ID+"/actions/wake/confirm", owner, `{}`)
	checkShape(t, doc, "PowerConfirmation", conf)
	var cf struct{ Token string }
	_ = json.Unmarshal(conf, &cf)
	if code, _ := do("POST", "/power/devices/"+pc.ID+"/actions/wake", owner, `{"confirmationToken":"`+cf.Token+`"}`); code != 422 {
		t.Fatalf("missing Idempotency-Key: %d", code)
	}
	code, env := do("POST", "/power/devices/"+pc.ID+"/actions/wake", owner, `{"confirmationToken":"`+cf.Token+`"}`, "Idempotency-Key", "power-contract-1")
	if code != http.StatusAccepted {
		t.Fatalf("wake: %d %s", code, env["error"])
	}
	checkShape(t, doc, "PowerJob", env["data"])
	buf := make([]byte, 256)
	_ = rx.SetReadDeadline(time.Now().Add(2 * time.Second))
	n, _, err := rx.ReadFromUDP(buf)
	want, _ := power.MagicPacket("00:00:5e:00:53:aa")
	if err != nil || !bytes.Equal(buf[:n], want) {
		t.Fatalf("magic packet at the test receiver: %d bytes, %v", n, err)
	}
	if code, _ = do("POST", "/power/devices/"+pc.ID+"/actions/wake", owner, `{}`, "Idempotency-Key", "power-contract-1"); code != http.StatusOK {
		t.Fatalf("replay: %d", code)
	}
	if code, _ = do("POST", "/power/devices/"+pc.ID+"/actions/format-disk", owner, `{}`, "Idempotency-Key", "power-contract-x"); code != 400 {
		t.Fatalf("unknown action: %d", code)
	}
	if code, _ = do("POST", "/power/devices/"+pc.ID+"/actions/shutdown", owner, `{"command":"sudo shutdown -h now"}`, "Idempotency-Key", "power-contract-y"); code != 400 {
		t.Fatalf("free-form command accepted: %d", code)
	}

	// Agent protocol.
	var pa, host struct{ Token string }
	_ = json.Unmarshal(call("POST", "/monitoring/agents", owner, `{"entityId":"`+pc.ID+`","name":"power","kind":"power"}`), &pa)
	_ = json.Unmarshal(call("POST", "/monitoring/agents", owner, `{"entityId":"`+pc.ID+`","name":"os","kind":"host"}`), &host)
	hello := `{"os":"linux","hostname":"pc-test","bootId":"b-1","dryRun":true,"firmware":"uefi","secureBoot":"enabled","bitlocker":"off",
		"bootManager":"refind","bootEntries":[{"id":"0000","label":"Ubuntu","os":"linux","current":false},{"id":"0003","label":"Windows Boot Manager","os":"windows","current":false}],
		"macs":["00:00:5e:00:53:aa"],"actions":{"shutdown":{"supported":true,"reason":""},"reboot":{"supported":true,"reason":""},"suspend":{"supported":true,"reason":""},"bootNext":{"supported":true,"reason":""}}}`
	if code, _ = do("POST", "/power/agent/hello", owner, hello); code != http.StatusUnauthorized {
		t.Fatalf("owner token on the agent route: %d", code)
	}
	if code, _ = do("POST", "/power/agent/hello", host.Token, hello); code != http.StatusForbidden {
		t.Fatalf("an OS agent is not a power agent: %d", code)
	}
	if code, _ = do("GET", "/power/devices", pa.Token, ""); code != http.StatusUnauthorized {
		t.Fatalf("agent token on an owner route: %d", code)
	}
	call("POST", "/power/agent/hello", pa.Token, hello)
	job := call("GET", "/power/jobs/"+jobID(env["data"]), owner, "")
	checkShape(t, doc, "PowerJob", job)
	if !strings.Contains(string(job), `"succeeded"`) {
		t.Fatalf("wake not settled by hello: %s", job)
	}
	dev := call("GET", "/power/devices/"+pc.ID, owner, "")
	checkShape(t, doc, "PowerDevice", dev)
	var d struct {
		Agents  []json.RawMessage
		Actions []json.RawMessage
	}
	_ = json.Unmarshal(dev, &d)
	checkShape(t, doc, "PowerAgent", d.Agents[0])
	each("PowerAction", mustJSON(d.Actions))

	_ = json.Unmarshal(call("POST", "/power/devices/"+pc.ID+"/actions/reboot/confirm", owner, `{}`), &cf)
	rb := call("POST", "/power/devices/"+pc.ID+"/actions/reboot", owner, `{"confirmationToken":"`+cf.Token+`"}`, "Idempotency-Key", "power-contract-2")
	var cmds struct{ Commands []json.RawMessage }
	_ = json.Unmarshal(call("GET", "/power/agent/commands?wait=1", pa.Token, ""), &cmds)
	if len(cmds.Commands) != 1 {
		t.Fatalf("commands: %d", len(cmds.Commands))
	}
	checkShape(t, doc, "PowerCommand", cmds.Commands[0])
	if code, _ = do("POST", "/power/jobs/"+jobID(rb)+"/cancel", owner, ""); code != http.StatusConflict {
		t.Fatalf("cancel after delivery: %d", code)
	}
	call("POST", "/power/agent/jobs/"+jobID(rb)+"/events", pa.Token, `{"kind":"simulated","message":"would run: systemctl reboot"}`)
	if !strings.Contains(string(call("GET", "/power/jobs/"+jobID(rb), owner, "")), `"simulated"`) {
		t.Fatal("not simulated")
	}
	each("PowerJob", call("GET", "/power/jobs?entityId="+pc.ID, owner, ""))
	checkShape(t, doc, "PowerDevice", call("PUT", "/power/devices/"+pc.ID+"/policy", owner,
		`{"enabled":true,"wake":true,"shutdown":true,"reboot":true,"suspend":true,"switchOs":true}`))
	sw := call("POST", "/power/devices/"+pc.ID+"/actions/switch_os/confirm", owner, `{"targetOs":"windows"}`)
	checkShape(t, doc, "PowerConfirmation", sw)
	checkShape(t, doc, "PowerDevice", call("DELETE", "/power/devices/"+pc.ID+"/wol", owner, ""))
}

func jobID(raw json.RawMessage) string {
	var j struct{ ID string }
	_ = json.Unmarshal(raw, &j)
	return j.ID
}
