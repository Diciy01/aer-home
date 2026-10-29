package remotegw

import (
	"bufio"
	"crypto/ecdh"
	"testing"
	"time"

	"aerhome/core/internal/connecthost"
	"aerhome/core/internal/remoteengine"
	"aerhome/core/internal/remotehost"
)

// The real password guard/runtime, Core and TLS Gateway; isolated fake
// desktop transport. Never captures or injects input on the user's desktop.
func (d *device) trustedConnect(number, password string, key *ecdh.PrivateKey) (string, int, string) {
	var ch struct{ AttemptID, Number, BoxPub, ViewerNumber string }
	st, code, reason := d.call("POST", "/gw/v1/connect/challenge", map[string]string{"number": number}, &ch)
	if st != 200 {
		return "", st, or(reason, code)
	}
	a, err := remoteengine.SealPassword(ch.BoxPub, remoteengine.ConnectAuth{AttemptID: ch.AttemptID, ViewerNumber: ch.ViewerNumber, TargetNumber: ch.Number}, password, time.Now())
	if err != nil {
		d.s.t.Fatal(err)
	}
	if key == nil {
		key, _ = remoteengine.ParseBoxKey(d.boxKey)
	}
	a, err = remoteengine.ProveIdentity(key, ch.BoxPub, a)
	if err != nil {
		d.s.t.Fatal(err)
	}
	var session struct{ ID string }
	st, code, reason = d.call("POST", "/gw/v1/connect", map[string]any{"attemptId": a.AttemptID, "ephPub": a.EphPub, "ciphertext": a.Ciphertext, "identityProof": a.IdentityProof}, &session)
	return session.ID, st, or(reason, code)
}

