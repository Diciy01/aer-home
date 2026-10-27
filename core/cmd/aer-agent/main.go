// Command aer-agent reports system metrics, service states and warning-level
// system logs of this computer to AER Core (M05). It runs independently of
// the AER HOME client; installation as a service is manual (docs/AGENTS.md).
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"log/slog"
	"os"
	"os/signal"
	"sort"
	"syscall"
	"time"

	"aerhome/core/internal/agent"
)

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, "aer-agent:", err)
		os.Exit(1)
	}
}

func build(cfgPath string, log *slog.Logger) (*agent.Agent, agent.Config, error) {
	cfg, err := agent.LoadConfig(cfgPath)
	if err != nil {
		return nil, cfg, err
	}
	sources := agent.PlatformSources(cfg.Collectors)
	if cfg.Collectors.SystemLogs {
		sources = append(sources, agent.SystemLogSource(time.Duration(cfg.LogIntervalSec)*time.Second))
	}
	names := map[string]string{}
	for _, s := range sources {
		names[s.Name()] = "on"
	}
	for _, off := range agent.Disabled(cfg.Collectors) {
		names[off] = "off"
	}
	return agent.New(cfg, sources, agent.PlatformInfo(names), log), cfg, nil
}

func run() error {
	cfgPath := flag.String("config", os.Getenv("AER_AGENT_CONFIG"), "path to agent JSON config")
	once := flag.Bool("once", false, "collect twice 2 s apart, print the report as JSON and exit (nothing is sent)")
	version := flag.Bool("version", false, "print version and exit")
	flag.Parse()
	if *version {
		fmt.Println(agent.Version)
		return nil
	}
	log := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelInfo}))
	if *once {
		return dryRun(*cfgPath)
	}
	if isService() {
		return runService(*cfgPath, log)
	}
	a, cfg, err := build(*cfgPath, log)
	if err != nil {
		return err
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	log.Info("aer-agent started", "version", agent.Version, "core", cfg.CoreURL, "intervalSec", cfg.IntervalSec)
	return a.Run(ctx)
}

// dryRun shows exactly what would be sent (no token needed, nothing sent).
func dryRun(cfgPath string) error {
	cfg := agent.DefaultConfig()
	if cfgPath != "" {
		var err error
		if cfg, err = agent.LoadConfig(cfgPath); err != nil {
			return err
		}
	}
	sources := agent.PlatformSources(cfg.Collectors)
	if cfg.Collectors.SystemLogs {
		sources = append(sources, agent.SystemLogSource(0))
	}
	var rep agent.Report
	for round := 0; round < 2; round++ { // rates and CPU need two readings
		rep.Samples = nil
		now := time.Now().UTC()
		for _, s := range sources {
			ss, ls := s.Collect(now)
			rep.Samples = append(rep.Samples, ss...)
			rep.Logs = append(rep.Logs, ls...)
		}
		if round == 0 {
			time.Sleep(2 * time.Second)
		}
	}
	rep.Agent = agent.PlatformInfo(nil)()
	sort.SliceStable(rep.Samples, func(i, j int) bool { return rep.Samples[i].Metric < rep.Samples[j].Metric })
	enc := json.NewEncoder(os.Stdout)
	enc.SetIndent("", "  ")
	enc.SetEscapeHTML(false)
	return enc.Encode(rep)
}
