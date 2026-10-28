package powerhost

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"net"
	"os"
	"os/exec"
	"runtime"
	"slices"
	"strings"
	"time"
)

// Runner runs a command and returns combined output (tests inject fakes).
type Runner func(ctx context.Context, argv []string) ([]byte, error)

func execRunner(ctx context.Context, argv []string) ([]byte, error) {
	cmd := exec.CommandContext(ctx, argv[0], argv[1:]...)
	var out bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &out
	err := cmd.Run()
	return out.Bytes(), err
}

// Host gathers facts and plans fixed argv for one OS. Every field is
// replaceable in tests; nothing here writes to the system.
type Host struct {
	GOOS     string
	Run      Runner
	ReadFile func(string) ([]byte, error)
	Stat     func(string) (os.FileInfo, error)
	Hostname func() (string, error)
	MACs     func() []string
	cfg      Config
}

// NewHost is the real host of this process.
func NewHost(cfg Config) *Host {
	return &Host{GOOS: runtime.GOOS, Run: execRunner, ReadFile: os.ReadFile, Stat: os.Stat, Hostname: os.Hostname, MACs: physicalMACs, cfg: cfg}
}

func physicalMACs() []string {
	out := []string{}
	ifs, _ := net.Interfaces()
	for _, i := range ifs {
		if i.Flags&net.FlagLoopback != 0 || len(i.HardwareAddr) != 6 {
			continue
		}
		if runtime.GOOS == "linux" {
			if _, err := os.Stat("/sys/class/net/" + i.Name + "/device"); err != nil {
				continue // virtual: bridges, veth, tun
			}
		}
		out = append(out, i.HardwareAddr.String())
	}
	return out
}

func (h *Host) run(ctx context.Context, argv ...string) (string, error) {
	ctx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	out, err := h.Run(ctx, argv)
	return string(out), err
}

func (h *Host) allowed(a string) bool { return slices.Contains(h.cfg.Allow, a) }

// Inventory collects facts; failures degrade to "unknown" with a reason.
func (h *Host) Inventory(ctx context.Context) HostInfo {
	info := HostInfo{OS: h.GOOS, Version: Version, DryRun: !h.cfg.Execute, Firmware: "unknown", SecureBoot: "unknown",
		BitLocker: "unknown", BootManager: "unknown", BootEntries: []BootEntry{}, MACs: h.MACs(), Actions: map[string]Capability{}}
	info.Hostname, _ = h.Hostname()
	switch h.GOOS {
	case "linux":
		h.linux(ctx, &info)
	case "windows":
		h.windows(ctx, &info)
	default:
		for _, a := range allActions {
			info.Actions[a] = Capability{Reason: "ОС " + h.GOOS + " не поддерживается агентом питания"}
		}
	}
	for _, a := range allActions {
		if c := info.Actions[a]; c.Supported && !h.allowed(a) {
			info.Actions[a] = Capability{Reason: "Запрещено в конфигурации агента на этом компьютере (allow)"}
		}
	}
	return info
}

func (h *Host) linux(ctx context.Context, info *HostInfo) {
	info.OS = "linux"
	if b, err := h.ReadFile("/etc/os-release"); err == nil {
		for _, l := range strings.Split(string(b), "\n") {
			if v, ok := strings.CutPrefix(l, "PRETTY_NAME="); ok {
				info.OSVersion = strings.Trim(v, `"`)
			}
		}
	}
	if b, err := h.ReadFile("/proc/sys/kernel/random/boot_id"); err == nil {
		info.BootID = strings.TrimSpace(string(b))
	}
	if _, err := h.Stat("/sys/firmware/efi"); err == nil {
		info.Firmware = "uefi"
		// efivarfs is world-readable: 4 attribute bytes, then the value.
		if b, err := h.ReadFile("/sys/firmware/efi/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c"); err == nil && len(b) >= 5 {
			info.SecureBoot = map[bool]string{true: "enabled", false: "disabled"}[b[4] == 1]
		}
		if out, err := h.run(ctx, "efibootmgr"); err == nil {
			info.BootEntries, _ = ParseEfibootmgr(out)
			info.BootManager = bootManagerOf(info.BootEntries)
		}
	} else {
		info.Firmware = "bios"
	}
	if out, err := h.run(ctx, "lsblk", "-J", "-o", "NAME,FSTYPE"); err == nil {
		info.BitLocker = ParseLsblkBitLocker([]byte(out))
	}
	for action, method := range map[string]string{"shutdown": "CanPowerOff", "reboot": "CanReboot", "suspend": "CanSuspend"} {
		out, err := h.run(ctx, "busctl", "call", "org.freedesktop.login1", "/org/freedesktop/login1", "org.freedesktop.login1.Manager", method)
		switch v := ParseLogindCan(out); {
		case err != nil:
			info.Actions[action] = Capability{Reason: "logind недоступен: " + firstLine(out, err)}
		case v == "yes":
			info.Actions[action] = Capability{Supported: true}
		case v == "challenge":
			info.Actions[action] = Capability{Reason: "Система требует пароль (polkit) — удалённо недоступно"}
		default:
			info.Actions[action] = Capability{Reason: "logind: " + or(v, "нет ответа")}
		}
	}
	info.Actions["bootNext"] = h.linuxBootNext(ctx, info)
}

