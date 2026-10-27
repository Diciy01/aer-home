package core

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/json"
	"encoding/pem"
	"io"
	"math/big"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"aerhome/core/internal/modules"
)

// TestRemoteContract checks Remote payloads against the contract and the
// split of credentials: owner token for clients, kind=remote host agents only
// on the agent routes, one-time grants.
func TestRemoteContract(t *testing.T) {
	doc := loadOpenAPI(t)
	cfg := testConfig(t, t.TempDir())
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
	k, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	tpl := &x509.Certificate{SerialNumber: big.NewInt(7), Subject: pkix.Name{CommonName: "test"}, NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour)}
	der, _ := x509.CreateCertificate(rand.Reader, tpl, tpl, &k.PublicKey, k)
	certJSON, _ := json.Marshal(string(pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})))

	// TEST DATA
	var pc struct{ ID string }
	_ = json.Unmarshal(call("POST", "/registry/entities", owner, `{"name":"ПК (тест)","type":"computer"}`), &pc)
	var remoteAgent, hostAgent struct{ Token string }
	_ = json.Unmarshal(call("POST", "/monitoring/agents", owner, `{"entityId":"`+pc.ID+`","name":"remote","kind":"remote"}`), &remoteAgent)
	_ = json.Unmarshal(call("POST", "/monitoring/agents", owner, `{"entityId":"`+pc.ID+`","name":"os","kind":"host"}`), &hostAgent)
	hello := `{"os":"linux","backend":"gnome-rdp","address":"192.0.2.10","port":3389,"certPem":` + string(certJSON) +
		`,"filesPort":3390,"capabilities":{"desktop":true,"input":true,"clipboard":true,"files":true,"apps":false},"approval":"auto","ready":true,"username":"aer"}`
	if code, _ := do("POST", "/remote/agent/hello", owner, hello); code != http.StatusUnauthorized {
		t.Fatalf("owner token on the agent route: %d", code)
	}
	if code, _ := do("POST", "/remote/agent/hello", hostAgent.Token, hello); code != http.StatusForbidden {
		t.Fatalf("an OS agent is not a remote agent: %d", code)
	}
	if code, _ := do("GET", "/remote/hosts", remoteAgent.Token, ""); code != http.StatusUnauthorized {
		t.Fatalf("agent token on an owner route: %d", code)
	}
	call("POST", "/remote/agent/hello", remoteAgent.Token, hello)

	var hosts []json.RawMessage
	_ = json.Unmarshal(call("GET", "/remote/hosts", owner, ""), &hosts)
	for _, h := range hosts {
		checkShape(t, doc, "RemoteHost", h)
	}
	checkShape(t, doc, "RemoteHost", call("PUT", "/remote/hosts/"+pc.ID+"/policy", owner, `{"enabled":true,"desktop":true,"clipboard":true,"files":true,"maxMinutes":30}`))
	checkShape(t, doc, "RemoteApps", call("GET", "/remote/hosts/"+pc.ID+"/apps", owner, ""))
	sess := call("POST", "/remote/sessions", owner, `{"entityId":"`+pc.ID+`","sourceName":"Ноутбук (тест)"}`, "Idempotency-Key", "remote-contract-1")
	checkShape(t, doc, "RemoteSession", sess)
	var s struct{ ID string }
	_ = json.Unmarshal(sess, &s)
	var cmds struct{ Commands []json.RawMessage }
	_ = json.Unmarshal(call("GET", "/remote/agent/commands?wait=1", remoteAgent.Token, ""), &cmds)
	if len(cmds.Commands) != 1 {
		t.Fatalf("commands: %d", len(cmds.Commands))
	}
	checkShape(t, doc, "RemoteCommand", cmds.Commands[0])
	call("POST", "/remote/agent/sessions/"+s.ID+"/events", remoteAgent.Token, `{"event":"ready","password":"pw-TEST-only","filesToken":"ft-test"}`)
	grant := call("POST", "/remote/sessions/"+s.ID+"/grant", owner, "")
	checkShape(t, doc, "RemoteGrant", grant)
	if code, _ := do("POST", "/remote/sessions/"+s.ID+"/grant", owner, ""); code != http.StatusGone {
		t.Fatalf("second grant: %d", code)
	}
	call("POST", "/remote/agent/sessions/"+s.ID+"/events", remoteAgent.Token, `{"event":"connected"}`)
	checkShape(t, doc, "RemoteSession", call("GET", "/remote/sessions/"+s.ID, owner, ""))
	var list []json.RawMessage
	_ = json.Unmarshal(call("GET", "/remote/sessions?entityId="+pc.ID, owner, ""), &list)
	for _, x := range list {
		checkShape(t, doc, "RemoteSession", x)
	}
	checkShape(t, doc, "RemoteSession", call("POST", "/remote/sessions/"+s.ID+"/revoke", owner, ""))
	checkShape(t, doc, "RemoteSession", call("POST", "/remote/sessions/"+s.ID+"/end", owner, ""))
	checkShape(t, doc, "RemoteHost", call("POST", "/remote/hosts/"+pc.ID+"/revoke-sessions", owner, ""))
	if code, _ := do("POST", "/remote/sessions", owner, `{"entityId":"`+pc.ID+`","kind":"app"}`); code != 422 {
		t.Fatalf("apps: %d", code)
	}
}
