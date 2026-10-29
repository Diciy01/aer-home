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

## M10 Windows Desktop — DONE (2026-10-28), не опубликовано
- [x] Приняты коммиты Claude `fe99701`, `09a2d33`, `6bd1ed2`, `b464b2e`; оба Windows-примера сохранены; незавершённый UI-тест Monitoring исправлен и повторён.
- [x] Go test/vet, Windows Agent → отдельный Core, TCP IPv4/IPv6, 215 Flutter tests/analyze, 11 Dart tests, Windows Release; настоящие UI Monitoring/навигация/Gateway sample RDP/переподключение/отзыв/offline, DPAPI, трей и Shell notification.
- [x] ZIP с FreeRDP/CRT/лицензиями и пользовательским установщиком; запуск с PATH=System32 без SDK/vcpkg overrides, удаление по хэшам с сохранением добавленных/изменённых файлов.
- [x] Исправлены Windows child trees Bots (Job Object), загрузка DLL, потерянный первый кадр и статус TLS-отказа. `windows-rdp` больше не обещает управляемый сеанс: Host → M14.4.
- [ ] Чистая Windows VM, второй ПК/интернет, Windows NLA/clipboard/RU desktop — UNVERIFIED. Полная матрица, артефакт ZIP и ограничения: `docs/M10_WINDOWS_REPORT.md`, сборка/установка — `docs/WINDOWS.md`.

## M14 Remote 2 (Engine + Gateway + AER Connect) — IN_PROGRESS (с 2026-10-28), не опубликовано
ADR-017, контракт 0.11.1, `docs/REMOTE_GATEWAY.md`. M07 сохранён: прежние backend/внешний клиент и прямой путь LAN остаются; новый `windows-shadow` требует relay.
- [x] ADR-017 и строка M14 в дорожной карте (после M10; M11 отменён и не является зависимостью)
- [x] M14.1 Engine: Go `core/internal/remoteengine` (Core и агент переведены на общие типы); Dart `packages/aer_remote` (клиент Gateway, закрепление, туннель, локальный порт, жизненный цикл сеанса, интерфейс `RemoteViewer`)
- [x] M14.2 Gateway: клиенты удалённого доступа и служебный API в Core (миграция remote 2), `aer-remote-gateway`, ноги ретрансляции агента, стенд `core/cmd/aer-remotelab`; тесты Go/Dart/бинарники — PASS на loopback
- [x] M14.3 встроенный просмотр: `native/aer_rdp` (FreeRDP 3.32, `freerdp3-dev` установлен владельцем), Dart FFI и `EmbeddedRdpViewer` в `packages/aer_remote`, страница рабочего стола в AER HOME (Remmina — запасной вариант); живые проверки на стенде — `docs/REMOTE_GATEWAY.md`
- [ ] M14.4 IN_PROGRESS (2026-10-29): AER Connect реализован, Release/установщик/UI/DPAPI проверены; `windows-shadow` реализован и проходит настоящий RDP/Gateway с SYNTHETIC источником, права, pin/password, clipboard/files/reconnect/revoke/TTL. Исправлен CRT allocator defect (`bf44ef9`). Реальные DXGI/SendInput BLOCKED до отдельного согласия и обычного пользовательского Host-процесса; Home/чистая VM/интернет UNVERIFIED. `M14_4_REPORT.md`, `CRT_FFI_REPORT.md`.
- [x] M14.5 интеграция в AER HOME: «Клиенты» (создать/права/код/отозвать) и «Через Gateway» (сервер, отпечаток, закрепление, сопряжение, сеанс во встроенном просмотре); Gateway сообщает отпечаток Core; живая проверка — `docs/REMOTE_GATEWAY.md`

## Следующий шаг
M10 завершён. Владелец 2026-10-28 поручил продолжить M14.4: AER Connect для Windows и управляемый Windows Host/`windows-shadow`; этап IN_PROGRESS. Начать с ограничений `docs/WINDOWS.md`; sample-сервер не является Windows Host. M11 (нативный iOS) окончательно CANCELLED / OUT OF SCOPE: существующие материалы сохраняются, инструменты Apple/сборки/прототипы не планируются, зависимости других этапов удалены. Android, Windows, Linux и Ubuntu Server поддерживаются. Веб для iPhone — только необязательная будущая идея без этапа. Перед публикацией — чистая Windows VM и решение о подписи пакета. Push запрещён без разрешения; живая приёмка M08 и управление текущим desktop требуют отдельного согласия.
