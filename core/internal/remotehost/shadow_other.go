//go:build !windows

package remotehost

import "errors"

func shadowPresenceCert(Config) (string, error) {
	return "", errors.New("windows-shadow requires Windows")
}

func newShadowBackend(Config) (Backend, error) {
	return nil, errors.New("windows-shadow requires Windows; use gnome-rdp on Linux")
}
