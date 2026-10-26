package auth

import (
	"os"
	"path/filepath"
	"runtime"
	"testing"
)

func TestCreateThenReuseToken(t *testing.T) {
	path := filepath.Join(t.TempDir(), "sub", "core.token")
	first, created, err := LoadOrCreateToken(path)
	if err != nil || !created || len(first) != 2*tokenBytes {
		t.Fatalf("create: token=%d chars created=%v err=%v", len(first), created, err)
	}
	second, created, err := LoadOrCreateToken(path)
	if err != nil || created || second != first {
		t.Fatalf("reuse: created=%v same=%v err=%v", created, second == first, err)
	}
	if runtime.GOOS != "windows" {
		info, err := os.Stat(path)
		if err != nil {
			t.Fatal(err)
		}
		if perm := info.Mode().Perm(); perm != 0o600 {
			t.Fatalf("token file perm = %o, want 600", perm)
		}
	}
}

func TestRejectsShortToken(t *testing.T) {
	path := filepath.Join(t.TempDir(), "core.token")
	if err := os.WriteFile(path, []byte("short\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, _, err := LoadOrCreateToken(path); err == nil {
		t.Fatal("expected short token to be rejected")
	}
}

func TestEqual(t *testing.T) {
	if !Equal("abc", "abc") || Equal("abc", "abd") || Equal("", "abc") {
		t.Fatal("Equal returned wrong result")
	}
}
