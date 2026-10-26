# AER Remote — техническая спецификация и обязательный feasibility spike

## Политика клиентов
- **Desktop (Flutter Windows/Linux):** полная удалённая пользовательская сессия работающей ОС, мышь/клавиатура (включая русскую раскладку), двусторонний текстовый буфер, передача файлов туда-обратно, file manager, желательно drag-and-drop если есть безопасная поддержка, несколько мониторов при поддержке provider.
- **Mobile (SwiftUI/Kotlin):** только список авторизованных **запущенных пользовательских приложений/окон**. По тапу → захват и управление выбранным окном либо специализированный remote API. **Никогда автоматически не переключать на полный рабочий стол**; скрывать/маскировать соседние окна и системные диалоги. Если ОС/Wayland не позволяет сделать это надёжно — показать `UNSUPPORTED` + рекомендацию использовать desktop клиент. Не маскировать обрезкой full-desktop как «изоляцию» без проверки безопасности.
- Remote actions доступны только после авторизации пользователя, explicit session consent/policy; всегда session timeout, revoke, audit.

## Возможности модели
`desktop_video`, `window_video`, `text_clipboard_bidir`, `file_upload`, `file_download`, `drag_drop`, `keyboard_ime`, `audio`, `multi_monitor`, `touch_input`. Не выдавать unavailable capabilities в UI как гарантированные.

## Провайдеры
MeshCentral — кандидат на agent/desktop/files/terminal, но Wayland может быть проблемой. RustDesk — альтернативный кандидат, но лицензия/встраивание и отдельные окна требуют проверки. Sunshine+Moonlight уже есть для ТВ, **не считать** их транспортом со встроенной двусторонней передачей файлов и clipboard. Guacamole/RDP потенциальны для Windows, Linux Wayland требует отдельных тестов.

## Spike до реализации
Матрица Windows host ↔ Windows viewer, Ubuntu 24.04 Wayland host ↔ Windows viewer, Ubuntu host ↔ Linux viewer; затем iPhone selected-window и Android selected-window. Фиксировать: capture, input, keyboard layouts, clipboard text, files, latency, audio, screen lock, foreground permissions, multiple windows/popups, provider API, license. Проверить отдельное окно без раскрытия остальных приложений. Прототип может отказаться от window mode при невозможности.

## Проектирование
AER Core — control plane, session metadata, permissions, heartbeat; bulk video/file stream — шифрованный p2p или контролируемый relay. Внутренний `RemoteProvider` указывает доступные capabilities по host/OS/session.

## Clipboard/files
- Текстовый clipboard поддерживать только при правильном focus, без постоянного тайного чтения с буфера.
- Файлы — отдельный защищённый канал с выбором направления/папки, progress, проверки размера и отказом от опасных путей.
- Drag-and-drop — enhancement, не базовая обещанная функция до spike.
- На mobile: клавиатура, управление жестами, paste только явным действием.

## Ошибки
DISPLAY_PERMISSION_REQUIRED, WAYLAND_UNSUPPORTED, NO_ACTIVE_SESSION, WINDOW_NOT_CAPTURABLE, AUTH_FAILED, HOST_ASLEEP, INPUT_DENIED, PROVIDER_UNAVAILABLE, CONNECTION_TIMEOUT.

## Запреты
Не обходить lockscreen, не запускать привилегированный hidden desktop, не публиковать remote порт в WAN, не хранить записанные сессии без согласия.
