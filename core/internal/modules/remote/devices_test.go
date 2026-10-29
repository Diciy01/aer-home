package remote

import (
	"crypto/ecdh"
	"encoding/hex"
	"errors"
	"strings"
	"sync"
	"testing"
	"time"

	"aerhome/core/internal/modules/monitoring"
	"aerhome/core/internal/remoteengine"
)

// TEST DATA: devices, codes and passwords below are fixtures.

type dev struct {
	e     Enrolled
	key   *ecdh.PrivateKey
	agent monitoring.Agent
	cli   Client
}

func instanceOf(n byte) string {
	return hex.EncodeToString([]byte{n, n, n, n, n, n, n, n, n, n, n, n, n, n, n, n})
}

func (f *fx) enroll(t *testing.T, code, name string, inst byte) dev {
	t.Helper()
	k, _ := remoteengine.NewBoxKey()
	e, err := f.svc.Enroll(f.ctx, EnrollInput{Code: code, DeviceName: name, BoxPub: remoteengine.EncodeKey(k.PublicKey().Bytes()), Instance: instanceOf(inst)}, "198.51.100.9")
	if err != nil {
		t.Fatal(err)
	}
	a, ok := f.mon.Authenticate(f.ctx, e.AgentToken)
	if !ok || a.Kind != "remote" || a.EntityID != e.EntityID {
		t.Fatalf("agent credential: %+v %v", a, ok)
	}
	c, err := f.svc.AuthenticateClient(f.ctx, e.ClientCredential, "")
	if err != nil {
		t.Fatal(err)
	}
	return dev{e: e, key: k, agent: a, cli: c}
}

// online says hello like AER Connect's host does.
func (f *fx) online(t *testing.T, d dev, inst byte, features ...string) {
	t.Helper()
	if features == nil {
		features = []string{remoteengine.FeatureConnectAuth}
	}
	info := HostInfo{OS: "windows", Backend: "windows-shadow", Address: "127.0.0.1", Port: 33389, CertPEM: certPEM(t),
		Caps: Caps{Desktop: true, Input: true, Clipboard: true}, Approval: "prompt", Ready: true, Username: "aer",
		Features: features, Instance: instanceOf(inst)}
	if _, err := f.svc.Hello(f.ctx, d.agent, info); err != nil {
		t.Fatal(err)
	}
}

// hostVerdict plays the host: open the sealed password, answer like the agent.
func (f *fx) hostVerdict(t *testing.T, d dev, want string, wg *sync.WaitGroup) {
	wg.Add(1)
	go func() {
		defer wg.Done()
		for range 200 {
			for _, c := range f.svc.Commands(f.ctx, d.agent, 20*time.Millisecond) {
				if c.Type != "open" || c.Auth == nil {
					continue
				}
				p, err := remoteengine.OpenPassword(d.key, *c.Auth, time.Now(), time.Minute)
				ev := AgentEvent{Event: remoteengine.EventAuthOK}
				if err != nil || p != want {
					ev = AgentEvent{Event: remoteengine.EventAuthFailed, Code: remoteengine.AuthBadPassword}
				}
				if _, err := f.svc.OnAgentEvent(f.ctx, d.agent, c.SessionID, ev); err != nil {
					t.Error(err)
				}
				return
			}
		}
	}()
}

