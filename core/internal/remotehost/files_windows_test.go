//go:build windows

package remotehost

import "testing"

func TestWindowsExchangeFileNames(t *testing.T) {
	for _, name := range []string{"CON", "con.txt", "LPT1.txt", "COM1", "file.txt:stream", "trailing.", "trailing ", "a?b", "a\x01b"} {
		if validName(name) {
			t.Errorf("accepted Windows device/stream/ambiguous name %q", name)
		}
	}
	for _, name := range []string{"Отчёт.txt", "report.txt", "two words.txt"} {
		if !validName(name) {
			t.Errorf("rejected plain name %q", name)
		}
	}
}
