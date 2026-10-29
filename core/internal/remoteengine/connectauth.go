package remoteengine

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/ecdh"
	"crypto/hkdf"
	"crypto/pbkdf2"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/json"
	"errors"
	"math/big"
	"strings"
	"time"
	"unicode/utf8"
)

// AER Connect Anywhere (ADR-018): a device is reached by its public number
// and a password that only the host checks. The viewer seals the password
// to the host's X25519 key for one attempt issued by Core; Core and the
// Gateway relay ciphertext they cannot open. The attempt id is the HKDF
// salt and the AEAD additional data, so a sealed password is useless for
// any other attempt, viewer or host.

// AuthVersion names the sealing scheme (HKDF info prefix).
const AuthVersion = "aer-connect-auth/1"

// FeatureConnectAuth is what a host agent declares in hello when it
// verifies device passwords itself. Core never sends a password attempt
// (or a device session at all) to a host without it.
const FeatureConnectAuth = "connect-auth/1"

// ConnectAuth travels Core → host agent inside an "open" command.
type ConnectAuth struct {
	AttemptID     string `json:"attemptId"`
	EphPub        string `json:"ephPub"`     // base64url, 32 bytes
	Ciphertext    string `json:"ciphertext"` // base64url AES-256-GCM
	ViewerNumber  string `json:"viewerNumber"`
	ViewerName    string `json:"viewerName"`
	TargetNumber  string `json:"targetNumber"`
	ViewerBoxPub  string `json:"viewerBoxPub,omitempty"`
	IdentityProof string `json:"identityProof,omitempty"`
	// Only Core sets this after consulting the receiving device's trust policy.
	TrustRevision int64 `json:"trustRevision,omitempty"`
}

// Auth failure codes a host reports (AgentEvent.Code).
const (
	AuthBadPassword = "bad_password"
	AuthLocked      = "locked"
	AuthDisabled    = "disabled"
	AuthMalformed   = "malformed"
	AuthReplay      = "replay"
)

var b64 = base64.RawURLEncoding

// EncodeKey / DecodeKey: raw 32-byte keys as unpadded base64url.
func EncodeKey(b []byte) string { return b64.EncodeToString(b) }

func DecodeKey(s string) ([]byte, error) {
	b, err := b64.DecodeString(strings.TrimRight(s, "="))
	if err != nil || len(b) != 32 {
		return nil, errors.New("key: 32 bytes base64url")
	}
	return b, nil
}

// ValidBoxKey checks a public X25519 key as a device registers it.
func ValidBoxKey(s string) bool {
	b, err := DecodeKey(s)
	if err != nil {
		return false
	}
	_, err = ecdh.X25519().NewPublicKey(b)
	return err == nil && subtle.ConstantTimeCompare(b, make([]byte, 32)) != 1
}

// NewBoxKey creates a device's X25519 key.
func NewBoxKey() (*ecdh.PrivateKey, error) { return ecdh.X25519().GenerateKey(rand.Reader) }

// ParseBoxKey restores a private key from its raw bytes (base64url).
func ParseBoxKey(s string) (*ecdh.PrivateKey, error) {
	b, err := DecodeKey(s)
	if err != nil {
		return nil, err
	}
	return ecdh.X25519().NewPrivateKey(b)
}

type sealed struct {
	V int    `json:"v"`
	P string `json:"p"`
	T int64  `json:"t"` // unix ms when sealed (host rejects very old)
}

func authKey(shared []byte, attemptID, viewer, target string, ephPub, hostPub []byte) ([]byte, error) {
	salt := sha256.Sum256([]byte(attemptID))
	info := AuthVersion + "\x00" + viewer + "\x00" + target + "\x00" + string(ephPub) + string(hostPub)
	return hkdf.Key(sha256.New, shared, salt[:], info, 32)
}

func gcm(key []byte) (cipher.AEAD, error) {
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	return cipher.NewGCM(block)
}

// SealPassword is the viewer side: a fresh ephemeral key per attempt, so
// the derived key is used once and a zero nonce is safe.
func SealPassword(hostPub string, a ConnectAuth, password string, now time.Time) (ConnectAuth, error) {
	return sealWith(nil, hostPub, a, password, now)
}

func sealWith(eph *ecdh.PrivateKey, hostPub string, a ConnectAuth, password string, now time.Time) (ConnectAuth, error) {
	hp, err := DecodeKey(hostPub)
	if err != nil {
		return a, err
	}
	pub, err := ecdh.X25519().NewPublicKey(hp)
	if err != nil {
		return a, err
	}
	if eph == nil {
		if eph, err = NewBoxKey(); err != nil {
			return a, err
		}
	}
	shared, err := eph.ECDH(pub)
	if err != nil {
		return a, err
	}
	ephPub := eph.PublicKey().Bytes()
	key, err := authKey(shared, a.AttemptID, a.ViewerNumber, a.TargetNumber, ephPub, hp)
	if err != nil {
		return a, err
	}
	aead, err := gcm(key)
	if err != nil {
		return a, err
	}
	pt, _ := json.Marshal(sealed{V: 1, P: password, T: now.UnixMilli()})
	a.EphPub = EncodeKey(ephPub)
	a.Ciphertext = b64.EncodeToString(aead.Seal(nil, make([]byte, aead.NonceSize()), pt, []byte(a.AttemptID)))
	return a, nil
}

// ErrAuthMalformed: the attempt cannot be opened with this host's key.
var ErrAuthMalformed = errors.New("sealed password cannot be opened")

