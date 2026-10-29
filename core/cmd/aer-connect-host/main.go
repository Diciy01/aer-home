// Command aer-connect-host is the host half of AER Connect (ADR-018). The
// AER Connect app starts it as a child process and talks JSON lines over
// stdin/stdout (internal/connecthost); it is not meant to be run by hand.
// It opens only outgoing TLS connections to the owner's Gateway, keeps
// device secrets in memory, and stops when the app closes its stdin.
//
//	aer-connect-host                 # serve (first stdin line: init)
//	aer-connect-host -keygen         # new X25519 device key as JSON
//	aer-connect-host -instance ID    # clone-detection fingerprint of ID on this machine
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

	"aerhome/core/internal/connecthost"
	"aerhome/core/internal/remoteengine"
	"aerhome/core/internal/remotehost"
)

func main() {
	keygen := flag.Bool("keygen", false, "print a new device key pair")
	instance := flag.String("instance", "", "print the instance fingerprint of this install id")
	version := flag.Bool("version", false, "print version")
	flag.Parse()
	switch {
	case *version:
		fmt.Println("aer-connect-host", remotehost.Version)
		return
	case *keygen:
		k, err := remoteengine.NewBoxKey()
		if err != nil {
			os.Exit(1)
		}
		_ = json.NewEncoder(os.Stdout).Encode(map[string]string{"private": remoteengine.EncodeKey(k.Bytes()),
			"public": remoteengine.EncodeKey(k.PublicKey().Bytes())})
		return
	case *instance != "":
		fmt.Println(connecthost.Instance(*instance))
		return
	}
	if connecthost.Elevated() {
		_ = json.NewEncoder(os.Stdout).Encode(connecthost.Out{Type: "fatal",
			Message: "AER Connect запущен с правами администратора — входящий доступ не включается. Запустите приложение обычным образом."})
		os.Exit(4)
	}
	log := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelWarn}))
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	err := connecthost.Run(ctx, os.Stdin, os.Stdout, connecthost.Options{Log: log})
	switch {
	case err == connecthost.ErrRevoked:
		os.Exit(3)
	case err != nil:
		log.Error("stopped", "err", err)
		os.Exit(1)
	}
}
