package remoteengine

import (
	"crypto/ecdh"
	"strings"
	"testing"
	"time"
)

// TEST DATA: keys and passwords below are fixtures, never real secrets.

func fixedKey(t *testing.T, fill byte) *ecdh.PrivateKey {
	t.Helper()
	b := make([]byte, 32)
	for i := range b {
		b[i] = fill + byte(i)
	}
	k, err := ecdh.X25519().NewPrivateKey(b)
	if err != nil {
		t.Fatal(err)
	}
	return k
}

func TestSealOpenRoundTripAndBinding(t *testing.T) {
	host, _ := NewBoxKey()
	pub := EncodeKey(host.PublicKey().Bytes())
	now := time.Now()
	a := ConnectAuth{AttemptID: NewAttemptID(), ViewerNumber: "111222333", TargetNumber: "444555666"}
	s, err := SealPassword(pub, a, "k7m2x9qp", now)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(s.Ciphertext, "k7m2x9qp") {
		t.Fatal("password visible in ciphertext")
	}
	got, err := OpenPassword(host, s, now, time.Minute)
	if err != nil || got != "k7m2x9qp" {
		t.Fatalf("open: %q %v", got, err)
	}
	// Any change of what the seal is bound to must fail (replay / reuse).
	for name, mut := range map[string]func(*ConnectAuth){
		"attempt": func(x *ConnectAuth) { x.AttemptID = NewAttemptID() },
		"viewer":  func(x *ConnectAuth) { x.ViewerNumber = "999888777" },
		"target":  func(x *ConnectAuth) { x.TargetNumber = "123123123" },
		"tamper": func(x *ConnectAuth) {
			b := []byte(x.Ciphertext)
			b[3] ^= 1
			x.Ciphertext = string(b)
		},
		"eph": func(x *ConnectAuth) { k, _ := NewBoxKey(); x.EphPub = EncodeKey(k.PublicKey().Bytes()) },
	} {
		x := s
		mut(&x)
		if _, err := OpenPassword(host, x, now, time.Minute); err == nil {
			t.Fatalf("%s: modified attempt opened", name)
		}
	}
	other, _ := NewBoxKey()
	if _, err := OpenPassword(other, s, now, time.Minute); err == nil {
		t.Fatal("another host key opened the attempt")
	}
	if _, err := OpenPassword(host, s, now.Add(2*time.Minute), time.Minute); err == nil {
		t.Fatal("stale attempt opened")
	}
}

// TestSealVector pins the wire format; packages/aer_remote/test/connect_auth_test.dart
// seals the same input and must produce exactly this ciphertext.
func TestSealVector(t *testing.T) {
	host, eph := fixedKey(t, 1), fixedKey(t, 101)
	a := ConnectAuth{AttemptID: "AAECAwQFBgcICQoLDA0ODw", ViewerNumber: "111222333", TargetNumber: "444555666"}
	s, err := sealWith(eph, EncodeKey(host.PublicKey().Bytes()), a, "k7m2x9qp", time.UnixMilli(1793000000000))
	if err != nil {
		t.Fatal(err)
	}
	const (
		wantHostPub = "B6N8vBQgk8i3VdwbEOhstCY3StFqqFPtC9_AsrhtHHw"
		wantEphPub  = "VxR2nRFr92Q2rnS8eT0sMK0ZA8WaxSc4BcfiaYtBDDY"
		wantCT      = "zp3V0YT58v4hrZHyjOL44GSFyMlfMf3oqnPu9rBvgKqZIhzTNLci8TCpmvr7yu-9rLiIHHhKmAA"
	)
	if got := EncodeKey(host.PublicKey().Bytes()); got != wantHostPub || s.EphPub != wantEphPub {
		t.Fatalf("keys changed: %s %s", got, s.EphPub)
	}
	got, err := OpenPassword(host, s, time.UnixMilli(1793000000000), time.Minute)
	if err != nil || got != "k7m2x9qp" {
		t.Fatal(got, err)
	}
	if s.Ciphertext != wantCT {
		t.Fatalf("wire format changed: %s", s.Ciphertext)
	}
}

func TestVerifierAndPasswords(t *testing.T) {
	v, err := NewVerifier("correct horse battery")
	if err != nil || !v.Valid() {
		t.Fatal(err)
	}
	if !v.Check("correct horse battery") || v.Check("correct horse batterY") || v.Check("") {
		t.Fatal("verifier check")
	}
	weak := v
	weak.Iter = 1000
	if weak.Valid() || weak.Check("correct horse battery") {
		t.Fatal("weak iteration count accepted")
	}
	for p, ok := range map[string]bool{"short": false, "aaaaaaaaaaaa": false, "abababababab": false, " padded-password ": false,
		"Tr0ub4dor&3x": true, "пароль-для-дома": true} {
		if (PermanentPasswordProblem(p) == "") != ok {
			t.Fatalf("%q: %q", p, PermanentPasswordProblem(p))
		}
	}
	seen := map[string]bool{}
	for range 200 {
		n := NewDeviceNumber()
		if !ValidDeviceNumber(n) {
			t.Fatalf("number %s", n)
		}
		seen[n] = true
		p := NewTempPassword()
		if len(p) != 8 || strings.Trim(p, tempAlphabet) != "" {
			t.Fatalf("temp %s", p)
		}
	}
	if len(seen) < 195 {
		t.Fatal("device numbers repeat too often")
	}
	if NormalizeDeviceNumber(" 123 456-789 ") != "123456789" || ValidDeviceNumber("012345678") || ValidDeviceNumber("12345678a") {
		t.Fatal("number normalization")
	}
	if !ValidBoxKey(EncodeKey(fixedKey(t, 1).PublicKey().Bytes())) || ValidBoxKey(EncodeKey(make([]byte, 32))) || ValidBoxKey("x") {
		t.Fatal("box key validation")
	}
}
