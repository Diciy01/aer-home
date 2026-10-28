package agent

import (
	"testing"
	"unicode/utf16"
	"unsafe"

	"golang.org/x/sys/windows"
)

// The real Service Control Manager, read-only: the event log service always
// runs; a missing service is an error, not "stopped".
func TestServiceRunningRealSCM(t *testing.T) {
	if ok, err := serviceRunning("EventLog"); err != nil || !ok {
		t.Fatalf("EventLog: %v %v", ok, err)
	}
	if _, err := serviceRunning("aer-no-such-service-m10"); err == nil {
		t.Fatal("missing service must be an error")
	}
}

// toANSI encodes like a console tool writing to a pipe (CP_ACP).
func toANSI(t *testing.T, s string) []byte {
	w := utf16.Encode([]rune(s))
	proc := windows.NewLazySystemDLL("kernel32.dll").NewProc("WideCharToMultiByte")
	call := func(dst []byte) int {
		var p uintptr
		if len(dst) > 0 {
			p = uintptr(unsafe.Pointer(&dst[0]))
		}
		n, _, _ := proc.Call(cpACP, 0, uintptr(unsafe.Pointer(&w[0])), uintptr(len(w)), p, uintptr(len(dst)), 0, 0)
		return int(n)
	}
	b := make([]byte, call(nil))
	if len(b) == 0 || call(b) != len(b) {
		t.Fatal("WideCharToMultiByte failed")
	}
	return b
}

// wevtutil output arrives in the ANSI code page; it must come out as text.
func TestFromANSIRoundTrip(t *testing.T) {
	if acp := windows.GetACP(); acp != 1251 && acp != 65001 {
		t.Skipf("ANSI code page %d has no Cyrillic", acp)
	}
	want := "Ошибка установки: plain ASCII too"
	if got := fromANSI(toANSI(t, want)); got != want {
		t.Fatalf("fromANSI = %q", got)
	}
	if fromANSI(nil) != "" {
		t.Fatal("empty")
	}
}
