// Package connecthost is the host side of AER Connect Anywhere (ADR-018):
// the device's password guard and the runtime that the AER Connect app
// starts as a child process. The app holds the device secrets in its
// DPAPI store and hands them over an anonymous pipe; this process keeps
// them in memory only, never on disk or in logs.
package connecthost

import (
	"crypto/ecdh"
	"crypto/subtle"
	"slices"
	"sync"
	"time"

	"aerhome/core/internal/remoteengine"
)

const (
	guardFailLimit  = 5
	guardFailWindow = 10 * time.Minute
	guardLockFor    = 15 * time.Minute
	sealMaxAge      = 15 * time.Minute // viewer and host clocks may differ
	seenKeep        = 30 * time.Minute
)

// Guard checks password attempts addressed to this device. It accepts the
// current temporary password or, when the user enabled one, the permanent
// password. Both checks run for every attempt (no timing hint which one
// exists). After guardFailLimit wrong attempts it refuses everything for
// guardLockFor, and every attempt id is accepted once only.
type Guard struct {
	key    *ecdh.PrivateKey
	number string
	now    func() time.Time

	mu        sync.Mutex
	temp      string
	permanent *remoteengine.Verifier
	incoming  bool
	fails     []time.Time
	locked    time.Time
	seen      map[string]time.Time
	usedTemp  bool
}

// NewGuard builds the guard with a fresh temporary password.
func NewGuard(key *ecdh.PrivateKey, number string, permanent *remoteengine.Verifier, incoming bool) *Guard {
	g := &Guard{key: key, number: number, now: time.Now, temp: remoteengine.NewTempPassword(), incoming: incoming,
		seen: map[string]time.Time{}}
	if permanent != nil && permanent.Valid() {
		p := *permanent
		g.permanent = &p
	}
	return g
}

// Verify implements remotehost.Authenticator.
func (g *Guard) Verify(a remoteengine.ConnectAuth) (bool, string) {
	now := g.now()
	g.mu.Lock()
	for k, t := range g.seen {
		if now.Sub(t) > seenKeep {
			delete(g.seen, k)
		}
	}
	switch {
	case !g.incoming:
		g.mu.Unlock()
		return false, remoteengine.AuthDisabled
	case now.Before(g.locked):
		g.mu.Unlock()
		return false, remoteengine.AuthLocked
	case a.TargetNumber != g.number:
		g.mu.Unlock()
		return false, remoteengine.AuthMalformed
	}
	if _, dup := g.seen[a.AttemptID]; dup || a.AttemptID == "" {
		g.mu.Unlock()
		return false, remoteengine.AuthReplay
	}
	g.seen[a.AttemptID] = now
	temp, perm := g.temp, g.permanent
	g.mu.Unlock()

	password, err := remoteengine.OpenPassword(g.key, a, now, sealMaxAge)
	tempOK := err == nil && subtle.ConstantTimeCompare([]byte(password), []byte(temp)) == 1
	permOK := false
	if perm != nil {
		permOK = perm.Check(password) && err == nil
	}

	g.mu.Lock()
	defer g.mu.Unlock()
	if tempOK || permOK {
		g.fails = nil
		if tempOK {
			g.usedTemp = true // a new temporary password after this session
		}
		return true, ""
	}
	g.fails = append(slices.DeleteFunc(g.fails, func(t time.Time) bool { return now.Sub(t) > guardFailWindow }), now)
	if len(g.fails) >= guardFailLimit {
		g.locked, g.fails = now.Add(guardLockFor), nil
		g.temp = remoteengine.NewTempPassword() // whatever was guessed is gone
	}
	if err != nil {
		return false, remoteengine.AuthMalformed
	}
	return false, remoteengine.AuthBadPassword
}

// Rotate replaces the temporary password and returns the new one.
func (g *Guard) Rotate() string {
	g.mu.Lock()
	defer g.mu.Unlock()
	g.temp, g.usedTemp = remoteengine.NewTempPassword(), false
	return g.temp
}

// RotateIfUsed changes the temporary password once a session that used it
// has ended (one-time access).
func (g *Guard) RotateIfUsed() bool {
	g.mu.Lock()
	defer g.mu.Unlock()
	if !g.usedTemp {
		return false
	}
	g.temp, g.usedTemp = remoteengine.NewTempPassword(), false
	return true
}

// Temp is the current temporary password (shown on this computer only).
func (g *Guard) Temp() string {
	g.mu.Lock()
	defer g.mu.Unlock()
	return g.temp
}

// SetPermanent installs a verifier (nil disables the permanent password).
func (g *Guard) SetPermanent(v *remoteengine.Verifier) {
	g.mu.Lock()
	defer g.mu.Unlock()
	if v == nil {
		g.permanent = nil
		return
	}
	p := *v
	g.permanent = &p
}

// SetIncoming allows or refuses incoming sessions.
func (g *Guard) SetIncoming(on bool) {
	g.mu.Lock()
	defer g.mu.Unlock()
	g.incoming = on
}

// State for the UI.
func (g *Guard) State() (permanent, incoming bool, lockedUntil *time.Time) {
	g.mu.Lock()
	defer g.mu.Unlock()
	if g.now().Before(g.locked) {
		t := g.locked.UTC()
		lockedUntil = &t
	}
	return g.permanent != nil, g.incoming, lockedUntil
}
