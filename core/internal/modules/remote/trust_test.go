package remote

import (
	"aerhome/core/internal/remoteengine"
	"testing"
)

func TestTrustStorageErrorsFailClosed(t *testing.T) {
	f := newFx(t)
	if err := f.svc.db.Close(); err != nil {
		t.Fatal(err)
	}
	if _, err := f.svc.trustRevision(f.ctx, "viewer", "target"); err == nil {
		t.Fatal("storage failure fell back to a policy")
	}
	if err := f.svc.sessionTrust(f.ctx, Session{State: StateConnected, TrustRevision: 1, ClientID: "viewer", EntityID: "target"}); err == nil {
		t.Fatal("storage failure allowed trusted transport")
	}
	if len(f.svc.Alive(f.ctx, []string{"session"})) != 0 {
		t.Fatal("storage failure kept tunnel alive")
	}
}

func TestTrustCompatibilityRequiresFeatureAndProof(t *testing.T) {
	f := newFx(t)
	code, err := f.svc.CreateEnrollment(f.ctx, EnrollmentInput{Name: "COMPAT TEST", MaxUses: 2})
	if err != nil {
		t.Fatal(err)
	}
	home, work := f.enroll(t, code.Code, "Home TEST", 1), f.enroll(t, code.Code, "Work TEST", 2)
	candidate, err := f.svc.TrustCandidate(f.ctx, home.cli, work.e.Number)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = f.svc.GrantTrust(f.ctx, home.cli, work.e.Number, candidate.Fingerprint); err != nil {
		t.Fatal(err)
	}
	if _, err = f.svc.SetUnattended(f.ctx, home.cli, true); err != nil {
		t.Fatal(err)
	}
	for _, test := range []struct {
		name           string
		feature, proof bool
	}{
		{"old host", false, true}, {"old client", true, false}, {"both updated", true, true},
	} {
		t.Run(test.name, func(t *testing.T) {
			features := []string{remoteengine.FeatureConnectAuth}
			if test.feature {
				features = append(features, remoteengine.FeatureConnectTrust)
			}
			f.online(t, home, 1, features...)
			a, err := remoteengine.SealPassword(remoteengine.EncodeKey(home.key.PublicKey().Bytes()), remoteengine.ConnectAuth{AttemptID: remoteengine.NewAttemptID(), ViewerNumber: work.e.Number, TargetNumber: home.e.Number}, "TEST-ONLY", f.clk.now())
			if err != nil {
				t.Fatal(err)
			}
			if test.proof {
				a, err = remoteengine.ProveIdentity(work.key, remoteengine.EncodeKey(home.key.PublicKey().Bytes()), a)
				if err != nil {
					t.Fatal(err)
				}
			}
			x, err := f.svc.create(f.ctx, NewSession{EntityID: home.e.EntityID, Kind: "desktop", ClientID: work.cli.ID, auth: &a}, "", remoteengine.RouteRelay, Caps{Desktop: true, Input: true}, nil)
			if err != nil {
				t.Fatal(err)
			}
			if (x.TrustRevision > 0) != (test.feature && test.proof) {
				t.Fatal("legacy endpoint incorrectly received unattended mode")
			}
			if _, err = f.svc.End(f.ctx, x.ID); err != nil {
				t.Fatal(err)
			}
		})
	}
}

func TestTrustPinsInstallationAndRejectsClones(t *testing.T) {
	f := newFx(t)
	code, err := f.svc.CreateEnrollment(f.ctx, EnrollmentInput{Name: "TRUST TEST", MaxUses: 3})
	if err != nil {
		t.Fatal(err)
	}
	home, work := f.enroll(t, code.Code, "Home TEST", 1), f.enroll(t, code.Code, "Work TEST", 2)
	unknown := f.enroll(t, code.Code, "Work TEST", 3) // Same name is not the same identity.
	candidate, err := f.svc.TrustCandidate(f.ctx, home.cli, work.e.Number)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = f.svc.GrantTrust(f.ctx, home.cli, work.e.Number, candidate.Fingerprint); err != nil {
		t.Fatal(err)
	}
	if revision, err := f.svc.trustRevision(f.ctx, work.cli.ID, home.e.EntityID); err != nil || revision != 0 {
		t.Fatal("default mode not manual", revision, err)
	}
	if _, err = f.svc.SetUnattended(f.ctx, home.cli, true); err != nil {
		t.Fatal(err)
	}
	if revision, err := f.svc.trustRevision(f.ctx, unknown.cli.ID, home.e.EntityID); err != nil || revision != 0 {
		t.Fatal("name/ID inferred trust", revision, err)
	}
	revision, err := f.svc.trustRevision(f.ctx, work.cli.ID, home.e.EntityID)
	if err != nil || revision == 0 {
		t.Fatal(err)
	}
	old := Session{State: StateConnected, ClientID: work.cli.ID, EntityID: home.e.EntityID, TrustRevision: revision}
	if _, err = f.svc.SetUnattended(f.ctx, home.cli, false); err != nil {
		t.Fatal(err)
	}
	if _, err = f.svc.SetUnattended(f.ctx, home.cli, true); err != nil {
		t.Fatal(err)
	}
	if err = f.svc.sessionTrust(f.ctx, old); err == nil {
		t.Fatal("toggle resurrected old authorization epoch")
	}
	revision, err = f.svc.trustRevision(f.ctx, work.cli.ID, home.e.EntityID)
	if err != nil {
		t.Fatal(err)
	}
	old.TrustRevision = revision
	f.online(t, work, 9, remoteengine.FeatureConnectAuth, remoteengine.FeatureConnectTrust)
	if err = f.svc.sessionTrust(f.ctx, old); err == nil {
		t.Fatal("cloned installation retained trusted transport")
	}
	state, err := f.svc.DeviceTrust(f.ctx, home.cli)
	if err != nil || state.Devices[0].RevokedAt == nil {
		t.Fatal("blocked installation still shown as trusted", err)
	}
}
