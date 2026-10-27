//go:build windows

package remotehost

import "os"

func terminate(p *os.Process) error { return p.Kill() }
