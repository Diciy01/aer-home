# AER HOME Desktop

Flutter-клиент Windows/Linux: дом и редактор сцены, Registry, Monitoring, Bots, Remote, Power, Network. Go Core запускается отдельно; по умолчанию клиент обращается к `http://127.0.0.1:8787`.

Windows: [сборка, установка и конфигурация](../../docs/WINDOWS.md), [отчёт M10](../../docs/M10_WINDOWS_REPORT.md). Для конечного пользователя поставляется весь Release/ZIP с DLL и CRT; SDK/vcpkg/компиляторы ему не нужны. Чистая Windows VM пока UNVERIFIED.

Проверки из этого каталога: `flutter analyze`, `flutter test`; нативная сборка на соответствующей ОС — `flutter build windows --release` / `flutter build linux --release`. Live-тесты в `integration_test/` используют только явно настроенный изолированный Core/стенд; инструкции Windows — в ссылке выше.

Общий Remote Engine — `packages/aer_remote`, native FreeRDP — `native/aer_rdp`. [Gateway и стенды](../../docs/REMOTE_GATEWAY.md). Внешние Remmina/mstsc сохранены как запасной вариант. Windows Host и отдельный AER Connect — отдельный M14.4.
