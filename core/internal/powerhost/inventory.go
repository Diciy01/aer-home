package powerhost

import (
	"bufio"
	"encoding/json"
	"regexp"
	"strings"
)

// HostInfo mirrors power.HostInfo (agent side; no secrets).
type HostInfo struct {
	OS          string                `json:"os"`
	OSVersion   string                `json:"osVersion"`
	Hostname    string                `json:"hostname"`
	Version     string                `json:"version"`
	BootID      string                `json:"bootId"`
	DryRun      bool                  `json:"dryRun"`
	Firmware    string                `json:"firmware"`
	SecureBoot  string                `json:"secureBoot"`
	BitLocker   string                `json:"bitlocker"`
	BootManager string                `json:"bootManager"`
	BootEntries []BootEntry           `json:"bootEntries"`
	MACs        []string              `json:"macs"`
	Actions     map[string]Capability `json:"actions"`
}

// BootEntry is one firmware boot entry.
type BootEntry struct {
	ID      string `json:"id"`
	Label   string `json:"label"`
	OS      string `json:"os"`
	Current bool   `json:"current"`
	path    string
}

// Capability is one action on this host, or why not.
type Capability struct {
	Supported bool   `json:"supported"`
	Reason    string `json:"reason"`
}

var (
	uefiID   = regexp.MustCompile(`^[0-9A-Fa-f]{4}$`)
	guidID   = regexp.MustCompile(`^\{[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\}$`)
	bootLine = regexp.MustCompile(`^Boot([0-9A-Fa-f]{4})(\*?)\s+(.*)$`)
	filePart = regexp.MustCompile(`File\(([^)]*)\)`)
)

// classify maps an entry to linux | windows | bootmanager | other by its
// loader path and label. Boot managers (rEFInd) are never a switch target.
func classify(label, path string) string {
	l, p := strings.ToLower(label), strings.ToLower(strings.ReplaceAll(path, "/", `\`))
	switch {
	case strings.Contains(p, `\microsoft\boot\bootmgfw.efi`) || strings.Contains(l, "windows boot manager"):
		return "windows"
	case strings.Contains(p, `\refind\`) || strings.Contains(l, "refind"):
		return "bootmanager"
	case strings.Contains(p, `\ubuntu\`) || strings.Contains(l, "ubuntu"):
		return "linux"
	}
	return "other"
}

// ParseEfibootmgr reads `efibootmgr` output: active entries only (an
// inactive entry is skipped by firmware and is not a valid target).
func ParseEfibootmgr(out string) (entries []BootEntry, current string) {
	sc := bufio.NewScanner(strings.NewReader(out))
	for sc.Scan() {
		line := strings.TrimRight(sc.Text(), "\r")
		if v, ok := strings.CutPrefix(line, "BootCurrent:"); ok {
			current = strings.ToUpper(strings.TrimSpace(v))
			continue
		}
		m := bootLine.FindStringSubmatch(line)
		if m == nil || m[2] != "*" {
			continue
		}
		label, rest, _ := strings.Cut(m[3], "\t")
		path := ""
		if f := filePart.FindStringSubmatch(rest); f != nil {
			path = f[1]
		}
		label = strings.TrimSpace(label)
		entries = append(entries, BootEntry{ID: strings.ToUpper(m[1]), Label: label, OS: classify(label, path), path: path})
	}
	for i := range entries {
		entries[i].Current = entries[i].ID == current
	}
	return entries, current
}

// bootManagerOf names what the firmware started this time.
func bootManagerOf(entries []BootEntry) string {
	for _, e := range entries {
		if !e.Current {
			continue
		}
		switch {
		case e.OS == "bootmanager" && strings.Contains(strings.ToLower(e.path+e.Label), "refind"):
			return "refind"
		case e.OS == "linux":
			return "grub"
		case e.OS == "windows":
			return "windows"
		}
		return "other"
	}
	return "unknown"
}

// ParseLsblkBitLocker: "on" if any block device is a BitLocker volume,
// "off" if NTFS volumes exist but none is BitLocker, "n/a" otherwise.
func ParseLsblkBitLocker(out []byte) string {
	var doc struct {
		Blockdevices []lsblkDev `json:"blockdevices"`
	}
	if json.Unmarshal(out, &doc) != nil {
		return "unknown"
	}
	ntfs, bl := false, false
	var walk func([]lsblkDev)
	walk = func(ds []lsblkDev) {
		for _, d := range ds {
			switch strings.ToLower(d.FSType) {
			case "bitlocker":
				bl = true
			case "ntfs":
				ntfs = true
			}
			walk(d.Children)
		}
	}
	walk(doc.Blockdevices)
	switch {
	case bl:
		return "on"
	case ntfs:
		return "off"
	}
	return "n/a"
}

type lsblkDev struct {
	Name     string     `json:"name"`
	FSType   string     `json:"fstype"`
	Children []lsblkDev `json:"children"`
}

// ParseLogindCan reads `busctl call … CanPowerOff` output (s "yes").
func ParseLogindCan(out string) string {
	f := strings.Fields(strings.TrimSpace(out))
	if len(f) == 2 && f[0] == "s" {
		return strings.Trim(f[1], `"`)
	}
	return ""
}

// ParseBcdeditFirmware reads `bcdedit /enum firmware` (English or Russian
// field names): one entry per block with an identifier GUID.
func ParseBcdeditFirmware(out string) []BootEntry {
	var entries []BootEntry
	var cur *BootEntry
	flush := func() {
		if cur != nil && guidID.MatchString(cur.ID) {
			cur.OS = classify(cur.Label, cur.path)
			entries = append(entries, *cur)
		}
		cur = nil
	}
	sc := bufio.NewScanner(strings.NewReader(out))
	for sc.Scan() {
		line := strings.TrimRight(sc.Text(), "\r")
		f := strings.Fields(line)
		if len(f) < 2 {
			continue
		}
		key, val := strings.ToLower(f[0]), strings.TrimSpace(strings.TrimPrefix(strings.TrimSpace(line), f[0]))
		switch key {
		case "identifier", "идентификатор":
			flush()
			cur = &BootEntry{ID: strings.ToLower(val)}
		case "description", "описание":
			if cur != nil {
				cur.Label = val
			}
		case "path", "путь":
			if cur != nil {
				cur.path = val
			}
		}
	}
	flush()
	return entries
}

// markWindowsCurrent: a running Windows was started by Windows Boot Manager.
func markWindowsCurrent(entries []BootEntry) {
	for i := range entries {
		entries[i].Current = entries[i].OS == "windows"
	}
}

// ParseManageBde reads `manage-bde -status C:` (English/Russian).
func ParseManageBde(out string) string {
	l := strings.ToLower(out)
	switch {
	case strings.Contains(l, "protection on") || strings.Contains(l, "защита включена"):
		return "on"
	case strings.Contains(l, "protection off") || strings.Contains(l, "защита отключена"):
		if strings.Contains(l, "fully decrypted") || strings.Contains(l, "полностью расшифрован") {
			return "off"
		}
		// Encrypted but suspended protection still matters for recovery.
		return "on"
	}
	return "unknown"
}
