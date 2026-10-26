// Package buildinfo carries version data injected at build time:
//
//	go build -ldflags "-X aerhome/core/internal/buildinfo.Version=0.1.0" ./cmd/aer-core
package buildinfo

// Version of this Core build.
var Version = "0.1.0-dev"
