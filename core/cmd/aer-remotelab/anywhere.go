package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"aerhome/core/internal/connecthost"
	"aerhome/core/internal/remoteengine"
	"aerhome/core/internal/remotehost"
)

// -anywhere (ADR-018): the stand also issues an enrollment code and runs
// one AER Connect host DEVICE through the real connecthost runtime, enrolled
// through the Gateway like the app does. Its desktop is the stand's FAKE
// RDP service or, with -shadow, the SYNTHETIC native source. Consent is
// answered by this TEST-ONLY binary; the production host never does that.
var anywhere = flag.Bool("anywhere", false, "also run an AER Connect host device (ID + password) and print its number and temporary password")

type labDevice struct {
	number, password, enrollCode string
	// passwordFile always holds the current temporary password (TEST ONLY:
	// the stand's own temp dir), as tests need it after each rotation.
	passwordFile string
	stdin                        io.WriteCloser
	done                         chan error
}

func runAnywhere(ctx context.Context, dir, gwURL, fp string, api func(method, path, body string, out any) error,
	rdpPort int, connections func() int, shadowExe, daemon string) (*labDevice, error) {
	var en struct{ Code string }
	if err := api("POST", "/remote/enrollments", `{"name":"AER Connect (стенд)","maxUses":20,"hours":24}`, &en); err != nil {
		return nil, err
	}
	key, _ := remoteengine.NewBoxKey()
	installID := "lab-install-" + remoteengine.NewAttemptID()
	body, _ := json.Marshal(map[string]string{"code": en.Code, "deviceName": "Домашний ПК (стенд, ID)",
		"boxPub": remoteengine.EncodeKey(key.PublicKey().Bytes()), "instance": connecthost.Instance(installID)})
	hc := &http.Client{Transport: &http.Transport{TLSClientConfig: remoteengine.PinnedTLS(fp)}, Timeout: 30 * time.Second}
	res, err := hc.Post(gwURL+"/gw/v1/devices/enroll", "application/json", strings.NewReader(string(body)))
	if err != nil {
		return nil, err
	}
	defer res.Body.Close()
	var env struct {
		Data struct{ Number, AgentToken string }
	}
	if err := json.NewDecoder(res.Body).Decode(&env); err != nil || res.StatusCode != 200 {
		return nil, fmt.Errorf("enroll lab device: HTTP %d", res.StatusCode)
	}
	newAgent := func(cfg remotehost.Config, log *slog.Logger) (*remotehost.Agent, error) {
		if shadowExe == "" {
			cfg.Backend, cfg.ShadowExecutable, cfg.ShadowSource = "gnome-rdp", "", ""
			cfg.Grdctl, cfg.Daemon, cfg.Port, cfg.RDPUser, cfg.PromptCommand = []string{"grdctl"}, []string{daemon}, rdpPort, "aer", []string{"lab"}
		}
		if err := cfg.Validate(); err != nil {
			return nil, err
		}
		a, err := remotehost.New(cfg, log)
		if err != nil {
			return nil, err
		}
		if shadowExe == "" {
			a.SetRunner(func(context.Context, []string) ([]byte, error) { return []byte("RDP:\n\tStatus: disabled\n"), nil },
				func([]string) (func(), error) { return func() {}, nil })
			a.Connections = connections
		}
		a.Prompt = func(context.Context, string) bool { return true } // TEST ONLY
		return a, nil
	}
	state := filepath.Join(dir, "device")
	inR, inW := io.Pipe()
	outR, outW := io.Pipe()
	d := &labDevice{number: env.Data.Number, enrollCode: en.Code, stdin: inW, done: make(chan error, 1),
		passwordFile: filepath.Join(dir, "device-password.txt")}
	go func() {
		d.done <- connecthost.Run(ctx, inR, outW, connecthost.Options{NewAgent: newAgent})
		outW.Close()
	}()
	source := "synthetic"
	exe := shadowExe
	if exe == "" {
		exe = state // only checked to be absolute; the fake backend never runs it
	}
	init, _ := json.Marshal(connecthost.Init{Type: "init", GatewayURL: gwURL, GatewayCertSHA256: fp, AgentToken: env.Data.AgentToken,
		BoxKey: remoteengine.EncodeKey(key.Bytes()), Number: env.Data.Number, InstallID: installID, StateDir: state,
		ShadowExecutable: exe, ShadowSource: source, Clipboard: true, AllowIncoming: true})
	if _, err := inW.Write(append(init, '\n')); err != nil {
		return nil, err
	}
	var mu sync.Mutex
	online := make(chan struct{})
	var once sync.Once
	go func() {
		sc := bufio.NewScanner(outR)
		for sc.Scan() {
			var o connecthost.Out
			if json.Unmarshal(sc.Bytes(), &o) != nil {
				continue
			}
			if o.Type == "status" {
				mu.Lock()
				d.password = o.TempPassword
				_ = os.WriteFile(d.passwordFile, []byte(o.TempPassword), 0o600)
				mu.Unlock()
				if o.Link == remotehost.LinkOnline {
					once.Do(func() { close(online) })
				}
			}
		}
	}()
	select {
	case <-online:
	case err := <-d.done:
		return nil, errors.Join(errors.New("lab device stopped"), err)
	case <-time.After(30 * time.Second):
		return nil, errors.New("lab device did not come online")
	}
	mu.Lock()
	defer mu.Unlock()
	return d, nil
}
