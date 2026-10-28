package netx

import (
	"context"
	"errors"
	"net"
	"runtime"
	"testing"
	"time"
)

func TestRefusedLoopbackConnect(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	addr := ln.Addr().String()
	ln.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	var d net.Dialer
	_, err = d.DialContext(ctx, "tcp", addr)
	if err == nil {
		t.Skip("port was reused")
	}
	if !IsConnRefused(err) {
		t.Fatalf("closed loopback port: %v (%T) not recognised as refused", err, errors.Unwrap(err))
	}
	if IsConnReset(err) || IsHostUnreachable(err) || IsNetUnreachable(err) {
		t.Fatalf("refused misclassified: %v", err)
	}
	if IsConnRefused(context.DeadlineExceeded) || IsConnRefused(nil) {
		t.Fatal("not a refusal")
	}
}

func TestIsLocalSocket(t *testing.T) {
	ok := []string{"/var/run/docker.sock", `\\.\pipe\docker_engine`}
	bad := []string{"", "docker.sock", "tcp://127.0.0.1:2375", "127.0.0.1:2375", `\\.\pipe\`, `\\.\pipe\a\b`, `\\server\pipe\docker_engine`}
	if runtime.GOOS == "windows" {
		ok = append(ok, `C:\ProgramData\docker\docker.sock`)
	}
	for _, p := range ok {
		if !IsLocalSocket(p) {
			t.Errorf("%q: want local", p)
		}
	}
	for _, p := range bad {
		if IsLocalSocket(p) {
			t.Errorf("%q: want rejected", p)
		}
	}
	if !IsLocalSocket(DefaultDockerSocket) {
		t.Errorf("default %q must validate", DefaultDockerSocket)
	}
}

func TestDialLocalMissing(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	p := t.TempDir() + "/none.sock"
	if runtime.GOOS == "windows" {
		p = PipePrefix + "aer-netx-test-missing"
	}
	if c, err := DialLocal(ctx, p); err == nil {
		c.Close()
		t.Fatal("dial of a missing endpoint succeeded")
	}
}
