//go:build unix && !linux

package bots

import "syscall"

func childAttrOS() *syscall.SysProcAttr { return &syscall.SysProcAttr{Setpgid: true} }