// OpenPassword is the host side. It fails for a different attempt id,
// viewer or target, a tampered ciphertext and anything older than maxAge.
func OpenPassword(priv *ecdh.PrivateKey, a ConnectAuth, now time.Time, maxAge time.Duration) (string, error) {
	ep, err := DecodeKey(a.EphPub)
	if err != nil {
		return "", ErrAuthMalformed
	}
	pub, err := ecdh.X25519().NewPublicKey(ep)
	if err != nil {
		return "", ErrAuthMalformed
	}
	shared, err := priv.ECDH(pub)
	if err != nil {
		return "", ErrAuthMalformed
	}
	ct, err := b64.DecodeString(a.Ciphertext)
	if err != nil || len(ct) > 4096 {
		return "", ErrAuthMalformed
	}
	key, err := authKey(shared, a.AttemptID, a.ViewerNumber, a.TargetNumber, ep, priv.PublicKey().Bytes())
	if err != nil {
		return "", ErrAuthMalformed
	}
	aead, err := gcm(key)
	if err != nil {
		return "", ErrAuthMalformed
	}
	pt, err := aead.Open(nil, make([]byte, aead.NonceSize()), ct, []byte(a.AttemptID))
	if err != nil {
		return "", ErrAuthMalformed
	}
	var s sealed
	if json.Unmarshal(pt, &s) != nil || s.V != 1 {
		return "", ErrAuthMalformed
	}
	age := now.Sub(time.UnixMilli(s.T))
	if age > maxAge || age < -maxAge {
		return "", ErrAuthMalformed
	}
	return s.P, nil
}

// ---- passwords ----

// PasswordIterations of PBKDF2-SHA256 for a permanent password verifier
// (OWASP 2023 recommendation for SHA-256).
const PasswordIterations = 600_000

// Verifier is what a host keeps instead of its permanent password.
type Verifier struct {
	Salt string `json:"salt"` // base64url, 16 bytes
	Hash string `json:"hash"` // base64url, 32 bytes
	Iter int    `json:"iter"`
}

// NewVerifier derives a verifier for password.
func NewVerifier(password string) (Verifier, error) {
	salt := make([]byte, 16)
	if _, err := rand.Read(salt); err != nil {
		return Verifier{}, err
	}
	h, err := pbkdf2.Key(sha256.New, password, salt, PasswordIterations, 32)
	if err != nil {
		return Verifier{}, err
	}
	return Verifier{Salt: b64.EncodeToString(salt), Hash: b64.EncodeToString(h), Iter: PasswordIterations}, nil
}

// Valid: a verifier this build accepts (no weak iteration counts).
func (v Verifier) Valid() bool {
	s, e1 := b64.DecodeString(v.Salt)
	h, e2 := b64.DecodeString(v.Hash)
	return e1 == nil && e2 == nil && len(s) == 16 && len(h) == 32 && v.Iter >= 100_000 && v.Iter <= 10_000_000
}

// Check compares password with the verifier in constant time.
func (v Verifier) Check(password string) bool {
	if !v.Valid() {
		return false
	}
	salt, _ := b64.DecodeString(v.Salt)
	want, _ := b64.DecodeString(v.Hash)
	got, err := pbkdf2.Key(sha256.New, password, salt, v.Iter, 32)
	return err == nil && subtle.ConstantTimeCompare(got, want) == 1
}

// PermanentPasswordProblem explains why a permanent password is too weak
// ("" when acceptable): at least 10 characters, 6 of them distinct.
func PermanentPasswordProblem(p string) string {
	n := utf8.RuneCountInString(p)
	switch {
	case n < 10:
		return "Не меньше 10 символов"
	case n > 128:
		return "Не больше 128 символов"
	case strings.TrimSpace(p) != p:
		return "Без пробелов в начале и в конце"
	}
	distinct := map[rune]bool{}
	for _, r := range p {
		distinct[r] = true
	}
	if len(distinct) < 6 {
		return "Слишком простой: нужно не меньше 6 разных символов"
	}
	return ""
}

// tempAlphabet: lowercase without look-alikes (no 0/o, 1/l/i).
const tempAlphabet = "abcdefghjkmnpqrstuvwxyz23456789"

// NewTempPassword: 8 symbols ≈ 39.6 bits, shown on the host and changed
// after each session, on request and on every start.
func NewTempPassword() string { return randomFrom(tempAlphabet, 8) }

// NewDeviceNumber: 9 digits, never starting with 0 (not a secret).
func NewDeviceNumber() string { return randomFrom("123456789", 1) + randomFrom("0123456789", 8) }

// ValidDeviceNumber accepts 9 digits (spaces already removed).
func ValidDeviceNumber(s string) bool {
	if len(s) != 9 || s[0] == '0' {
		return false
	}
	return strings.Trim(s, "0123456789") == ""
}

// NormalizeDeviceNumber drops spaces and dashes a user may type.
func NormalizeDeviceNumber(s string) string {
	return strings.NewReplacer(" ", "", "-", "", " ", "").Replace(strings.TrimSpace(s))
}

func randomFrom(alphabet string, n int) string {
	var b strings.Builder
	max := big.NewInt(int64(len(alphabet)))
	for range n {
		k, err := rand.Int(rand.Reader, max)
		if err != nil {
			panic(err)
		}
		b.WriteByte(alphabet[k.Int64()])
	}
	return b.String()
}

// NewAttemptID is a 128-bit random id for one password attempt.
func NewAttemptID() string {
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	return b64.EncodeToString(b)
}