func (f *fx) try(t *testing.T, viewer dev, target dev, password string) (Session, error) {
	t.Helper()
	ch, err := f.svc.Challenge(f.ctx, viewer.cli, target.e.Number)
	if err != nil {
		return Session{}, err
	}
	sealed, err := remoteengine.SealPassword(ch.BoxPub, remoteengine.ConnectAuth{AttemptID: ch.AttemptID, ViewerNumber: ch.ViewerNumber, TargetNumber: ch.Number}, password, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	var wg sync.WaitGroup
	f.hostVerdict(t, target, "k7m2x9qp", &wg)
	defer wg.Wait()
	return f.svc.ConnectDevice(f.ctx, viewer.cli, ConnectInput{AttemptID: ch.AttemptID, EphPub: sealed.EphPub, Ciphertext: sealed.Ciphertext})
}

func TestEnrollmentCodesAndUniqueNumbers(t *testing.T) {
	f := newFx(t)
	if _, err := f.svc.CreateEnrollment(f.ctx, EnrollmentInput{Name: "x", MaxUses: 1000}); err == nil {
		t.Fatal("too many uses accepted")
	}
	code, err := f.svc.CreateEnrollment(f.ctx, EnrollmentInput{Name: "Домашние ПК (тест)", MaxUses: 3})
	if err != nil || !code.Enrollment.Active {
		t.Fatal(err)
	}
	k, _ := remoteengine.NewBoxKey()
	pub := remoteengine.EncodeKey(k.PublicKey().Bytes())
	if _, err := f.svc.Enroll(f.ctx, EnrollInput{Code: code.Code, DeviceName: "ПК", BoxPub: "AAAA", Instance: instanceOf(1)}, ""); err == nil {
		t.Fatal("bad key accepted")
	}
	if _, err := f.svc.Enroll(f.ctx, EnrollInput{Code: "AAAA-BBBB-CCCC", DeviceName: "ПК", BoxPub: pub, Instance: instanceOf(1)}, ""); !refused(err, "bad_code") {
		t.Fatalf("wrong code: %v", err)
	}
	numbers := map[string]bool{}
	for i := range 3 {
		d := f.enroll(t, strings.ToLower(code.Code), "ПК "+string(rune('A'+i)), byte(i+1))
		if !remoteengine.ValidDeviceNumber(d.e.Number) || numbers[d.e.Number] {
			t.Fatalf("number %q", d.e.Number)
		}
		numbers[d.e.Number] = true
		if !strings.HasPrefix(d.e.ClientCredential, ClientPrefix) || !strings.HasPrefix(d.e.AgentToken, "aer1.") {
			t.Fatal("credential formats")
		}
	}
	if _, err := f.svc.Enroll(f.ctx, EnrollInput{Code: code.Code, DeviceName: "Четвёртый", BoxPub: pub, Instance: instanceOf(9)}, ""); !refused(err, "bad_code") {
		t.Fatalf("used up code accepted: %v", err)
	}
	list, _ := f.svc.Enrollments(f.ctx)
	if len(list) != 1 || list[0].Uses != 3 || list[0].Active {
		t.Fatalf("enrollments %+v", list)
	}
	// Revoked codes stop at once; secrets never reach the database.
	c2, _ := f.svc.CreateEnrollment(f.ctx, EnrollmentInput{Name: "Ещё (тест)"})
	if _, err := f.svc.RevokeEnrollment(f.ctx, c2.Enrollment.ID); err != nil {
		t.Fatal(err)
	}
	if _, err := f.svc.Enroll(f.ctx, EnrollInput{Code: c2.Code, DeviceName: "ПК", BoxPub: pub, Instance: instanceOf(5)}, ""); !refused(err, "bad_code") {
		t.Fatalf("revoked code accepted: %v", err)
	}
	devs, _ := f.svc.Devices(f.ctx)
	if len(devs) != 3 || devs[0].Status != "offline" {
		t.Fatalf("devices %+v", devs)
	}
}

func TestConnectByNumberAndPassword(t *testing.T) {
	f := newFx(t)
	code, _ := f.svc.CreateEnrollment(f.ctx, EnrollmentInput{Name: "тест", MaxUses: 5})
	host, viewer := f.enroll(t, code.Code, "Домашний ПК", 1), f.enroll(t, code.Code, "Ноутбук", 2)
	if _, err := f.svc.Challenge(f.ctx, viewer.cli, host.e.Number); !refused(err, "offline") {
		t.Fatalf("offline host: %v", err)
	}
	if _, err := f.svc.Challenge(f.ctx, viewer.cli, "999999999"); !refused(err, "unknown_device") {
		t.Fatalf("unknown: %v", err)
	}
	if _, err := f.svc.Challenge(f.ctx, viewer.cli, viewer.e.Number); !refused(err, "self") {
		t.Fatalf("self: %v", err)
	}
	f.online(t, host, 1, "something-else")
	if _, err := f.svc.Challenge(f.ctx, viewer.cli, host.e.Number); !refused(err, "offline") {
		t.Fatalf("host without connect-auth: %v", err)
	}
	f.online(t, host, 1)
	// A device never takes a session without its password, even from a
	// client the owner allowed explicitly.
	if _, err := f.svc.UpdateClient(f.ctx, viewer.cli.ID, ClientInput{Name: viewer.cli.Name, Hosts: []string{host.e.EntityID}, Clipboard: true}); err != nil {
		t.Fatal(err)
	}
	cli, _ := f.svc.Client(f.ctx, viewer.cli.ID)
	if _, err := f.svc.ClientCreate(f.ctx, cli, NewSession{EntityID: host.e.EntityID}, ""); !refused(err, "device_password") {
		t.Fatalf("passwordless session to device: %v", err)
	}

	if _, err := f.try(t, viewer, host, "wrong-pass"); !refused(err, "bad_password") {
		t.Fatalf("wrong password: %v", err)
	}
	x, err := f.try(t, viewer, host, "k7m2x9qp")
	if err != nil {
		t.Fatal(err)
	}
	if x.State != StatePending || x.Route != remoteengine.RouteRelay || x.ClientID != viewer.cli.ID || !strings.Contains(x.SourceName, viewer.e.Number) {
		t.Fatalf("session %+v", x)
	}
	// The session continues on the usual client API; a second viewer is refused.
	if got, err := f.svc.ClientSession(f.ctx, viewer.cli, x.ID); err != nil || got.ID != x.ID {
		t.Fatal(err)
	}
	third := f.enroll(t, code.Code, "Третий", 3)
	if _, err := f.svc.Challenge(f.ctx, third.cli, host.e.Number); !refused(err, "busy") {
		t.Fatalf("busy: %v", err)
	}
	if _, err := f.svc.ClientSession(f.ctx, third.cli, x.ID); !errors.Is(err, ErrNotFound) {
		t.Fatal("foreign session visible")
	}
	if _, err := f.svc.End(f.ctx, x.ID); err != nil {
		t.Fatal(err)
	}
}

func TestAttemptsAreSingleUseAndBound(t *testing.T) {
	f := newFx(t)
	code, _ := f.svc.CreateEnrollment(f.ctx, EnrollmentInput{Name: "тест", MaxUses: 5})
	host, viewer, other := f.enroll(t, code.Code, "ПК", 1), f.enroll(t, code.Code, "Ноутбук", 2), f.enroll(t, code.Code, "Чужой", 3)
	f.online(t, host, 1)
	ch, err := f.svc.Challenge(f.ctx, viewer.cli, host.e.Number)
	if err != nil {
		t.Fatal(err)
	}
	sealed, _ := remoteengine.SealPassword(ch.BoxPub, remoteengine.ConnectAuth{AttemptID: ch.AttemptID, ViewerNumber: ch.ViewerNumber, TargetNumber: ch.Number}, "k7m2x9qp", time.Now())
	in := ConnectInput{AttemptID: ch.AttemptID, EphPub: sealed.EphPub, Ciphertext: sealed.Ciphertext}
	// Another client cannot redeem the attempt; it is burnt by the try.
	if _, err := f.svc.ConnectDevice(f.ctx, other.cli, in); !refused(err, "bad_attempt") {
		t.Fatalf("foreign attempt: %v", err)
	}
	if _, err := f.svc.ConnectDevice(f.ctx, viewer.cli, in); !refused(err, "bad_attempt") {
		t.Fatalf("replayed attempt: %v", err)
	}
	// An expired attempt is refused too.
	ch, _ = f.svc.Challenge(f.ctx, viewer.cli, host.e.Number)
	f.clk.add(2 * attemptTTL)
	if _, err := f.svc.ConnectDevice(f.ctx, viewer.cli, ConnectInput{AttemptID: ch.AttemptID, EphPub: sealed.EphPub, Ciphertext: sealed.Ciphertext}); !refused(err, "bad_attempt") {
		t.Fatalf("expired attempt: %v", err)
	}
	// Agent events cannot skip the password check.
	f.clk.add(-2 * attemptTTL)
}

func TestWrongPasswordLimitsAndRevocation(t *testing.T) {
	f := newFx(t)
	code, _ := f.svc.CreateEnrollment(f.ctx, EnrollmentInput{Name: "тест", MaxUses: 5})
	host, viewer, second := f.enroll(t, code.Code, "ПК", 1), f.enroll(t, code.Code, "Ноутбук", 2), f.enroll(t, code.Code, "Второй", 3)
	f.online(t, host, 1)
	for i := range pairFailLimit {
		if _, err := f.try(t, viewer, host, "guess"); !refused(err, "bad_password") {
			t.Fatalf("try %d: %v", i, err)
		}
	}
	if _, err := f.try(t, viewer, host, "k7m2x9qp"); !refused(err, "locked") {
		t.Fatalf("locked viewer got through: %v", err)
	}
	// Another viewer is not locked out by the first one.
	x, err := f.try(t, second, host, "k7m2x9qp")
	if err != nil {
		t.Fatal(err)
	}
	f.clk.add(lockFor + time.Minute)
	// Revoking the host device ends its sessions and stops its credentials.
	if _, err := f.svc.RevokeDevice(f.ctx, host.e.DeviceID); err != nil {
		t.Fatal(err)
	}
	if got, _ := f.svc.Session(f.ctx, x.ID); got.State != StateRevoked {
		t.Fatalf("session after revoke: %s", got.State)
	}
	if _, ok := f.mon.Authenticate(f.ctx, host.e.AgentToken); ok {
		t.Fatal("revoked agent credential accepted")
	}
	if _, err := f.svc.AuthenticateClient(f.ctx, host.e.ClientCredential, ""); err == nil {
		t.Fatal("revoked client credential accepted")
	}
	if _, err := f.svc.Challenge(f.ctx, viewer.cli, host.e.Number); !refused(err, "device_revoked") {
		t.Fatalf("revoked target: %v", err)
	}
}

func TestClonedInstallationIsBlocked(t *testing.T) {
	f := newFx(t)
	code, _ := f.svc.CreateEnrollment(f.ctx, EnrollmentInput{Name: "тест", MaxUses: 5})
	host, viewer := f.enroll(t, code.Code, "ПК", 1), f.enroll(t, code.Code, "Ноутбук", 2)
	f.online(t, host, 1)
	f.online(t, host, 1) // same instance again: fine
	if _, err := f.svc.Challenge(f.ctx, viewer.cli, host.e.Number); err != nil {
		t.Fatal(err)
	}
	f.online(t, host, 7) // the same credential from a copied installation
	if _, err := f.svc.Challenge(f.ctx, viewer.cli, host.e.Number); !refused(err, "device_conflict") {
		t.Fatalf("clone accepted: %v", err)
	}
	h, _ := f.svc.Host(f.ctx, host.e.EntityID)
	if h.CanConnect {
		t.Fatal("conflicting device offered for connection")
	}
	devs, _ := f.svc.Devices(f.ctx)
	for _, d := range devs {
		if d.ID == host.e.DeviceID && d.Status != "conflict" {
			t.Fatalf("status %s", d.Status)
		}
	}
}

func TestAgentCannotSkipPasswordCheck(t *testing.T) {
	f := newFx(t)
	code, _ := f.svc.CreateEnrollment(f.ctx, EnrollmentInput{Name: "тест", MaxUses: 5})
	host, viewer := f.enroll(t, code.Code, "ПК", 1), f.enroll(t, code.Code, "Ноутбук", 2)
	f.online(t, host, 1)
	ch, _ := f.svc.Challenge(f.ctx, viewer.cli, host.e.Number)
	sealed, _ := remoteengine.SealPassword(ch.BoxPub, remoteengine.ConnectAuth{AttemptID: ch.AttemptID, ViewerNumber: ch.ViewerNumber, TargetNumber: ch.Number}, "x", time.Now())
	done := make(chan error, 1)
	go func() {
		_, err := f.svc.ConnectDevice(f.ctx, viewer.cli, ConnectInput{AttemptID: ch.AttemptID, EphPub: sealed.EphPub, Ciphertext: sealed.Ciphertext})
		done <- err
	}()
	var sid string
	waitFor(t, func() bool {
		for _, c := range f.svc.Commands(f.ctx, host.agent, 10*time.Millisecond) {
			sid = c.SessionID
		}
		return sid != ""
	})
	for _, ev := range []string{"awaiting_approval", "approved", "ready"} {
		if _, err := f.svc.OnAgentEvent(f.ctx, host.agent, sid, AgentEvent{Event: ev, Password: "p"}); !refused(err, "auth_required") {
			t.Fatalf("%s before auth: %v", ev, err)
		}
	}
	if _, err := f.svc.OnAgentEvent(f.ctx, host.agent, sid, AgentEvent{Event: remoteengine.EventAuthFailed, Code: remoteengine.AuthBadPassword}); err != nil {
		t.Fatal(err)
	}
	if err := <-done; !refused(err, "bad_password") {
		t.Fatalf("verdict: %v", err)
	}
	if _, err := f.svc.OnAgentEvent(f.ctx, host.agent, sid, AgentEvent{Event: remoteengine.EventAuthOK}); err == nil {
		t.Fatal("second verdict accepted")
	}
}

func waitFor(t *testing.T, cond func() bool) {
	t.Helper()
	for range 300 {
		if cond() {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("timeout")
}

func TestParallelConnectsOneSessionWins(t *testing.T) {
	f := newFx(t)
	code, _ := f.svc.CreateEnrollment(f.ctx, EnrollmentInput{Name: "тест", MaxUses: 10})
	host := f.enroll(t, code.Code, "ПК", 1)
	f.online(t, host, 1)
	var viewers []dev
	for i := range 6 {
		viewers = append(viewers, f.enroll(t, code.Code, "Зритель", byte(10+i)))
	}
	// The host answers every attempt with the right password.
	stop := make(chan struct{})
	go func() {
		for {
			select {
			case <-stop:
				return
			default:
			}
			for _, c := range f.svc.Commands(f.ctx, host.agent, 20*time.Millisecond) {
				if c.Auth != nil {
					_, _ = f.svc.OnAgentEvent(f.ctx, host.agent, c.SessionID, AgentEvent{Event: remoteengine.EventAuthOK})
				}
			}
		}
	}()
	defer close(stop)
	var mu sync.Mutex
	won, busy := 0, 0
	var wg sync.WaitGroup
	for _, v := range viewers {
		wg.Add(1)
		go func() {
			defer wg.Done()
			ch, err := f.svc.Challenge(f.ctx, v.cli, host.e.Number)
			if err != nil {
				mu.Lock()
				busy++
				mu.Unlock()
				return
			}
			s, _ := remoteengine.SealPassword(ch.BoxPub, remoteengine.ConnectAuth{AttemptID: ch.AttemptID, ViewerNumber: ch.ViewerNumber, TargetNumber: ch.Number}, "k7m2x9qp", time.Now())
			_, err = f.svc.ConnectDevice(f.ctx, v.cli, ConnectInput{AttemptID: ch.AttemptID, EphPub: s.EphPub, Ciphertext: s.Ciphertext})
			mu.Lock()
			defer mu.Unlock()
			switch {
			case err == nil:
				won++
			case refused(err, "busy"):
				busy++
			default:
				t.Errorf("unexpected: %v", err)
			}
		}()
	}
	wg.Wait()
	if won != 1 || busy != len(viewers)-1 {
		t.Fatalf("won %d busy %d", won, busy)
	}
}
