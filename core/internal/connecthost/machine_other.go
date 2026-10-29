//go:build !windows

package connecthost

import (
	"os"
	"strings"
)

func machineID() string {
	b, _ := os.ReadFile("/etc/machine-id")
	return strings.TrimSpace(string(b))
}

// Elevated reports root (the Windows Host is the supported one).
func Elevated() bool { return os.Geteuid() == 0 }
