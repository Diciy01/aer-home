# M00 — Discovery / feasibility: отчёт

**Дата:** 2026-10-26 • **Хост:** основной ПК разработчика, Ubuntu 24.04 LTS, GNOME **Wayland**.
Все проверки — read-only, кроме согласованной установки Go (user-local, без sudo).

## 1. Фактическое состояние

- Рабочий раздел — общий NTFS-раздел, **не отдельный проект**: на нём лежат и другие данные.
- Документация AER HOME: пакет документов (16 документов + контракты + пример сцены). Исходного кода и git до M00 не было.
- Решение владельца: репозиторий AER HOME = каталог пакета документации (ADR-006). Другие данные на разделе не затрагивались.

## 2. Окружение

| Компонент | Результат | Статус |
|---|---|---|
| Git | 2.56.0; глобальной identity нет → задана локально в репо | OK |
| Flutter / Dart | 3.47.7 stable / 3.13.5 (`<tools>/flutter-3.47.7`), `flutter doctor` без проблем | OK |
| Linux toolchain | clang 18.1.3, cmake 3.28.3, ninja 1.11.1, GTK 3.24.41 | OK |
| Go | отсутствовал → установлен **1.27.3** в `<tools>/go-1.27.3` (SHA256 проверен, PATH профиля не менялся) | OK |
| Docker | CLI есть, демон `inactive` | Не блокирует; Docker-мониторинг локально не проверить |
| SQLite CLI | только из Android SDK; не нужен (драйвер встроен) | OK |
| NTFS-раздел | exec-бит, symlink, регистр имён — проверены, работают | OK с оговорками (§5) |
| Устройства Flutter | Linux desktop (+ Android-устройства по ADB) | для справки |

## 3. Совместимость Flutter Desktop + Flame

- Flame **1.38.2** (2026-08-27) и flame_tiled **3.1.2**: требуют Flutter ≥ 3.41, Dart ≥ 3.11 → совместимы с 3.47.7. Лицензия MIT.
- Linux-сборка Flutter release проверена (≈33 с), рендер Impeller/OpenGLES работает под Wayland.
- **Не сделано:** FPS/memory-бенчмарк сцены (1 комната, 5 hit zones) — перенесён во вход M03, т.к. в M01 изометрия запрещена.

## 4. Сборка под Windows

- Flutter **не кросс-компилирует** Windows-приложение с Linux: нужен Windows-хост + Visual Studio (Desktop C++). Проект содержит `windows/` runner, но сборка **UNVERIFIED** до M10.
- Плюс: репозиторий лежит на NTFS-разделе, видимом из Windows → можно собирать из того же каталога после загрузки в Windows (см. риск hibernation ниже).
- Go Core кросс-компилируется: `GOOS=windows` и `GOOS=linux GOARCH=arm64` собраны успешно (pure-Go SQLite, без cgo).

## 5. Технические риски

1. **NTFS + Windows Fast Startup/гибернация.** Если Windows выключена с гибернацией, запись на раздел из Linux может повредить данные. Проверить, что Fast Startup отключён (в Windows), до активной работы. БД Core по умолчанию **не** на NTFS: `~/.local/share/aer-home/core`.
2. **BitLocker**: на стороне Windows возможен BitLocker. Любое переключение через UEFI BootNext/изменение загрузчика — риск Recovery-запроса (S-Power).
3. **Secure Boot / пользовательские параметры GRUB**: перед S-Power провести инвентаризацию загрузчика и учесть существующие настройки.
4. **Wayland**: удалённый доступ к рабочему столу и тем более к отдельным окнам требует порталов/PipeWire и, как правило, подтверждения пользователя на хосте — unattended-режим под вопросом. Это главный риск AER Remote.
5. **WoL при Core на том же ПК** невозможен (ПК не будит сам себя) до появления always-on устройства.
6. Docker-демон выключен — интеграцию Docker тестировать на fake/stub до его запуска с согласия.

## 6. Внешние проекты (проверено через GitHub API 2026-10-26)

