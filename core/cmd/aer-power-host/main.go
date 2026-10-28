// Command aer-power-host is the AER Power host agent (M08): it reports
// power facts and the boot inventory of this OS and runs a closed set of
// power actions (shutdown, reboot, suspend, one-time boot of the other OS)
// through fixed argv adapters. Without "execute": true it runs nothing.
//
//	aer-power-host -config /path/power-host.json
//	aer-power-host -config /path/power-host.json -inventory   # print facts, no Core
//
// It is never installed automatically; see docs/POWER_CONNECT.md.
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"log/slog"
	"os"
	"os/signal"
	"syscall"

	"aerhome/core/internal/powerhost"
)

func main() {
	path := flag.String("config", "", "config file (JSON)")
	inventory := flag.Bool("inventory", false, "print the inventory this agent would report and exit")
	version := flag.Bool("version", false, "print version")
	flag.Parse()
	if *version {
		fmt.Println("aer-power-host", powerhost.Version)
		return
	}
	log := slog.New(slog.NewTextHandler(os.Stderr, nil))
	cfg, err := powerhost.Load(*path)
	if err != nil {
		log.Error("config", "err", err)
		os.Exit(2)
	}
	a := powerhost.New(cfg, log)
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	if *inventory {
		enc := json.NewEncoder(os.Stdout)
		enc.SetIndent("", "  ")
		_ = enc.Encode(a.Host().Inventory(ctx))
		return
	}
	mode := "check mode (nothing is executed)"
	if cfg.Execute {
		mode = "EXECUTE"
	}
	log.Info("aer-power-host started", "mode", mode, "allow", cfg.Allow)
	if err := a.Run(ctx); err != nil {
		log.Error("stopped", "err", err)
		os.Exit(1)
	}
	log.Info("aer-power-host stopped")
}
