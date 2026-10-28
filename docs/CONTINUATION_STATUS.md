# Состояние работы (для продолжения после прерывания)

Обновлено: 2026-10-28.

## M07 Remote — DONE
Коммиты `4066866..185205d`. UNVERIFIED — см. `docs/M07_REMOTE_REPORT.md`.

## M08 Power — DONE по ПО; живая приёмка — PENDING (нужно согласие и присутствие владельца)
Коммиты `b771ada` (Core, контракт 0.9.0, ADR-014), `93d4f49` (агент), `14cb500` (Flutter), `5286e84` (стенд, исправление Monitoring, производительность), затем документация. S-Power выполнен внутри M08 только чтением.

Выполнено: модуль Core `power`, агент `aer-power-host`, раздел «Питание» и панель в доме, контрактные/модульные/сквозные тесты, живой стенд `tools/power-lab` (только SIMULATED и WoL на 127.0.0.1), замеры, документы (`POWER.md`, `POWER_CONNECT.md`, `USER_GUIDE_POWER.md`, `S_POWER_FEASIBILITY.md`, `M08_POWER_REPORT.md`).

Не выполнялось и запрещено без отдельного разрешения: реальные WoL в сеть, shutdown/reboot/suspend, BootNext/bcdedit, изменения GRUB/rEFInd/UEFI/BitLocker/Secure Boot/sudoers, установка служб.

## Следующий шаг
M09 (Network + TV) — **не начинать без команды владельца**. Отдельно, по согласию владельца: живая приёмка M08 по `docs/POWER_DUALBOOT.md` → «Приёмка».