func (h *Host) linuxBootNext(ctx context.Context, info *HostInfo) Capability {
	switch {
	case info.Firmware != "uefi":
		return Capability{Reason: "Не UEFI: одноразовая загрузка BootNext недоступна"}
	case len(info.BootEntries) == 0:
		return Capability{Reason: "efibootmgr не вернул загрузочные записи"}
	case !info.Actions["reboot"].Supported:
		return Capability{Reason: "Перезагрузка недоступна: " + info.Actions["reboot"].Reason}
	}
	helper := h.cfg.BootNextHelper
	if helper[0] == "sudo" {
		// Read-only listing; a cached sudo password must not count, so a
		// NOPASSWD rule for this binary (or ALL) is required.
		out, err := h.run(ctx, "sudo", "-n", "-l")
		if err != nil || !NopasswdAllows(out, helper[len(helper)-1]) {
			return Capability{Reason: "Нет помощника с правами: разрешите «" + strings.Join(helper, " ") +
				" --bootnext» без пароля в sudoers (решение владельца; AER его не устанавливает)"}
		}
	}
	return Capability{Supported: true}
}

// NopasswdAllows reads `sudo -n -l` and reports whether a NOPASSWD rule
// covers bin (by path, path with arguments, or ALL).
func NopasswdAllows(listing, bin string) bool {
	for _, line := range strings.Split(listing, "\n") {
		_, cmds, ok := strings.Cut(line, "NOPASSWD:")
		if !ok {
			continue
		}
		for _, c := range strings.Split(cmds, ",") {
			c = strings.TrimSpace(c)
			if c == "ALL" || c == bin || strings.HasPrefix(c, bin+" ") {
				return true
			}
		}
	}
	return false
}

func (h *Host) windows(ctx context.Context, info *HostInfo) {
	info.OS, info.Firmware = "windows", "uefi"
	if out, err := h.run(ctx, "cmd", "/c", "ver"); err == nil {
		info.OSVersion = strings.TrimSpace(out)
	}
	info.BootID = windowsBootID()
	if out, err := h.run(ctx, "powershell", "-NoProfile", "-NonInteractive", "-Command", "Confirm-SecureBootUEFI"); err == nil {
		switch strings.TrimSpace(out) {
		case "True":
			info.SecureBoot = "enabled"
		case "False":
			info.SecureBoot = "disabled"
		}
	} else if strings.Contains(out, "not supported") {
		info.Firmware = "bios"
	}
	if out, err := h.run(ctx, "manage-bde", "-status", "C:"); err == nil {
		info.BitLocker = ParseManageBde(out)
	}
	fwOK := false
	if out, err := h.run(ctx, "bcdedit", "/enum", "firmware"); err == nil {
		info.BootEntries = ParseBcdeditFirmware(out)
		markWindowsCurrent(info.BootEntries)
		info.BootManager, fwOK = "windows", len(info.BootEntries) > 0
	}
	info.Actions["shutdown"] = Capability{Supported: true}
	info.Actions["reboot"] = Capability{Supported: true}
	info.Actions["suspend"] = Capability{Reason: "Сон на Windows через AER не поддерживается: нет надёжной команды без изменения настроек гибернации"}
	switch {
	case info.Firmware != "uefi":
		info.Actions["bootNext"] = Capability{Reason: "Не UEFI"}
	case !fwOK:
		info.Actions["bootNext"] = Capability{Reason: "bcdedit /enum firmware недоступен: агент должен работать с правами администратора"}
	default:
		info.Actions["bootNext"] = Capability{Supported: true}
	}
}

