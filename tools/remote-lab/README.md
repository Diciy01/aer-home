# AER Remote — изолированный стенд (S-Remote, M07)

ТЕСТОВЫЙ стенд для проверки RDP-транспорта на одной Ubuntu-машине без изменения сеанса и настроек пользователя:
- `lab-host.sh <dir> [port]` — headless GNOME Wayland (своя D-Bus, свои XDG-каталоги) + gnome-remote-desktop на тестовом порту, RDP выключен до сеанса;
- `lab-client.sh <dir> :77 rdp://…` — Remmina в изолированном Xvfb;
- `shot.py`, `clip.py`, `latency_mouse.py` — снимок экрана клиента, проба буфера обмена, замер «мышь → изображение».
Ограничения: петля localhost; хост — headless-сеанс, а не вошедший пользователь. Результаты — `docs/S_REMOTE_FEASIBILITY.md`.
