# Архитектура AER HOME

## Решение
Лёгкий **modular monolith**: один Go процесс `aer-core` + SQLite WAL, отдельные агенты для хостов и нативные клиенты; внешние сервисы (Beszel/remote) — **опциональные adapters**, а не обязательный фундамент.

```text
Flutter Desktop (Windows/Linux)      SwiftUI iOS / Kotlin Android
       |                                         |
       +----------- HTTPS/WSS via secure private transport --------+
                                                                   |
                                                         AER Core (Go)
                                             auth | registry | scene | events
                                             monitoring | bots | power | remote
                                              SQLite | log rotation | scheduler
                                                 /              |                                                  AER Agent Linux/Win   Beszel*    Remote provider*
                                                 |              |            |
                                        host/Docker/bots     metrics    desktop/files
* Optional; capability-gated; protocol chosen after spike.
```

- Изометрия и редактор рендерятся на клиенте. Core хранит сцену как данные и рассылает обновления.
- Core не должен декодировать/кодировать remote video в обычном случае; соединения прямые/через проверенный relay; Core — control plane.
- Серверу не нужен GPU; проектируется под слабый CPU, 4 ГБ RAM, диски неизвестны. Ресурсные лимиты, лог-ротация, адаптивные интервалы опроса.
- Только сам пользователь; аутентификация всё равно нужна, в том числе локально.

## Модели и границы
`PhysicalDevice` (железо) → `Runtime` (активная ОС или сервис) → `Capability` → `TelemetrySource` → `Incident`; `VisualObject` связан с `Entity` по ID (0..N). `Room` не содержит пароль/SSH детали.

- Registry владеет стабильными IDs, types, credentials references, capabilities.
- Scene владеет комнатами/позициями/ассетами, не управляет железом.
- Monitoring владеет normalised measurements, health, log references, incidents.
- Power инициирует idempotent audited jobs, знает физические устройства и ОС.
- Remote реализует session negotiation, capability checks, а не собственный codec.
- Bots принимает health/heartbeat/task statuses и log references.

## Сцена (M03)
Core хранит документ сцены (`/api/v1/scenes`, таблицы `scene_*`), клиент рендерит: Flame + кэшированная векторная картинка и текстура; камера, выбор и оверлеи — независимые части клиента. Связь с Registry — только UUID `entityBinding` и Registry API. Подробно: `docs/SCENE_FORMAT.md`, ADR-009.

## Данные
SQLite WAL на этапе MVP; миграции идемпотентные и тестируемые; журнал действий хранится отдельно логически; secrets через OS vault/зашифрованное хранилище, не в сценах/JSON. Опциональный PostgreSQL только при фактической необходимости. Раздельные таблицы/DAO по владельцу модуля, без прямого доступа других модулей к ним.

## События
Внутренний typed event bus в одном процессе; пример внешнего формата `contracts/events.schema.json`; доставка клиентам SSE/WebSocket с cursor. Не обещать exactly-once; включить event ID, createdAt, source, entityId, severity, correlationId, schemaVersion. Replay ограничен retention.

## Режимы исполнения
- `development`: Core + SQLite на Ubuntu; demo devices отграничены, fake agents, локальные тестовые комнаты.
- `local`: работа с настоящими агентами на том же домашнем LAN.
- `server`: Core переносится на отдельный Linux ПК; clients указывают новый endpoint, импорт БД, assets, конфигов; тест restore.
- `remote`: доступ только через приватный защищённый канал (например Tailscale), никаких WAN пробросов по умолчанию.

## Нефункциональные цели (targets, не гарантия)
- Core boot с минимальными зависимостями; мониторинг не мешает работе ботов.
- Обычная сцена ~60 fps на настольном GPU при разумном количестве объектов; доступен reduce-motion/performance mode.
- Нет Core: клиент запускается, отображает cached state как stale, блокирует destructive actions.
- Core crash/restart: данные Registry/Scene не теряются, миграции/бэкапы и watchdog.
- HTTP API prefix `/api/v1`; OpenAPI source of truth; versioned capabilities.

## ADRs перед реализацией
ADR-001: Go/SQLite; ADR-002: Flutter+Flame; ADR-003: remote provider после SPIKE; ADR-004: cross-OS boot control после проверки реального GRUB/UEFI; ADR-005: iOS scene rendering choice after prototype.
