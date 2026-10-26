package ids

import "testing"

func TestNewIsValidV4(t *testing.T) {
	seen := map[string]bool{}
	for range 100 {
		id := New()
		if !Valid(id) || id[14] != '4' {
			t.Fatalf("not a v4 uuid: %s", id)
		}
		if seen[id] {
			t.Fatalf("duplicate id %s", id)
		}
		seen[id] = true
	}
}

func TestValid(t *testing.T) {
	for _, bad := range []string{"", "room-office", "00000000-0000-4000-8000-00000000000Z", "00000000000040008000000000000001"} {
		if Valid(bad) {
			t.Fatalf("%q should be invalid", bad)
		}
	}
}
