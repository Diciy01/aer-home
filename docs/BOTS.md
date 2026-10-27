# Боты (M06)

Единый центр Telegram-ботов, Python-процессов, контейнеров, n8n и других автоматизаций: что работает, что сломалось, какие задания прошли и что можно безопасно сделать. Решения — ADR-012; подключение — `docs/BOTS_CONNECT.md`; руководство — `docs/USER_GUIDE_BOTS.md`; замеры — `docs/M06_BOTS_REPORT.md`.

## Архитектура

```text
 бот (aer_heartbeat.py) ──heartbeat──► /monitoring/agent/report ─┐
                       └──задания───► /bots/agent/jobs ───────┐ │
 n8n (REST, ключ из файла) ◄── опрос ──┐                       │ │
 процесс / systemd --user / Docker ◄─ управление ─┐            │ │
                                                  │            ▼ ▼
                     Core: модуль bots ───────────┴── Monitoring (state, метрики,
   ┌────────────┬───────────┬───────────┬────────────┐  логи, события, инциденты)
   │ Конфиги    │ Задания   │ Действия  │ Адаптеры   │
   │ bot_configs│ bot_jobs  │ bot_actions│ heartbeat, │◄── Registry (объект, теги,
   │            │           │ (аудит)   │ telegram,  │    runs_on, depends_on, архив)
   │            │           │           │ process,   │
   │            │           │           │ systemd,   │
   │            │           │           │ docker, n8n│
   └────────────┴───────────┴───────────┴────────────┘
              ▼  /api/v1/bots/* (токен владельца)
   Flutter: раздел «Боты», карточка бота, мастер, панель бота в доме
```

- **Registry** — единственный реестр: бот — это объект типа `telegram_bot`, `process`, `service`, `automation`, `application` или `docker_container`. Сервер — связь `runs_on`, зависимости — `depends_on`, теги и архив — тоже в Registry.
- **Bots** хранит конфигурацию бота, задания и аудит действий. Ничего не дублирует из Monitoring.
- **Monitoring** — состояние (`online/degraded/offline/unknown/unsupported`), метрики (CPU/RAM процесса или контейнера, `bot.api_ok`), логи, события (запуски, остановки, падения, перезапуски), инциденты.

## Состояние бота
| Что показывается | Откуда |
|---|---|
| Состояние и причина | Monitoring: heartbeat бота (агент вида `bot`), иначе контейнер (`attributes.monitoring.container`) или HTTP-проверка (`url`, для n8n — `/healthz`) |
| Heartbeat, последний ответ | агенты бота в Monitoring; тайм-аут — из настроек бота (`attributes.monitoring.heartbeatTimeoutSec`) |
| Uptime | `startedAt` из heartbeat (пока heartbeat свежий) или время запуска адаптером; у остановленного адаптером процесса uptime не показывается |
| CPU, RAM | `process.cpu_percent`/`process.rss_bytes` (процесс Core или heartbeat 0.2+ на Linux) или Docker stats; значение старше 5 минут не показывается |
| Версия | поле `bot.version` heartbeat |
| Последняя ошибка / успех | heartbeat бота (текст очищен от секретов) |
| Среда (процесс запущен/остановлен, PID) | управляющий адаптер; «запущен» ≠ «работает» |
| Последнее успешное / неудачное задание, счётчики 24 ч | `bot_jobs` |
| История падений | инциденты Monitoring с ключами `availability:`, `bot_process:`, `container:`, `n8n_failed:`, `bot_api:` |
| История перезапусков | события `bot_started`, `bot_stopped`, `bot_restarted`, `bot_crashed`, `container_state` |
| Зависимости | связи `depends_on` + их состояние в Monitoring |

Без heartbeat и без другого источника бот — «неизвестно», а не «в сети».

## Адаптеры
| Адаптер | Возможности | Объявление |
|---|---|---|
| `heartbeat` | мониторинг, логи ошибок, задания | не нужно (токен бота выдаётся в мастере) |
| `telegram` | то же + проверка `getMe` | `bots.telegramTokens[{id,file}]` — только для `getMe` |
| `process` | старт/стоп/перезапуск, вывод → журнал, CPU/RAM, коды выхода | `bots.controllers[{kind:"process", command, workDir, env, stopTimeoutSec, allow}]` |
| `systemd_user` | старт/стоп/перезапуск `systemctl --user`, состояние юнита | `bots.controllers[{kind:"systemd_user", unit, allow}]` |
| `docker` | старт/стоп/перезапуск объявленного контейнера | `bots.controllers[{kind:"docker", container, allow}]`, сокет `bots.dockerSocket` |
| `n8n` | состояние сервиса, workflows, выполнения → задания, ошибки, повтор (если `allowRetry`) | `bots.n8n[{id, baseUrl, apiKeyFile, allowRetry}]` |

