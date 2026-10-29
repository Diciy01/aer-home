//go:build windows

package remotehost

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
	"unsafe"

	"golang.org/x/sys/windows"
)

// A single owned child per session. No Windows RDP service or accounts are
// touched. Child stdin EOF, local Stop and secure desktop all close access.
type shadowBackend struct {
	c                   Config
	mu                  sync.Mutex
	cmd                 *exec.Cmd
	input               io.WriteCloser
	done                chan struct{}
	alive               atomic.Bool
	dir, cert, key, pem string
}

func privateShadowDir(parent string) (string, error) {
	if err := os.MkdirAll(parent, 0700); err != nil {
		return "", err
	}
	dir := filepath.Join(parent, "session-"+newToken())
	// Protected DACL: current owner and SYSTEM only, no inherited broad ACEs.
	sd, err := windows.SecurityDescriptorFromString("D:P(A;OICI;FA;;;SY)(A;OICI;FA;;;OW)")
	if err != nil {
		return "", err
	}
	path, err := windows.UTF16PtrFromString(dir)
	if err != nil {
		return "", err
	}
	err = windows.CreateDirectory(path, &windows.SecurityAttributes{Length: uint32(unsafe.Sizeof(windows.SecurityAttributes{})), SecurityDescriptor: sd})
	return dir, err
}

func newShadowBackend(c Config) (Backend, error) { return &shadowBackend{c: c}, nil }

