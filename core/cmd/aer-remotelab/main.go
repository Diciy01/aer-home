// Command aer-remotelab is an ISOLATED test stand of AER Remote 2 (M14):
// an in-process Core in a temporary data dir, the Remote Gateway on
// 127.0.0.1 with a fresh self-signed certificate, and one host agent with
// a FAKE grdctl and a FAKE "RDP server" (greets "HOST <name>" and echoes).
// Nothing listens beyond loopback. The default and -shadow modes never
// capture a desktop. Only an explicit Windows -desktop-acceptance flag AND
// AER_DESKTOP_ACCEPTANCE=1 select the real desktop after owner permission;
// native local consent stays mandatory and clipboard/files are disabled.
// Clients pair with the printed test-only code; never log that JSON line.
//
//	aer-remotelab            # prints one JSON line, runs until stdin closes or SIGTERM
//	aer-remotelab -rdp 127.0.0.1:PORT -rdp-cert server.crt -rdp-key server.key
//	                         # the agent relays to a REAL RDP server on loopback
//	                         # (e.g. the FreeRDP sample server, M10 on Windows)
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
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"sync/atomic"
	"syscall"
	"time"

	"aerhome/core/internal/core"
	"aerhome/core/internal/foundation/config"
	"aerhome/core/internal/modules"
	"aerhome/core/internal/remotegw"
	"aerhome/core/internal/remotehost"
)

// TEST DATA: every computer, client and credential here is generated.

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, "aer-remotelab:", err)
		os.Exit(1)
	}
}

var (
	realRDP           = flag.String("rdp", "", "use this REAL RDP server on loopback (127.0.0.1:port) instead of the fake one")
	rdpCert           = flag.String("rdp-cert", "", "with -rdp: the server's certificate (PEM), pinned by the agent")
	rdpKey            = flag.String("rdp-key", "", "with -rdp: the server's key (PEM), for the agent's file channel")
	shadow            = flag.String("shadow", "", "app-local aer-shadow.exe, SYNTHETIC by default; real desktop requires the separate owner-opt-in acceptance mode")
	desktopAcceptance = flag.Bool("desktop-acceptance", false, "EXPLICIT OWNER CONSENT ONLY: use real desktop with -shadow and AER_DESKTOP_ACCEPTANCE=1; keeps native local consent, disables clipboard/files")
	viewOnly          = flag.Bool("shadow-view-only", false, "synthetic host: deny input")
	noClipboard       = flag.Bool("no-clipboard", false, "deny host clipboard")
	noFiles           = flag.Bool("no-files", false, "deny host files")
)