Пример — `deploy/core-bots.example.json`. Неверная декларация останавливает запуск Core с понятной ошибкой. Новый адаптер реализует `bots.Adapter` (+ `Controller`/`Checker`/`Syncer`/`Retrier` по возможностям) и регистрируется `Service.Register`.

## Действия
`start`, `stop`, `restart` (управляющий адаптер), `check` (только чтение: обновить состояние, спросить адаптер, `getMe`, `/healthz` n8n), `job.retry` (n8n).

1. `GET /bots/{id}/actions` — что доступно сейчас и почему нет («Только мониторинг», «не разрешено в allow», «Уже запущен», «бот в архиве»).
2. `POST /bots/{id}/actions/{a}/confirm` → одноразовое подтверждение: сводка, риски, срок (по умолчанию 120 с).
3. `POST /bots/{id}/actions/{a}` с `Idempotency-Key` (8–100 символов) и `confirmationToken` (кроме `check`).
   - тот же ключ → первый результат, `replayed: true`, ничего не исполняется;
   - ключ другой операции → 409; для бота уже идёт действие → 409; нет подтверждения → 403 `PERMISSION_REQUIRED`;
   - операция ограничена `opTimeoutSec` и `maxConcurrentOps`, не прерывается разрывом соединения.
4. Аудит: `GET /bots/{id}/audit` (выполнено / ошибка / отклонено) + событие `bot_action` в Monitoring.

## Задания
Модель: `id`, `name`, `status` (`pending/running/success/failed/cancelled`), `startedAt`, `finishedAt`, `durationMs`, `result`, `error`, `retryable`, `retryOf`, `source` (`heartbeat`/`n8n`). Бот сообщает задания своими учётными данными: `POST /bots/agent/jobs {"jobs":[{id,name,status,startedAt?,finishedAt?,result?,error?}]}` (до 200 за раз, повтор того же `id` обновляет задание). Неудачное задание пишется в журнал бота уровнем `error`. Повтор — только у адаптеров с `Retrier` и после подтверждения.

## API (под `/api/v1`, контракт 0.7.0)
Токен владельца: `GET /bots/adapters`, `GET/POST /bots`, `GET/PATCH /bots/{id}`, `POST /bots/{id}/archive`, `POST /bots/{id}/restore`, `POST /bots/{id}/credentials`, `GET /bots/{id}/jobs?status=&before=&limit=`, `GET /bots/{id}/logs?level=&q=&before=`, `GET /bots/{id}/activity`, `GET /bots/{id}/actions`, `POST /bots/{id}/actions/{action}/confirm`, `POST /bots/{id}/actions/{action}`, `GET /bots/{id}/audit`.
Токен бота (агент вида `bot`): `POST /bots/agent/jobs`.

Создание: либо `entityId` (привязать существующий объект), либо `name` + `type` (создать). `PATCH` требует `revision` конфигурации бота (409 при устаревшей). Архив переносит объект Registry в архив и **ничего не останавливает**.

## Хранение и лимиты (`bots` в конфиге Core)
| Параметр | По умолчанию |
|---|---|
| `maxConcurrentOps` — одновременных операций управления | 2 |
| `opTimeoutSec` — тайм-аут операции / опроса | 30 |
| `syncIntervalSec` — опрос n8n и состояний | 60 (CPU/RAM процессов — каждые 15 с) |
| `confirmTtlSec` — срок подтверждения | 120 |
| `jobRetentionDays` / `jobMaxRows` — задания | 90 дней / 200 000 строк (выполняющиеся не удаляются) |
| `auditRetentionDays` — аудит действий | 365 |

Очистка — раз в час. Модуль выключается `"modules": {"bots": false}`; без Monitoring не запускается (состояние и журналы живут там).

## Клиент
Раздел «Боты»: карточки (состояние, среда, версия, CPU/RAM, uptime, heartbeat, задания за 24 ч), поиск по имени/тегам/категории, фильтры по состоянию, среде, категории, архив; мастер добавления (4 шага); страница бота — Обзор, Нагрузка (графики Monitoring), Активность, Логи, Ошибки, Задания, Управление (+журнал действий), Интеграция (настройки, n8n workflows, токен heartbeat, архив). Без связи с Core — последний список с пометкой «устарел», действия неактивны. В доме: у объекта, привязанного к боту, карточка показывает панель бота — состояние, последнюю ошибку, «Карточка бота», «Ошибки», разрешённые команды с подтверждением; «Диагностика» ведёт в Monitoring.
