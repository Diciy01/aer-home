package remote

import "testing"

func TestWindowsShadowRequiresRelayLocalApprovalAndSessionPassword(t *testing.T) {
	f := newFx(t)
	e, a := f.host(t, "Windows (TEST ONLY)", func(h *HostInfo) {
		h.Backend = "windows-shadow"
		h.OS = "windows"
		h.Address = "127.0.0.1"
		h.Approval = "prompt"
	})
	if _, err := f.svc.Create(f.ctx, NewSession{EntityID: e.ID}, ""); !refused(err, "relay_required") {
		t.Fatalf("direct route: %v", err)
	}
	client, _ := f.pairedClient(t, "Connect (TEST ONLY)", []string{e.ID}, false)
	session, err := f.svc.ClientCreate(f.ctx, client, NewSession{EntityID: e.ID}, "shadow-test")
	if err != nil {
		t.Fatal(err)
	}
	if _, err = f.svc.OnAgentEvent(f.ctx, a, session.ID, AgentEvent{Event: "ready"}); err == nil {
		t.Fatal("shadow accepted an empty session password")
	}
	row, err := f.svc.hostRow(f.ctx, e.ID)
	if err != nil {
		t.Fatal(err)
	}
	for _, mut := range []func(*HostInfo){func(h *HostInfo) { h.CertPEM = "" }, func(h *HostInfo) { h.Approval = "auto" }, func(h *HostInfo) { h.Address = "0.0.0.0" }} {
		bad := row.info
		mut(&bad)
		if _, err = f.svc.Hello(f.ctx, a, bad); err == nil {
			t.Fatal("unsafe shadow hello accepted")
		}
	}
}
