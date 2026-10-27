//go:build !linux

package bots

import (
	"errors"
	"time"
)

type cpuSample struct {
	at     time.Time
	cpuSec float64
}

var errNoProc = errors.New("process metrics are collected on Linux only")

func readCPU(int) (cpuSample, error) { return cpuSample{}, errNoProc }

func readRSS(int) (float64, error) { return 0, errNoProc }
