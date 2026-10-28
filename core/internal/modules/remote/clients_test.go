package remote

import (
	"errors"
	"os"
	"strings"
	"testing"
	"time"

	"aerhome/core/internal/remoteengine"
)

// TEST DATA: clients, codes and credentials below are fixtures.

func (f *fx) pairedClient(t *testing.T, name string, hosts []string, files bool) (Client, string) {
	t.Helper()
	p, err := f.svc.CreateClient(f.ctx, ClientInput{Name: name, Hosts: hosts, Clipboard: true, Files: files})
	if err != nil {
		t.Fatal(err)
	}
	got, err := f.svc.Pair(f.ctx, strings.ToLower(p.Code), "Рабочий ПК (тест)", "198.51.100.7")
	if err != nil {
		t.Fatal(err)
	}
	c, err := f.svc.AuthenticateClient(f.ctx, got.Credential, "198.51.100.7")
	if err != nil {
		t.Fatal(err)
	}
	return c, got.Credential
}

func TestClientPairingOnce(t *testing.T) {
	f := newFx(t)
	e, _ := f.host(t, "ПК (тест)")
	if _, err := f.svc.CreateClient(f.ctx, ClientInput{Name: " ", Hosts: []string{e.ID}}); err == nil {
		t.Fatal("empty name accepted")
	}
	if _, err := f.svc.CreateClient(f.ctx, ClientInput{Name: "X", Hosts: []string{"no-such-host"}}); err == nil {
		t.Fatal("unknown host accepted")
	}
	p, err := f.svc.CreateClient(f.ctx, ClientInput{Name: "Рабочий ноутбук (тест)", Hosts: []string{e.ID, e.ID}})
	if err != nil || len(p.Code) != 14 || p.Client.Paired || !p.Client.PairPending || len(p.Client.Hosts) != 1 {
		t.Fatalf("create: %+v %v", p, err)
	}
	if _, err := f.svc.Pair(f.ctx, "AAAA-BBBB-CCCC", "", ""); !refused(err, "bad_code") {
		t.Fatalf("wrong code: %v", err)
	}
	got, err := f.svc.Pair(f.ctx, " "+strings.ReplaceAll(p.Code, "-", " ")+" ", "dev", "")
	if err != nil || !strings.HasPrefix(got.Credential, ClientPrefix+p.Client.ID+".") {
		t.Fatalf("pair: %+v %v", got, err)
	}
	if _, err := f.svc.Pair(f.ctx, p.Code, "dev", ""); !refused(err, "bad_code") {
		t.Fatalf("code reused: %v", err)
	}
	c, _ := f.svc.Client(f.ctx, p.Client.ID)
	if !c.Paired || c.PairPending || c.DeviceName != "dev" {
		t.Fatalf("after pairing: %+v", c)
	}
	// Expired code.
	p2, _ := f.svc.CreateClient(f.ctx, ClientInput{Name: "Поздний (тест)"})
	f.clk.add(pairTTL + time.Second)
	if _, err := f.svc.Pair(f.ctx, p2.Code, "", ""); !refused(err, "bad_code") {
		t.Fatalf("expired code: %v", err)
	}
	// Re-pairing replaces the credential.
	rp, err := f.svc.RepairClient(f.ctx, c.ID)
	if err != nil {
		t.Fatal(err)
	}
	got2, err := f.svc.Pair(f.ctx, rp.Code, "new", "")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := f.svc.AuthenticateClient(f.ctx, got.Credential, ""); err == nil {
		t.Fatal("old credential still works after re-pairing")
	}
	if _, err := f.svc.AuthenticateClient(f.ctx, got2.Credential, ""); err != nil {
		t.Fatal(err)
	}
	raw, _ := os.ReadFile(f.dbPath)
	wal, _ := os.ReadFile(f.dbPath + "-wal")
	sec := strings.SplitN(got2.Credential, ".", 3)[2]
	if strings.Contains(string(raw)+string(wal), sec) || strings.Contains(string(raw)+string(wal), strings.ReplaceAll(rp.Code, "-", "")) {
		t.Fatal("credential or pairing code stored in clear")
	}
}

