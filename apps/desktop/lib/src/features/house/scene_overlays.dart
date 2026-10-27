import 'package:flutter/material.dart';

import '../../scene/binding/scene_binding.dart';
import '../../scene/geometry/scene_layout.dart';
import '../../scene/model/scene_document.dart';
import '../../scene/render/scene_game.dart';
import '../../shell/status_presentation.dart';
import '../../theme/tokens.dart';

String statusLabel(SceneStatus s) => switch (s) {
  SceneStatus.online => 'В сети',
  SceneStatus.offline => 'Не в сети',
  SceneStatus.warning => 'Предупреждение',
  SceneStatus.critical => 'Критично',
  SceneStatus.unknown => 'Неизвестно',
  SceneStatus.loading => 'Загрузка',
  SceneStatus.archived => 'В архиве',
};

IconData statusIcon(SceneStatus s) => switch (s) {
  SceneStatus.online => Icons.check_rounded,
  SceneStatus.offline => Icons.power_settings_new_rounded,
  SceneStatus.warning => Icons.priority_high_rounded,
  SceneStatus.critical => Icons.close_rounded,
  SceneStatus.unknown => Icons.question_mark_rounded,
  SceneStatus.loading => Icons.sync_rounded,
  SceneStatus.archived => Icons.inventory_2_outlined,
};

/// "В сети · тест" / "Неизвестно · устарело" / null for decor.
String? statusLine(ObjectPresentation p) {
  final s = p.status;
  if (s == null) return null;
  return [
    statusLabel(s),
    if (p.isDemo) 'тест',
    if (p.stale) 'устарело',
  ].join(' · ');
}

IconData roomIcon(String kind) => switch (kind) {
  'office' => Icons.desk_outlined,
  'living' => Icons.weekend_outlined,
  'server' => Icons.dns_outlined,
  'network' => Icons.router_outlined,
  'automation' => Icons.smart_toy_outlined,
  'bedroom' => Icons.bed_outlined,
  'kitchen' => Icons.kitchen_outlined,
  _ => Icons.meeting_room_outlined,
};

/// Round status mark used in Flutter overlays (mirrors the scene badges).
class StatusDot extends StatelessWidget {
  const StatusDot(
    this.status, {
    super.key,
    this.size = 20,
    this.demo = false,
    this.stale = false,
  });

  final SceneStatus status;
  final double size;
  final bool demo;
  final bool stale;

  @override
  Widget build(BuildContext context) {
    final dot = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: statusColor(status).withValues(alpha: stale ? 0.6 : 1),
        shape: BoxShape.circle,
        border: Border.all(color: AerColors.surface, width: 1.5),
      ),
      child: Icon(
        statusIcon(status),
        size: size * 0.62,
        color: AerColors.surface,
      ),
    );
    if (!demo) return dot;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        dot,
        Positioned(
          right: -2,
          top: -2,
          child: Container(
            width: size * 0.42,
            height: size * 0.42,
            decoration: BoxDecoration(
              color: AerColors.lavender,
              shape: BoxShape.circle,
              border: Border.all(color: AerColors.surface, width: 1),
            ),
          ),
        ),
      ],
    );
  }
}

/// Small floating label above the hovered object.
class HoverLabel extends StatelessWidget {
  const HoverLabel({super.key, required this.presentation});

  final ObjectPresentation presentation;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final line = statusLine(presentation);
    return Material(
      color: AerColors.ink.withValues(alpha: 0.88),
      borderRadius: BorderRadius.circular(AerRadii.small),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              presentation.title,
              style: text.labelLarge?.copyWith(color: AerColors.surface),
            ),
            if (line != null)
              Text(
                line,
                style: text.labelSmall?.copyWith(color: AerColors.accentSoft),
              ),
          ],
        ),
      ),
    );
  }
}

/// Short card shown on single click.
class QuickCard extends StatelessWidget {
  const QuickCard({
    super.key,
    required this.geometry,
    required this.presentation,
    required this.capabilityLabel,
    required this.onClose,
    required this.onOpen,
    required this.onProperties,
    this.onDiagnostics,
    this.extra,
  });

  final ObjectGeometry geometry;
  final ObjectPresentation presentation;
  final String Function(String) capabilityLabel;
  final VoidCallback onClose;
  final VoidCallback? onOpen;
  final VoidCallback onProperties;
  final VoidCallback? onDiagnostics;

