// Package powerhost is the AER Power host agent (aer-power-host, M08):
// it reports power facts and the boot inventory of this OS and runs a
// closed set of power actions through fixed argv adapters. By default it
// executes nothing (check mode) and answers "simulated".
package powerhost

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"runtime"
	"slices"
)

// Config of the power agent (JSON file; the token lives in TokenFile).
type Config struct {
	CoreURL   string `json:"coreUrl"`
	TokenFile string `json:"tokenFile"`
	// Execute: false (default) is check mode — nothing is run, every job
	// ends "simulated" with the argv that would have run.
	Execute bool `json:"execute"`
	// Allow restricts actions on this host (shutdown, reboot, suspend, bootNext).
	Allow []string `json:"allow"`
	// BootNextHelper is the privileged argv prefix for efibootmgr (Linux),
	// e.g. ["sudo","-n","/usr/bin/efibootmgr"]. A matching sudoers rule is
	// the owner's decision; AER never installs it.
	BootNextHelper []string `json:"bootNextHelper"`
	// WindowsDelaySec: shutdown.exe /t delay (lets the user cancel with shutdown /a).
	WindowsDelaySec int `json:"windowsDelaySec"`
}

var allActions = []string{"shutdown", "reboot", "suspend", "bootNext"}

// Load reads and validates a config file.
func Load(path string) (Config, error) {
	c := Config{Allow: slices.Clone(allActions), BootNextHelper: []string{"sudo", "-n", "/usr/bin/efibootmgr"}, WindowsDelaySec: 30}
	raw, err := os.ReadFile(path)
	if err != nil {
		return c, err
	}
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&c); err != nil {
		return c, fmt.Errorf("parse %s: %w", path, err)
	}
	return c, c.Validate()
}

// Validate rejects unsafe or incomplete settings.
func (c Config) Validate() error {
	var errs []error
	if u, err := url.Parse(c.CoreURL); err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Host == "" {
		errs = append(errs, errors.New("coreUrl: want http(s)://host:port"))
	}
	if !filepath.IsAbs(c.TokenFile) {
		errs = append(errs, errors.New("tokenFile: absolute path"))
	}
	for _, a := range c.Allow {
		if !slices.Contains(allActions, a) {
			errs = append(errs, fmt.Errorf("allow: %q, want %v", a, allActions))
		}
	}
	if runtime.GOOS != "windows" && (len(c.BootNextHelper) == 0 || !filepath.IsAbs(c.BootNextHelper[len(c.BootNextHelper)-1])) {
		errs = append(errs, errors.New("bootNextHelper: argv ending with the absolute path of efibootmgr"))
	}
	if c.WindowsDelaySec < 0 || c.WindowsDelaySec > 600 {
		errs = append(errs, errors.New("windowsDelaySec: 0…600"))
	}
	return errors.Join(errs...)
}
