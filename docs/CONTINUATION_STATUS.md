# Состояние работы (для продолжения после прерывания)

Обновлено: 2026-10-28.

## M07 Remote — DONE
Коммиты `4066866..185205d`. UNVERIFIED — см. `docs/M07_REMOTE_REPORT.md`.

## M08 Power — DONE по ПО; живая приёмка — PENDING (нужно согласие и присутствие владельца)
Коммиты `7bbc6b4` (Core, контракт 0.9.0, ADR-014), `80d03eb` (агент), `0812b58` (Flutter), `24f476f` (стенд, исправление Monitoring, производительность), `9ca40d6` (документация), `84a43e4` (исправление плана, повторная проверка). S-Power выполнен внутри M08 только чтением.

Выполнено: модуль Core `power`, агент `aer-power-host`, раздел «Питание» и панель в доме, контрактные/модульные/сквозные тесты, живой стенд `tools/power-lab` (только SIMULATED и WoL на 127.0.0.1), замеры, документы (`POWER.md`, `POWER_CONNECT.md`, `USER_GUIDE_POWER.md`, `S_POWER_FEASIBILITY.md`, `M08_POWER_REPORT.md`).

Не выполнялось и запрещено без отдельного разрешения: реальные WoL в сеть, shutdown/reboot/suspend, BootNext/bcdedit, изменения GRUB/rEFInd/UEFI/BitLocker/Secure Boot/sudoers, установка служб.

## Публикация
2026-10-28: `main` отправлена в origin (fast-forward `2370757..84a43e4`, M04–M08) после аудита истории; до публикации неопубликованные коммиты M08 очищены от фрагмента GUID реальной загрузочной записи и от упоминания sudo-настроек основного ПК (резервные локальные ветки `backup/pre-*-20261028`, не публикуются).

## M09 Network + TV — DONE (2026-10-28), не опубликовано
- [x] Monitoring: метрика `net.latency`, записи без объекта; модуль Core `network` (интернет, UPnP IGD read-only, Sunshine serverinfo), контракт 0.10.0, ADR-015
- [x] Flutter: раздел «Сеть и ТВ», журнал, панель в доме, карточка в «Обзоре» (10 тестов)
- [x] Стенд tools/network-lab (заглушки), живой тест приложения, скриншоты, проверка реальных роутера/ТВ/Sunshine только чтением (real_check.py), найдено: TUN-прокси подделывает TCP → интернет через TLS
- [x] Документы и отчёт `docs/M09_NETWORK_TV_REPORT.md`

2026-10-28 (сессия M12): M09 перепроверен без изменений кода — gofmt/vet/test/race, flutter analyze/test/build ok; требования брифа M09 покрыты (см. отчёт).

## M12 Android — DONE (2026-10-28), не опубликовано
- [x] `apps/android`: `:core-api` (31 JVM-тест), `:scene` (21), `:app` (8 тестов состояния интерфейса), Lint 0 замечаний; ADR-016, `ANDROID.md`, отчёт `M12_ANDROID_REPORT.md`
- [x] Эмулятор API 35 в `/mnt/Project` (пути — LOCAL_NOTES); сквозные тесты против стенда: 6/6 debug, 5/5 release; сбой/восстановление Core (`tools/mobile-lab/outage.py`)
- [ ] Физический телефон, реальный Core в LAN/Tailscale — по команде владельца

## M14 Remote 2 (Engine + Gateway + AER Connect) — IN_PROGRESS (с 2026-10-28), не опубликовано
ADR-017, контракт 0.11.0, `docs/REMOTE_GATEWAY.md`. M07 сохранён полностью (прямой путь LAN работает как прежде).
- [x] ADR-017 и строка M14 в дорожной карте (после M10, до M11)
- [x] M14.1 Engine: Go `core/internal/remoteengine` (Core и агент переведены на общие типы); Dart `packages/aer_remote` (клиент Gateway, закрепление, туннель, локальный порт, жизненный цикл сеанса, интерфейс `RemoteViewer`)
- [x] M14.2 Gateway: клиенты удалённого доступа и служебный API в Core (миграция remote 2), `aer-remote-gateway`, ноги ретрансляции агента, стенд `core/cmd/aer-remotelab`; тесты Go/Dart/бинарники — PASS на loopback
- [x] M14.3 встроенный просмотр: `native/aer_rdp` (FreeRDP 3.32, `freerdp3-dev` установлен владельцем), Dart FFI и `EmbeddedRdpViewer` в `packages/aer_remote`, страница рабочего стола в AER HOME (Remmina — запасной вариант); живые проверки на стенде — `docs/REMOTE_GATEWAY.md`
- [ ] M14.4 AER Connect (Windows) и хост `windows-shadow` — после M10 (нужен Windows)
- [ ] M14.5 интеграция в AER HOME: подключение вне дома через Gateway на `packages/aer_remote`, управление клиентами удалённого доступа (создать/код/отозвать), единое управление сеансами

## Следующий шаг
M14.5 (интеграция Gateway/клиентов в AER HOME) — по команде владельца; затем M10 (Windows desktop) — **отложен владельцем до появления доступа к Windows**; не начинать без команды. M11 (iOS) — последним, после M10 (предпосылки — ROADMAP). M09 и M12 закоммичены локально, push — только с разрешения. Отдельно, по согласию владельца: живая приёмка M08 по `docs/POWER_DUALBOOT.md` → «Приёмка».
