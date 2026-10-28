package netx

import (
	"context"
	"errors"
	"net"
	"os"
	"time"

	"golang.org/x/sys/windows"
)

// DefaultDockerSocket is the named pipe of Docker Desktop / Docker Engine.
const DefaultDockerSocket = `\\.\pipe\docker_engine`

var (
	errConnRefused error = windows.WSAECONNREFUSED
	errHostUnreach error = windows.WSAEHOSTUNREACH
	errNetUnreach  error = windows.WSAENETUNREACH
	errConnReset   error = windows.WSAECONNRESET
)

// dialPipe opens the pipe for overlapped I/O, so os.File honours deadlines
// and Close unblocks a pending read. A busy pipe is retried until ctx ends.
func dialPipe(ctx context.Context, path string) (net.Conn, error) {
	for {
		f, err := os.OpenFile(path, os.O_RDWR|windows.FILE_FLAG_OVERLAPPED, 0)
		if err == nil {
			return &pipeConn{File: f, addr: pipeAddr(path)}, nil
		}
		if !errors.Is(err, windows.ERROR_PIPE_BUSY) {
			return nil, err
		}
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-time.After(20 * time.Millisecond):
		}
	}
}

type pipeAddr string

func (pipeAddr) Network() string  { return "pipe" }
func (a pipeAddr) String() string { return string(a) }

type pipeConn struct {
	*os.File
	addr pipeAddr
}

func (c *pipeConn) LocalAddr() net.Addr  { return c.addr }
func (c *pipeConn) RemoteAddr() net.Addr { return c.addr }
