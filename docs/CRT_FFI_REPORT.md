# Windows CRT / Dart FFI: разбор и регрессия (2026-10-29)

## Воспроизведение и причина

Сообщение владельца: `dartvm.exe`, `debug_heap.cpp:904`,
`_CrtIsValidHeapPointer(block)`, затем Abort. Такой прогон — **FAIL**.

Изолированный Dart-тест `embedded viewer clipboard and asynchronous disposal
through relay` из `packages/aer_remote/test/windows_shadow_test.dart` с DLL из
Flutter Debug воспроизвёл ошибку (выход 3 после Abort). Тот же тест с отдельной
Release DLL проходил. Данные и сервер — синтетические, все порты loopback.

Затем добавлен минимальный `native/aer_rdp/tests/clipboard_alloc_test.c`:
он вообще не запускает Dart, сеть, захват, ввод или системный clipboard.
Тест намеренно использует Debug CRT и Release WinPR, вызывает настоящие
clipboard callbacks и захватывает их ответ в памяти.
До исправления: **FAIL, exit 86**, та же строка 904 и то же выражение CRT.
Отчёт CRT перенаправляется в stderr с немедленным ненулевым выходом:
проверки остаются включёнными, продолжения после ошибки нет.

`dumpbin /dependents` и `/directives` подтвердили:

- Flutter Debug `aer_rdp.dll`: `VCRUNTIME140D.dll`, `ucrtbased.dll`,
  объектный файл с `/DEFAULTLIB:MSVCRTD`.
- FreeRDP/WinPR из используемого vcpkg — Release CRT.
- `ConvertUtf8ToWCharAlloc` и `ConvertWCharNToUtf8Alloc` выделяли память
  внутри WinPR. Прослойка вызывала свой `free(w)`, а также сохраняла
  WinPR-буфер `remote_text` и позднее освобождала его своим `free`.
- `CMP0091` в Flutter Windows включалась после первого `project()`.
  Поэтому `MSVC_RUNTIME_LIBRARY=MultiThreadedDLL` фактически игнорировалось;
  старый CMake cache дополнительно содержал `/MDd`.

Причина — освобождение через несовместимый аллокатор. Это не доказательство
double free: конкретное падение воспроизведено на первом освобождении
UTF-16 буфера, выделенного другой CRT.

## Исправление

1. Конвертация WinPR теперь пишет в буферы, выделенные самой прослойкой,
   через двухпроходные non-allocating API. Та же прослойка освобождает буферы.
   Это безопасно и при намеренно разных CRT в регрессионном тесте. API
   освобождения новых версий WinPR не требуется; Linux-путь сохранён.
2. `CMP0091 NEW` включается до верхнего `project()` в Windows AER HOME и
   AER Connect. Старые CRT-флаги удаляются только из локальных C-параметров
   подкаталога `aer_rdp`, без перезаписи CMake cache, runner или plugins.
3. Post-build проверяет реальную таблицу DLL imports; Debug CRT в
   поставляемой `aer_rdp.dll` прерывает сборку с ошибкой.
4. Установлен предел clipboard 1 MiB; повреждённая/нечётная UTF-16 длина
   отбрасывается до чтения буфера.
5. Закрытие FreeRDP, которое может ожидать TLS-трафик через Dart relay,
   выполняется рабочим isolate. Один handle имеет одного владельца;
   повторные `disposeAsync` ожидают тот же Future. Close/autoreconnect
   ожидают уже начатое освобождение, не освобождают handle повторно.

## Проверка границ памяти

| Память | Владелец / освобождение |
|---|---|
| Dart FFI строки и out-parameters | `package:ffi` calloc → его же free; на Windows это CoTaskMem |
| `AerRdp`, кадр, local/remote clipboard | аллокатор прослойки → прослойка |
| Выдаваемая Dart копия clipboard | `aer_rdp_clip_get` → только `aer_rdp_mem_free` в finally |
| Кадр под lock | заимствованный указатель, копия до unlock; Dart не освобождает его |
| Текст ошибки | заимствован до освобождения handle; Dart копирует строку |
| FreeRDP context/GDI/channels | штатные FreeRDP creation/free API, после join connection thread |

Параллельных агентов редактирования не обнаружено. Тестовые процессы имели
отдельные PID, временные данные, loopback-порты и сеансовые сертификаты.
Параллельные процессы не разделяют эти heap-указатели. Зависший тестовый
клиент был остановлен по проверенному пути; исходный Monitoring Agent не
затрагивался. Новые воспроизведения CRT проводятся последовательно.

## Результаты

| Проверка | Результат |
|---|---|
| Минимальный тест до исправления | FAIL (ожидаемое воспроизведение), exit 86 |
| Тот же forced Debug CRT тест после исправления | PASS: 1000 циклов, `_CrtCheckMemory` |
| CTest Debug | PASS 1/1 |
| Negative test проверки imports | PASS: намеренный Debug CRT отклонён |
| Новая Flutter Debug viewer DLL imports | PASS: Release CRT, без `ucrtbased`/`VCRUNTIME140D` |
| Dart native lifecycle | PASS: 50 concurrent/repeated async + 100 repeated sync disposals |
| Dart embedded clipboard / disposal через Gateway | PASS с новой Flutter Debug DLL |
| Сквозной native synthetic Host, pin/password, кадры/ввод/clipboard/files/reconnect/revoke | PASS с новой Flutter Debug DLL |
| Flutter UI после исправления | PASS, 9 с: изображение, clipboard echo, переподключение, отзыв и teardown без зависания; DPAPI roundtrip отдельного тестового ключа |
| AER HOME Flutter analyze / unit+widget tests | PASS, 224/224 |
| Dart analyze | PASS, замечаний нет |
| Linux native runtime | UNVERIFIED: Linux/WSL среда недоступна |

Локальные журналы: `E:/dev/logs/codex-crt-before-fix.log`,
`codex-crt-after-fix.log`, `codex-crt-ctest-after.log`,
`codex-crt-import-guard-negative.log`, `codex-crt-debug-imports-after.log`,
`codex-crt-dart-debug-after.log`, `codex-crt-connect-live-after.log`.
Секреты пользователя в тестах не используются.

Сквозные проверки с `windows_shadow_test.dart` и AER Connect используют
разрабатываемый стенд M14.4 в рабочем дереве. Минимальный native CTest и
`ffi_lifecycle_test.dart` независимы от Windows Host и воспроизводятся отдельно.
