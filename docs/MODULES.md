# Каталог модулей и контракты границ

| Модуль | Зона ответственности | Не должен делать | MVP |
|---|---|---|---|
| Foundation | bootstrap, config, auth, jobs, event bus, migrations | UI решения | 00–01 |
| Registry | сущности, типы, capability, providers, wizard | хранить scene coordinates | 01 |
| Scene | комнаты, камеры, визуальные объекты, editor state; редактор M04 (команды, история, проверка размещения, черновик, каталог) — на клиенте, Core хранит документ и ревизии | читать Docker и SSH; копировать данные Registry в сцену | 02–04 |
| Monitoring | probes (+задержка `net.latency`, M09), heartbeat, logs, incidents, retention; M05: `core/internal/modules/monitoring` + агент `core/cmd/aer-agent` (docs/MONITORING.md, docs/AGENTS.md) | самочинно перезапускать службы; писать в таблицы Registry; управлять контейнерами | 05 |
| Bots | конфигурация ботов поверх Registry, задания, разрешённые действия (подтверждение, идемпотентность, аудит), адаптеры heartbeat/telegram/process/systemd/docker/n8n — **M06, ADR-012, `docs/BOTS.md`** | хранить Telegram токены в UI; свой реестр устройств; свои метрики/логи (это Monitoring); выполнять команды не из конфига Core | 05 |
| Remote | плоскость управления удалённым доступом: хосты поверх Registry, политика, сеансы, одноразовая выдача, отзыв, аудит; агент хоста `aer-remote-host` — **M07, ADR-013, `docs/REMOTE.md`** | прямой доступ к bootloader; пропускать видео/файлы через Core; хранить пароли сеансов | SPIKE + 07 |
| Power | WoL (отправляет Core), shutdown/reboot/suspend, одноразовая смена ОС через агент `aer-power-host`; политика, подтверждение + Idempotency-Key + аудит, задания — **M08, ADR-014, `docs/POWER.md`** | предоставлять remote video; принимать команды от клиента; менять порядок загрузки/GRUB/rEFInd/UEFI/BitLocker; повторять перезагрузки; наблюдать за устройствами (это Monitoring) | SPIKE + 08 |
| Network | обзор сети и ТВ: интернет (явные цели, TLS), WAN роутера (UPnP IGD, только чтение), Sunshine (serverinfo); устройства — из Registry + Monitoring; история/журнал/инциденты — Monitoring — **M09, ADR-015, `docs/NETWORK.md`** | менять настройки роутера/Wi-Fi/DHCP/DNS/firewall; сканировать сеть; управлять Sunshine; свой журнал/метрики/инциденты | 09 |
| Integrations | Beszel, Docker, MeshCentral/etc adapters | ломать Core при отказе внешнего сервиса | по одному |
| Desktop | Flutter Windows/Linux, scene, classic, app shell | core business logic | 01–03 |
| iOS | SwiftUI/Swift + scene, classic, remote apps | общий desktop stream на телефоне | позднее |
| Android | Kotlin/Compose + scene, classic | общий desktop stream на телефоне | позднее |

## Интерфейсы (концептуальные, уточнить в коде)
- `EntityRepository`: create/get/list/update/archive with optimistic version. **Реализовано в M02** как `registry.Reader` (Get/List/Relations/Catalog) — единственный способ для других модулей читать Registry (ADR-008).
- `CapabilityProvider`: probe(entity) => supported actions and explanation.
- `TelemetryProvider`: observe(entity) => samples, health, log stream (optional). **Реализовано в M05** как протокол агента v1 (`POST /monitoring/agent/report`) с отдельными учётными данными агентов; Scene получает состояние через `LiveStatus` (Scene Binding), а не из таблиц Monitoring.
- `ActionExecutor`: plan(command) => risks+confirmation; execute(approved plan) => job. **Реализовано для ботов в M06**: `POST /bots/{id}/actions/{a}/confirm` (план: сводка, риски, срок) → `POST /bots/{id}/actions/{a}` с `Idempotency-Key` → запись аудита `bot_actions`; исполнители — адаптеры `bots.Controller`/`bots.Retrier` (ADR-012). Для питания — M08: `POST /power/devices/{id}/actions/{a}/confirm` (проверки, риски, токен) → `POST /power/devices/{id}/actions/{a}` с `Idempotency-Key` → задание `power_jobs` + события; исполнитель — агент `aer-power-host` (фиксированные адаптеры, ADR-014).
- `RemoteProvider`: list sessions/apps; negotiateDesktop; negotiateWindow; clipboard/file capability. **Реализовано в M07** как `remotehost.Backend` (Prepare/Open/Close/Ready: `gnome-rdp`, `windows-rdp`) + протокол агента `/remote/agent/*`; `negotiateWindow` — `GET /remote/hosts/{id}/apps` (сейчас честный `unsupported`).
- `BootProvider`: discover modes, validate prerequisites, planOneShotBoot, verifyPostBoot. **Реализовано в M08**: инвентаризация агента (`bootEntries`, Secure Boot, BitLocker) → `targets` в действии `switch_os` → `Host.Plan` (BootNext + reboot) → проверка по новому `bootId` и ОС.
- `SceneRepository`: load/save scene version, visual-object bindings. **Реализовано в M03/M04**: `SceneApi` (list/get/create/replace с revision, 409 при конфликте), `SceneCache` (офлайн-копия), `SceneDraftStore` (черновик редактора).
- Редактор (M04, клиент): `EditorController` → `EditCommand.apply(doc)` поверх `SceneEdits` → `EditHistory` (снимки) → `SceneController.previewDocument` → рендерер получает `EditorOverlay` (только данные). Проверка — `PlacementValidator`, справочник — `SceneCatalog` (ADR-010).

## Правила
- Один модуль = отдельный пакет и владелец таблиц; public API/contract tests.
- Внешние adapters всегда опциональны: `UNAVAILABLE`, `UNSUPPORTED`, `PERMISSION_REQUIRED` — разные состояния.
- Различать UI availability, endpoint reachability, authenticated functionality.
- Опасная операция — job с audit, expiry, confirmation token и таймаутом, без автоматического повтора.
