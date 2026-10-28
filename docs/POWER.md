# AER Power (M08)

Включение по сети, выключение, перезагрузка, сон и одноразовая смена ОС dual-boot ПК. Решения — ADR-014; исследование — `S_POWER_FEASIBILITY.md`; модель dual-boot и приёмка — `POWER_DUALBOOT.md`; установка — `POWER_CONNECT.md`; руководство — `USER_GUIDE_POWER.md`; замеры — `M08_POWER_REPORT.md`.

## Компоненты
- **Модуль Core `power`** (`core/internal/modules/power`): устройства поверх Registry, цель WoL, политика, подтверждения, задания и их аудит, протокол агента. Состояние «в сети» берёт у Monitoring (только чтение) и у своих агентов; сам ничего не наблюдает и не пишет в таблицы других модулей.
- **Агент `aer-power-host`** (`core/cmd/aer-power-host`, `core/internal/powerhost`): на каждом компьютере, по одному на каждую ОС dual-boot ПК. Сообщает факты (ОС, `bootId`, UEFI, Secure Boot, BitLocker, загрузочные записи, MAC, какие действия возможны и почему нет) и исполняет закрытый список действий фиксированными командами. **По умолчанию — режим проверки**: ничего не выполняет, отвечает `simulated`.
- **Клиент** — раздел «Питание», панель в доме (`apps/desktop/lib/src/features/power`).

## API (контракт 0.9.0, `contracts/openapi.yaml`)
| Метод | Путь | Назначение |
|---|---|---|
| GET | `/power/devices`, `/power/devices/{id}` | состояние, ОС, последний контакт, WoL, «Core на этом ПК», агенты, политика, действия с причинами недоступности, активное и последнее задание |
| PUT/DELETE | `/power/devices/{id}/wol` | MAC, адрес назначения (частные сети, loopback, 255.255.255.255), интерфейс Core, порт |
| PUT | `/power/devices/{id}/policy` | что разрешено; выключение действия отменяет его неотданные задания |
| POST | `/power/devices/{id}/actions/{action}/confirm` | план: проверки, риски, одноразовый токен (120 с), привязан к устройству, действию и целевой ОС |
| POST | `/power/devices/{id}/actions/{action}` | `Idempotency-Key` обязателен; 202 + задание; повтор ключа → 200 то же задание; другой операции → 409 |
| GET | `/power/jobs`, `/power/jobs/{id}` | история и аудит |
| POST | `/power/jobs/{id}/cancel` | только пока агент не забрал команду |
| GET | `/power/interfaces` | интерфейсы Core для WoL, включена ли отправка |
| POST/GET/POST | `/power/agent/hello`, `/power/agent/commands`, `/power/agent/jobs/{id}/events` | протокол агента (учётка Monitoring вида `power`) |

Действия: `wake | shutdown | reboot | suspend | switch_os | check`. Тело запроса — только `confirmationToken` и `targetOs`; лишние поля (например, текст команды) → 400.

## Задание
`queued` (ждёт агента) → `sent` (агент забрал) → `waiting` (выполняется, ждём результат) → `succeeded | failed | timeout | cancelled | simulated`; отказ на входе — `rejected` (тоже в аудите).
| Действие | Успех, когда | Тайм-аут (по умолчанию) |
|---|---|---|
| wake | агент или Мониторинг устройства на связи после отправки | 300 с |
| shutdown, suspend | устройство перестало отвечать ≥45 с после начала (или Мониторинг: offline) — подтверждения от выключенного устройства быть не может, так и пишется | 180 с |
| reboot | агент сообщил новый `bootId` | 300 с |
| switch_os | новый `bootId` и ОС = цель; другая ОС → `failed` «загрузилась другая ОС» | 300 с |
Агент должен забрать команду за 60 с, иначе задание `failed`, команда отозвана. Тайм-аут = «состояние неизвестно», не успех. Автоматических повторов нет; после перезапуска Core неотданные команды завершаются `failed`.

## Конфигурация Core (`power`)
`wol.enabled` (**false**), `wol.port` (9), `wol.repeat` (3), `confirmTtlSec` (120), `pickupTimeoutSec` (60), `offlineTimeoutSec` (180), `bootTimeoutSec` (300), `agentTimeoutSec` (90), `maxActiveJobs` (8), `retentionDays` (365). Модуль выключается `"modules": {"power": false}`.

## Фиксированные команды агента
| Действие | Linux | Windows |
|---|---|---|
| shutdown | `systemctl poweroff` | `shutdown.exe /s /t 30 /c …` |
| reboot | `systemctl reboot` | `shutdown.exe /r /t 30 /c …` |
| suspend | `systemctl suspend` | не поддерживается |
| switch_os | `sudo -n /usr/bin/efibootmgr --bootnext XXXX` (проверка вывода `BootNext: XXXX`) → `systemctl reboot` | `bcdedit /set {fwbootmgr} bootsequence {GUID}` (проверка успеха) → `shutdown.exe /r /t 30` |
`XXXX`/`{GUID}` — только запись из **свежей** инвентаризации самого агента, ведущая в целевую ОС. Если BootNext не подтверждён — перезагрузки нет, задание `failed`.

## Интеграции
- **Registry**: возможности `power.wake`, `power.shutdown`, `power.reboot`, `power.suspend` (новая), `power.switch_os` — без них действие недоступно с причиной.
- **Monitoring**: события `power_job`, `power_boot`, `power_policy`, `power_wol`; инцидент `power:<id>:<действие>` при `failed/timeout` (уведомления по правилам M05), закрывается следующим успехом. Учётки `remote`/`power` не являются источниками heartbeat Мониторинга.
- **Remote**: из карточки и панели дома — переход в «Удалённый доступ».
- **Scene**: панель питания в быстрой карточке привязанного компьютера.
