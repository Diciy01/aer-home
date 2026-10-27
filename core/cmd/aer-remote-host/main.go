// Command aer-remote-host is the AER Remote host agent (M07): it opens the
// local RDP server only for sessions authorized by Core, with a new
// password per session, and closes it on end, revoke or expiry.
//
//	aer-remote-host -config /path/remote-host.json
//
// It is never installed automatically; see docs/REMOTE_CONNECT.md.
package main

import (
	"context"
	"flag"
	"fmt"
	"log/slog"
	"os"
	"os/signal"
	"syscall"

	"aerhome/core/internal/remotehost"
)

func main() {
	path := flag.String("config", "", "config file (JSON)")
	version := flag.Bool("version", false, "print version")
	flag.Parse()
	if *version {
		fmt.Println("aer-remote-host", remotehost.Version)
		return
	}
	log := slog.New(slog.NewTextHandler(os.Stderr, nil))
	cfg, err := remotehost.Load(*path)
	if err != nil {
		log.Error("config", "err", err)
		os.Exit(2)
	}
	a, err := remotehost.New(cfg, log)
	if err != nil {
		log.Error("start", "err", err)
		os.Exit(1)
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	log.Info("aer-remote-host started", "backend", cfg.Backend, "port", cfg.Port, "approval", cfg.Approval)
	if err := a.Run(ctx); err != nil {
		log.Error("stopped", "err", err)
		os.Exit(1)
	}
	log.Info("aer-remote-host stopped; RDP disabled")
}
