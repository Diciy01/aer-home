package remotehost

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// Backend controls the local RDP server.
type Backend interface {
	// Prepare puts the server in a known safe state: configured but disabled.
	Prepare(ctx context.Context) error
	// Open enables the server for one session with these credentials.
	Open(ctx context.Context, user, password string) error
	// Close disables the server (drops connections) and forgets credentials.
	Close(ctx context.Context) error
	// Ready says whether a session could be opened now.
	Ready(ctx context.Context) (bool, string)
	// Username for clients ("" when the OS account is used).
	Username() string
}

// Runner runs a command and returns combined output (tests inject fakes).
type Runner func(ctx context.Context, argv []string) ([]byte, error)

func execRunner(ctx context.Context, argv []string) ([]byte, error) {
	cmd := exec.CommandContext(ctx, argv[0], argv[1:]...)
	var out bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &out
	err := cmd.Run()
	return out.Bytes(), err
}

// gnomeBackend drives gnome-remote-desktop with grdctl. The password goes
// to grdctl's argv for a moment (visible to the same user only); grdctl
// stores it in the user's keyring/credential file, cleared on Close.
type gnomeBackend struct {
	c   Config
	run Runner
	// start launches the daemon; tests inject a fake.
	start  func(argv []string) (stop func(), err error)
	stopFn func()
}

// startDaemon runs the daemon as a child of the agent; stop sends SIGTERM,
// then kills after 3 s. Its output goes to the agent's state dir.
func startDaemon(stateDir string) func(argv []string) (func(), error) {
	return func(argv []string) (func(), error) {
		cmd := exec.Command(argv[0], argv[1:]...)
		if f, err := os.OpenFile(filepath.Join(stateDir, "gnome-remote-desktop.log"), os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600); err == nil {
			cmd.Stdout, cmd.Stderr = f, f
			defer f.Close()
		}
		if err := cmd.Start(); err != nil {
			return nil, err
		}
		done := make(chan struct{})
		go func() { _ = cmd.Wait(); close(done) }()
		return func() {
			_ = terminate(cmd.Process)
			select {
			case <-done:
			case <-time.After(3 * time.Second):
				_ = cmd.Process.Kill()
				<-done
			}
		}, nil
	}
}

func (g *gnomeBackend) grd(ctx context.Context, args ...string) error {
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	out, err := g.run(ctx, append(append([]string{}, g.c.Grdctl...), args...))
	if err != nil {
		msg := strings.TrimSpace(string(out))
		for _, line := range strings.Split(msg, "\n") { // drop grdctl's TPM notice
			if !strings.Contains(line, "TPM") && strings.TrimSpace(line) != "" {
				msg = line
				break
			}
		}
		if args[0] == "rdp" && len(args) > 1 && args[1] == "set-credentials" {
			return fmt.Errorf("grdctl rdp set-credentials: %v", err) // never echo argv/password
		}
		return fmt.Errorf("grdctl %s: %v %s", strings.Join(args, " "), err, msg)
	}
	return nil
}

func (g *gnomeBackend) Prepare(ctx context.Context) error {
	for _, a := range [][]string{
		{"rdp", "disable"},
		{"rdp", "clear-credentials"},
		{"rdp", "set-port", strconv.Itoa(g.c.Port)},
		{"rdp", "disable-port-negotiation"},
		{"rdp", "set-tls-cert", g.c.TLSCert},
		{"rdp", "set-tls-key", g.c.TLSKey},
		{"rdp", "disable-view-only"},
	} {
		if err := g.grd(ctx, a...); err != nil {
			return err
		}
	}
	return nil
}

func (g *gnomeBackend) Open(ctx context.Context, user, password string) error {
	if err := g.grd(ctx, "rdp", "set-credentials", user, password); err != nil {
		return err
	}
	if err := g.grd(ctx, "rdp", "enable"); err != nil {
		return err
	}
	stop, err := g.start(g.c.Daemon)
	if err != nil {
		return fmt.Errorf("start gnome-remote-desktop: %w", err)
	}
	g.stopFn = stop
	return nil
}

func (g *gnomeBackend) Close(ctx context.Context) error {
	err := errors.Join(g.grd(ctx, "rdp", "disable"), g.grd(ctx, "rdp", "clear-credentials"))
	if g.stopFn != nil { // drops every connection and forgets cached credentials
		g.stopFn()
		g.stopFn = nil
	}
	return err
}

func (g *gnomeBackend) Ready(ctx context.Context) (bool, string) {
	if _, err := os.Stat(g.c.Daemon[0]); err != nil {
		return false, "gnome-remote-desktop не установлен"
	}
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	if out, err := g.run(ctx, append(append([]string{}, g.c.Grdctl...), "status")); err != nil {
		return false, "gnome-remote-desktop недоступен: " + firstLine(out, err)
	}
	return true, "RDP-сервер GNOME настроен и выключен до сеанса"
}

func (g *gnomeBackend) Username() string { return g.c.RDPUser }

// windowsBackend: built-in Windows RDP. AER never changes the Windows
// account password, so sessions use the user's own credentials (NLA) and
// the agent only probes availability. It cannot enforce session credentials,
// certificate pinning, permissions or revocation. Until a managed Windows
// adapter exists (M14.4), never authorize a session on this backend.
type windowsBackend struct{ c Config }

func (w *windowsBackend) Prepare(context.Context) error { return nil }
func (w *windowsBackend) Open(context.Context, string, string) error {
	return errors.New("windows-rdp: managed sessions unsupported (credentials, certificate and revocation require a Windows host adapter)")
}
func (w *windowsBackend) Close(context.Context) error { return nil }
func (w *windowsBackend) Ready(ctx context.Context) (bool, string) {
	d := net.Dialer{Timeout: 2 * time.Second}
	conn, err := d.DialContext(ctx, "tcp", net.JoinHostPort("127.0.0.1", strconv.Itoa(w.c.Port)))
	if err != nil {
		return false, "Встроенный RDP Windows не слушает порт (выключен или Windows Home)"
	}
	conn.Close()
	return false, "Порт RDP Windows доступен, но управляемые сеансы AER не поддерживаются: сертификат, права и отзыв требуют Windows-адаптера (M14.4)"
}
func (w *windowsBackend) Username() string { return "" }

func firstLine(out []byte, err error) string {
	for _, l := range strings.Split(string(out), "\n") {
		if l = strings.TrimSpace(l); l != "" && !strings.Contains(l, "TPM") {
			return l
		}
	}
	if err != nil {
		return err.Error()
	}
	return ""
}
