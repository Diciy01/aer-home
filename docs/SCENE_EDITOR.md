# Scene Engine + Room Editor

## Цель
Изометрическая сцена с редактируемыми комнатами и предметами. Графика в нативном клиенте, Core хранит только сериализованные данные сцены. Flutter+Flame; Tiled подходит для authoring исходных карт, но итоговый встроенный редактор — свой.

## Схема
Home → Rooms → Layers → VisualObjects. `VisualObject` имеет `id`, `assetId`, `roomId`, `transform{x,y,z,scale,rotation}`, `sortAnchor`, `hitArea`, `deviceBinding{entityId,role}`, visual props, local overrides, schemaVersion. Никаких токенов/IP или executable scripts в scene JSON.

## Рендер
- Камера pan/zoom, изометрическая проекция, корректный z-order и occlusion.
- Устройство подсвечивается по normalized health; отдельно focus/selection state.
- Отключаемые эффекты и LOD; сцена не грузит Core и сохраняет работоспособность при offline.
- Asset pipeline: исходники, лицензии, атласы, низкое/высокое разрешение, fallback asset.

## Редактор
- Создать/клонировать/переименовать/архивировать комнату.
- Добавить предмет, переместить, rotate в поддерживаемых углах, align/snap; undo/redo, autosave draft, publish.
- Выбрать техобъект из Registry (или создать в wizard) → bind. Смена внешнего вида не меняет технический объект.
- Несколько визуальных объектов могут отображать одну сущность, техническая сущность может быть «без комнаты».
- Импорт/экспорт JSON+assets, schema migrations, validation, ревизии и безопасное восстановление прошлой версии.
- Устройство без доступа/провайдера остаётся в комнате с `UNKNOWN` или `UNSUPPORTED`, не исчезает.

## Flutter ↔ mobile
Общий JSON scene schema + assets/IDs. На iOS/Android отдельные рендереры либо совместимый общий движок **только после spike** по производительности и стоимости поддержки. Не утверждать, что SwiftUI/Compose нативно рендерят Flame.

## MVP порядок
1. одна статичная изометрическая комната (3–5 объектов), hit tests; 2. Camera; 3. Bind Registry; 4. Undo/redo; 5. Save/load; 6. Multiple rooms; 7. import assets/LOD.

## Приёмка
Тестами подтверждено: переименование/перемещение/перезапуск не ломают привязки; сохранённый дом открывается на следующем запуске; офлайн-сцена читаема; объект показывает семантику статуса, а не просто цвет.
