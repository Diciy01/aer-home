package remoteengine

import (
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"crypto/tls"
	"crypto/x509"
	"encoding/hex"
	"encoding/pem"
	"errors"
	"strings"
)

// ErrPinMismatch: the server's certificate is not the pinned one.
var ErrPinMismatch = errors.New("certificate does not match the pinned fingerprint")

// Fingerprint is the SHA-256 of a DER certificate as colon-separated hex
// (the format Core shows and stores since M07).
func Fingerprint(der []byte) string {
	sum := sha256.Sum256(der)
	parts := make([]string, len(sum))
	for i, c := range sum {
		parts[i] = hex.EncodeToString([]byte{c})
	}
	return strings.Join(parts, ":")
}

// FingerprintPEM fingerprints the first certificate in PEM text.
func FingerprintPEM(pemText string) (string, error) {
	b, _ := pem.Decode([]byte(pemText))
	if b == nil || b.Type != "CERTIFICATE" {
		return "", errors.New("not a PEM certificate")
	}
	if _, err := x509.ParseCertificate(b.Bytes); err != nil {
		return "", err
	}
	return Fingerprint(b.Bytes), nil
}

// NormalizeFingerprint lowercases and drops separators, so "AB:CD…" and
// "abcd…" compare equal.
func NormalizeFingerprint(fp string) string {
	return strings.ToLower(strings.NewReplacer(":", "", " ", "", "-", "").Replace(fp))
}

// PinnedTLS trusts exactly one certificate (by SHA-256), whoever signed
// it: the Gateway and host certificates are self-signed by default and
// pinned at pairing. The TLS handshake itself is the standard library's.
func PinnedTLS(fingerprint string) *tls.Config {
	want := NormalizeFingerprint(fingerprint)
	return &tls.Config{
		MinVersion:         tls.VersionTLS12,
		InsecureSkipVerify: true, // replaced by the pin check below
		VerifyConnection: func(cs tls.ConnectionState) error {
			if len(cs.PeerCertificates) == 0 || want == "" {
				return ErrPinMismatch
			}
			got := NormalizeFingerprint(Fingerprint(cs.PeerCertificates[0].Raw))
			if subtle.ConstantTimeCompare([]byte(got), []byte(want)) != 1 {
				return ErrPinMismatch
			}
			return nil
		},
	}
}

// NewSecret returns 32 random bytes as hex (tickets, credentials).
func NewSecret() string {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		panic(err) // crypto/rand never fails on supported platforms
	}
	return hex.EncodeToString(b)
}

// HashSecret is what servers keep instead of a secret.
func HashSecret(s string) [32]byte { return sha256.Sum256([]byte(s)) }
