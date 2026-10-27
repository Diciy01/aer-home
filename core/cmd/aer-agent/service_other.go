//go:build !windows

package main

import (
	"errors"
	"log/slog"
)

func isService() bool { return false }

func runService(string, *slog.Logger) error {
	return errors.New("service mode is Windows-only; use systemd on Linux")
}
