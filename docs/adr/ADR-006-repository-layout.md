# ADR-006: Расположение и структура репозитория

**Статус:** ACCEPTED (2026-10-26, решение владельца)

## Контекст
Задание указывает общий раздел как корень проекта, но на нём лежат и другие проекты и системные каталоги. `git init` в корне раздела рискует захватить чужие файлы.

## Решение
Корень репозитория — каталог пакета документации AER HOME (там уже `CLAUDE.md`, `docs/`, `contracts/`; README называет его каталогом репозитория). Monorepo:

```text
core/            Go module aerhome/core (cmd/aer-core, internal/foundation/*, internal/core)
apps/desktop/    Flutter Linux/Windows клиент
contracts/       openapi.yaml, events.schema.json (source of truth)
docs/            требования, ADR, отчёты
examples/        примерные данные (демо)
```
Позже: `agents/` (Go), `apps/ios/`, `apps/android/`.

## Последствия
- `git config core.filemode false` (NTFS); identity задана локально в репо.
- Runtime-данные Core (БД, токен) — вне репозитория, в `~/.local/share/aer-home/core` (ext4), не на NTFS.
- Риск: запись на NTFS при гибернации Windows (Fast Startup) — см. M00 §5.
