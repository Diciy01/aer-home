//go:build !windows

package powerhost

// windowsBootID is only meaningful on Windows (Linux reads boot_id).
func windowsBootID() string { return "" }
