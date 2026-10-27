# Roadmap, отдельные маленькие задачи для одного разработчика + Claude Code

Статусы: TODO / IN_PROGRESS / DONE / BLOCKED / SPIKE. Любой DONE требует артефакта и воспроизводимых тестов.

| ID | Этап | Результат | Статус |
|---|---|---|---|
| M00 | Discovery/feasibility | реальное окружение, ADRs, dependency choices, риски remote/Wayland, baseline benchmark | DONE 2026-10-26 — `docs/M00_DISCOVERY.md`; Flame FPS-бенчмарк перенесён во вход M03 |
| M01 | Foundation | monorepo, Go Core, SQLite migrations, Flutter shell Linux, API contracts, tests, mocks | DONE 2026-10-26 — `go test`, `flutter test/analyze`, Linux release build, live Core↔client; Windows build UNVERIFIED (M10); event bus → M05, jobs/audit → M08 |
| M02 | Registry | device types, CRUD, capabilities, add wizard, secrets refs | DONE 2026-10-26 — ADR-008, contract 0.3.0; Go unit/HTTP/contract tests, Flutter 44 tests, live integration_test против реального Core; scene binding → M03, export/import → M04, UI правки secretRefs/attributes/icon — позже |
| M03 | Scene vertical slice | Flutter Flame одна комната, камера, выбор предмета, provider-agnostic binding | DONE 2026-10-26 — 5 комнат, 35 объектов; формат v1 + Core `/scenes`; ADR-009; 60 fps (замер `docs/M03_SCENE_REPORT.md`); графика временная (procedural placeholder), финальные спрайты — `docs/SCENE_ART_ASSETS.md` |
| M04 | Editor | создание комнат, drag/place, undo/redo, save/load, export | DONE 2026-10-27 — режим строительства, каталог 33 предметов, проверка размещения, Undo/Redo, черновик, конфликты ревизий, привязки Registry; ADR-010, contract 0.5.0; 60 fps при 200 объектах (замер `docs/M04_EDITOR_REPORT.md`); графика — улучшенный placeholder (не финал); импорт/экспорт JSON отложен |
| M05 | Monitoring | lightweight probes, journal, incidents, evidence, log rotation | DONE 2026-10-27 — модуль Core `monitoring` (SQLite, агрегаты, хранение), агент `aer-agent` Linux (проверен вживую) и Windows (сборка и тесты, на Windows UNVERIFIED), инциденты, логи, уведомления (Telegram выключен по умолчанию), Docker только чтение, heartbeat ботов, UI и состояния в доме; ADR-011, contract 0.6.0; замеры `docs/M05_MONITORING_REPORT.md` |
| M06 | Bots | heartbeat/task results, Docker/log adapters, UI/alerts | DONE 2026-10-27 — модуль Core `bots` поверх Registry и Monitoring (без своего реестра и своих логов/метрик), адаптеры heartbeat/telegram/process/systemd --user/docker/n8n из конфига Core, действия с подтверждением + Idempotency-Key + аудит, задания, раздел «Боты», панель бота в доме; ADR-012, contract 0.7.0; управление проверено вживую только на изолированном тестовом процессе, Docker/systemd/n8n — на подделках API (реальные UNVERIFIED); замеры `docs/M06_BOTS_REPORT.md` |
| S-Remote | Feasibility SPIKE | Windows/Linux Wayland desktop, clipboard, file, iOS isolated app window | TODO |
| S-Power | Feasibility SPIKE | WoL prerequisites, GRUB/UEFI, BitLocker and fallback | TODO |
| M07 | Remote Desktop | proven provider, desktop-only client modes, auth/session/files/clipboard | BLOCKED by S-Remote |
| M08 | Power | WoL, boot controller, secure jobs, live acceptance with consent | BLOCKED by S-Power |
| M09 | Network + TV | router read-only checks, Sunshine status and link, logs | TODO |
| M10 | Windows desktop | native build/tests on Windows, installer, tray, notification | TODO |
| M11 | iOS | SwiftUI classic + mode toggle + scene prototype + selected-window policy | BLOCKED by macOS/Xcode + S-Remote |
| M12 | Android | Kotlin/Compose equivalent with 2 modes | LATER |
| M13 | Migration | перенос Core на подаренный Linux сервер, backup/restore, WoL always-on | BLOCKED by hardware |

## Вертикальный срез M01–M03
Запустить AER Desktop на Ubuntu → видеть изометрическую комнату + classic tab → создать локальный «ПК» в Registry → связать с объектом → изменить simulated status → обе визуализации показывают изменение → restart восстанавливает состояние. Без настоящих сетевых команд и удалёнки.

## Правила планирования
- Одновременно не более одного основного `IN_PROGRESS` модуля.
- SPIKE исследует неизвестное, а не обещает production-функцию.
- Каждая задача <= ограниченной порции кода с тестами, не длинный мегапромпт.
- Отдельное решение по третьему рендереру (SwiftUI/Kotlin): prototype before commitment.