func firstLine(out string, err error) string {
	if l, _, _ := strings.Cut(strings.TrimSpace(out), "\n"); l != "" {
		return l
	}
	return err.Error()
}

func or(a, b string) string {
	if a != "" {
		return a
	}
	return b
}

// Step is one fixed command of a plan; Check validates its output.
type Step struct {
	Argv  []string
	Check func(out string) error
}

// Plan validates a command against a fresh inventory and returns the
// fixed argv to run. Nothing from Core is ever used as argv except an
// entry id that this inventory itself lists for the target OS.
func (h *Host) Plan(c Command, inv HostInfo) ([]Step, error) {
	key := c.Action
	if key == "switch_os" {
		key = "bootNext"
	}
	if cp, ok := inv.Actions[key]; !ok || !cp.Supported {
		return nil, fmt.Errorf("действие недоступно на этом компьютере: %s", or(cp.Reason, key))
	}
	win := inv.OS == "windows"
	delay := fmt.Sprint(h.cfg.WindowsDelaySec)
	reboot := Step{Argv: []string{"systemctl", "reboot"}}
	if win {
		reboot = Step{Argv: []string{"shutdown.exe", "/r", "/t", delay, "/c", "AER HOME: перезагрузка по команде владельца"}}
	}
	switch c.Action {
	case "shutdown":
		if win {
			return []Step{{Argv: []string{"shutdown.exe", "/s", "/t", delay, "/c", "AER HOME: выключение по команде владельца"}}}, nil
		}
		return []Step{{Argv: []string{"systemctl", "poweroff"}}}, nil
	case "reboot":
		return []Step{reboot}, nil
	case "suspend":
		if win {
			return nil, errors.New("сон на Windows не поддерживается")
		}
		return []Step{{Argv: []string{"systemctl", "suspend"}}}, nil
	case "switch_os":
		var match *BootEntry
		for i, e := range inv.BootEntries {
			if strings.EqualFold(e.ID, c.EntryID) {
				match = &inv.BootEntries[i]
			}
		}
		switch {
		case match == nil:
			return nil, fmt.Errorf("загрузочной записи %q нет в текущей инвентаризации", c.EntryID)
		case match.OS != c.TargetOS || (c.TargetOS != "linux" && c.TargetOS != "windows"):
			return nil, fmt.Errorf("запись %s ведёт в %s, а не в %s", match.ID, match.OS, c.TargetOS)
		case match.OS == inv.OS:
			return nil, errors.New("целевая ОС уже загружена")
		}
		if win {
			if !guidID.MatchString(match.ID) {
				return nil, errors.New("идентификатор записи Windows должен быть GUID")
			}
			set := Step{Argv: []string{"bcdedit", "/set", "{fwbootmgr}", "bootsequence", match.ID}, Check: func(out string) error {
				if !strings.Contains(strings.ToLower(out), "success") && !strings.Contains(strings.ToLower(out), "успешно") {
					return errors.New("bcdedit не подтвердил bootsequence: " + firstLine(out, errors.New("пусто")))
				}
				return nil
			}}
			return []Step{set, reboot}, nil
		}
		if !uefiID.MatchString(match.ID) {
			return nil, errors.New("номер записи UEFI должен быть 4 шестнадцатеричные цифры")
		}
		argv := append(slices.Clone(h.cfg.BootNextHelper), "--bootnext", match.ID)
		set := Step{Argv: argv, Check: func(out string) error {
			if !strings.Contains(out, "BootNext: "+match.ID) {
				return errors.New("efibootmgr не подтвердил BootNext " + match.ID)
			}
			return nil
		}}
		return []Step{set, reboot}, nil
	}
	return nil, fmt.Errorf("неизвестное действие %q", c.Action)
}