func TestClientAuthLockoutAndRevoke(t *testing.T) {
	f := newFx(t)
	e, a := f.host(t, "ПК (тест)")
	c, cred := f.pairedClient(t, "Ноутбук (тест)", []string{e.ID}, false)
	x, err := f.svc.ClientCreate(f.ctx, c, NewSession{EntityID: e.ID}, "")
	if err != nil {
		t.Fatal(err)
	}
	f.cmds(a)
	for _, bad := range []string{"", "Bearer x", "aerc1.", "aerc1.zzz." + strings.Repeat("0", 64), cred[:len(cred)-1] + "x", "aer1." + c.ID + "." + strings.Repeat("0", 64)} {
		if _, err := f.svc.AuthenticateClient(f.ctx, bad, ""); !errors.Is(err, ErrClientAuth) {
			t.Fatalf("%q accepted: %v", bad, err)
		}
	}
	wrong := ClientPrefix + c.ID + "." + strings.Repeat("ab", 32)
	for range maxFails - 2 { // one failure above already counted
		_, _ = f.svc.AuthenticateClient(f.ctx, wrong, "")
	}
	if _, err := f.svc.AuthenticateClient(f.ctx, cred, ""); err != nil {
		t.Fatalf("locked too early: %v", err)
	}
	_, _ = f.svc.AuthenticateClient(f.ctx, wrong, "")
	if _, err := f.svc.AuthenticateClient(f.ctx, cred, ""); !errors.Is(err, ErrClientAuth) {
		t.Fatal("not locked after repeated failures")
	}
	f.clk.add(lockFor + time.Second)
	if _, err := f.svc.AuthenticateClient(f.ctx, cred, ""); err != nil {
		t.Fatalf("lock must expire: %v", err)
	}

	if _, err := f.svc.RevokeClient(f.ctx, c.ID); err != nil {
		t.Fatal(err)
	}
	if x, _ = f.svc.Session(f.ctx, x.ID); x.State != StateRevoked {
		t.Fatalf("session of a revoked client: %s", x.State)
	}
	if cm := f.cmds(a); len(cm) != 1 || cm[0].Type != "close" {
		t.Fatalf("host must close: %+v", cm)
	}
	if _, err := f.svc.AuthenticateClient(f.ctx, cred, ""); !errors.Is(err, ErrClientAuth) {
		t.Fatal("revoked client accepted")
	}
	if _, err := f.svc.RepairClient(f.ctx, c.ID); !refused(err, "revoked") {
		t.Fatal("revoked client re-paired")
	}
}

