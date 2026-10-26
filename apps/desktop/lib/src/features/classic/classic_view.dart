import 'dart:async';

import 'package:flutter/material.dart';

import '../../core_api/models.dart';
import '../../shell/status_presentation.dart';
import '../../state/connection_controller.dart';
import '../../theme/tokens.dart';

/// Classic (non-isometric) mode. In M01 it shows the system status panel;
/// devices, incidents and logs are added by their own modules.
class ClassicView extends StatelessWidget {
  const ClassicView({super.key, required this.connection});

  final ConnectionController connection;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return ListenableBuilder(
      listenable: connection,
      builder: (context, _) => ListView(
        padding: const EdgeInsets.all(AerSpacing.l),
        children: [
          Text('Состояние системы', style: text.headlineSmall),
          const SizedBox(height: AerSpacing.m),
          _ConnectionCard(connection: connection),
          const SizedBox(height: AerSpacing.m),
          if (connection.info case final info?)
            _SystemInfoCard(info: info, stale: connection.isStale),
          const SizedBox(height: AerSpacing.l),
          Text(
            'Устройства, инциденты, журналы и боты появятся в модулях M02–M06.',
            style: text.bodySmall?.copyWith(color: AerColors.inkMuted),
          ),
        ],
      ),
    );
  }
}

class _ConnectionCard extends StatelessWidget {
  const _ConnectionCard({required this.connection});

  final ConnectionController connection;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final p = LinkPresentation.of(connection.link);
    final now = DateTime.now();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AerSpacing.l),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(p.icon, color: p.color, size: 28),
                const SizedBox(width: AerSpacing.m),
                Expanded(child: Text(p.label, style: text.titleMedium)),
                OutlinedButton.icon(
                  onPressed: connection.link == CoreLink.checking
                      ? null
                      : () => unawaited(connection.refresh()),
                  icon: const Icon(Icons.refresh_rounded, size: 18),
                  label: const Text('Проверить'),
                ),
              ],
            ),
            const SizedBox(height: AerSpacing.s),
            Text(p.explanation, style: text.bodyMedium),
            const SizedBox(height: AerSpacing.m),
            _Fact('Адрес Core', connection.endpoint.toString()),
            _Fact(
              'Последняя проверка',
              formatAge(connection.lastCheckedAt, now),
            ),
            _Fact(
              'Последний успешный ответ',
              formatAge(connection.lastOnlineAt, now),
            ),
            if (connection.detail case final detail?)
              _Fact('Подробности', detail, mono: true),
          ],
        ),
      ),
    );
  }
}

class _SystemInfoCard extends StatelessWidget {
  const _SystemInfoCard({required this.info, required this.stale});

  final SystemInfo info;
  final bool stale;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AerSpacing.l,
              AerSpacing.l,
              AerSpacing.l,
              0,
            ),
            child: Row(
              children: [
                Expanded(child: Text('AER Core', style: text.titleMedium)),
                if (stale)
                  const _Tag(
                    icon: Icons.history_rounded,
                    label: 'Устаревшие данные',
                    color: AerColors.amber,
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AerSpacing.l,
              vertical: AerSpacing.s,
            ),
            child: Column(
              children: [
                _Fact('Версия', '${info.coreVersion} · API ${info.apiVersion}'),
                _Fact(
                  'Режим',
                  info.demo ? '${info.mode} (демо-данные возможны)' : info.mode,
                ),
                _Fact('Работает', formatUptime(info.uptimeSeconds)),
              ],
            ),
          ),
          ExpansionTile(
            title: const Text('Подробности'),
            shape: const Border(),
            collapsedShape: const Border(),
            childrenPadding: const EdgeInsets.fromLTRB(
              AerSpacing.l,
              0,
              AerSpacing.l,
              AerSpacing.l,
            ),
            children: [
              _Fact('ID экземпляра', info.instanceId, mono: true),
              for (final s in info.schema)
                _Fact('Схема «${s.module}»', 'v${s.version}'),
              if (info.modules.isEmpty)
                const _Fact('Модули', 'пока не подключены')
              else
                for (final m in info.modules)
                  _Fact(
                    'Модуль «${m.name}»',
                    m.error != null
                        ? 'ошибка запуска: ${m.error}'
                        : (m.enabled ? 'включён' : 'выключен'),
                  ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Fact extends StatelessWidget {
  const _Fact(this.label, this.value, {this.mono = false});

  final String label;
  final String value;
  final bool mono;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AerSpacing.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 220,
            child: Text(
              label,
              style: text.bodyMedium?.copyWith(color: AerColors.inkMuted),
            ),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: mono
                  ? text.bodyMedium?.copyWith(fontFamily: 'monospace')
                  : text.bodyMedium,
            ),
          ),
        ],
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag({required this.icon, required this.label, required this.color});

  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AerSpacing.s,
        vertical: AerSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(AerRadii.small),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: AerColors.ink),
          const SizedBox(width: AerSpacing.xs),
          Text(label, style: Theme.of(context).textTheme.labelMedium),
        ],
      ),
    );
  }
}
