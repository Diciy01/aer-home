package powerhost

import "testing"

// TEST DATA: outputs below follow the real tools' formats; disk GUIDs and
// firmware GUIDs are fixtures.

const efibootmgrOut = `BootCurrent: 0001
Timeout: 1 seconds
BootOrder: 0001,0000,0003
Boot0000* Ubuntu	HD(1,GPT,00000000-0000-4000-8000-000000000001,0x800,0x219800)/File(\EFI\UBUNTU\SHIMX64.EFI)
Boot0001* OSSwitcher rEFInd	HD(1,GPT,00000000-0000-4000-8000-000000000001,0x800,0x219800)/File(\EFI\REFIND\SHIMX64.EFI)
Boot0002  Old entry	HD(1,GPT,00000000-0000-4000-8000-000000000001,0x800,0x219800)/File(\EFI\OLD\X.EFI)
Boot0003* Windows Boot Manager	HD(1,GPT,00000000-0000-4000-8000-000000000001,0x800,0x219800)/File(\EFI\MICROSOFT\BOOT\BOOTMGFW.EFI)57494e444f5753000100
Boot0004* UEFI: USB Stick	PciRoot(0x0)/Pci(0x14,0x0)/USB(3,0)
`

func TestParseEfibootmgr(t *testing.T) {
	e, cur := ParseEfibootmgr(efibootmgrOut)
	if cur != "0001" || len(e) != 4 {
		t.Fatalf("%s %+v", cur, e)
	}
	want := map[string]string{"0000": "linux", "0001": "bootmanager", "0003": "windows", "0004": "other"}
	for _, x := range e {
		if want[x.ID] != x.OS {
			t.Errorf("%s: %s", x.ID, x.OS)
		}
		if x.Current != (x.ID == "0001") {
			t.Errorf("current %s", x.ID)
		}
	}
	if m := bootManagerOf(e); m != "refind" {
		t.Fatalf("boot manager %s", m)
	}
	// An older efibootmgr without paths still classifies by label.
	e, _ = ParseEfibootmgr("BootCurrent: 0000\nBoot0000* ubuntu\nBoot0003* Windows Boot Manager\n")
	if len(e) != 2 || e[0].OS != "linux" || e[1].OS != "windows" || bootManagerOf(e) != "grub" {
		t.Fatalf("labels only: %+v", e)
	}
}

func TestParseLsblkBitLocker(t *testing.T) {
	cases := map[string]string{
		`{"blockdevices":[{"name":"nvme0n1","fstype":null,"children":[{"name":"nvme0n1p2","fstype":"ntfs"}]}]}`:      "off",
		`{"blockdevices":[{"name":"nvme0n1","fstype":null,"children":[{"name":"nvme0n1p2","fstype":"BitLocker"}]}]}`: "on",
		`{"blockdevices":[{"name":"sda","fstype":null,"children":[{"name":"sda1","fstype":"ext4"}]}]}`:               "n/a",
		`not json`: "unknown",
	}
	for in, want := range cases {
		if got := ParseLsblkBitLocker([]byte(in)); got != want {
			t.Errorf("%s → %s, want %s", in, got, want)
		}
	}
}

func TestParseLogindCan(t *testing.T) {
	for in, want := range map[string]string{`s "yes"` + "\n": "yes", `s "challenge"`: "challenge", `s "na"`: "na", "Failed to connect": ""} {
		if got := ParseLogindCan(in); got != want {
			t.Errorf("%q → %q", in, got)
		}
	}
}

const bcdEN = `Firmware Boot Manager
---------------------
identifier              {fwbootmgr}
displayorder            {a0000000-0000-4000-8000-000000000001}
                        {a0000000-0000-4000-8000-000000000002}
timeout                 1

Windows Boot Manager
--------------------
identifier              {bootmgr}
device                  partition=\Device\HarddiskVolume1
path                    \EFI\Microsoft\Boot\bootmgfw.efi
description             Windows Boot Manager

Firmware Application (101fffff)
-------------------------------
identifier              {a0000000-0000-4000-8000-000000000002}
device                  partition=\Device\HarddiskVolume1
path                    \EFI\ubuntu\shimx64.efi
description             ubuntu

Firmware Application (101fffff)
-------------------------------
identifier              {a0000000-0000-4000-8000-000000000001}
path                    \EFI\Microsoft\Boot\bootmgfw.efi
description             Windows Boot Manager

Firmware Application (101fffff)
-------------------------------
identifier              {11111111-2222-3333-4444-555555555555}
path                    \EFI\refind\shimx64.efi
description             OSSwitcher rEFInd
`

const bcdRU = `Диспетчер загрузки встроенного ПО
---------------------------------
идентификатор           {fwbootmgr}

Приложение встроенного ПО (101fffff)
------------------------------------
идентификатор           {a0000000-0000-4000-8000-000000000002}
путь                    \EFI\ubuntu\shimx64.efi
описание                ubuntu
`

func TestParseBcdeditFirmware(t *testing.T) {
	e := ParseBcdeditFirmware(bcdEN)
	if len(e) != 3 || e[0].OS != "linux" || e[0].ID != "{a0000000-0000-4000-8000-000000000002}" || e[1].OS != "windows" || e[2].OS != "bootmanager" {
		t.Fatalf("en: %+v", e)
	}
	e = ParseBcdeditFirmware(bcdRU)
	if len(e) != 1 || e[0].OS != "linux" || e[0].ID != "{a0000000-0000-4000-8000-000000000002}" {
		t.Fatalf("ru: %+v", e)
	}
}

func TestParseManageBde(t *testing.T) {
	cases := map[string]string{
		"Conversion Status:    Fully Decrypted\n    Protection Status:    Protection Off":     "off",
		"Conversion Status:    Fully Encrypted\n    Protection Status:    Protection On":      "on",
		"Conversion Status:    Fully Encrypted\n    Protection Status:    Protection Off":     "on",
		"Состояние преобразования: Полностью расшифрован\nСостояние защиты: Защита отключена": "off",
		"ERROR: An attempt to access a required resource was denied.":                         "unknown",
	}
	for in, want := range cases {
		if got := ParseManageBde(in); got != want {
			t.Errorf("%q → %s, want %s", in, got, want)
		}
	}
}
