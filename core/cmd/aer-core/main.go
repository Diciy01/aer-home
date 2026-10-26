// Command aer-core runs the AER HOME Core: REST API + SQLite, single process.
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"net"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"aerhome/core/internal/buildinfo"
	"aerhome/core/internal/core"
	"aerhome/core/internal/foundation/config"
	"aerhome/core/internal/foundation/logging"
	"aerhome/core/internal/modules"
)

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, "aer-core:", err)
		os.Exit(1)
	}
}

func run() error {
	configPath := flag.String("config", os.Getenv("AER_CONFIG"), "path to JSON config file (optional)")
	showVersion := flag.Bool("version", false, "print version and exit")
	flag.Parse()
	if *showVersion {
		fmt.Println(buildinfo.Version)
		return nil
	}

	cfg, err := config.Load(*configPath, os.LookupEnv)
	if err != nil {
		return err
	}
	log, err := logging.New(os.Stderr, cfg.LogLevel, cfg.LogFormat)
	if err != nil {
		return err
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	c, err := core.New(ctx, core.Options{Config: cfg, Logger: log, Modules: modules.All()})
	if err != nil {
		return err
	}
	defer c.Close()
	if c.TokenCreated() {
		// Print the location only; the token itself is never logged.
		log.Info("created new API token", "path", cfg.TokenPath())
	}

	ln, err := net.Listen("tcp", cfg.ListenAddr)
	if err != nil {
		return fmt.Errorf("listen %s: %w", cfg.ListenAddr, err)
	}
	srv := &http.Server{
		Handler:           c.Handler(),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       15 * time.Second,
		WriteTimeout:      30 * time.Second,
		IdleTimeout:       60 * time.Second,
	}
	log.Info("aer-core started", "version", buildinfo.Version, "mode", cfg.Mode,
		"listen", ln.Addr().String(), "dataDir", cfg.DataDir, "demo", cfg.IsDemo())

	errc := make(chan error, 1)
	go func() { errc <- srv.Serve(ln) }()

	select {
	case err := <-errc:
		if !errors.Is(err, http.ErrServerClosed) {
			return err
		}
	case <-ctx.Done():
		log.Info("shutting down")
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		if err := srv.Shutdown(shutdownCtx); err != nil {
			return fmt.Errorf("shutdown: %w", err)
		}
	}
	return nil
}
