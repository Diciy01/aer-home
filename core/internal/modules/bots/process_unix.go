//go:build unix

package bots

import (
	"os/exec"
	"syscall"
)

// The child gets its own process group so stop reaches its subprocesses too.
func childAttr() *syscall.SysProcAttr { return childAttrOS() }

func terminate(cmd *exec.Cmd) error { return syscall.Kill(-cmd.Process.Pid, syscall.SIGTERM) }

func kill(cmd *exec.Cmd) error { return syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL) }
