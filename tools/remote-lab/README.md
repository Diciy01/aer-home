# AER Remote — изолированный стенд (S-Remote, M07)

ТЕСТОВЫЙ стенд для проверки RDP-транспорта на одной Ubuntu-машине без изменения сеанса и настроек пользователя:
- `lab-host.sh <dir> [port]` — headless GNOME Wayland (своя D-Bus, свои XDG-каталоги) + gnome-remote-desktop на тестовом порту, RDP выключен до сеанса;
- `lab-client.sh <dir> :77 rdp://…` — Remmina в изолированном Xvfb;
- `shot.py`, `clip.py`, `latency_mouse.py` — снимок экрана клиента, проба буфера обмена, замер «мышь → изображение».
Ограничения: петля localhost; хост — headless-сеанс, а не вошедший пользователь. Результаты — `docs/S_REMOTE_FEASIBILITY.md`.

## Ретрансляция через Gateway (M14)
- `relay_lab.py up DIR` — `lab-host.sh` + изолированные `aer-core` (127.0.0.1:18787), `aer-remote-gateway` (127.0.0.1:18443), `aer-remote-host` внутри сеанса стенда; пишет `DIR/lab.json`. Занятые порты не трогает. `relay_lab.py down DIR` — остановка (агент первым: выключает RDP).
- Клиент: `dart run tool/relay_client.dart DIR DIR/rc/client/config/freerdp` (в `packages/aer_remote`), затем `lab-client.sh DIR/rc :77 rdp://…@127.0.0.1:<порт движка>`.
Результаты — `docs/REMOTE_GATEWAY.md`.
