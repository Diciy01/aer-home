package connecthost

import (
	"aerhome/core/internal/remoteengine"
	"testing"
)

func TestTrustedApprovalStillRequiresPasswordAndIdentity(t *testing.T) {
	for _, mode := range []string{"off", "trusted", "bad password", "spoof", "no proof", "incoming off"} {
		t.Run(mode, func(t *testing.T) {
			g, clock := newGuard(t, nil)
			viewer, _ := remoteengine.NewBoxKey()
			password := g.Temp()
			if mode == "bad password" {
				password = "WRONG-TEST-ONLY"
			}
			a := sealFor(t, g, remoteengine.NewAttemptID(), password, clock.t)
			var err error
			a, err = remoteengine.ProveIdentity(viewer, remoteengine.EncodeKey(g.key.PublicKey().Bytes()), a)
			if err != nil {
				t.Fatal(err)
			}
			if mode != "off" {
				a.TrustRevision = 1
			}
			if g.SkipApproval(a) {
				t.Fatal("skip without accepted password")
			}
			if mode == "spoof" {
				other, _ := remoteengine.NewBoxKey()
				a.ViewerBoxPub = remoteengine.EncodeKey(other.PublicKey().Bytes())
			}
			if mode == "no proof" {
				a.IdentityProof = ""
			}
			ok, _ := g.Verify(a)
			if mode == "bad password" || mode == "spoof" || mode == "no proof" {
				if ok || g.SkipApproval(a) {
					t.Fatal("authentication bypass")
				}
				return
			}
			if !ok {
				t.Fatal("valid password/identity refused")
			}
			if mode == "incoming off" {
				g.SetIncoming(false)
			}
			if g.SkipApproval(a) != (mode == "trusted") {
				t.Fatal("incorrect approval decision")
			}
			if mode == "incoming off" && g.CanOpen() {
				t.Fatal("incoming disable ignored")
			}
		})
	}
}