| Проект | Лицензия | Активность | Вывод |
|---|---|---|---|
| Flame | MIT | активен (push 2026-10-26) | ADOPT для M03 |
| Tiled | GPL-2 (редактор) / BSD (libtiled), API отдаёт NOASSERTION | активен | только как dev tool |
| Beszel | MIT | активен | EVALUATE как опциональный adapter метрик |
| MeshCentral | Apache-2.0 | активен | SPIKE; issue #7875 (Wayland) теперь **closed** — перепроверить фактическую поддержку |
| RustDesk | AGPL-3.0 | активен | SPIKE; только как внешний процесс, без встраивания кода |
| Uptime Kuma | MIT | активен | OPTIONAL |
| Healthchecks | BSD-3 | активен | REFERENCE (формат ping-heartbeat позаимствовать идейно) |
| Sunshine / Moonlight-qt | GPL-3.0 | активны | только статус/логи (как в docs) |
| modernc.org/sqlite | BSD-3 (GitLab; зеркало на GitHub архивировано) | релиз v1.61.0 от 2026-10-21 | ADOPT (ADR-001) |

## 7. Противоречия и решения

| # | Противоречие | Решение |
|---|---|---|
| 1 | Задание: «проект прямо в `<общий раздел>`» vs фактически общий раздел с другими проектами | ADR-006: репо = каталог пакета документации (по решению владельца) |
| 2 | CLAUDE_WORKFLOW: «не писать код до плана, коммитит владелец» vs задание: самостоятельно делать Foundation и коммитить | приоритет у задания; коммиты локальные, без push |
| 3 | openapi `/health` «authenticated by default» vs требование объяснять offline | ADR-007: `/health` публичный, без идентификаторов |
| 4 | openapi 0.1 отдаёт голые массивы vs «единый формат ответов» | ADR-007: конверт `{data|error, meta}`, contract 0.2.0 |
| 5 | Типы сущностей в openapi (computer…custom) ≠ категории задания (сайты, БД, процессы, Docker-контейнеры, пользовательские объекты) | решить в M02 (ADR + contract bump) |
| 6 | `examples/home.scene.json`: `entityBinding`, id `room-office` vs SCENE_EDITOR `deviceBinding{entityId,role}` и openapi `Room.id: uuid`; нет `sortAnchor/hitArea/layers` | решить в M03 (scene schema v1) |
| 7 | `events.schema.json`: `entityId` обязателен, а системные события (Core start, WAN down) без сущности | сделать nullable в M05 |
| 8 | Задание: Android — целевая платформа; ROADMAP: M12 LATER | оставить порядок, Android после iOS-решения |
| 9 | Задание §9 «переключение ОС» внутри Remote; docs — отдельный модуль Power | Remote лишь вызывает Power API |
| 10 | MODULES: Foundation включает event bus и jobs; задание §19 их не требует | перенесены в первый модуль, которому нужны (M05 / M08) |

## 8. Необходимые API-контракты (план)

1. **Foundation** (сделано, 0.2.0): `/health`, `/system/info`, конверт, коды ошибок.
2. **Registry (M02):** `GET/POST /entities`, `GET/PATCH /entities/{id}` с `revision` (optimistic locking), `POST /entities/{id}:archive`, `GET /entity-types` (схема мастера: обязательные/расширенные поля), `GET /entities/{id}/capabilities`, secret references (не значения).
3. **Scene (M03–M04):** `GET/PUT /scene` (версионируемый документ), `GET /assets`, import/export.
4. **Events (M05):** `GET /events?cursor=` + SSE/WebSocket stream с cursor/replay.
5. **Monitoring/Incidents (M05):** ingest `POST /ingest/heartbeat`, `POST /ingest/metrics` (агенты/боты, токен на источник), `GET /incidents`, `POST /incidents/{id}:ack`, `GET /logs?entity&severity&from&to`.
6. **Jobs (M08):** `POST /jobs:plan` → риски+confirmation token → `POST /jobs/{id}:confirm` → статус/аудит.
7. **Remote (M07, после SPIKE):** `GET /remote/hosts/{id}/capabilities`, `POST /remote/sessions` (negotiation), `DELETE` (revoke).
8. **Agent protocol:** регистрация агента, heartbeat, capabilities; отдельные scoped credentials (замена единого токена из ADR-007 до mobile/remote).

## 9. Облегчённый Core — замер

`aer-core` (linux/amd64): бинарник 16.9 МБ, **RSS в простое ≈ 13.5 МБ**, старт < 50 мс, БД ~80 КБ. Без внешних сервисов, без cgo. Цель «4 ГБ RAM, слабый CPU» достижима с большим запасом.

## 10. Последовательность разработки

M01 Foundation (сделано) → **M02 Registry** → M03 Scene slice (+ Flame бенчмарк) → M04 Editor → M05 Monitoring (+ event bus) → M06 Bots → S-Remote / S-Power (spike, с физическим присутствием) → M07/M08 → M09 Network+TV → M10 Windows → M11 iOS → M12 Android → M13 Migration.
