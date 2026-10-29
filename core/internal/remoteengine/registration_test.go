package remoteengine

import (
	"encoding/json"
	"os"
	"testing"
)

func TestRegistrationEnvelope(t *testing.T) {
	seed := make([]byte, 32)
	for i := range seed {
		seed[i] = byte(i + 1)
	}
	key, _ := ParseBoxKey(EncodeKey(seed))
	box, err := SealRegistration(EncodeKey(key.PublicKey().Bytes()), "REQUEST-TEST", "INSTANCE-TEST", []byte("CHALLENGE-TEST-ONLY"))
	if err != nil {
		t.Fatal(err)
	}
	plain, err := OpenRegistration(key, "REQUEST-TEST", "INSTANCE-TEST", box)
	if err != nil || string(plain) != "CHALLENGE-TEST-ONLY" {
		t.Fatalf("round trip: %v", err)
	}
	// One shared non-production vector checks Go/Dart wire compatibility.
	raw, err := os.ReadFile("../../../packages/aer_remote/test/fixtures/registration.json")
	if err != nil {
		t.Fatal(err)
	}
	var vector struct {
		ID, Instance           string
		Challenge, Credentials RegistrationBox
	}
	if err = json.Unmarshal(raw, &vector); err != nil {
		t.Fatal(err)
	}
	if p, err := OpenRegistration(key, vector.ID, vector.Instance, vector.Challenge); err != nil || string(p) != "CHALLENGE-TEST-ONLY" {
		t.Fatalf("shared challenge vector: %v", err)
	}
	if p, err := OpenRegistration(key, vector.ID, vector.Instance, vector.Credentials); err != nil || !json.Valid(p) {
		t.Fatalf("shared credential vector: %v", err)
	}
	other, _ := NewBoxKey()
	for _, tc := range []struct {
		name, id, instance string
		keyData            bool
	}{
		{"wrong request", "OTHER", "INSTANCE-TEST", false},
		{"wrong instance", "REQUEST-TEST", "OTHER", false},
		{"wrong key", "REQUEST-TEST", "INSTANCE-TEST", true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			k := key
			if tc.keyData {
				k = other
			}
			if _, err := OpenRegistration(k, tc.id, tc.instance, box); err == nil {
				t.Fatal("accepted substituted registration context")
			}
		})
	}
	box.Ciphertext = "AAAA"
	if _, err = OpenRegistration(key, "REQUEST-TEST", "INSTANCE-TEST", box); err == nil {
		t.Fatal("accepted damaged ciphertext")
	}
}
