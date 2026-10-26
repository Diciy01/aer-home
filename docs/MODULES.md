# Каталог модулей и контракты границ

| Модуль | Зона ответственности | Не должен делать | MVP |
|---|---|---|---|
| Foundation | bootstrap, config, auth, jobs, event bus, migrations | UI решения | 00–01 |
| Registry | сущности, типы, capability, providers, wizard | хранить scene coordinates | 01 |
| Scene | комнаты, камеры, визуальные объекты, editor state | читать Docker и SSH | 02–03 |
| Monitoring | probes, heartbeat, logs, incidents, retention | самочинно перезапускать службы | 04 |
| Bots | регистрации ботов, задача, health, ошибки | хранить Telegram токены в UI | 05 |
| Remote | negotiation сеанса, policy, desktop/apps/files/clipboard | прямой доступ к bootloader | SPIKE + 07 |
| Power | WoL, shutdown/reboot, boot switch | предоставлять remote video | SPIKE + 07 |
| Network | WAN/LAN checks, router capability adapters | слепо менять router settings | 08 |
| Integrations | Beszel, Docker, MeshCentral/etc adapters | ломать Core при отказе внешнего сервиса | по одному |
| Desktop | Flutter Windows/Linux, scene, classic, app shell | core business logic | 01–03 |
| iOS | SwiftUI/Swift + scene, classic, remote apps | общий desktop stream на телефоне | позднее |
| Android | Kotlin/Compose + scene, classic | общий desktop stream на телефоне | позднее |

## Интерфейсы (концептуальные, уточнить в коде)
- `EntityRepository`: create/get/list/update/archive with optimistic version.
- `CapabilityProvider`: probe(entity) => supported actions and explanation.
- `TelemetryProvider`: observe(entity) => samples, health, log stream (optional).
- `ActionExecutor`: plan(command) => risks+confirmation; execute(approved plan) => job.
- `RemoteProvider`: list sessions/apps; negotiateDesktop; negotiateWindow; clipboard/file capability.
- `BootProvider`: discover modes, validate prerequisites, planOneShotBoot, verifyPostBoot.
- `SceneRepository`: load/save scene version, visual-object bindings.

## Правила
- Один модуль = отдельный пакет и владелец таблиц; public API/contract tests.
- Внешние adapters всегда опциональны: `UNAVAILABLE`, `UNSUPPORTED`, `PERMISSION_REQUIRED` — разные состояния.
- Различать UI availability, endpoint reachability, authenticated functionality.
- Опасная операция — job с audit, expiry, confirmation token и таймаутом, без автоматического повтора.