func run() error {
	flag.Parse()
	if *desktopAcceptance && (*shadow == "" || runtime.GOOS != "windows" || os.Getenv("AER_DESKTOP_ACCEPTANCE") != "1") {
		return errors.New("desktop acceptance requires Windows, -shadow and explicit AER_DESKTOP_ACCEPTANCE=1; never enabled by default")
	}
	if *shadow != "" && *realRDP != "" {
		return errors.New("choose -shadow synthetic or -rdp")
	}
	if (*realRDP != "") != (*rdpCert != "" && *rdpKey != "") {
		return errors.New("-rdp needs -rdp-cert and -rdp-key")
	}
	if *realRDP != "" {
		if h, _, err := net.SplitHostPort(*realRDP); err != nil || !net.ParseIP(h).IsLoopback() {
			return errors.New("-rdp: a loopback address (the stand never leaves 127.0.0.1)")
		}
	}
	dir, err := os.MkdirTemp("", "aer-remotelab-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(dir)
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	go func() { _, _ = io.Copy(io.Discard, os.Stdin); stop() }()
	quiet := slog.New(slog.DiscardHandler)

	cfg := config.Default(func(string) (string, bool) { return "", false })
	cfg.DataDir = filepath.Join(dir, "core")
	cfg.Monitoring.Docker.Enabled = false
	c, err := core.New(ctx, core.Options{Config: cfg, Logger: quiet, Modules: modules.All()})
	if err != nil {
		return err
	}
	defer c.Close()
	cln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return err
	}
	go func() { _ = http.Serve(cln, c.Handler()) }()
	coreURL := "http://" + cln.Addr().String()
	raw, _ := os.ReadFile(cfg.TokenPath())
	owner := strings.TrimSpace(string(raw))
	api := func(method, path, body string, out any) error {
		req, _ := http.NewRequest(method, coreURL+"/api/v1"+path, strings.NewReader(body))
		req.Header.Set("Authorization", "Bearer "+owner)
		res, err := http.DefaultClient.Do(req)
		if err != nil {
			return err
		}
		defer res.Body.Close()
		var env struct{ Data json.RawMessage }
		if err := json.NewDecoder(res.Body).Decode(&env); err != nil || res.StatusCode >= 300 {
			return fmt.Errorf("%s %s: %d", method, path, res.StatusCode)
		}
		if out != nil {
			return json.Unmarshal(env.Data, out)
		}
		return nil
	}

	var server, pc struct{ ID string }
	var gwCred, hostCred struct{ Token string }
	steps := []error{
		api("POST", "/registry/entities", `{"name":"Сервер (стенд)","type":"server"}`, &server),
		api("POST", "/registry/entities", `{"name":"Домашний ПК (стенд)","type":"computer"}`, &pc),
	}
	steps = append(steps,
		api("POST", "/monitoring/agents", `{"entityId":"`+server.ID+`","name":"gateway","kind":"gateway"}`, &gwCred),
		api("POST", "/monitoring/agents", `{"entityId":"`+pc.ID+`","name":"remote","kind":"remote"}`, &hostCred),
		api("PUT", "/remote/hosts/"+pc.ID+"/policy", `{"enabled":true,"desktop":true,"clipboard":true,"files":true,"maxMinutes":30}`, nil))
	for _, e := range steps {
		if e != nil {
			return e
		}
	}
	gwTok, hostTok := filepath.Join(dir, "gw.token"), filepath.Join(dir, "host.token")
	_ = os.WriteFile(gwTok, []byte(gwCred.Token), 0o600)
	_ = os.WriteFile(hostTok, []byte(hostCred.Token), 0o600)

	gcfg := remotegw.Default()
	gcfg.ListenAddr, gcfg.CoreURL, gcfg.TokenFile, gcfg.StateDir = "127.0.0.1:0", coreURL, gwTok, filepath.Join(dir, "gw")
	gcfg.AliveCheckSec, gcfg.PairWaitSec = 1, 5
	g, err := remotegw.New(gcfg, quiet)
	if err != nil {
		return err
	}
	srv, err := g.Server()
	if err != nil {
		return err
	}
	gln, err := net.Listen("tcp", gcfg.ListenAddr)
	if err != nil {
		return err
	}
	go func() { _ = srv.ServeTLS(gln, "", "") }()
	go g.Maintain(ctx)
	gwURL := "https://" + gln.Addr().String()
	fp, _ := g.Fingerprint()

	var rdpPort int
	var live atomic.Int32
	if *realRDP != "" {
		// A real RDP server already listening on loopback (e.g. the FreeRDP
		// sample server); the agent pins its certificate.
		_, p, err := net.SplitHostPort(*realRDP)
		if err != nil {
			return fmt.Errorf("-rdp: %w", err)
		}
		if rdpPort, err = strconv.Atoi(p); err != nil {
			return fmt.Errorf("-rdp: %w", err)
		}
	} else if *shadow != "" {
		ln, err := net.Listen("tcp", "127.0.0.1:0")
		if err != nil {
			return err
		}
		rdpPort = ln.Addr().(*net.TCPAddr).Port
		ln.Close()
	} else {
		rdp, err := net.Listen("tcp", "127.0.0.1:0")
		if err != nil {
			return err
		}
		rdpPort = rdp.Addr().(*net.TCPAddr).Port
		go func() {
			for {
				conn, err := rdp.Accept()
				if err != nil {
					return
				}
				live.Add(1)
				go func() {
					defer live.Add(-1)
					defer conn.Close()
					_, _ = io.WriteString(conn, "HOST Домашний ПК (стенд)\n")
					_, _ = io.Copy(conn, conn)
				}()
			}
		}()
	}
	fl, _ := net.Listen("tcp", "127.0.0.1:0")
	filesPort := fl.Addr().(*net.TCPAddr).Port
	fl.Close()
	// The daemon is faked below; Ready only checks that the path exists.
	self, err := os.Executable()
	if err != nil {
		return err
	}
	acfg := remotehost.Config{CoreURL: coreURL, TokenFile: hostTok, StateDir: filepath.Join(dir, "agent"), Backend: "gnome-rdp",
		Grdctl: []string{"grdctl"}, Daemon: []string{self}, Address: "192.0.2.10", Port: rdpPort,
		RDPUser: "aer", Approval: "auto", Clipboard: true, TLSCert: *rdpCert, TLSKey: *rdpKey,
		Files:      remotehost.Files{Enabled: true, Dir: filepath.Join(dir, "exchange"), Port: filesPort, MaxBytes: 1 << 20},
		GatewayURL: gwURL, GatewayCertSHA256: fp}
	if *shadow != "" {
		acfg.Backend, acfg.ShadowExecutable, acfg.ShadowSource, acfg.Address, acfg.Approval = "windows-shadow", *shadow, "synthetic", "127.0.0.1", "prompt"
		if *desktopAcceptance {
			acfg.ShadowSource = "desktop"
		}
		acfg.ShadowViewOnly = *viewOnly
	}
	acfg.Clipboard = !*noClipboard
	acfg.Files.Enabled = !*noFiles
	if *desktopAcceptance {
		acfg.Clipboard, acfg.Files.Enabled = false, false
	}
	a, err := remotehost.New(acfg, quiet)
	if err != nil {
		return err
	}
	a.SetRunner(func(context.Context, []string) ([]byte, error) { return []byte("RDP:\n\tStatus: disabled\n"), nil },
		func([]string) (func(), error) { return func() {}, nil })
	if *shadow != "" && !*desktopAcceptance {
		a.Prompt = func(context.Context, string) bool { return true }
	} // explicit test-only synthetic source
	if *realRDP == "" && *shadow == "" {
		a.Connections = func() int { return int(live.Load()) }
	} // else: the agent counts real connections to the port (Linux/Windows)
	agentDone := make(chan struct{})
	go func() { defer close(agentDone); _ = a.Run(ctx) }()
	defer func() { stop(); <-agentDone }()

	var pair struct {
		Code   string
		Client struct{ ID string }
	}
	if err := api("POST", "/remote/clients", `{"name":"AER Connect (стенд)","hosts":["`+pc.ID+`"],"clipboard":true,"files":true}`, &pair); err != nil {
		return err
	}
	for i := 0; ; i++ { // wait until the host agent said hello
		var h struct{ CanConnect bool }
		if api("GET", "/remote/hosts/"+pc.ID, "", &h) == nil && h.CanConnect {
			break
		}
		if i > 200 {
			return fmt.Errorf("host agent not ready")
		}
		time.Sleep(25 * time.Millisecond)
	}
	result := map[string]string{"gateway": gwURL, "fingerprint": fp, "pairingCode": pair.Code, "clientId": pair.Client.ID,
		"hostId": pc.ID, "coreUrl": coreURL, "ownerToken": owner, "exchangeDir": acfg.Files.Dir,
		"hostMode": acfg.ShadowSource, "rdpPort": strconv.Itoa(rdpPort)}
	if *anywhere {
		shadowExe := ""
		if *shadow != "" && !*desktopAcceptance {
			shadowExe = *shadow
		}
		d, err := runAnywhere(ctx, dir, gwURL, fp, api, rdpPort, func() int { return int(live.Load()) }, shadowExe, self)
		if err != nil {
			return err
		}
		defer func() { d.stdin.Close(); <-d.done }()
		result["enrollCode"], result["deviceNumber"], result["devicePasswordFile"] = d.enrollCode, d.number, d.passwordFile
		// TEST ONLY: owner of the synthetic receiving device can configure trust.
		result["deviceClientCredential"], result["devicePromptsFile"] = d.clientCredential, d.promptsFile
	}
	out, _ := json.Marshal(result)
	w := bufio.NewWriter(os.Stdout)
	_, _ = w.Write(append(out, '\n'))
	_ = w.Flush()
	<-ctx.Done()
	sctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	_ = srv.Shutdown(sctx)
	return nil
}