func TestTrustedDeviceAccessEndToEnd(t *testing.T) {
	s := newAnywhere(t)
	var enrollment struct{ Code string }
	if st := s.ownerCall("POST", "/remote/enrollments", `{"name":"TRUST TEST ONLY","maxUses":3}`, &enrollment); st != 201 {
		t.Fatal(st)
	}
	home, work, unknown := s.enroll(enrollment.Code, "Home TEST"), s.enroll(enrollment.Code, "Work TEST"), s.enroll(enrollment.Code, "Unknown TEST")
	host := home.runHost(t, true)
	waitUntil(t, "host online", func() bool { return host.last().Link == remotehost.LinkOnline })
	must := func(d *device, method, path string, body, out any) {
		t.Helper()
		if st, _, reason := d.call(method, path, body, out); st != 200 {
			t.Fatalf("%s %s: %d %s", method, path, st, reason)
		}
	}
	type state struct {
		Enabled bool
		Devices []struct {
			Number, Fingerprint string
			RevokedAt           *time.Time
		}
	}
	var trust state
	path := "/gw/v1/devices/me/trust"
	must(home, "GET", path, nil, &trust)
	if trust.Enabled || len(trust.Devices) != 0 {
		t.Fatal("unattended access enabled by default")
	}
	const password = "Trusted-Test-Only-Password#2026"
	host.send(connecthost.Command{Cmd: "setPermanent", Password: password})
	waitUntil(t, "permanent password", func() bool { return host.last().Permanent })
	manual := func(d *device) {
		t.Helper()
		id, st, reason := d.trustedConnect(home.number, password, nil)
		if st != 201 {
			t.Fatalf("manual connect %d %s", st, reason)
		}
		waitUntil(t, "manual local consent", func() bool {
			return d.state(id) == "awaiting_approval" && host.last().Session != nil && host.last().Session.State == "prompt"
		})
		host.prompt <- false
		waitUntil(t, "denied manual request", func() bool { return d.state(id) == "failed" })
		waitUntil(t, "host idle", func() bool { return host.last().Session == nil })
	}
	manual(work) // A permanent password alone never turns consent off.
	var candidate struct{ Number, Name, Fingerprint string }
	must(home, "POST", path+"/candidate", map[string]string{"number": work.number}, &candidate)
	if candidate.Number != work.number || len(candidate.Fingerprint) != 64 {
		t.Fatal("candidate lacks installation identity")
	}
	if st, _, _ := home.call("POST", path+"/grant", map[string]string{"number": work.number, "fingerprint": "BAD"}, nil); st != 409 {
		t.Fatal("grant without matching key fingerprint", st)
	}
	must(home, "POST", path+"/grant", map[string]string{"number": work.number, "fingerprint": candidate.Fingerprint}, &trust)
	manual(work) // Allow-list retained, global switch still off.
	must(home, "PUT", path, map[string]bool{"enabled": true}, &trust)
	manual(unknown) // Unknown installation still needs visible approval.
	if _, st, _ := work.trustedConnect(home.number, "WRONG-TEST-ONLY", nil); st != 403 {
		t.Fatal("wrong password accepted", st)
	}
	wrong, _ := remoteengine.NewBoxKey()
	if _, st, _ := work.trustedConnect(home.number, password, wrong); st != 403 {
		t.Fatal("forged installation identity accepted", st)
	}
	waitUntil(t, "idle after refusals", func() bool { return host.last().Session == nil })

	start := func() (string, grant) {
		t.Helper()
		var hostInfo struct{ Agent struct{ Features []string } }
		s.ownerCall("GET", "/remote/hosts/"+home.entityID, "", &hostInfo)
		must(home, "GET", path, nil, &trust)
		if !trust.Enabled {
			t.Fatal("trusted mode not enabled")
		}
		id, st, reason := work.trustedConnect(home.number, password, nil)
		if st != 201 {
			t.Fatalf("trusted connect %d %s", st, reason)
		}
		var debug struct {
			State, Reason string
			Events        []struct{ Kind, Message string }
		}
		for i := 0; i < 100; i++ {
			work.call("GET", "/gw/v1/sessions/"+id, nil, &debug)
			if debug.State == "connecting" {
				break
			}
			time.Sleep(40 * time.Millisecond)
		}
		if debug.State != "connecting" {
			t.Fatalf("trusted state=%s reason=%s host=%+v audit=%+v", debug.State, debug.Reason, host.last().Session, debug.Events)
		}
		if len(host.prompt) != 0 {
			t.Fatal("unexpected consent response consumed")
		}
		var g grant
		must(work, "POST", "/gw/v1/sessions/"+id+"/grant", nil, &g)
		return id, g
	}
	id, g := start()
	assertClosed := func(reader *bufio.Reader) {
		t.Helper()
		done := make(chan error, 1)
		go func() { _, err := reader.ReadByte(); done <- err }()
		select {
		case err := <-done:
			if err == nil {
				t.Fatal("transport survived access removal")
			}
		case <-time.After(4 * time.Second):
			t.Fatal("transport did not close after access removal")
		}
	}
	leg, err := work.tunnel(g.Tunnel.Tickets["rdp"])
	if err != nil {
		t.Fatal(err)
	}
	_, reader := greet(t, leg)
	echo(t, leg, reader, "TRUSTED TEST ONLY\n")
	must(home, "PUT", path, map[string]bool{"enabled": false}, &trust)
	waitUntil(t, "disable terminates trusted session", func() bool { return work.state(id) == "revoked" && host.last().Session == nil })
	assertClosed(reader)
	leg.Close()
	manual(work) // Turning off restores consent, retains explicit trust records.
	must(home, "PUT", path, map[string]bool{"enabled": true}, &trust)

	// Restart the host runtime with the SAME installation key and saved verifier.
	host.stdin.Close()
	waitUntil(t, "host runtime stopped", func() bool { return host.last().Link == remotehost.LinkStopped })
	verifier, _ := remoteengine.NewVerifier(password)
	s.stopGateway()
	s.stopCore()
	s.startCore()
	s.startGateway()
	host = home.runHost(t, true, &verifier)
	waitUntil(t, "restarted host online", func() bool { return host.last().Link == remotehost.LinkOnline })
	must(home, "GET", path, nil, &trust)
	if !trust.Enabled || len(trust.Devices) != 1 {
		t.Fatal("trust lost on runtime/Core/Gateway restart")
	}
	id, g = start()
	leg, err = work.tunnel(g.Tunnel.Tickets["rdp"])
	if err != nil {
		t.Fatal(err)
	}
	_, reader = greet(t, leg)
	var fresh struct{ Ticket string }
	must(work, "POST", "/gw/v1/sessions/"+id+"/tickets", map[string]string{"channel": "rdp"}, &fresh)
	must(home, "POST", path+"/revoke", map[string]string{"number": work.number}, &trust)
	waitUntil(t, "revoke terminates session", func() bool { return work.state(id) == "revoked" && host.last().Session == nil })
	assertClosed(reader)
	leg.Close()
	if old, err := work.tunnel(fresh.Ticket); err == nil {
		old.Close()
		t.Fatal("unused old ticket restored revoked access")
	}
	if _, st, reason := work.trustedConnect(home.number, password, nil); st != 403 || reason != "trust_revoked" {
		t.Fatalf("revoked reconnect %d %s", st, reason)
	}
	must(home, "PUT", path, map[string]bool{"enabled": false}, &trust)
	s.stopGateway()
	s.stopCore()
	s.startCore()
	s.startGateway()
	must(home, "GET", path, nil, &trust)
	if trust.Enabled || len(trust.Devices) != 1 || trust.Devices[0].RevokedAt == nil {
		t.Fatal("revocation tombstone lost")
	}
	if _, st, _ := work.trustedConnect(home.number, password, nil); st != 403 {
		t.Fatal("restart or disable cleared revocation", st)
	}
}
