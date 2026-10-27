# Monitoring / Bots / Incidents

> Боты как модуль (конфигурация, адаптеры, задания, управление) — M06: `docs/BOTS.md`, ADR-012.
> Реализация M05: `docs/MONITORING.md` (архитектура, хранение, инциденты, API), `docs/AGENTS.md` (агенты и heartbeat ботов), ADR-011. Этот файл — исходные требования.

## Lightweight-first
Для слабого сервера (ориентир 4 ГБ RAM) Core Go + SQLite, ограниченное число probes, TTL и retention. Beszel — необязательный внешний модуль системных метрик; heavy log stack не обязателен. Ограничивать RAM/CPU дисковые квоты, избегать постоянного polling раз в секунду.

## Источники
Ubuntu: systemd journal, kernel, NetworkManager, Docker events, disk/CPU/RAM/temp по доступу; Windows: Event Log, services, perf metrics через agent; router: ping + поддерживаемая read-only телеметрия; Android TV: проверка доступности, ADB/logcat только после explicit enable; Sunshine: systemd logs; bots: heartbeat, job result, Docker status, file logs, HTTP health.

## Боты
Сущности: Bot, Runtime (process/container), ScheduledTask, Dependency, Heartbeat, TaskExecution. Бот `process running` ≠ бот `healthy`. Счётчики: last heartbeat, last successful action, fails 1h/24h, queue age, version, avg execution, dependency failures, restart count. Никаких секретов Telegram в UI/логах.

## Инциденты
- Normalized severity INFO/WARNING/ERROR/CRITICAL, timestamps, sourceId, correlationId, affected entities.
- Группировать «router/WAN down → X зависимых сервисов offline» в root incident с вложенными evidence.
- Last known vs current; acknowledge/snooze, только explicit confirmation для remedial actions.
- Incident detail: первичная ошибка, таймлайн, сырой лог с redaction, вероятные причины с уверенностью, ручные действия.
- Никакого автоматического запуска непроверенных команд из содержимого логов.

## Хранение
Бюджет на старт: detailed logs 7 дней / важные инциденты 90 дней (конфигурируемо); log caps по размеру, index, filters, rotation, purge policy, backup metadata и метрики свободного места. Не обещать отсутствие потребления памяти от бесконечной истории.

## Базовые проверки
- Интернет не определяется единственным ICMP адресом.
- Host reachable ≠ user agent healthy; различать network/proxy/VPN states.
- Мониторинг dual boot: активный runtime жив, альтернативный `INACTIVE`, без false alarm.
- Уведомления не должны спамить при повторяющихся ошибках: dedupe, debounce, ack.
