package connecthost

import (
	"bufio"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"aerhome/core/internal/remoteengine"
	"aerhome/core/internal/remotehost"
)

// Wire protocol with the AER Connect app: JSON lines over the child's
// stdin/stdout. The first line is Init; then the app sends Commands and
// the runtime answers with Out messages. Closing stdin stops the host:
// the app's exit never leaves a host behind.

// Init configures the runtime (secrets live only in this message).
type Init struct {
	Type              string                 `json:"type"` // init
	GatewayURL        string                 `json:"gatewayUrl"`
	GatewayCertSHA256 string                 `json:"gatewayCertSha256"`
	AgentToken        string                 `json:"agentToken"`
	BoxKey            string                 `json:"boxKey"`
	Number            string                 `json:"number"`
	InstallID         string                 `json:"installId"`
	StateDir          string                 `json:"stateDir"`
	ShadowExecutable  string                 `json:"shadowExecutable"`
	ShadowSource      string                 `json:"shadowSource"` // desktop | synthetic (tests)
	ViewOnly          bool                   `json:"viewOnly"`
	Clipboard         bool                   `json:"clipboard"`
	Files             FilesInit              `json:"files"`
	Permanent         *remoteengine.Verifier `json:"permanent"`
	AllowIncoming     bool                   `json:"allowIncoming"`
}

// FilesInit is the exchange folder (off unless the user chose one).
type FilesInit struct {
	Enabled bool   `json:"enabled"`
	Dir     string `json:"dir"`
}

// Command from the app.
type Command struct {
	Cmd      string `json:"cmd"` // rotate | setPermanent | clearPermanent | allowIncoming | stopSession | status
	Password string `json:"password,omitempty"`
	Value    bool   `json:"value,omitempty"`
}

// Out is one message to the app.
type Out struct {
	Type          string                    `json:"type"` // status | permanent | error | fatal
	Link          string                    `json:"link,omitempty"`
	Error         string                    `json:"error,omitempty"`
	Session       *remotehost.SessionStatus `json:"session,omitempty"`
	Number        string                    `json:"number,omitempty"`
	TempPassword  string                    `json:"tempPassword,omitempty"`
	Permanent     bool                      `json:"permanent"`
	AllowIncoming bool                      `json:"allowIncoming"`
	LockedUntil   *time.Time                `json:"lockedUntil,omitempty"`
	Verifier      *remoteengine.Verifier    `json:"verifier,omitempty"`
	Problem       string                    `json:"problem,omitempty"`
	Message       string                    `json:"message,omitempty"`
}

// Options are test seams.
type Options struct {
	// NewAgent builds the host agent (default: remotehost.New).
	NewAgent func(cfg remotehost.Config, log *slog.Logger) (*remotehost.Agent, error)
	Log      *slog.Logger
}

// ErrRevoked: Core rejected the device credential (exit code 3).
var ErrRevoked = errors.New("device revoked")

// Validate checks an Init before anything starts.
func (in Init) Validate() error {
	var errs []error
	if !remoteengine.ValidDeviceNumber(in.Number) {
		errs = append(errs, errors.New("number: 9 digits"))
	}
	if !strings.HasPrefix(in.AgentToken, "aer1.") || len(in.AgentToken) > 200 {
		errs = append(errs, errors.New("agentToken"))
	}
	if _, err := remoteengine.ParseBoxKey(in.BoxKey); err != nil {
		errs = append(errs, errors.New("boxKey"))
	}
	if len(in.InstallID) < 16 || len(in.InstallID) > 128 {
		errs = append(errs, errors.New("installId"))
	}
	if !filepath.IsAbs(in.StateDir) {
		errs = append(errs, errors.New("stateDir: absolute path"))
	}
	if in.Permanent != nil && !in.Permanent.Valid() {
		errs = append(errs, errors.New("permanent: invalid verifier"))
	}
	return errors.Join(errs...)
}

// Instance is the clone-detection fingerprint: this installation on this
// machine. A copied profile on another machine yields another value.
func Instance(installID string) string {
	sum := sha256.Sum256([]byte("aer-connect-instance/1\x00" + installID + "\x00" + machineID()))
	return hex.EncodeToString(sum[:])
}

func freePort() (int, error) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return 0, err
	}
	defer ln.Close()
	return ln.Addr().(*net.TCPAddr).Port, nil
}

// Config builds the host agent configuration from Init: windows-shadow on
// loopback, local prompt for every session, Core reached only through the
// Gateway's agent proxy, every TLS connection pinned to the Gateway.
func (in Init) Config() (remotehost.Config, error) {
	rdp, err := freePort()
	if err != nil {
		return remotehost.Config{}, err
	}
	files, err := freePort()
	if err != nil {
		return remotehost.Config{}, err
	}
	gw := strings.TrimRight(in.GatewayURL, "/")
	source := in.ShadowSource
	if source == "" {
		source = "desktop"
	}
	c := remotehost.Config{CoreURL: gw + "/gw/v1/agent", CoreCertSHA256: in.GatewayCertSHA256,
		TokenFile: filepath.Join(in.StateDir, "no-token-file"), StateDir: in.StateDir, Backend: "windows-shadow",
		ShadowExecutable: in.ShadowExecutable, ShadowSource: source, ShadowViewOnly: in.ViewOnly,
		Address: "127.0.0.1", Port: rdp, Approval: "prompt", Clipboard: in.Clipboard,
		Files:      remotehost.Files{Enabled: in.Files.Enabled, Dir: in.Files.Dir, Port: files, MaxBytes: 2 << 30},
		GatewayURL: gw, GatewayCertSHA256: in.GatewayCertSHA256}
	return c, c.Validate()
}

