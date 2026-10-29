package connecthost

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"strings"
	"testing"
	"time"

	"aerhome/core/internal/remoteengine"
)

// TEST DATA: keys and passwords are generated fixtures.

type clock struct{ t time.Time }

func (c *clock) now() time.Time { return c.t }

func sealFor(t *testing.T, g *Guard, attempt, password string, at time.Time) remoteengine.ConnectAuth {
	t.Helper()
	a, err := remoteengine.SealPassword(remoteengine.EncodeKey(g.key.PublicKey().Bytes()),
		remoteengine.ConnectAuth{AttemptID: attempt, ViewerNumber: "111222333", TargetNumber: g.number}, password, at)
	if err != nil {
		t.Fatal(err)
	}
	return a
}

func newGuard(t *testing.T, perm *remoteengine.Verifier) (*Guard, *clock) {
	k, _ := remoteengine.NewBoxKey()
	g := NewGuard(k, "444555666", perm, true)
	c := &clock{t: time.Now()}
	g.now = c.now
	return g, c
}

func TestGuardTemporaryPasswordAndReplay(t *testing.T) {
	g, c := newGuard(t, nil)
	temp := g.Temp()
	a := sealFor(t, g, remoteengine.NewAttemptID(), temp, c.t)
	if ok, code := g.Verify(a); !ok {
		t.Fatalf("right temp password refused: %s", code)
	}
	if ok, code := g.Verify(a); ok || code != remoteengine.AuthReplay {
		t.Fatalf("replay accepted: %v %s", ok, code)
	}
	wrongTarget := a
	wrongTarget.AttemptID, wrongTarget.TargetNumber = remoteengine.NewAttemptID(), "999999999"
	if ok, code := g.Verify(wrongTarget); ok || code != remoteengine.AuthMalformed {
		t.Fatalf("other target accepted: %s", code)
	}
	if !g.RotateIfUsed() || g.Temp() == temp || g.RotateIfUsed() {
		t.Fatal("temporary password not single-session")
	}
	if ok, _ := g.Verify(sealFor(t, g, remoteengine.NewAttemptID(), temp, c.t)); ok {
		t.Fatal("old temporary password accepted")
	}
	stale := sealFor(t, g, remoteengine.NewAttemptID(), g.Temp(), c.t.Add(-time.Hour))
	if ok, code := g.Verify(stale); ok || code != remoteengine.AuthMalformed {
		t.Fatalf("stale seal accepted: %s", code)
	}
}

func TestGuardLockoutAndPermanent(t *testing.T) {
	v, _ := remoteengine.NewVerifier("Дом-2026-надёжный")
	g, c := newGuard(t, &v)
	for i := range guardFailLimit {
		if ok, code := g.Verify(sealFor(t, g, remoteengine.NewAttemptID(), "guess", c.t)); ok || code != remoteengine.AuthBadPassword {
			t.Fatalf("guess %d: %s", i, code)
		}
	}
	// Locked: even the right password is refused, and the temporary password changed.
	if ok, code := g.Verify(sealFor(t, g, remoteengine.NewAttemptID(), "Дом-2026-надёжный", c.t)); ok || code != remoteengine.AuthLocked {
		t.Fatalf("locked guard: %v %s", ok, code)
	}
	if _, _, locked := g.State(); locked == nil {
		t.Fatal("lock not reported")
	}
	c.t = c.t.Add(guardLockFor + time.Second)
	if ok, _ := g.Verify(sealFor(t, g, remoteengine.NewAttemptID(), "Дом-2026-надёжный", c.t)); !ok {
		t.Fatal("permanent password refused after lock")
	}
	if g.RotateIfUsed() {
		t.Fatal("permanent password must not rotate the temporary one")
	}
	g.SetPermanent(nil)
	if ok, _ := g.Verify(sealFor(t, g, remoteengine.NewAttemptID(), "Дом-2026-надёжный", c.t)); ok {
		t.Fatal("disabled permanent password accepted")
	}
	g.SetIncoming(false)
	if ok, code := g.Verify(sealFor(t, g, remoteengine.NewAttemptID(), g.Temp(), c.t)); ok || code != remoteengine.AuthDisabled {
		t.Fatalf("incoming off: %s", code)
	}
}

func TestRuntimeRefusesBadInitWithoutSecretsInOutput(t *testing.T) {
	var out bytes.Buffer
	in := Init{Type: "init", AgentToken: "aer1.x.secretsecret", BoxKey: "bad", Number: "1"}
	b, _ := json.Marshal(in)
	err := Run(context.Background(), io.MultiReader(bytes.NewReader(append(b, '\n'))), &out, Options{})
	if err == nil || !strings.Contains(out.String(), `"fatal"`) {
		t.Fatalf("bad init accepted: %v %s", err, out.String())
	}
	if strings.Contains(out.String(), "secretsecret") {
		t.Fatal("credential echoed")
	}
	if Instance("a-install-id-0000") == Instance("b-install-id-0000") || len(Instance("x")) != 64 {
		t.Fatal("instance fingerprint")
	}
}
