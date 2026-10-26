# Roadmap, отдельные маленькие задачи для одного разработчика + Claude Code

Статусы: TODO / IN_PROGRESS / DONE / BLOCKED / SPIKE. Любой DONE требует артефакта и воспроизводимых тестов.

| ID | Этап | Результат | Статус |
|---|---|---|---|
| M00 | Discovery/feasibility | реальное окружение, ADRs, dependency choices, риски remote/Wayland, baseline benchmark | TODO |
| M01 | Foundation | monorepo, Go Core, SQLite migrations, Flutter shell Linux, API contracts, tests, mocks | TODO |
| M02 | Registry | device types, CRUD, capabilities, add wizard, secrets refs | TODO |
| M03 | Scene vertical slice | Flutter Flame одна комната, камера, выбор предмета, provider-agnostic binding | TODO |
| M04 | Editor | создание комнат, drag/place, undo/redo, save/load, export | TODO |
| M05 | Monitoring | lightweight probes, journal, incidents, evidence, log rotation | TODO |
| M06 | Bots | heartbeat/task results, Docker/log adapters, UI/alerts | TODO |
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
