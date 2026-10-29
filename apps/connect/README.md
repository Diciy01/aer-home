# AER Connect

Лёгкий Windows-клиент собственного AER Gateway. Общие движок FreeRDP и
визуальный стиль AER HOME; отдельное защищённое хранилище учётки клиента.

- [Подключение, сборка и установка](../../docs/AER_CONNECT.md)
- [Результаты M14.4 и ограничения приёмки](../../docs/M14_4_REPORT.md)
- [Windows Host](../../docs/WINDOWS_HOST.md)

Основные проверки: `flutter analyze`, `flutter test`,
`flutter build windows --release`. Сквозной тест
`integration_test/connect_live_test.dart` запускает отдельный loopback-стенд
с синтетическим Host; его окружение описано в исходнике теста.
Настоящий захват рабочего стола не запускается этим тестом.
