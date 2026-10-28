// Package netx holds the few network details that differ between Linux and
// Windows: socket error codes and local IPC endpoints (unix sockets, named
// pipes). On Windows a refused TCP connect is WSAECONNREFUSED, which
// errors.Is(err, syscall.ECONNREFUSED) does not match.
package netx

import (
	"context"
	"errors"
	"net"
	"path/filepath"
	"strings"
	"syscall"
)

// PipePrefix starts every local Windows named pipe path.
const PipePrefix = `\\.\pipe\`

// IsConnRefused: the peer answered with a reset to the SYN — the host is up.
func IsConnRefused(err error) bool { return is(err, syscall.ECONNREFUSED, errConnRefused) }

// IsHostUnreachable: no route to the host.
func IsHostUnreachable(err error) bool { return is(err, syscall.EHOSTUNREACH, errHostUnreach) }

// IsNetUnreachable: no route to the network.
func IsNetUnreachable(err error) bool { return is(err, syscall.ENETUNREACH, errNetUnreach) }

// IsConnReset: the connection was reset by the peer.
func IsConnReset(err error) bool { return is(err, syscall.ECONNRESET, errConnReset) }

func is(err error, posix, native error) bool {
	return errors.Is(err, posix) || (native != nil && errors.Is(err, native))
}

// IsLocalSocket reports whether p names a local IPC endpoint: an absolute
// unix socket path or (on any OS, for configs written for Windows) a local
// named pipe. TCP addresses and remote pipes are rejected.
func IsLocalSocket(p string) bool {
	if name, ok := strings.CutPrefix(p, PipePrefix); ok {
		return name != "" && !strings.ContainsAny(name, `\/`)
	}
	if strings.HasPrefix(p, `\\`) || strings.HasPrefix(p, "//") {
		return false // UNC: another machine
	}
	return strings.HasPrefix(p, "/") || filepath.IsAbs(p)
}

// DialLocal connects to a local unix socket or, on Windows, a named pipe.
func DialLocal(ctx context.Context, path string) (net.Conn, error) {
	if strings.HasPrefix(path, PipePrefix) {
		return dialPipe(ctx, path)
	}
	var d net.Dialer
	return d.DialContext(ctx, "unix", path)
}