  /// Module-specific panel for the bound entity (e.g. a bot's controls).
  final Widget? extra;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final p = presentation;
    final s = p.status;
    final caps = p.snapshot?.capabilities ?? const <String>[];
    return Card(
      key: const Key('scene-quick-card'),
      elevation: 6,
      shadowColor: AerColors.ink.withValues(alpha: 0.25),
      child: Padding(
        padding: const EdgeInsets.all(AerSpacing.m),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        p.title,
                        style: text.titleMedium,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        p.subtitle,
                        style: text.bodySmall?.copyWith(
                          color: AerColors.inkMuted,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Закрыть',
                  visualDensity: VisualDensity.compact,
                  onPressed: onClose,
                  icon: const Icon(Icons.close, size: 18),
                ),
              ],
            ),
            const SizedBox(height: AerSpacing.s),
            if (s != null)
              Row(
                children: [
                  StatusDot(s, demo: p.isDemo, stale: p.stale),
                  const SizedBox(width: AerSpacing.s),
                  Expanded(child: Text(statusLine(p)!, style: text.bodyMedium)),
                ],
              ),
            const SizedBox(height: AerSpacing.xs),
            Text(
              p.note,
              style: text.bodySmall?.copyWith(color: AerColors.inkMuted),
            ),
            if (p.live case final live?) ...[
              const SizedBox(height: AerSpacing.xs),
              Text(
                [
                  if (live.lastContactAt != null)
                    'Последний контакт: ${formatAge(live.lastContactAt, DateTime.now())}',
                  if (live.openIncidents > 0)
                    'Активных инцидентов: ${live.openIncidents}',
                ].join(' · '),
                key: const Key('quick-card-live'),
                style: text.bodySmall,
              ),
            ],
            if (caps.isNotEmpty) ...[
              const SizedBox(height: AerSpacing.s),
              Wrap(
                spacing: AerSpacing.xs,
                runSpacing: AerSpacing.xs,
                children: [
                  for (final c in caps.take(6))
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: AerColors.surfaceMuted,
                        borderRadius: BorderRadius.circular(AerRadii.small),
                      ),
                      child: Text(capabilityLabel(c), style: text.labelSmall),
                    ),
                  if (caps.length > 6)
                    Text('+${caps.length - 6}', style: text.labelSmall),
                ],
              ),
            ],
            if (extra case final w?) ...[
              const SizedBox(height: AerSpacing.s),
              w,
            ],
            const SizedBox(height: AerSpacing.m),
            Wrap(
              spacing: AerSpacing.s,
              runSpacing: AerSpacing.s,
              children: [
                if (onOpen != null)
                  FilledButton.icon(
                    key: const Key('scene-open-details'),
                    onPressed: onOpen,
                    icon: const Icon(Icons.open_in_new_rounded, size: 16),
                    label: const Text('Подробнее'),
                  ),
                if (onDiagnostics != null)
                  FilledButton.tonalIcon(
                    key: const Key('scene-open-diagnostics'),
                    onPressed: onDiagnostics,
                    icon: const Icon(Icons.monitor_heart_outlined, size: 16),
                    label: const Text('Диагностика'),
                  ),
                OutlinedButton(
                  onPressed: onProperties,
                  child: const Text('Свойства'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Legend: what badges, the test marker and faded badges mean.
class SceneLegend extends StatelessWidget {
  const SceneLegend({super.key, required this.onClose});

  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Card(
      key: const Key('scene-legend'),
      elevation: 4,
      child: Padding(
        padding: const EdgeInsets.all(AerSpacing.m),
        child: SizedBox(
          width: 260,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(child: Text('Обозначения', style: text.titleSmall)),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    onPressed: onClose,
                    icon: const Icon(Icons.close, size: 18),
                  ),
                ],
              ),
              for (final s in SceneStatus.values)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(
                    children: [
                      StatusDot(s, size: 18),
                      const SizedBox(width: AerSpacing.s),
                      Text(statusLabel(s), style: text.bodyMedium),
                    ],
                  ),
                ),
              const Divider(),
              Row(
                children: [
                  const StatusDot(SceneStatus.online, size: 18, demo: true),
                  const SizedBox(width: AerSpacing.s),
                  Expanded(
                    child: Text(
                      'Лиловая метка — тестовое состояние демо-сцены',
                      style: text.bodySmall,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AerSpacing.xs),
              Row(
                children: [
                  const StatusDot(SceneStatus.unknown, size: 18, stale: true),
                  const SizedBox(width: AerSpacing.s),
                  Expanded(
                    child: Text(
                      'Бледный значок — данные устарели (нет связи)',
                      style: text.bodySmall,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AerSpacing.s),
              Text(
                'Состояния привязанных объектов приходят из модуля Monitoring. Нет данных — «Неизвестно»; '
                'без связи с Core показывается последнее известное состояние бледным значком.',
                style: text.bodySmall?.copyWith(color: AerColors.inkMuted),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Read-only scene properties of an object (editing is M04).
Future<void> showObjectProperties(
  BuildContext context,
  ObjectGeometry g,
  ObjectPresentation? p,
) {
  final o = g.object;
  final rows = <(String, String)>[
    ('Подпись', o.label.isEmpty ? '—' : o.label),
    ('Комната', g.room.name),
    ('Ассет', '${g.asset.label} (${g.asset.id})'),
    (
      'Графика',
      g.asset.art.isPlaceholder ? 'временная (placeholder)' : 'финальная',
    ),
    (
      'Позиция, тайлы',
      'x ${o.position.x}, y ${o.position.y}, z ${o.position.z}',
    ),
    ('Поворот', '${o.rotation}°'),
    ('Масштаб', '${o.scale}'),
    ('Слой', o.layer.name),
    ('Привязка', o.entityBinding?.entityId ?? 'нет'),
    ('ID объекта сцены', o.id),
  ];
  return showDialog<void>(
    context: context,
    builder: (context) {
      final text = Theme.of(context).textTheme;
      return AlertDialog(
        title: Text('Свойства: ${p?.title ?? o.label}'),
        content: SizedBox(
          width: 460,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final (k, v) in rows)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 150,
                        child: Text(
                          k,
                          style: text.bodyMedium?.copyWith(
                            color: AerColors.inkMuted,
                          ),
                        ),
                      ),
                      Expanded(
                        child: SelectableText(v, style: text.bodyMedium),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: AerSpacing.s),
              Text(
                'Изменение расположения и привязок появится в редакторе (M04).',
                style: text.bodySmall?.copyWith(color: AerColors.inkMuted),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Закрыть'),
          ),
        ],
      );
    },
  );
}

String sourceText(String kind, {int? revision, DateTime? at}) => switch (kind) {
  'core' => 'Сцена из Core · версия $revision',
  'cache' => 'Офлайн-копия от ${formatAge(at, DateTime.now())}',
  'bundled' => 'Демо-планировка · не сохранена в Core',
  _ => 'Загрузка сцены…',
};
