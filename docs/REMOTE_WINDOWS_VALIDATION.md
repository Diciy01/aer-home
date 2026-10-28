# План проверки AER Remote на Windows (M07 → M10)

M07 не имел Windows-машины. M10 проверил клиент на настоящей Windows, но RDP-хостом был loopback FreeRDP sample, а не пользовательский desktop. Результаты и команды — `M10_WINDOWS_REPORT.md`, `WINDOWS.md`. Настоящий Windows Host остаётся M14.4.

## Подготовка
- Хост: Windows 10/11 **Pro** (Home не умеет быть RDP-хостом — проверить и зафиксировать отказ агента «RDP не слушает порт»).
- Клиенты: Windows (mstsc), Ubuntu (Remmina). Сеть: LAN, затем Tailscale.
- Сборка: `GOOS=windows go build ./cmd/aer-remote-host`, Flutter `flutter build windows`.

## Матрица
| # | Сценарий | Ожидание | Результат |
|---|---|---|---|
| W1 | Агент `windows-rdp` на Pro с выключенным RDP | `ready=false`, причина в карточке | |
| W2 | RDP включён пользователем | «Готов к подключению» | |
| W3 | Ubuntu → Windows (Remmina) | рабочий стол, вход учёткой Windows (NLA), мышь, клавиатура RU/EN | |
| W4 | Windows → Ubuntu (mstsc, хост GNOME) | `.rdp`-файл AER, вход паролем сеанса; mstsc спросит пароль — UX проверить; сертификат — предупреждение mstsc (закрепление FreeRDP не применяется) | |
| W5 | Windows → Windows | как W3/W4 | |
| W6 | Буфер обмена (текст) в обе стороны | работает; `redirectclipboard:i:0` выключает | |
| W7 | Файлы: канал агента на Windows-хосте | загрузка/скачивание/SHA-256 | |
| W8 | Несколько мониторов | выбор/охват в mstsc | |
| W9 | Блокировка экрана во время сеанса | локальный сеанс блокируется (поведение клиентской Windows), не обходится | |
| W10 | UAC/защищённые окна | видны через RDP по политике Windows; не обходить | |
| W11 | Завершение/отзыв из AER | `windows-rdp` не авторизует управляемые сеансы: ready=false, Open отказывает; WTS/сертификат/NLA ещё не реализованы | PASS: отказ на fake listener; Windows → Gateway → sample: отзыв закрывает viewer. Реальный Windows Host UNVERIFIED |
| W12 | Потеря сети, переподключение | | |
| W13 | Задержки, CPU, RAM, трафик | замер как в M07 | |

Пустые результаты W1–W10/W12/W13 означают **UNVERIFIED** именно для настоящего Windows RDP-хоста/LAN/Tailscale. M10 отдельно проверил картинку, изменение кадра от мыши, scancode/Unicode-отправку, pin refusal, отключённые clipboard/files, переподключение и отзыв на localhost sample. Sample не поддерживает NLA/clipboard transfer; это не заменяет W3–W10.

## Известные риски
- M10 устранил ложную готовность `windows-rdp`: управляемый сеанс не выдаётся, поэтому незавершённая реализация не обещает отзыв, которого нет. Системный RDP и его пользователи не затрагиваются. Управляемый Windows Host — M14.4.
- Учётные данные Windows вводятся в mstsc; AER их не видит и не хранит.
