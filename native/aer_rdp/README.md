# aer_rdp — встроенный просмотр RDP (M14.3, ADR-017)

Тонкая C-прослойка над FreeRDP 3 (`libfreerdp-client3`, Apache-2.0) для встроенного просмотра AER HOME (и позже AER Connect). Один дескриптор — одно соединение в своём потоке; вызывающая сторона опрашивает состояние и кадры (BGRA) и ставит ввод в очередь — без обратных вызовов через FFI. API — `aer_rdp.h`, Dart-привязка — `packages/aer_remote/lib/src/rdp/`.

- Сертификат хоста принимается только при совпадении SHA-256 с закреплённым; ничего не сохраняется (отдельный временный каталог конфигурации FreeRDP на соединение).
- Буфер обмена — только текст (CF_UNICODETEXT) в обе стороны; без права на буфер канал `cliprdr` не загружается вовсе.
- Графика — программный GDI + конвейер GFX (его требует gnome-remote-desktop).

Сборка (нужны заголовки `freerdp3-dev`, FreeRDP ≥ 3.5; проверено с 3.32.1):

    cmake -S native/aer_rdp -B native/aer_rdp/build -G Ninja -DCMAKE_BUILD_TYPE=Release && ninja -C native/aer_rdp/build

AER HOME для Linux собирает библиотеку сам (`apps/desktop/linux/CMakeLists.txt`) и кладёт в `bundle/lib/`; без заголовков FreeRDP приложение собирается как прежде и использует внешний клиент. Windows — после M10 (UNVERIFIED).
