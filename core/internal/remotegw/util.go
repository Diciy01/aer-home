package remotegw

import (
	"bytes"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"io"
	"math/big"
	"os"
	"path/filepath"
	"sync"
	"time"
)

func bytesReader(b []byte) io.Reader { return bytes.NewReader(b) }

// EnsureCert fills TLSCert/TLSKey with a self-signed ECDSA P-256 pair in
// StateDir when none is configured (created once, reused afterwards).
func EnsureCert(c *Config) error {
	if c.TLSCert != "" {
		return nil
	}
	c.TLSCert, c.TLSKey = filepath.Join(c.StateDir, "gateway-tls.crt"), filepath.Join(c.StateDir, "gateway-tls.key")
	if _, err := os.Stat(c.TLSCert); err == nil {
		return nil
	}
	if err := os.MkdirAll(c.StateDir, 0o700); err != nil {
		return err
	}
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return err
	}
	serial, _ := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 120))
	tpl := &x509.Certificate{SerialNumber: serial, Subject: pkix.Name{CommonName: "AER Remote Gateway"},
		NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().AddDate(5, 0, 0),
		KeyUsage: x509.KeyUsageDigitalSignature, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}}
	der, err := x509.CreateCertificate(rand.Reader, tpl, tpl, &key.PublicKey, key)
	if err != nil {
		return err
	}
	kd, err := x509.MarshalECPrivateKey(key)
	if err != nil {
		return err
	}
	if err := os.WriteFile(c.TLSKey, pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: kd}), 0o600); err != nil {
		return err
	}
	return os.WriteFile(c.TLSCert, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}), 0o644)
}

// limiter counts failures per address and bans an address that failed
// too often; separately it caps pairing attempts per address.
type limiter struct {
	mu         sync.Mutex
	now        func() time.Time
	limit      int
	window     time.Duration
	ban        time.Duration
	pairs      int
	fails      map[string][]time.Time
	banned     map[string]time.Time
	paired     map[string][]time.Time
	registered map[string][]time.Time
}

func newLimiter(c Config, now func() time.Time) *limiter {
	return &limiter{now: now, limit: c.AuthFailLimit, window: time.Duration(c.AuthFailWindowSec) * time.Second,
		ban: time.Duration(c.BanSec) * time.Second, pairs: c.PairLimit,
		fails: map[string][]time.Time{}, banned: map[string]time.Time{}, paired: map[string][]time.Time{}, registered: map[string][]time.Time{}}
}

func recent(ts []time.Time, now time.Time, w time.Duration) []time.Time {
	out := ts[:0]
	for _, t := range ts {
		if now.Sub(t) <= w {
			out = append(out, t)
		}
	}
	return out
}

// Banned reports whether the address is currently banned.
func (l *limiter) Banned(addr string) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	until, ok := l.banned[addr]
	if ok && l.now().After(until) {
		delete(l.banned, addr)
		return false
	}
	return ok
}

// Fail records a failed authentication; true when the address got banned.
func (l *limiter) Fail(addr string) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	now := l.now()
	f := append(recent(l.fails[addr], now, l.window), now)
	if len(f) >= l.limit {
		delete(l.fails, addr)
		l.banned[addr] = now.Add(l.ban)
		return true
	}
	l.fails[addr] = f
	return false
}

// Pair takes one pairing attempt; false when the address used them up.
func (l *limiter) Pair(addr string) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	now := l.now()
	p := recent(l.paired[addr], now, l.window)
	if len(p) >= l.pairs {
		l.paired[addr] = p
		return false
	}
	l.paired[addr] = append(p, now)
	return true
}

// Polling must not consume the much smaller one-shot pairing budget.
func (l *limiter) Registration(addr string) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	now := l.now()
	p := recent(l.registered[addr], now, time.Minute)
	if len(p) >= 60 {
		l.registered[addr] = p
		return false
	}
	l.registered[addr] = append(p, now)
	return true
}

// gc drops stale entries (called by the maintenance loop).
func (l *limiter) gc() {
	l.mu.Lock()
	defer l.mu.Unlock()
	now := l.now()
	for k, v := range l.registered {
		if v = recent(v, now, time.Minute); len(v) == 0 {
			delete(l.registered, k)
		} else {
			l.registered[k] = v
		}
	}
	for k, v := range l.fails {
		if v = recent(v, now, l.window); len(v) == 0 {
			delete(l.fails, k)
		} else {
			l.fails[k] = v
		}
	}
	for k, v := range l.paired {
		if v = recent(v, now, l.window); len(v) == 0 {
			delete(l.paired, k)
		} else {
			l.paired[k] = v
		}
	}
	for k, until := range l.banned {
		if now.After(until) {
			delete(l.banned, k)
		}
	}
}