type runtime struct {
	out   *json.Encoder
	outMu sync.Mutex
	guard *Guard
	in    Init
	agent *remotehost.Agent
	last  remotehost.Status
	mu    sync.Mutex
}

func (r *runtime) send(o Out) {
	r.outMu.Lock()
	defer r.outMu.Unlock()
	_ = r.out.Encode(o)
}

func (r *runtime) status() {
	r.mu.Lock()
	st := r.last
	r.mu.Unlock()
	perm, incoming, locked := r.guard.State()
	r.send(Out{Type: "status", Link: st.Link, Error: st.Error, Session: st.Session, Number: r.in.Number,
		TempPassword: r.guard.Temp(), Permanent: perm, AllowIncoming: incoming, LockedUntil: locked})
}

// Run serves one AER Connect host until stdin closes or ctx ends.
func Run(ctx context.Context, stdin io.Reader, stdout io.Writer, opt Options) error {
	if opt.Log == nil {
		opt.Log = slog.New(slog.DiscardHandler)
	}
	if opt.NewAgent == nil {
		opt.NewAgent = remotehost.New
	}
	r := &runtime{out: json.NewEncoder(stdout)}
	sc := bufio.NewScanner(stdin)
	sc.Buffer(make([]byte, 64<<10), 64<<10)
	if !sc.Scan() {
		return errors.New("no init message")
	}
	var in Init
	if err := json.Unmarshal(sc.Bytes(), &in); err != nil || in.Type != "init" {
		r.send(Out{Type: "fatal", Message: "Некорректная конфигурация хоста"})
		return errors.New("bad init message")
	}
	if err := in.Validate(); err != nil {
		r.send(Out{Type: "fatal", Message: "Некорректная конфигурация хоста"})
		return err
	}
	key, _ := remoteengine.ParseBoxKey(in.BoxKey)
	r.in = in
	r.guard = NewGuard(key, in.Number, in.Permanent, in.AllowIncoming)
	cfg, err := in.Config()
	if err != nil {
		r.send(Out{Type: "fatal", Message: "Хост не настроен: " + err.Error()})
		return err
	}
	a, err := opt.NewAgent(cfg, opt.Log)
	if err != nil {
		r.send(Out{Type: "fatal", Message: "Не удалось запустить хост"})
		return err
	}
	r.agent = a
	a.Auth, a.Token, a.Instance = r.guard, in.AgentToken, Instance(in.InstallID)
	a.OnStatus = func(st remotehost.Status) {
		r.mu.Lock()
		hadSession := r.last.Session != nil
		r.last = st
		r.mu.Unlock()
		if hadSession && st.Session == nil {
			r.guard.RotateIfUsed()
		}
		r.status()
	}
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	done := make(chan error, 1)
	go func() { done <- a.Run(ctx) }()
	r.status()

	lines := make(chan []byte)
	go func() {
		defer close(lines)
		for sc.Scan() {
			b := append([]byte(nil), sc.Bytes()...)
			select {
			case lines <- b:
			case <-ctx.Done():
				return
			}
		}
	}()
	for {
		select {
		case err := <-done:
			if err != nil && strings.Contains(err.Error(), "credential rejected") {
				r.status()
				r.send(Out{Type: "fatal", Link: remotehost.LinkRevoked, Message: "Устройство отозвано на сервере — зарегистрируйте его снова"})
				return ErrRevoked
			}
			if err != nil {
				r.send(Out{Type: "fatal", Message: "Хост остановлен: " + err.Error()})
			}
			return err
		case b, ok := <-lines:
			if !ok { // the app is gone: stop and close any session
				cancel()
				return <-done
			}
			r.handle(ctx, b)
		}
	}
}

func (r *runtime) handle(ctx context.Context, b []byte) {
	var c Command
	if err := json.Unmarshal(b, &c); err != nil {
		r.send(Out{Type: "error", Message: "Некорректная команда"})
		return
	}
	switch c.Cmd {
	case "status":
	case "rotate":
		r.guard.Rotate()
	case "setPermanent":
		if p := remoteengine.PermanentPasswordProblem(c.Password); p != "" {
			r.send(Out{Type: "permanent", Problem: p})
			return
		}
		v, err := remoteengine.NewVerifier(c.Password)
		if err != nil {
			r.send(Out{Type: "error", Message: "Не удалось сохранить пароль"})
			return
		}
		r.guard.SetPermanent(&v)
		r.send(Out{Type: "permanent", Verifier: &v})
	case "clearPermanent":
		r.guard.SetPermanent(nil)
		r.send(Out{Type: "permanent"})
	case "allowIncoming":
		r.guard.SetIncoming(c.Value)
		if !c.Value {
			r.agent.StopSession(ctx)
		}
	case "stopSession":
		r.agent.StopSession(ctx)
		r.guard.Rotate() // whoever was connected cannot simply come back
	default:
		r.send(Out{Type: "error", Message: fmt.Sprintf("Неизвестная команда %q", c.Cmd)})
		return
	}
	r.status()
}
