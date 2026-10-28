# Критерии приёмки и тест-план

## Foundation
- Запуск Flutter Linux desktop и Go Core локально; Core API healthy; без сервера приложение стартует и понятно объясняет offline.
- SQLite data survives restart; migrations tested; config isolated; `go test`, `flutter test`, `flutter analyze` pass.
- Никаких hardcoded IP, tokens; режим демо явно помечен.

## Registry + editor
- Объект компьютера/бота/сервиса создаётся из UI с максимум тремя обязательными простыми шагами, расширенные настройки скрыты.
- Создание, rename, move, delete/archive, scene binding, save/load, backup/export/import проверены.
- Scene fallback при отключении backend; выбранные health states показываются значком+текстом, логично трактуется `UNKNOWN`.

## Monitoring / Bots
- Служба «up», но heartbeat пропал → правильный DEGRADED/ERROR.
- Логи фильтруются по времени/severity/entity; секреты скрыты.
- Связанные ошибки дедуплицируются и указывают вероятную первопричину с пометкой достоверности.
- Retention/limits реально ограничивают дисковое потребление.

## Remote
- Desktop Windows и Linux: подтвержденные доступные функции, работа раскладок, ввод, текстовый clipboard, скачивание и загрузка файлов; нет обещания unsupported drag-and-drop.
- Mobile: выбор только авторизованных запущенных окон; тест приватности на уведомлениях, popups, соседних окнах; если тест не пройден, feature disabled.
- Сеанс завершается, токен отзывается, внешний WAN-доступ без приватной сети отсутствует.

## Power
- Никаких фактических reboot/WoL/bootloader modifications в автоматических тестах.
- Наличие отдельного WoL sender; двойной boot switch проверен при физическом присутствии; BitLocker recovery/fallback документирован.
- Сбой загрузки возвращает честное UNKNOWN/FAILED, без бесконечной перезагрузки.

## Поддерживаемые платформы
- Обязательные платформы: Android, Windows, Linux/Ubuntu Desktop, Ubuntu Server. M11 (нативный iOS) — CANCELLED / OUT OF SCOPE по решению владельца 2026-10-28; его реализация, инструменты Apple и iOS-сборки не входят в критерии завершения или зависимости задач. Исходники и документы не удаляются. Веб для iPhone — только необязательная будущая идея, без нового этапа.
- Windows desktop: installer, launch, tray, notifications, secure API access, tests.
- Android: mode choice first launch, persistent setting, переключение без потери состояния; для функций нет «ложных» кнопок.
- Макеты проходят accessibility/low motion/performance checks.

## Миграция на сервер
- Export Core SQLite+assets+config with secrets separated; перенос на физический сервер; rollback procedures; no loss rooms/entities/incidents; основной ПК можно выключить, Core остаётся доступным.
