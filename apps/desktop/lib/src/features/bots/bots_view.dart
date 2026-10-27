import 'dart:async';

import 'package:flutter/material.dart';

import '../../core_api/bots_api.dart';
import '../../core_api/monitoring_api.dart';
import '../../state/bots_controller.dart';
import '../../state/monitoring_controller.dart';
import '../../state/registry_controller.dart';
import '../../theme/tokens.dart';
import '../monitoring/mon_widgets.dart';
import '../registry/error_text.dart';
import 'add_bot_wizard.dart';
import 'bot_details.dart';
import 'bot_widgets.dart';

/// «Боты»: every Telegram bot, Python process, container and automation
/// in one place — state, errors, jobs and allowed management.
class BotsView extends StatefulWidget {
  const BotsView({
    super.key,
    required this.bots,
    required this.mon,
    required this.registry,
  });

  final BotsController bots;
  final MonitoringController mon;
  final RegistryController registry;

  @override
  State<BotsView> createState() => _BotsViewState();
}

class _BotsViewState extends State<BotsView> {
  final _search = TextEditingController();

  @override
  void initState() {
    super.initState();
    unawaited(widget.bots.start());
    _search.text = widget.bots.filter.query;
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _open(String id) => showBotDetails(
    context,
    bots: widget.bots,
    mon: widget.mon,
    registry: widget.registry,
    entityId: id,
  );

  Future<void> _add() async {
    final id = await showAddBotWizard(
      context,
      bots: widget.bots,
      registry: widget.registry,
    );
    if (id != null && mounted) _open(id);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.bots,
      builder: (context, _) {
        final b = widget.bots;
        final text = Theme.of(context).textTheme;
        final f = b.filter;
        final items = b.visible;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AerSpacing.l,
                AerSpacing.m,
                AerSpacing.l,
                AerSpacing.s,
              ),
              child: Row(
                children: [
                  Text('Боты', style: text.headlineSmall),
                  const SizedBox(width: AerSpacing.m),
                  Flexible(child: _Freshness(bots: b)),
                  const Spacer(),
                  IconButton(
                    key: const Key('bots-refresh'),
                    tooltip: 'Обновить',
                    onPressed: b.canAct && !b.loading ? b.refresh : null,
                    icon: const Icon(Icons.refresh_rounded),
                  ),
                  const SizedBox(width: AerSpacing.s),
                  FilledButton.icon(
                    key: const Key('bots-add'),
                    onPressed: b.canAct ? _add : null,
                    icon: const Icon(Icons.add_rounded),
                    label: const Text('Добавить бота'),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AerSpacing.l),
              child: Wrap(
                spacing: AerSpacing.s,
                runSpacing: AerSpacing.s,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  SizedBox(
                    width: 280,
                    child: TextField(
                      key: const Key('bots-search'),
                      controller: _search,
                      decoration: const InputDecoration(
                        isDense: true,
                        prefixIcon: Icon(Icons.search_rounded),
                        hintText: 'Поиск: имя, тег, категория',
                      ),
                      onChanged: (v) => b.filter = b.filter.copyWith(query: v),
                    ),
                  ),
                  for (final s in [
                    MonStatus.online,
                    MonStatus.degraded,
                    MonStatus.offline,
                    MonStatus.unknown,
                  ])
                    FilterChip(
                      key: Key('bots-filter-${s.name}'),
                      avatar: Icon(monIcon(s), size: 16, color: monColor(s)),
                      label: Text(
                        '${monLabel(s)} · ${b.all.where((x) => x.status == s).length}',
                      ),
                      selected: f.status == s,
                      onSelected: (on) => b.filter = b.filter.copyWith(
                        status: () => on ? s : null,
                      ),
                    ),
                  DropdownButton<String?>(
                    key: const Key('bots-filter-runtime'),
                    value: f.runtime,
                    hint: const Text('Любая среда'),
                    items: [
                      const DropdownMenuItem(
                        value: null,
                        child: Text('Любая среда'),
                      ),
                      for (final r in botRuntimes)
                        DropdownMenuItem(
                          value: r,
                          child: Text(runtimeLabel(r)),
                        ),
                    ],
                    onChanged: (v) =>
                        b.filter = b.filter.copyWith(runtime: () => v),
                  ),
                  if (b.categories.isNotEmpty)
                    DropdownButton<String?>(
                      value: f.category,
                      hint: const Text('Любая категория'),
                      items: [
                        const DropdownMenuItem(
                          value: null,
                          child: Text('Любая категория'),
                        ),
                        for (final c in b.categories)
                          DropdownMenuItem(value: c, child: Text(c)),
                      ],
                      onChanged: (v) =>
                          b.filter = b.filter.copyWith(category: () => v),
                    ),
                  FilterChip(
                    key: const Key('bots-filter-archived'),
                    avatar: const Icon(Icons.inventory_outlined, size: 16),
                    label: const Text('Архив'),
                    selected: f.archived,
                    onSelected: (on) =>
                        b.filter = b.filter.copyWith(archived: on),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AerSpacing.s),
            Expanded(child: _body(context, b, items)),
          ],
        );
      },
    );
  }

