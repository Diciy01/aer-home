// Package testenv lets tests written with Linux paths run on Windows too
// (M10). It is imported only from _test.go files.
package testenv

import (
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"testing"
)

// Abs turns a slash-rooted test path ("/x/t") into an absolute path on this
// OS: unchanged on Unix, "C:\x\t" on Windows. Only for paths that are never
// opened — dummies that config validation must accept as absolute.
func Abs(p string) string {
	if runtime.GOOS == "windows" {
		return `C:` + filepath.FromSlash(p)
	}
	return p
}

// Shell returns the absolute path of a POSIX sh for tests that run small
// scripts as child processes. On Windows it is the sh.exe of Git for Windows
// (usr\bin, not the bin\ launcher, so killing it kills the script); the test
// is skipped if none is found.
func Shell(t testing.TB) string {
	t.Helper()
	if runtime.GOOS != "windows" {
		return "/bin/sh"
	}
	if git, err := exec.LookPath("git"); err == nil {
		// git.exe lives in <root>\cmd or <root>\bin.
		sh := filepath.Join(filepath.Dir(filepath.Dir(git)), "usr", "bin", "sh.exe")
		if _, err := os.Stat(sh); err == nil {
			return sh
		}
	}
	t.Skip("no POSIX sh: install Git for Windows to run process tests")
	return ""
}

// LinuxOnly skips a test that loads a Linux-only artefact (a deploy example
// with Linux paths, a systemd unit) on other systems.
func LinuxOnly(t testing.TB, what string) {
	t.Helper()
	if runtime.GOOS != "linux" {
		t.Skipf("%s is Linux-only", what)
	}
}

// ExistingFile returns an absolute path that exists on this OS (the test
// binary itself), for configs whose executables are stat-ed but never run.
func ExistingFile(t testing.TB) string {
	t.Helper()
	p, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	return p
}
