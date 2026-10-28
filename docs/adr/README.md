# Architecture Decision Records

| ADR | Тема | Статус |
|---|---|---|
| [ADR-001](ADR-001-go-sqlite.md) | Go + SQLite (modernc, WAL) для Core | ACCEPTED |
| [ADR-002](ADR-002-flutter-flame.md) | Flutter desktop + Flame для сцены | ACCEPTED (Flame подтверждён замером M03, ADR-009) |
| [ADR-013](ADR-013-remote-transport.md) (бывш. ADR-003) | Remote provider: RDP, Core как плоскость управления | ACCEPTED |
| [ADR-015](ADR-015-network-tv.md) | Сеть и ТВ: модуль наблюдения поверх Registry и Monitoring, UPnP IGD только чтение, Sunshine serverinfo | ACCEPTED |
| [ADR-014](ADR-014-power.md) (бывш. ADR-004) | Питание и смена ОС: WoL из Core, фиксированные адаптеры агента, одноразовая загрузка UEFI | ACCEPTED |
| ADR-005 | Рендер сцены на iOS | PENDING — после прототипа |
| [ADR-006](ADR-006-repository-layout.md) | Расположение и структура репозитория | ACCEPTED |
| [ADR-007](ADR-007-api-envelope-and-auth.md) | Конверт REST, ошибки, локальный токен | ACCEPTED |
| [ADR-008](ADR-008-registry-model.md) | Модель Registry: каталог, возможности, связи, архив | ACCEPTED |
| [ADR-009](ADR-009-scene-engine.md) | Движок сцены: формат v1, хранение, Flame, растровый кэш | ACCEPTED |
| [ADR-010](ADR-010-scene-editor.md) | Редактор дома: команды и история снимков, проверка размещения, черновик, материалы-данные | ACCEPTED |
| [ADR-011](ADR-011-monitoring.md) | Мониторинг: SQLite с агрегатами, протокол и учётные данные агентов, инциденты, уведомления | ACCEPTED |
| [ADR-012](ADR-012-bots.md) | Боты: конфигурация поверх Registry, адаптеры из конфига, подтверждение + идемпотентность + аудит действий, задания | ACCEPTED |
