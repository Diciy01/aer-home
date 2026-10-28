package powerhost

import (
	"syscall"
	"time"
)

var tick64 = syscall.NewLazyDLL("kernel32.dll").NewProc("GetTickCount64")

// windowsBootID is the boot time rounded to a minute (uptime is
// monotonic; rounding absorbs clock jitter between hellos).
func windowsBootID() string {
	ms, _, _ := tick64.Call()
	boot := time.Now().Add(-time.Duration(ms) * time.Millisecond).UTC().Round(time.Minute)
	return "win-" + boot.Format("20060102T1504Z")
}
