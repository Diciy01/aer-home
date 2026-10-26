// Package auth manages the local API bearer token.
//
// MVP model (ADR-007): one owner, one random token stored in a 0600 file in the
// Core data dir. Local clients read the file; remote clients get it out of band.
// Device-scoped credentials with capabilities replace this before Remote/mobile.
package auth

import (
	"crypto/rand"
	"crypto/subtle"
	"encoding/hex"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
)

const tokenBytes = 32

// LoadOrCreateToken reads the token at path, creating a new one if the file is missing.
// created reports whether a new token was generated.
func LoadOrCreateToken(path string) (token string, created bool, err error) {
	raw, err := os.ReadFile(path)
	if err == nil {
		token = strings.TrimSpace(string(raw))
		if len(token) < tokenBytes {
			return "", false, fmt.Errorf("token file %q is too short; delete it to regenerate", path)
		}
		return token, false, nil
	}
	if !errors.Is(err, fs.ErrNotExist) {
		return "", false, fmt.Errorf("read token file: %w", err)
	}

	buf := make([]byte, tokenBytes)
	if _, err := rand.Read(buf); err != nil {
		return "", false, fmt.Errorf("generate token: %w", err)
	}
	token = hex.EncodeToString(buf)
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return "", false, fmt.Errorf("create token dir: %w", err)
	}
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return "", false, fmt.Errorf("create token file: %w", err)
	}
	if _, err := f.WriteString(token + "\n"); err != nil {
		f.Close()
		return "", false, fmt.Errorf("write token file: %w", err)
	}
	if err := f.Close(); err != nil {
		return "", false, err
	}
	return token, true, nil
}

// Equal compares a presented token with the expected one in constant time.
func Equal(presented, expected string) bool {
	return subtle.ConstantTimeCompare([]byte(presented), []byte(expected)) == 1
}
