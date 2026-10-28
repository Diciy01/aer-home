# S-Power — исследование: Wake-on-LAN, загрузчик, UEFI, BitLocker (2026-10-28)

Выполнено внутри M08 **только чтением** на основном ПК (dual-boot Ubuntu 24.04 / Windows 11). Ничего не изменялось: ни UEFI, ни NVRAM, ни GRUB/rEFInd, ни настройки сетевой карты, ни sudoers. Реальные идентификаторы дисков/записей — в `docs/private/LOCAL_NOTES.md` (не публикуются).

## Что найдено
| Вопрос | Результат | Как проверено |
|---|---|---|
| Режим прошивки | UEFI | `/sys/firmware/efi` |
| Secure Boot | включён | `mokutil --sb-state`, переменная `SecureBoot` в efivarfs (читается без root) |
| Порядок загрузки | первым — менеджер **rEFInd** (через подписанный shim), затем shim Ubuntu, затем Windows Boot Manager | `efibootmgr` (без аргументов, без root) |
| rEFInd | `timeout 0`, `scanfor manual`, `use_nvram false`; две ручные записи (Ubuntu → shim, Windows → `firmware_bootnum` записи Windows Boot Manager) | чтение `refind.conf` на ESP |
| GRUB | скрыт, `GRUB_TIMEOUT=0`, `GRUB_DEFAULT=0`; есть отдельный фрагмент `grub.d` (виртуальный монитор ТВ); `grubenv` пуст; `grub.cfg` только для root | `/etc/default/grub` |
| BitLocker | раздел Windows — обычный NTFS (тома BitLocker не обнаружены); заметки владельца от 24.10 — BitLocker на C:, D:, E: выключен | `lsblk -o FSTYPE` |
| Wake-on-LAN | на уровне ОС флаг пробуждения устройства выключен; поле `Wake-on` в `ethtool` без root не читается; настройка UEFI неизвестна | `/sys/class/net/*/device/power/wakeup`, `ethtool` |
| Сон/выключение | logind: `CanPowerOff/CanReboot/CanSuspend = yes`, `mem_sleep = deep` | `busctl … CanPowerOff` |
| Одноразовая загрузка systemd-boot | недоступна (`CanRebootToBootLoaderEntry = na`) — загрузчик не systemd-boot | logind |
| Права для BootNext | `efibootmgr --bootnext` требует root; агент вызывает только `sudo -n` для одного бинарника и считает действие доступным лишь при правиле NOPASSWD именно для него (кеш пароля не считается). Состояние sudoers основного ПК — в локальных заметках; AER sudoers не меняет | `sudo -n -l` (только листинг) |
| У владельца есть собственный переключатель | проект на rEFInd + ярлык Windows `bcdedit /set {fwbootmgr} bootsequence {…}` | чтение README (проект не изменялся) |

## Механизмы и выбор
| Механизм | Плюсы | Минусы | Решение |
|---|---|---|---|
| **UEFI BootNext** (Linux: `efibootmgr --bootnext`; Windows: `bcdedit /set {fwbootmgr} bootsequence`) | одноразовый, прошивка сама сбрасывает; не трогает порядок, GRUB, rEFInd, файлы ESP; работает при Secure Boot (цели подписаны); минует rEFInd | нужны права root/администратора; некоторые прошивки игнорируют BootNext (проверяется только вживую) | **выбран** |
| `grub-reboot` | стандартный в Ubuntu | требует `GRUB_DEFAULT=saved`, пишет `grubenv`; GRUB здесь не первый (rEFInd); Windows → Ubuntu всё равно нужен BootNext | отклонён |
| rEFInd `PreviousBoot` (`vars/` на ESP) | rEFInd уже стоит | запись на ESP из AER; зависит от настроек rEFInd владельца | отклонён |
| Изменение постоянного порядка | просто | необратимо без вмешательства, риск остаться без загрузки | запрещено |

## Wake-on-LAN: предпосылки
1. Включено в UEFI («Wake on LAN», «Power On By PCI-E», выключен «ErP/EuP»), иначе карта обесточена в S5.
2. Включено в драйвере **обеих** ОС (Windows: «Wake on Magic Packet», выключить «Быстрый запуск»; Linux: `ethtool -s <if> wol g`). Последняя загрузившаяся ОС определяет состояние карты при выключении.
3. Отправитель должен быть **включён** и в той же сети: пока Core на этом же ПК, разбудить его некому. Решение — постоянно включённый сервер (M13).
4. Проверка — только вживую при согласии владельца: S5 (выключение), S3 (сон), после Windows и после Ubuntu.

## BitLocker и Secure Boot
- BootNext не меняет политику Secure Boot; Windows Boot Manager и shim подписаны.
- Изменение порядка загрузки или загрузка через другой менеджер может вызвать запрос ключа восстановления BitLocker. Сейчас BitLocker выключен; AER блокирует смену ОС при обнаруженном BitLocker, пока владелец явно не разрешит в политике, и предупреждает, если состояние неизвестно.

## Что остаётся непроверенным (UNVERIFIED)
Фактическая работа BootNext на этой прошивке в обе стороны; WoL из S5/S3; агент на Windows (чтение `{fwbootmgr}`, `manage-bde`, `Confirm-SecureBootUEFI` требуют администратора); выключение/перезагрузка через logind из фонового сеанса (polkit для неактивного сеанса может потребовать пароль).
