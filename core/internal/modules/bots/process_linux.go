//go:build linux

package bots

import (
	"bytes"
	"fmt"
	"os"
	"strconv"
	"strings"
	"syscall"
	"time"
)

// Pdeathsig: if Core dies, its children get SIGTERM instead of running
// unsupervised.
func childAttrOS() *syscall.SysProcAttr {
	return &syscall.SysProcAttr{Setpgid: true, Pdeathsig: syscall.SIGTERM}
}

type cpuSample struct {
	at     time.Time
	cpuSec float64
}

const clkTck = 100 // USER_HZ on Linux

func readCPU(pid int) (cpuSample, error) {
	raw, err := os.ReadFile(fmt.Sprintf("/proc/%d/stat", pid))
	if err != nil {
		return cpuSample{}, err
	}
	// Fields after the ")" of comm: state is field 3; utime 14, stime 15.
	i := bytes.LastIndexByte(raw, ')')
	if i < 0 {
		return cpuSample{}, fmt.Errorf("bad stat")
	}
	f := strings.Fields(string(raw[i+1:]))
	if len(f) < 13 {
		return cpuSample{}, fmt.Errorf("bad stat")
	}
	ut, _ := strconv.ParseFloat(f[11], 64)
	st, _ := strconv.ParseFloat(f[12], 64)
	return cpuSample{at: time.Now(), cpuSec: (ut + st) / clkTck}, nil
}

func readRSS(pid int) (float64, error) {
	raw, err := os.ReadFile(fmt.Sprintf("/proc/%d/statm", pid))
	if err != nil {
		return 0, err
	}
	f := strings.Fields(string(raw))
	if len(f) < 2 {
		return 0, fmt.Errorf("bad statm")
	}
	pages, err := strconv.ParseFloat(f[1], 64)
	return pages * float64(os.Getpagesize()), err
}
