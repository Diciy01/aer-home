//go:build unix

package remotehost

import (
	"os"
	"syscall"
)

func terminate(p *os.Process) error { return p.Signal(syscall.SIGTERM) }