  Widget _body(BuildContext context, BotsController b, List<Bot> items) {
    final text = Theme.of(context).textTheme;
    if (b.updatedAt == null) {
      if (b.loading || (b.error == null && b.canAct)) {
        return const Center(child: CircularProgressIndicator());
      }
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.cloud_off_rounded,
              size: 40,
              color: AerColors.inkMuted,
            ),
            const SizedBox(height: 8),
            Text(
              b.error != null
                  ? describeError(b.error!)
                  : 'Нет связи с Core: список ботов хранится на сервере',
              textAlign: TextAlign.center,
            ),
          ],
        ),
      );
    }
    if (b.all.isEmpty) {
      return Center(
        child: Column(
          key: const Key('bots-empty'),
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.smart_toy_outlined,
              size: 48,
              color: AerColors.accent,
            ),
            const SizedBox(height: 8),
            Text(
              b.filter.archived ? 'В архиве ботов нет' : 'Ботов пока нет',
              style: text.titleMedium,
            ),
            const SizedBox(height: 4),
            Text(
              'Добавьте Telegram-бота, Python-скрипт, контейнер или n8n — '
              'AER HOME покажет его состояние, ошибки и задания.',
              style: text.bodyMedium?.copyWith(color: AerColors.inkMuted),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      );
    }
    if (items.isEmpty) {
      return const Center(child: Text('Под фильтр ничего не подходит'));
    }
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(
        AerSpacing.l,
        AerSpacing.s,
        AerSpacing.l,
        AerSpacing.l,
      ),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 360,
        mainAxisExtent: 238,
        crossAxisSpacing: AerSpacing.m,
        mainAxisSpacing: AerSpacing.m,
      ),
      itemCount: items.length,
      itemBuilder: (_, i) => BotCard(
        bot: items[i],
        stale: b.isStale,
        onOpen: () => _open(items[i].entityId),
      ),
    );
  }
}

class _Freshness extends StatelessWidget {
  const _Freshness({required this.bots});
  final BotsController bots;

  @override
  Widget build(BuildContext context) {
    final at = bots.updatedAt;
    final (icon, color, label) = bots.isStale
        ? (
            Icons.history_rounded,
            AerColors.amber,
            'Нет связи с Core — список от ${at == null ? '—' : dateTime(at)}, устарел',
          )
        : (
            Icons.sync_rounded,
            AerColors.sage,
            at == null ? 'Загрузка…' : 'Обновлено в ${clock(at)}',
          );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            label,
            style: Theme.of(context).textTheme.labelMedium,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}

/// A bot card: health from Monitoring, runtime from the adapter, jobs.
class BotCard extends StatelessWidget {
  const BotCard({
    super.key,
    required this.bot,
    required this.stale,
    required this.onOpen,
  });

  final Bot bot;
  final bool stale;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final b = bot;
    final muted = text.labelSmall?.copyWith(color: AerColors.inkMuted);
    return Card(
      key: Key('bot-${b.entityId}'),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: AerColors.accentSoft,
                      borderRadius: BorderRadius.circular(AerRadii.small),
                    ),
                    child: Icon(
                      runtimeIcon(b.runtime),
                      color: AerColors.ink,
                      size: 20,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          b.name,
                          style: text.titleSmall,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          [
                            runtimeLabel(b.runtime),
                            if (b.category.isNotEmpty) b.category,
                            if (b.version.isNotEmpty) 'v${b.version}',
                          ].join(' · '),
                          style: muted,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  if (b.openIncidents > 0)
                    Tooltip(
                      message: 'Активных инцидентов: ${b.openIncidents}',
                      child: Badge(
                        label: Text('${b.openIncidents}'),
                        backgroundColor: AerColors.terracotta,
                        child: const Icon(Icons.report_outlined, size: 20),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  StatusChip(b.status, stale: stale || b.archived, dense: true),
                  if (b.monitorOnly)
                    Tooltip(
                      message:
                          'Управляющий адаптер не выбран: только наблюдение',
                      child: _Pill('только мониторинг', AerColors.inkMuted),
                    )
                  else if (b.runtimeState case final rt?)
                    _Pill(runtimeStateLabel(rt.state), AerColors.blue),
                  if (b.archived) const _Pill('в архиве', AerColors.lavender),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                b.lastError.isNotEmpty && b.status != MonStatus.online
                    ? 'Ошибка: ${b.lastError}'
                    : b.statusReason,
                style: text.bodySmall,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              const Spacer(),
              Wrap(
                spacing: 12,
                children: [
                  Text(
                    'CPU ${fmtValue(b.cpuPercent, '%')}',
                    style: text.labelMedium,
                  ),
                  Text(
                    'RAM ${fmtValue(b.memBytes, 'B')}',
                    style: text.labelMedium,
                  ),
                  if (b.uptimeSec != null)
                    Text(
                      '↑ ${fmtDuration(b.uptimeSec!.toDouble())}',
                      style: text.labelMedium,
                    ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                [
                  'Heartbeat: ${b.heartbeat.credentials == 0 ? 'не настроен' : ago(b.heartbeat.lastSeenAt)}',
                  if (b.success24h + b.failed24h > 0)
                    'задания 24 ч: ${b.success24h} ✓ ${b.failed24h} ✗',
                ].join(' · '),
                style: muted,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill(this.label, this.color);
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(AerRadii.large),
    ),
    child: Text(label, style: Theme.of(context).textTheme.labelSmall),
  );
}
