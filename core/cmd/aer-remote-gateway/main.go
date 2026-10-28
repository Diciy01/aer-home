// Command aer-remote-gateway is the AER Remote Gateway (M14, ADR-017): the
// single TLS entry point for remote access clients and host agents outside
// the home. Core decides everything; the Gateway relays.
//
//	aer-remote-gateway -config /path/remote-gateway.json
//	aer-remote-gateway -config /path/remote-gateway.json -fingerprint
//
// It is never installed or exposed automatically: forwarding a WAN port to
// it is the owner's manual step (docs/REMOTE_GATEWAY.md).
package main

import (
	"context"
	"flag"
	"fmt"
	"log/slog"
	"os"
	"os/signal"
	"syscall"

	"aerhome/core/internal/remotegw"
)

func main() {
	path := flag.String("config", "", "config file (JSON)")
	fp := flag.Bool("fingerprint", false, "print the certificate fingerprint clients pin, then exit")
	version := flag.Bool("version", false, "print version")
	flag.Parse()
	if *version {
		fmt.Println("aer-remote-gateway", remotegw.Version)
		return
	}
	log := slog.New(slog.NewTextHandler(os.Stderr, nil))
	cfg, err := remotegw.Load(*path)
	if err != nil {
		log.Error("config", "err", err)
		os.Exit(2)
	}
	g, err := remotegw.New(cfg, log)
	if err != nil {
		log.Error("start", "err", err)
		os.Exit(1)
	}
	sum, err := g.Fingerprint()
	if err != nil {
		log.Error("certificate", "err", err)
		os.Exit(1)
	}
	if *fp {
		fmt.Println(sum)
		return
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	log.Info("aer-remote-gateway started", "listen", cfg.ListenAddr, "certSha256", sum)
	if err := g.Run(ctx); err != nil {
		log.Error("stopped", "err", err)
		os.Exit(1)
	}
	log.Info("aer-remote-gateway stopped; tunnels closed")
}
