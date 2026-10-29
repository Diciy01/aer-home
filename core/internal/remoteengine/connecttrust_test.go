package remoteengine

import (
	"testing"
	"time"
)

func TestInstallationIdentityProof(t *testing.T) {
	host, viewer := fixedKey(t, 1), fixedKey(t, 51)
	auth, err := sealWith(fixedKey(t, 101), EncodeKey(host.PublicKey().Bytes()), ConnectAuth{AttemptID: "AAECAwQFBgcICQoLDA0ODw", ViewerNumber: "111222333", TargetNumber: "444555666"}, "k7m2x9qp", time.UnixMilli(1793000000000))
	if err != nil {
		t.Fatal(err)
	}
	auth, err = ProveIdentity(viewer, EncodeKey(host.PublicKey().Bytes()), auth)
	if err != nil || VerifyIdentity(host, auth) != nil {
		t.Fatal("valid identity proof refused", err)
	}
	t.Log("PUBLIC TEST VECTOR proof:", auth.IdentityProof)
	for name, mut := range map[string]func(*ConnectAuth){
		"attempt":       func(a *ConnectAuth) { a.AttemptID = "other" },
		"viewer":        func(a *ConnectAuth) { a.ViewerNumber = "999888777" },
		"target":        func(a *ConnectAuth) { a.TargetNumber = "999888777" },
		"password box":  func(a *ConnectAuth) { a.Ciphertext += "A" },
		"ephemeral":     func(a *ConnectAuth) { a.EphPub = EncodeKey(host.PublicKey().Bytes()) },
		"identity":      func(a *ConnectAuth) { a.ViewerBoxPub = EncodeKey(fixedKey(t, 52).PublicKey().Bytes()) },
		"missing proof": func(a *ConnectAuth) { a.IdentityProof = "" },
	} {
		t.Run(name, func(t *testing.T) {
			a := auth
			mut(&a)
			if VerifyIdentity(host, a) == nil {
				t.Fatal("tampered proof accepted")
			}
		})
	}
}
