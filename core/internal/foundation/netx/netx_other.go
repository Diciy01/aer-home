//go:build !windows

package netx

import (
	"context"
	"errors"
	"net"
)

// DefaultDockerSocket is where the local Docker Engine listens.
const DefaultDockerSocket = "/var/run/docker.sock"

var errConnRefused, errHostUnreach, errNetUnreach, errConnReset error

func dialPipe(context.Context, string) (net.Conn, error) {
	return nil, errors.New("named pipes are only available on Windows")
}
