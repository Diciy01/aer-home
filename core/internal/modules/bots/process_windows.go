//go:build windows

package bots

import (
	"os/exec"
	"syscall"
)

// Windows support of supervised processes is UNVERIFIED (M10): stop is a
// hard kill there, without a graceful signal.
func childAttr() *syscall.SysProcAttr { return nil }

func terminate(cmd *exec.Cmd) error { return cmd.Process.Kill() }

func kill(cmd *exec.Cmd) error { return cmd.Process.Kill() }
