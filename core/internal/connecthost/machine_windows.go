//go:build windows

package connecthost

import (
	"golang.org/x/sys/windows"
	"golang.org/x/sys/windows/registry"
)

// machineID reads the Windows installation's MachineGuid (read-only).
func machineID() string {
	k, err := registry.OpenKey(registry.LOCAL_MACHINE, `SOFTWARE\Microsoft\Cryptography`, registry.QUERY_VALUE|registry.WOW64_64KEY)
	if err != nil {
		return ""
	}
	defer k.Close()
	v, _, err := k.GetStringValue("MachineGuid")
	if err != nil {
		return ""
	}
	return v
}

// Elevated reports an elevated token: AER Connect's host refuses to run so
// (the native helper checks too).
func Elevated() bool {
	return windows.GetCurrentProcessToken().IsElevated()
}
