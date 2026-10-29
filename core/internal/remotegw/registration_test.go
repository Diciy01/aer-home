package remotegw

import (
	"encoding/json"
	"net/http"
	"strings"
	"testing"

	"aerhome/core/internal/connecthost"
	"aerhome/core/internal/modules/remote"
	"aerhome/core/internal/remoteengine"
	"aerhome/core/internal/remotehost"
)

func (s *anywhere) registerAutomatically(name string) *device {
	t := s.t
	key, _ := remoteengine.NewBoxKey()
	d := &device{s: s, hc: &http.Client{Transport: &http.Transport{TLSClientConfig: remoteengine.PinnedTLS(s.gwFP)}}, boxKey: remoteengine.EncodeKey(key.Bytes()), installT: "AUTO-TEST-" + name}
	// Exactly the instance that the real host runtime derives from install ID.
	body := map[string]string{"deviceName": name, "boxPub": remoteengine.EncodeKey(key.PublicKey().Bytes()), "instance": connecthost.Instance(d.installT)}
	var reply remote.RegistrationReply
	if st, code, _ := d.call("POST", "/gw/v1/devices/registration", body, &reply); st != 200 || reply.Status != "verifying" {
		t.Fatalf("request %d %s", st, code)
	}
	proof, err := remoteengine.OpenRegistration(key, reply.ID, body["instance"], *reply.Box)
	if err != nil {
		t.Fatal(err)
	}
	body["proof"] = string(proof)
	if st, _, _ := d.call("POST", "/gw/v1/devices/registration", body, &reply); st != 200 || reply.Status != "pending" {
		t.Fatal("not pending")
	}
	if st := s.ownerCall("POST", "/remote/registrations/"+reply.ID+"/approve", "", nil); st != 200 {
		t.Fatalf("approve: %d", st)
	}
	if st, _, _ := d.call("POST", "/gw/v1/devices/registration", body, &reply); st != 200 || reply.Status != "approved" {
		t.Fatal("not approved")
	}
	plain, err := remoteengine.OpenRegistration(key, reply.ID, body["instance"], *reply.Box)
	if err != nil {
		t.Fatal(err)
	}
	var e remote.Enrolled
	if err = json.Unmarshal(plain, &e); err != nil {
		t.Fatal(err)
	}
	d.number, d.entityID, d.agentToken, d.cred = e.Number, e.EntityID, e.AgentToken, e.ClientCredential
	return d
}

func TestAutomaticRegistrationGatewayAndPasswordFlow(t *testing.T) {
	s := newAnywhere(t)
	home, work := s.registerAutomatically("HOME TEST"), s.registerAutomatically("WORK TEST")
	// Owner administration is never reachable on the public Gateway.
	if st, _, _ := work.call("GET", "/gw/v1/registrations", nil, nil); st != 404 {
		t.Fatalf("owner API leaked: %d", st)
	}
	s.stopGateway()
	s.stopCore()
	s.startCore()
	s.startGateway()
	host := home.runHost(t, true)
	waitUntil(t, "synthetic host online", func() bool { return host.last().Link == remotehost.LinkOnline })
	password := host.last().TempPassword
	if _, st, reason := work.connect(home.number, "WRONG TEST PASSWORD"); st != 403 || reason != "bad_password" {
		t.Fatalf("wrong password: %d %s", st, reason)
	}
	// Registration does not grant unattended access: local consent still gates
	// the synthetic desktop. No real Windows capture/input is used.
	host.prompt <- true
	id, st, why := work.connect(home.number, password)
	if st != 201 {
		t.Fatalf("connect: %d %s", st, why)
	}
	waitUntil(t, "ready", func() bool { return work.state(id) == "connecting" })
	var g grant
	if st, _, _ := work.call("POST", "/gw/v1/sessions/"+id+"/grant", nil, &g); st != 200 {
		t.Fatalf("grant: %d", st)
	}
	leg, err := work.tunnel(g.Tunnel.Tickets["rdp"])
	if err != nil {
		t.Fatal(err)
	}
	defer leg.Close()
	name, reader := greet(t, leg)
	if !strings.Contains(name, home.number) {
		t.Fatal("wrong synthetic host")
	}
	echo(t, leg, reader, "AUTOMATIC REGISTRATION TEST\n")
	if st, _, _ := work.call("POST", "/gw/v1/sessions/"+id+"/end", nil, nil); st != 200 {
		t.Fatalf("end: %d", st)
	}
	// A replacement cert is still refused, including before registration.
	wrong := &http.Client{Transport: &http.Transport{TLSClientConfig: remoteengine.PinnedTLS(strings.Repeat("0", 64))}}
	if res, err := wrong.Get(s.gwURL() + "/gw/v1/health"); err == nil {
		res.Body.Close()
		t.Fatal("wrong pin accepted")
	}
}