// Hello needs a public certificate before any session exists. Its unused
// private key is removed immediately; only session keys ever back a listener.
func shadowPresenceCert(c Config) (string, error) {
	dir, err := privateShadowDir(c.StateDir)
	if err != nil {
		return "", err
	}
	bootstrap := Config{StateDir: dir}
	cert, generateErr := EnsureCert(&bootstrap)
	var cleanupErr error
	for _, path := range []string{filepath.Join(dir, "rdp-tls.key"), filepath.Join(dir, "rdp-tls.crt"), dir} {
		if err := os.Remove(path); err != nil && !os.IsNotExist(err) {
			cleanupErr = errors.Join(cleanupErr, err)
		}
	}
	return cert, errors.Join(generateErr, cleanupErr)
}
func (s *shadowBackend) Prepare(context.Context) error { return nil }
func (s *shadowBackend) Username() string              { return "aer" }
func (s *shadowBackend) Ready(ctx context.Context) (bool, string) {
	if _, err := os.Stat(s.c.ShadowExecutable); err != nil {
		return false, "Не найден app-local aer-shadow.exe"
	}
	if s.c.ShadowSource == "synthetic" {
		return true, "TEST ONLY: синтетический RDP, рабочий стол не захватывается"
	}
	ctx, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, s.c.ShadowExecutable, "--probe")
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true}
	if cmd.Run() != nil {
		return false, "Нет доступного пользовательского рабочего стола или зависимостей Host; служба/session 0 не поддерживается"
	}
	return true, "AER Windows Host: требуется локальное подтверждение каждого сеанса"
}
func (s *shadowBackend) Prompt(ctx context.Context, text string) bool {
	// Synthetic is only a test source. Tests must explicitly inject Prompt;
	// never silently approve production desktop sessions.
	ctx, cancel := context.WithTimeout(ctx, 90*time.Second)
	defer cancel()
	return exec.CommandContext(ctx, s.c.ShadowExecutable, "--consent", text).Run() == nil
}
func (s *shadowBackend) Open(context.Context, string, string) error {
	return errors.New("windows-shadow requires the session's effective permissions")
}
func (s *shadowBackend) OpenSession(ctx context.Context, user, password string, c Command) error {
	if !c.Relay || !c.Allowed.Desktop {
		return errors.New("windows-shadow requires an authorized Gateway relay session")
	}
	if ttl := time.Until(c.ExpiresAt); ttl <= 0 || ttl > 24*time.Hour {
		return errors.New("shadow session lifetime must be positive and at most 24 hours")
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.cmd != nil {
		return errors.New("shadow session already active")
	}
	dir, err := privateShadowDir(s.c.StateDir)
	if err != nil {
		return err
	}
	s.dir = dir
	cfg := Config{StateDir: dir}
	pem, err := ensureCertUntil(&cfg, c.ExpiresAt)
	if err != nil {
		s.removeSessionFiles()
		return err
	}
	// FreeRDP shadow API reads ConfigPath/shadow/shadow.{crt,key}.
	shadowDir := filepath.Join(dir, "shadow")
	if err = os.Mkdir(shadowDir, 0700); err != nil {
		s.removeSessionFiles()
		return err
	}
	cert, key := filepath.Join(shadowDir, "shadow.crt"), filepath.Join(shadowDir, "shadow.key")
	s.cert, s.key = cert, key
	if err = os.Rename(cfg.TLSCert, cert); err == nil {
		err = os.Rename(cfg.TLSKey, key)
	}
	if err != nil {
		s.removeSessionFiles()
		return err
	}
	cmd := exec.Command(s.c.ShadowExecutable, "--config-stdin")
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true}
	input, err := cmd.StdinPipe()
	if err != nil {
		s.removeSessionFiles()
		return err
	}
	output, err := cmd.StdoutPipe()
	if err != nil {
		input.Close()
		s.removeSessionFiles()
		return err
	}
	// Never relay native library diagnostics into the agent log.
	cmd.Stderr = io.Discard
	if err = cmd.Start(); err != nil {
		input.Close()
		output.Close()
		s.removeSessionFiles()
		return errors.New("could not start app-local shadow helper")
	}
	s.cmd, s.input, s.done = cmd, input, make(chan struct{})
	s.alive.Store(true)
	s.cert, s.key, s.pem = cert, key, pem
	ready := make(chan bool, 1)
	go func() {
		scanner := bufio.NewScanner(output)
		ok := scanner.Scan() && scanner.Text() == "READY"
		ready <- ok
		for scanner.Scan() {
			if scanner.Text() == "STOPPING" {
				s.alive.Store(false)
			}
		}
		s.alive.Store(false)
		_ = cmd.Wait()
		close(s.done)
	}()
	body := map[string]any{"user": user, "password": password, "stateDir": dir, "port": s.c.Port, "mode": s.c.ShadowSource,
		"input": c.Allowed.Input, "clipboard": s.c.Clipboard && c.Allowed.Clipboard, "ttlMs": time.Until(c.ExpiresAt).Milliseconds()}
	err = json.NewEncoder(input).Encode(body)
	if err != nil {
		s.stop()
		return errors.New("shadow configuration pipe failed")
	}
	select {
	case ok := <-ready:
		if !ok {
			s.stop()
			return errors.New("shadow helper refused capture or RDP initialization")
		}
	case <-ctx.Done():
		s.stop()
		return ctx.Err()
	case <-time.After(15 * time.Second):
		s.stop()
		return errors.New("shadow helper readiness timeout")
	}
	return nil
}
func (s *shadowBackend) SessionTLS() (string, string, string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.cert, s.key, s.pem
}
func (s *shadowBackend) Alive() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.done == nil || !s.alive.Load() {
		return false
	}
	select {
	case <-s.done:
		return false
	default:
		return true
	}
}
func (s *shadowBackend) stop() {
	s.alive.Store(false)
	if s.input != nil {
		_ = s.input.Close()
		s.input = nil
	}
	if s.cmd != nil {
		select {
		case <-s.done:
		case <-time.After(5 * time.Second):
			_ = s.cmd.Process.Kill()
			<-s.done
		}
		s.cmd = nil
	}
	s.removeSessionFiles()
}
func (s *shadowBackend) removeSessionFiles() {
	// Only files this backend creates, no recursive deletion of caller paths.
	for _, p := range []string{s.cert, s.key, filepath.Join(s.dir, "rdp-tls.crt"), filepath.Join(s.dir, "rdp-tls.key")} {
		if s.dir != "" && filepath.Dir(p) == s.dir || s.dir != "" && filepath.Dir(p) == filepath.Join(s.dir, "shadow") {
			_ = os.Remove(p)
		}
	}
	if s.dir != "" {
		_ = os.Remove(filepath.Join(s.dir, "shadow"))
		_ = os.Remove(s.dir)
	}
	s.dir, s.cert, s.key, s.pem = "", "", "", ""
}
func (s *shadowBackend) Close(context.Context) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.stop()
	return nil
}
