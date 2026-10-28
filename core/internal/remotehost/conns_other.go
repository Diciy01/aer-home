//go:build !windows

package remotehost

func establishedWindows(int) int { return -1 }
