# Подключение управления питанием (M08)

AER ничего не устанавливает и не меняет в системе сам: агент, автозапуск, правило sudo и настройки Wake-on-LAN — решения владельца. Без них соответствующие кнопки остаются неактивными с объяснением.

## 1. Компьютер в Registry
«Устройства» → компьютер → возможности: «Wake-on-LAN», «Выключение», «Перезагрузка», «Сон», «Смена ОС» (что нужно).

## 2. Агент на компьютере (Ubuntu)
1. «Мониторинг → Агенты» → добавить вид **power** (или `POST /api/v1/monitoring/agents {"entityId":…,"name":"power ubuntu","kind":"power"}`). Токен — в файл с правами 600, например `~/.config/aer-home/power-host.token`.
2. `deploy/power-host.example.json` → `~/.config/aer-home/power-host.json`, укажите `coreUrl`.
3. Сборка и проверка без Core:
   ```bash
   cd core && go build -o bin/aer-power-host ./cmd/aer-power-host
   bin/aer-power-host -config ~/.config/aer-home/power-host.json -inventory   # только чтение
   bin/aer-power-host -config ~/.config/aer-home/power-host.json
   ```
4. Агент работает **в режиме проверки**, пока вы сами не поставите `"execute": true`. В интерфейсе это видно («агент в режиме проверки», результаты — SIMULATED).
5. `allow` ограничивает действия на этом компьютере независимо от Core.

### Смена ОС на Ubuntu: права для BootNext (по желанию)
`efibootmgr --bootnext` требует root. Агент вызывает **только** `sudo -n /usr/bin/efibootmgr --bootnext XXXX`. Узкое правило (пример, применять — решение владельца):
```
# /etc/sudoers.d/aer-power  (visudo -f)
youruser ALL=(root) NOPASSWD: /usr/bin/efibootmgr --bootnext [0-9A-F][0-9A-F][0-9A-F][0-9A-F]
```
Без правила «Сменить ОС» недоступна с причиной «Нет помощника с правами». Кеш пароля sudo не считается.

## 3. Агент на Windows (UNVERIFIED)
Сборка: `GOOS=windows go build -o aer-power-host.exe ./cmd/aer-power-host`. Чтение `bcdedit /enum firmware`, `manage-bde`, `Confirm-SecureBootUEFI` и запись `{fwbootmgr} bootsequence` требуют **прав администратора** — запуск от администратора/как службы решает владелец. Сон на Windows не поддерживается. Выключение/перезагрузка — с задержкой 30 с (`shutdown /a` отменяет).

## 4. Wake-on-LAN
1. Core должен работать на **другом, постоянно включённом** компьютере в той же сети (M13). Пока Core на этом же ПК, включение по сети показывается недоступным.
2. В UEFI компьютера: Wake on LAN / Power On By PCI-E включено, ErP выключено. В Windows: свойства сетевой карты → «Wake on Magic Packet», «Быстрый запуск» выключить. В Ubuntu: `ethtool -s <if> wol g` (сохранение — через NetworkManager: `nmcli c modify <con> 802-3-ethernet.wake-on-lan magic`). AER этого не делает.
3. В Core: `"power": {"wol": {"enabled": true}}`.
4. В AER: «Питание» → компьютер → «Wake-on-LAN…»: MAC карты, интерфейс Core (широковещательный адрес подставится), «Сохранить».
5. Проверка — «Включить» на выключенном компьютере; успех засчитывается, только когда компьютер появился в сети (агент или Мониторинг).

## 5. Тестовый стенд (без опасных действий)
`python3 -I tools/power-lab/lab.py up DIR 18797` — изолированный Core, агент **принудительно** в режиме проверки, приёмник Magic Packet на 127.0.0.1. См. `docs/DEVELOPMENT.md`.
