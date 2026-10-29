package remote

import (
	"encoding/json"
	"testing"
	"time"

	"aerhome/core/internal/remoteengine"
)

func TestAutomaticRegistrationLifecycle(t *testing.T) {
	f := newFx(t)
	key, _ := remoteengine.NewBoxKey()
	in := RegistrationInput{DeviceName: "AUTO TEST", BoxPub: remoteengine.EncodeKey(key.PublicKey().Bytes()), Instance: instanceOf(1)}
	first, err := f.svc.Registration(f.ctx, in, "127.0.0.1")
	if err != nil || first.Status != "verifying" || first.Box == nil {
		t.Fatalf("challenge: %+v %v", first, err)
	}
	if _, err = f.svc.DecideRegistration(f.ctx, first.ID, true); err == nil {
		t.Fatal("owner approved an unverified public key")
	}
	if list, err := f.svc.Registrations(f.ctx); err != nil || len(list) != 0 {
		t.Fatalf("unverified listed: %+v %v", list, err)
	}
	proof, err := remoteengine.OpenRegistration(key, first.ID, in.Instance, *first.Box)
	if err != nil {
		t.Fatal(err)
	}
	in.Proof = "FORGED"
	if _, err = f.svc.Registration(f.ctx, in, "127.0.0.1"); err == nil {
		t.Fatal("forged possession accepted")
	}
	in.Proof = string(proof)
	pending, err := f.svc.Registration(f.ctx, in, "127.0.0.1")
	if err != nil || pending.Status != "pending" || pending.Box != nil {
		t.Fatalf("pending: %+v %v", pending, err)
	}
	if list, err := f.svc.Devices(f.ctx); err != nil || len(list) != 0 {
		t.Fatal("credentials issued before owner consent")
	}
	requests, err := f.svc.Registrations(f.ctx)
	if err != nil || len(requests) != 1 || len(requests[0].Fingerprint) != 64 {
		t.Fatalf("owner list: %+v %v", requests, err)
	}
	if _, err = f.svc.DecideRegistration(f.ctx, first.ID, true); err != nil {
		t.Fatal(err)
	}
	// A fresh service on the persisted DB can recover the same sealed answer.
	f.svc = NewService(f.svc.db, f.reg, f.mon, f.svc.cfg, nil, f.clk.now)
	approved, err := f.svc.Registration(f.ctx, in, "127.0.0.1")
	if err != nil || approved.Status != "approved" || approved.Box == nil {
		t.Fatalf("restart: %+v %v", approved, err)
	}
	plain, err := remoteengine.OpenRegistration(key, approved.ID, in.Instance, *approved.Box)
	if err != nil {
		t.Fatal(err)
	}
	var e Enrolled
	if err = json.Unmarshal(plain, &e); err != nil {
		t.Fatal(err)
	}
	if _, err = f.svc.AuthenticateClient(f.ctx, e.ClientCredential, ""); err != nil {
		t.Fatal(err)
	}
	if _, ok := f.mon.Authenticate(f.ctx, e.AgentToken); !ok {
		t.Fatal("agent credential rejected")
	}
	again, _ := f.svc.Registration(f.ctx, in, "127.0.0.1")
	if *again.Box != *approved.Box {
		t.Fatal("retry rotated credentials")
	}
	forged := in
	forged.Instance = instanceOf(2)
	if _, err = f.svc.Registration(f.ctx, forged, "127.0.0.1"); err == nil {
		t.Fatal("copied public identity accepted on another machine")
	}
	if _, err = f.svc.DecideRegistration(f.ctx, first.ID, true); err == nil {
		t.Fatal("approval replay reissued credentials")
	}
	if _, err = f.svc.RevokeDevice(f.ctx, e.DeviceID); err != nil {
		t.Fatal(err)
	}
	revoked, err := f.svc.Registration(f.ctx, in, "127.0.0.1")
	if err != nil || revoked.Status != "revoked" || revoked.Box != nil {
		t.Fatalf("revocation recovery: %+v %v", revoked, err)
	}
	if _, err = f.svc.AuthenticateClient(f.ctx, e.ClientCredential, ""); err == nil {
		t.Fatal("old credential revived")
	}
}

func TestAutomaticRegistrationRejectionExpiryAndStorage(t *testing.T) {
	for _, scenario := range []string{"reject", "expire", "storage"} {
		t.Run(scenario, func(t *testing.T) {
			f := newFx(t)
			key, _ := remoteengine.NewBoxKey()
			in := RegistrationInput{DeviceName: "TEST", BoxPub: remoteengine.EncodeKey(key.PublicKey().Bytes()), Instance: instanceOf(1)}
			first, err := f.svc.Registration(f.ctx, in, "127.0.0.1")
			if err != nil {
				t.Fatal(err)
			}
			p, err := remoteengine.OpenRegistration(key, first.ID, in.Instance, *first.Box)
			if err != nil {
				t.Fatal(err)
			}
			in.Proof = string(p)
			if _, err = f.svc.Registration(f.ctx, in, "127.0.0.1"); err != nil {
				t.Fatal(err)
			}
			switch scenario {
			case "reject":
				if _, err = f.svc.DecideRegistration(f.ctx, first.ID, false); err != nil {
					t.Fatal(err)
				}
				r, err := f.svc.Registration(f.ctx, in, "127.0.0.1")
				if err != nil || r.Status != "rejected" || r.Box != nil {
					t.Fatal("rejection bypassed")
				}
			case "expire":
				f.clk.add(25 * time.Hour)
				if _, err = f.svc.DecideRegistration(f.ctx, first.ID, true); err == nil {
					t.Fatal("expired approval accepted")
				}
				if _, err = f.svc.Registration(f.ctx, in, "127.0.0.1"); err == nil {
					t.Fatal("expired request accepted")
				}
			case "storage":
				_ = f.svc.db.Close()
				if _, err = f.svc.Registration(f.ctx, in, "127.0.0.1"); err == nil {
					t.Fatal("storage failure bypassed registration")
				}
			}
		})
	}
}
