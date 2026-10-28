# Состояние работы (для продолжения после прерывания)

Обновлено: 2026-10-28.

## M07 Remote — DONE
Коммиты `4066866..185205d`. Повторная финальная проверка 2026-10-28 пройдена (Go, Flutter 176, release, контракт 0.8.0, поиск секретов). UNVERIFIED — см. `docs/M07_REMOTE_REPORT.md`.

## M08 Power — IN_PROGRESS
Разрешено владельцем 2026-10-28. S-Power выполняется внутри M08 как исследование только на чтение (как S-Remote в M07).

Запрещено без отдельного разрешения: реальные WoL-пакеты в сеть, shutdown/reboot/suspend, efibootmgr --bootnext, grub-reboot, bcdedit, изменение GRUB/rEFInd/UEFI/BitLocker/Secure Boot, установка служб/sudoers.

План (отмечать по мере выполнения):
- [x] S-Power: инвентаризация загрузчика/SB/NIC/BitLocker (только чтение), реальные детали — в `docs/private/LOCAL_NOTES.md`
- [x] Core: config `power`, модуль `power` (WoL, задания, политика, аудит), kind=power в Monitoring, ADR-014
- [ ] Агент `aer-power-host` (фиксированные адаптеры linux/windows, по умолчанию dry-run)
- [x] OpenAPI 0.9.0 + контрактный тест (Magic Packet на тестовый приёмник 127.0.0.1)
- [ ] Flutter: раздел «Питание», панель в доме, тесты
- [ ] Живая проверка: Core + агент (dry-run) + тестовый UDP-приёмник WoL на 127.0.0.1
- [ ] Документы: S_POWER_FEASIBILITY, POWER_DUALBOOT, ADR-014, M08 report, user guide, ROADMAP, MODULES

## Следующий шаг
См. первый неотмеченный пункт плана.
