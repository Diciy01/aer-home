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

// TestRemoteGatewayContract checks the M14 payloads and the credential
// split: owner token for client management only, the gateway credential
// (kind=gateway) for /remote/gw only, and the remote client's credential
// on top of it for client operations.
func TestRemoteGatewayContract(t *testing.T) {
	doc := loadOpenAPI(t)
	cfg := testConfig(t, t.TempDir())
	c := newCore(t, cfg, modules.All()...)
	srv := httptest.NewServer(c.Handler())
	defer srv.Close()
	owner := readToken(t, cfg)
	do := func(method, path, token, body string, hdr ...string) (int, json.RawMessage) {
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
			return res.StatusCode, env["error"]
		}
		return res.StatusCode, env["data"]
	}
	call := func(method, path, token, body string, hdr ...string) json.RawMessage {
		t.Helper()
		code, data := do(method, path, token, body, hdr...)
		if code >= 300 {
			t.Fatalf("%s %s: %d %s", method, path, code, data)
		}
		return data
	}
	k, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	tpl := &x509.Certificate{SerialNumber: big.NewInt(7), Subject: pkix.Name{CommonName: "test"}, NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour)}
	der, _ := x509.CreateCertificate(rand.Reader, tpl, tpl, &k.PublicKey, k)
	certJSON, _ := json.Marshal(string(pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})))

	// TEST DATA
	var pc, server struct{ ID string }
	_ = json.Unmarshal(call("POST", "/registry/entities", owner, `{"name":"ПК (тест)","type":"computer"}`), &pc)
	_ = json.Unmarshal(call("POST", "/registry/entities", owner, `{"name":"Сервер (тест)","type":"server"}`), &server)
	var remoteAgent, gwAgent struct{ Token string }
	_ = json.Unmarshal(call("POST", "/monitoring/agents", owner, `{"entityId":"`+pc.ID+`","name":"remote","kind":"remote"}`), &remoteAgent)
	_ = json.Unmarshal(call("POST", "/monitoring/agents", owner, `{"entityId":"`+server.ID+`","name":"gateway","kind":"gateway"}`), &gwAgent)
	call("POST", "/remote/agent/hello", remoteAgent.Token, `{"os":"linux","backend":"gnome-rdp","address":"192.0.2.10","port":3389,"certPem":`+string(certJSON)+
		`,"filesPort":3390,"capabilities":{"desktop":true,"input":true,"clipboard":true,"files":true,"apps":false},"approval":"auto","ready":true,"username":"aer"}`)
	call("PUT", "/remote/hosts/"+pc.ID+"/policy", owner, `{"enabled":true,"desktop":true,"clipboard":true,"files":true,"maxMinutes":30}`)

	if string(call("GET", "/remote/gateway", owner, "")) != "null" {
		t.Fatal("gateway info before any report")
	}
	if code, _ := do("POST", "/remote/gw/info", gwAgent.Token, `{"certSha256":"nope"}`); code != 422 {
		t.Fatalf("bad fingerprint accepted: %d", code)
	}
	call("POST", "/remote/gw/info", gwAgent.Token, `{"certSha256":"`+strings.Repeat("ab:", 31)+`ab","version":"0.1.0"}`)
	checkShape(t, doc, "RemoteGatewayInfo", call("GET", "/remote/gateway", owner, ""))
	if code, _ := do("POST", "/remote/gw/info", owner, `{"certSha256":"x"}`); code != http.StatusUnauthorized {
		t.Fatalf("owner token on /remote/gw/info: %d", code)
	}
	pairing := call("POST", "/remote/clients", owner, `{"name":"Рабочий ноутбук (тест)","hosts":["`+pc.ID+`"],"clipboard":true,"files":true}`)
	checkShape(t, doc, "RemotePairing", pairing)
	var p struct {
		Code   string
		Client struct{ ID string }
	}
	_ = json.Unmarshal(pairing, &p)
	var list []json.RawMessage
	_ = json.Unmarshal(call("GET", "/remote/clients", owner, ""), &list)
	if len(list) != 1 {
		t.Fatalf("clients: %d", len(list))
	}
	checkShape(t, doc, "RemoteClient", list[0])
	checkShape(t, doc, "RemoteClient", call("PUT", "/remote/clients/"+p.Client.ID, owner, `{"name":"Ноутбук (тест)","hosts":["`+pc.ID+`"],"clipboard":true,"files":true}`))

	// Credential split.
	for _, tok := range []string{owner, remoteAgent.Token} {
		if code, _ := do("POST", "/remote/gw/pair", tok, `{"code":"`+p.Code+`"}`); code != http.StatusUnauthorized {
			t.Fatalf("non-gateway credential on /remote/gw: %d", code)
		}
	}
	if code, _ := do("GET", "/remote/clients", gwAgent.Token, ""); code != http.StatusUnauthorized {
		t.Fatalf("gateway credential on an owner route: %d", code)
	}
	if code, _ := do("POST", "/remote/agent/hello", gwAgent.Token, `{}`); code != http.StatusForbidden {
		t.Fatalf("gateway credential on the host agent route: %d", code)
	}
	var paired struct{ Credential string }
	_ = json.Unmarshal(call("POST", "/remote/gw/pair", gwAgent.Token, `{"code":"`+p.Code+`","deviceName":"dev"}`), &paired)
	if code, _ := do("POST", "/remote/gw/pair", gwAgent.Token, `{"code":"`+p.Code+`"}`); code != http.StatusUnauthorized {
		t.Fatalf("pairing code reused: %d", code)
	}
	if code, _ := do("GET", "/remote/gw/client/hosts", gwAgent.Token, ""); code != http.StatusUnauthorized {
		t.Fatalf("client operation without client credential: %d", code)
	}
	cl := []string{"X-AER-Remote-Client", paired.Credential}
	var hosts struct{ Hosts []json.RawMessage }
	_ = json.Unmarshal(call("GET", "/remote/gw/client/hosts", gwAgent.Token, "", cl...), &hosts)
	if len(hosts.Hosts) != 1 || strings.Contains(string(hosts.Hosts[0]), "192.0.2.10") {
		t.Fatalf("client hosts: %s", hosts.Hosts)
	}
	checkShape(t, doc, "RemoteHost", hosts.Hosts[0])

	sess := call("POST", "/remote/gw/client/sessions", gwAgent.Token, `{"entityId":"`+pc.ID+`"}`, append(cl, "Idempotency-Key", "gw-1")...)
	checkShape(t, doc, "RemoteSession", sess)
	var s struct{ ID, Route string }
	_ = json.Unmarshal(sess, &s)
	if s.Route != "relay" {
		t.Fatalf("route %q", s.Route)
	}
	checkShape(t, doc, "RemoteSession", call("GET", "/remote/gw/client/sessions/"+s.ID, gwAgent.Token, "", cl...))
	var cmds struct {
		Commands []struct{ Relay bool }
	}
	_ = json.Unmarshal(call("GET", "/remote/agent/commands?wait=1", remoteAgent.Token, ""), &cmds)
	if len(cmds.Commands) != 1 || !cmds.Commands[0].Relay {
		t.Fatalf("relay command: %+v", cmds)
	}
	call("POST", "/remote/agent/sessions/"+s.ID+"/events", remoteAgent.Token, `{"event":"ready","password":"pw-TEST-only","filesToken":"ft-test"}`)
	if code, _ := do("POST", "/remote/sessions/"+s.ID+"/grant", owner, ""); code != http.StatusConflict {
		t.Fatalf("owner grant of a relay session: %d", code)
	}
	grant := call("POST", "/remote/gw/client/sessions/"+s.ID+"/grant", gwAgent.Token, "", cl...)
	checkShape(t, doc, "RemoteGrant", grant)
	var g struct {
		Tunnel struct{ Tickets map[string]string }
	}
	_ = json.Unmarshal(grant, &g)
	claim := call("POST", "/remote/gw/tunnel/claim", gwAgent.Token, `{"ticket":"`+g.Tunnel.Tickets["rdp"]+`"}`, cl...)
	checkShape(t, doc, "RemoteTunnelClaim", claim)
	if code, _ := do("POST", "/remote/gw/tunnel/claim", gwAgent.Token, `{"ticket":"`+g.Tunnel.Tickets["rdp"]+`"}`, cl...); code != http.StatusForbidden {
		t.Fatalf("ticket replay: %d", code)
	}
	if code, _ := do("POST", "/remote/gw/tunnel/host", gwAgent.Token, `{"sessionId":"`+s.ID+`","channel":"rdp"}`, "X-AER-Remote-Agent", owner); code != http.StatusUnauthorized {
		t.Fatalf("host leg with a non-agent credential: %d", code)
	}
	checkShape(t, doc, "RemoteTunnelClaim", call("POST", "/remote/gw/tunnel/host", gwAgent.Token, `{"sessionId":"`+s.ID+`","channel":"rdp"}`, "X-AER-Remote-Agent", remoteAgent.Token))
	call("POST", "/remote/gw/tunnel/event", gwAgent.Token, `{"sessionId":"`+s.ID+`","kind":"tunnel_opened","message":"rdp from 198.51.100.7"}`)
	call("POST", "/remote/gw/client/sessions/"+s.ID+"/tickets", gwAgent.Token, `{"channel":"files"}`, cl...)
	var alive struct{ Active []string }
	_ = json.Unmarshal(call("POST", "/remote/gw/alive", gwAgent.Token, `{"sessions":["`+s.ID+`"]}`), &alive)
	if len(alive.Active) != 1 {
		t.Fatalf("alive: %v", alive)
	}
	checkShape(t, doc, "RemoteSession", call("POST", "/remote/gw/client/sessions/"+s.ID+"/end", gwAgent.Token, "", cl...))
	checkShape(t, doc, "RemotePairing", call("POST", "/remote/clients/"+p.Client.ID+"/pairing", owner, ""))
	checkShape(t, doc, "RemoteClient", call("POST", "/remote/clients/"+p.Client.ID+"/revoke", owner, ""))
	if code, _ := do("GET", "/remote/gw/client/hosts", gwAgent.Token, "", cl...); code != http.StatusUnauthorized {
		t.Fatalf("revoked client: %d", code)
	}
}