func TestRelaySessionTicketsAndIsolation(t *testing.T) {
	f := newFx(t)
	e, a := f.host(t, "ПК (тест)")
	other, _ := f.host(t, "Чужой ПК (тест)")
	if _, err := f.svc.SetPolicy(f.ctx, e.ID, Policy{Enabled: true, Desktop: true, Clipboard: true, Files: true, MaxMinutes: 60}); err != nil {
		t.Fatal(err)
	}
	c, _ := f.pairedClient(t, "Ноутбук (тест)", []string{e.ID}, true)
	noFiles, _ := f.pairedClient(t, "Без файлов (тест)", []string{e.ID}, false)

	if _, err := f.svc.ClientCreate(f.ctx, c, NewSession{EntityID: other.ID}, ""); !errors.Is(err, ErrNotFound) {
		t.Fatalf("host outside the client's list: %v", err)
	}
	hosts, _ := f.svc.ClientHosts(f.ctx, c)
	if len(hosts) != 1 || hosts[0].Agent.Address != "" || hosts[0].Agent.CertPEM != "" || !hosts[0].CanConnect {
		t.Fatalf("client view leaks LAN data: %+v", hosts)
	}

	x, err := f.svc.ClientCreate(f.ctx, c, NewSession{EntityID: e.ID}, "k1")
	if err != nil || x.Route != remoteengine.RouteRelay || x.ClientID != c.ID || x.SourceName != c.Name || !x.Allowed.Files {
		t.Fatalf("relay session: %+v %v", x, err)
	}
	if y, _ := f.svc.ClientCreate(f.ctx, noFiles, NewSession{EntityID: e.ID}, "k1"); y.ID == x.ID {
		t.Fatal("idempotency keys of different clients collide")
	}
	cm := f.cmds(a)
	if len(cm) != 1 || !cm[0].Relay {
		t.Fatalf("relay open: %+v", cm)
	}
	if _, err := f.svc.ClientTicket(f.ctx, c, x.ID, "rdp"); !refused(err, "not_granted") {
		t.Fatalf("ticket before grant: %v", err)
	}
	if _, err := f.svc.Grant(f.ctx, x.ID); !refused(err, "relay") {
		t.Fatalf("owner grant of a relay session: %v", err)
	}
	if _, err := f.svc.ClientSession(f.ctx, noFiles, x.ID); !errors.Is(err, ErrNotFound) {
		t.Fatal("another client sees the session")
	}
	if _, err := f.svc.HostLeg(f.ctx, e.ID, x.ID, "rdp"); !refused(err, "not_ready") {
		t.Fatalf("host leg before ready: %v", err)
	}
	f.svc.OnAgentEvent(f.ctx, a, x.ID, AgentEvent{Event: "ready", Password: "Relay-Pass-TEST", FilesToken: "ft-test"})
	if _, err := f.svc.ClientGrant(f.ctx, noFiles, x.ID); !errors.Is(err, ErrNotFound) {
		t.Fatal("another client got the grant")
	}
	g, err := f.svc.ClientGrant(f.ctx, c, x.ID)
	if err != nil || g.Route != "relay" || g.Host != "" || g.Port != 0 || g.Files == nil || g.Files.URL != "" || g.Tunnel == nil ||
		g.Tunnel.Path != TunnelPath || len(g.Tunnel.Tickets) != 2 || g.Password != "Relay-Pass-TEST" {
		t.Fatalf("relay grant: %+v %v", g, err)
	}
	if _, err := f.svc.ClientGrant(f.ctx, c, x.ID); !refused(err, "already_granted") {
		t.Fatal("grant twice")
	}
	rdp := g.Tunnel.Tickets["rdp"]
	if _, err := f.svc.ClaimTicket(f.ctx, noFiles, rdp); !refused(err, "bad_ticket") {
		t.Fatal("ticket of another client accepted")
	}
	if _, err := f.svc.ClaimTicket(f.ctx, c, rdp); !refused(err, "bad_ticket") {
		t.Fatal("a refused claim must burn the ticket")
	}
	files := g.Tunnel.Tickets["files"]
	cl, err := f.svc.ClaimTicket(f.ctx, c, files)
	if err != nil || cl.SessionID != x.ID || cl.Channel != "files" || cl.EntityID != e.ID {
		t.Fatalf("claim: %+v %v", cl, err)
	}
	if _, err := f.svc.ClaimTicket(f.ctx, c, files); !refused(err, "bad_ticket") {
		t.Fatal("ticket replayed")
	}
	t2, err := f.svc.ClientTicket(f.ctx, c, x.ID, "rdp")
	if err != nil {
		t.Fatal(err)
	}
	f.clk.add(time.Duration(f.svc.cfg.GrantTTLSec+1) * time.Second)
	if _, err := f.svc.ClaimTicket(f.ctx, c, t2); !refused(err, "bad_ticket") {
		t.Fatal("expired ticket accepted")
	}
	if _, err := f.svc.HostLeg(f.ctx, other.ID, x.ID, "rdp"); !refused(err, "foreign") {
		t.Fatalf("host leg of another host: %v", err)
	}
	if _, err := f.svc.HostLeg(f.ctx, e.ID, x.ID, "ssh"); !refused(err, "not_relay") {
		t.Fatalf("unknown channel: %v", err)
	}
	if _, err := f.svc.HostLeg(f.ctx, e.ID, x.ID, "rdp"); err != nil {
		t.Fatal(err)
	}
	if got := f.svc.Alive(f.ctx, []string{x.ID, "nope"}); len(got) != 1 {
		t.Fatalf("alive: %v", got)
	}
	t3, _ := f.svc.ClientTicket(f.ctx, c, x.ID, "rdp")
	if _, err := f.svc.ClientEnd(f.ctx, c, x.ID); err != nil {
		t.Fatal(err)
	}
	if _, err := f.svc.ClaimTicket(f.ctx, c, t3); !refused(err, "bad_ticket") {
		t.Fatal("ticket of an ended session accepted")
	}
	if got := f.svc.Alive(f.ctx, []string{x.ID}); len(got) != 0 {
		t.Fatal("ended session alive")
	}
	if _, err := f.svc.HostLeg(f.ctx, e.ID, x.ID, "rdp"); !refused(err, "not_ready") {
		t.Fatal("host leg of an ended session")
	}

	// A client without file rights never gets a files channel.
	y, err := f.svc.ClientCreate(f.ctx, noFiles, NewSession{EntityID: e.ID}, "")
	if err != nil || y.Allowed.Files {
		t.Fatalf("files must be narrowed: %+v %v", y, err)
	}
	f.svc.OnAgentEvent(f.ctx, a, y.ID, AgentEvent{Event: "ready", Password: "P-TEST"})
	g2, _ := f.svc.ClientGrant(f.ctx, noFiles, y.ID)
	if g2.Files != nil || len(g2.Tunnel.Tickets) != 1 {
		t.Fatalf("files leaked: %+v", g2)
	}
	if _, err := f.svc.ClientTicket(f.ctx, noFiles, y.ID, "files"); !refused(err, "files_denied") {
		t.Fatal("files ticket without permission")
	}
	if _, err := f.svc.HostLeg(f.ctx, e.ID, y.ID, "files"); !refused(err, "files_denied") {
		t.Fatal("files host leg without permission")
	}
}

func TestTicketLimit(t *testing.T) {
	f := newFx(t)
	e, a := f.host(t, "ПК (тест)")
	c, _ := f.pairedClient(t, "Ноутбук (тест)", []string{e.ID}, false)
	x, _ := f.svc.ClientCreate(f.ctx, c, NewSession{EntityID: e.ID}, "")
	f.svc.OnAgentEvent(f.ctx, a, x.ID, AgentEvent{Event: "ready", Password: "P-TEST"})
	if _, err := f.svc.ClientGrant(f.ctx, c, x.ID); err != nil {
		t.Fatal(err)
	}
	var err error
	for i := 0; i < maxTicketsPerSes && err == nil; i++ {
		_, err = f.svc.ClientTicket(f.ctx, c, x.ID, "rdp")
	}
	if !refused(err, "ticket_limit") {
		t.Fatalf("no limit on reconnect tickets: %v", err)
	}
}
