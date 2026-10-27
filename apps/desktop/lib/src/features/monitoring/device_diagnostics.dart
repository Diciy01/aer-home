import 'dart:async';

import 'package:flutter/material.dart';

import '../../core_api/monitoring_api.dart';
import '../../state/monitoring_controller.dart';
import '../../theme/tokens.dart';
import '../registry/error_text.dart';
import 'mon_widgets.dart';

/// Opens the full diagnostics of one Registry entity.
Future<void> showDiagnostics(
  BuildContext context,
  MonitoringController mon,
  String entityId,
) => showDialog<void>(
  context: context,
  builder: (_) => Dialog(
    insetPadding: const EdgeInsets.all(AerSpacing.l),
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 1000, maxHeight: 760),
      child: DeviceDiagnostics(mon: mon, entityId: entityId),
    ),
  ),
);

class DeviceDiagnostics extends StatefulWidget {
  const DeviceDiagnostics({
    super.key,
    required this.mon,
    required this.entityId,
  });
  final MonitoringController mon;
  final String entityId;

  @override
  State<DeviceDiagnostics> createState() => _DeviceDiagnosticsState();
}

class _DeviceDiagnosticsState extends State<DeviceDiagnostics> {
  DeviceState? _state;
  List<MetricValue> _all = const [];
  Object? _error;
  bool _loading = true;

  MonitoringApi get api => widget.mon.api;

  @override
  void initState() {
    super.initState();
    _state = widget.mon.stateFor(widget.entityId);
    unawaited(_load());
  }

  Future<void> _load() async {
    if (!widget.mon.canAct) {
      setState(() {
        _loading = false;
        _all = _state?.keyMetrics ?? const [];
      });
      return;
    }
    setState(() => _loading = true);
    try {
      final st = await api.state(widget.entityId);
      if (!mounted) return;
      setState(() {
        _state = st;
        _all = st.keyMetrics;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final st = _state;
    final offline = !widget.mon.canAct;
    return DefaultTabController(
      length: 6,
      child: Column(
        key: const Key('diagnostics'),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 8, 0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(
                  Icons.monitor_heart_outlined,
                  color: AerColors.accent,
                  size: 28,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(st?.name ?? 'Устройство', style: text.titleLarge),
                      const SizedBox(height: 4),
                      Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          if (st != null)
                            StatusChip(
                              st.status,
                              stale: offline || widget.mon.isStale,
                            ),
                          Text(
                            'Последний контакт: ${ago(st?.lastContactAt)}',
                            style: text.bodySmall,
                          ),
                          if (st?.lastCheckAt != null)
                            Text(
                              '· проверено ${ago(st!.lastCheckAt)}',
                              style: text.bodySmall?.copyWith(
                                color: AerColors.inkMuted,
                              ),
                            ),
                        ],
                      ),
                      if (st != null && st.reason.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            st.reason,
                            style: text.bodySmall?.copyWith(
                              color: AerColors.inkMuted,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Обновить',
                  onPressed: _loading || offline ? null : _load,
                  icon: const Icon(Icons.refresh_rounded),
                ),
                IconButton(
                  key: const Key('diagnostics-close'),
                  tooltip: 'Закрыть',
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
          ),
          if (offline)
            Container(
              margin: const EdgeInsets.fromLTRB(20, 8, 20, 0),
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: AerColors.amber.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(AerRadii.small),
              ),
              child: Text(
                'Нет связи с Core: показано последнее известное состояние. Графики, журнал и история недоступны.',
                style: text.bodySmall,
              ),
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text(
                describeError(_error!),
                style: text.bodySmall?.copyWith(color: AerColors.terracotta),
              ),
            ),
          const TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            tabs: [
              Tab(text: 'Обзор'),
              Tab(text: 'Метрики'),
              Tab(text: 'Графики'),
              Tab(text: 'Логи'),
              Tab(text: 'Инциденты'),
              Tab(text: 'История событий'),
            ],
          ),
          Expanded(
            child: _loading && st == null
                ? const Center(child: CircularProgressIndicator())
                : TabBarView(
                    children: [
                      _overview(context),
                      _metrics(context),
                      offline
                          ? _needsCore(context)
                          : MetricCharts(
                              api: api,
                              entityId: widget.entityId,
                              metrics: _all,
                            ),
                      offline
                          ? _needsCore(context)
                          : _EntityLogs(api: api, entityId: widget.entityId),
                      offline
                          ? _needsCore(context)
                          : _EntityIncidents(
                              mon: widget.mon,
                              entityId: widget.entityId,
                            ),
                      offline
                          ? _needsCore(context)
                          : _EntityEvents(api: api, entityId: widget.entityId),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _needsCore(BuildContext context) => Center(
    child: Text(
      'Нужна связь с Core',
      style: Theme.of(context).textTheme.bodyMedium
          ?.copyWith(color: AerColors.inkMuted),
    ),
  );

  Widget _overview(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final st = _state;
    if (st == null) return const Center(child: Text('Нет данных'));
    final key = [
      for (final id in [
        'cpu.usage',
        'mem.used_percent',
        'cpu.temperature',
        'gpu.temperature',
        'gpu.usage',
        'swap.used_percent',
      ])
        ?_all.where((m) => m.metric == id).firstOrNull,
      ..._all.where((m) => m.metric == 'disk.used_percent'),
    ];
    final checks = switch (st.checkKind) {
      'agent' => 'Агент на устройстве (heartbeat и метрики)',
      'heartbeat' => 'Heartbeat бота',
      'http' => 'HTTP-проверка',
      'tcp' => 'TCP-проверка доступности',
      'docker' => 'Docker Engine (только чтение)',
      _ => 'Не проверяется',
    };
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text('Способ проверки: $checks', style: text.bodyMedium),
        if (st.openIncidents > 0)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              'Активных инцидентов: ${st.openIncidents}',
              style: text.bodyMedium?.copyWith(
                color: sevColor(st.worstSeverity ?? MonSeverity.warning),
              ),
            ),
          ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            for (final m in key) _MetricTile(m),
            if (key.isEmpty)
              Text(
                'Ключевых показателей нет',
                style: text.bodyMedium?.copyWith(color: AerColors.inkMuted),
              ),
          ],
        ),
        if (st.agents.isNotEmpty) ...[
          const SizedBox(height: 20),
          Text('Источники данных', style: text.titleSmall),
          const SizedBox(height: 8),
          for (final a in st.agents)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                a.active ? Icons.sensors_rounded : Icons.sensors_off_rounded,
                color: a.active ? AerColors.sage : AerColors.inkMuted,
              ),
              title: Text(
                '${a.name}${a.osVersion.isNotEmpty ? ' · ${a.osVersion}' : ''}',
              ),
              subtitle: Text(
                [
                  a.revokedAt != null
                      ? 'доступ отозван'
                      : (a.active ? 'активен' : 'не активен'),
                  'последний отчёт ${ago(a.lastSeenAt)}',
                  if (a.version.isNotEmpty) 'агент ${a.version}',
                  if (a.lastError.isNotEmpty)
                    'последняя ошибка: ${a.lastError}',
                ].join(' · '),
              ),
            ),
        ],
      ],
    );
  }

  Widget _metrics(BuildContext context) {
    final text = Theme.of(context).textTheme;
    if (_all.isEmpty) {
      return Center(
        child: Text(
          'Метрик пока нет: устройство не присылает данные',
          style: text.bodyMedium?.copyWith(color: AerColors.inkMuted),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.all(20),
      itemCount: _all.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, i) {
        final m = _all[i];
        return ListTile(
          dense: true,
          title: Text(metricName(m)),
          subtitle: Text(
            m.quality == 'ok'
                ? 'измерено ${ago(m.at)} · ${m.source}'
                : '${m.quality == 'unsupported' ? 'не поддерживается' : 'недоступно'}: ${m.reason}',
          ),
          trailing: Text(
            fmtValue(m.value, m.unit),
            style: text.titleSmall?.copyWith(
              color: m.value == null ? AerColors.inkMuted : AerColors.ink,
            ),
          ),
        );
      },
    );
  }
}

class _MetricTile extends StatelessWidget {
  const _MetricTile(this.m);
  final MetricValue m;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Container(
      width: 170,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AerColors.background,
        borderRadius: BorderRadius.circular(AerRadii.small),
        border: Border.all(color: AerColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            metricName(m),
            style: text.labelMedium?.copyWith(color: AerColors.inkMuted),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 4),
          Text(fmtValue(m.value, m.unit), style: text.titleLarge),
          if (m.value == null)
            Text(
              m.reason,
              style: text.labelSmall,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
        ],
      ),
    );
  }
}

/// Metric picker + range chips + chart for one entity (also used by Bots).
class MetricCharts extends StatefulWidget {
  const MetricCharts({
    super.key,
    required this.api,
    required this.entityId,
    required this.metrics,
  });
  final MonitoringApi api;
  final String entityId;
  final List<MetricValue> metrics;

  @override
  State<MetricCharts> createState() => _MetricChartsState();
}

class _MetricChartsState extends State<MetricCharts> {
  late MetricValue? _metric = _defaultMetric();
  Duration _range = const Duration(hours: 1);
  MetricSeries? _series;
  Object? _error;
  bool _loading = false;

  MetricValue? _defaultMetric() {
    final ok = widget.metrics.where((m) => m.quality == 'ok').toList();
    return ok.where((m) => m.metric == 'cpu.usage').firstOrNull ??
        ok.firstOrNull;
  }

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final m = _metric;
    if (m == null) return;
    setState(() => _loading = true);
    try {
      final now = DateTime.now();
      final s = await widget.api.history(
        widget.entityId,
        m.metric,
        label: m.label,
        from: now.subtract(_range),
        to: now,
      );
      if (mounted) {
        setState(() {
          _series = s;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final options = widget.metrics.where((m) => m.quality == 'ok').toList();
    if (options.isEmpty) {
      return Center(
        child: Text('Нет метрик для графика', style: text.bodyMedium),
      );
    }
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            DropdownButton<String>(
              key: const Key('chart-metric'),
              value: '${_metric!.metric}|${_metric!.label}',
              items: [
                for (final m in options)
                  DropdownMenuItem(
                    value: '${m.metric}|${m.label}',
                    child: Text(metricName(m)),
                  ),
              ],
              onChanged: (v) {
                setState(
                  () => _metric = options.firstWhere(
                    (m) => '${m.metric}|${m.label}' == v,
                  ),
                );
                unawaited(_load());
              },
            ),
            for (final (label, d) in const [
              ('1 ч', Duration(hours: 1)),
              ('6 ч', Duration(hours: 6)),
              ('24 ч', Duration(hours: 24)),
              ('7 д', Duration(days: 7)),
            ])
              ChoiceChip(
                label: Text(label),
                selected: _range == d,
                onSelected: (_) {
                  setState(() => _range = d);
                  unawaited(_load());
                },
              ),
            if (_loading)
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
          ],
        ),
        const SizedBox(height: 16),
        if (_error != null)
          Text(
            describeError(_error!),
            style: text.bodySmall?.copyWith(color: AerColors.terracotta),
          ),
        if (_series case final s?) ...[
          MetricChart(series: s, height: 300),
          const SizedBox(height: 8),
          Text(
            s.resolution == 'raw'
                ? 'Исходные измерения'
                : 'Средние за 5 минут (полоса — минимум и максимум)',
            style: text.bodySmall?.copyWith(color: AerColors.inkMuted),
          ),
        ],
      ],
    );
  }
}

class _EntityLogs extends StatefulWidget {
  const _EntityLogs({required this.api, required this.entityId});
  final MonitoringApi api;
  final String entityId;

  @override
  State<_EntityLogs> createState() => _EntityLogsState();
}

class _EntityLogsState extends State<_EntityLogs> {
  List<LogEntry>? _items;
  Object? _error;

  @override
  void initState() {
    super.initState();
    widget.api
        .logs(entityId: widget.entityId, limit: 200)
        .then(
          (p) => mounted ? setState(() => _items = p.items) : null,
          onError: (Object e) => mounted ? setState(() => _error = e) : null,
        );
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) return Center(child: Text(describeError(_error!)));
    final items = _items;
    if (items == null) return const Center(child: CircularProgressIndicator());
    if (items.isEmpty) return const Center(child: Text('Записей журнала нет'));
    return ListView.builder(
      itemCount: items.length,
      itemBuilder: (context, i) => LogRow(entry: items[i]),
    );
  }
}

class _EntityIncidents extends StatefulWidget {
  const _EntityIncidents({required this.mon, required this.entityId});
  final MonitoringController mon;
  final String entityId;

  @override
  State<_EntityIncidents> createState() => _EntityIncidentsState();
}

class _EntityIncidentsState extends State<_EntityIncidents> {
  List<Incident>? _items;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() => widget.mon.api
      .incidents(status: '', entityId: widget.entityId)
      .then(
        (v) => mounted ? setState(() => _items = v) : null,
        onError: (_) {},
      );

  @override
  Widget build(BuildContext context) {
    final items = _items;
    if (items == null) return const Center(child: CircularProgressIndicator());
    if (items.isEmpty) return const Center(child: Text('Инцидентов не было'));
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        for (final i in items)
          IncidentCard(
            key: ValueKey(i.id),
            incident: i,
            mon: widget.mon,
            onChanged: _load,
          ),
      ],
    );
  }
}

class _EntityEvents extends StatelessWidget {
  const _EntityEvents({required this.api, required this.entityId});
  final MonitoringApi api;
  final String entityId;

  @override
  Widget build(BuildContext context) => FutureBuilder<List<MonEvent>>(
    future: api.events(entityId: entityId, limit: 100),
    builder: (context, snap) {
      if (snap.hasError) return Center(child: Text(describeError(snap.error!)));
      final items = snap.data;
      if (items == null) {
        return const Center(child: CircularProgressIndicator());
      }
      if (items.isEmpty) return const Center(child: Text('Событий пока нет'));
      return ListView(
        padding: const EdgeInsets.all(12),
        children: [for (final e in items) EventRow(event: e)],
      );
    },
  );
}

class EventRow extends StatelessWidget {
  const EventRow({super.key, required this.event});
  final MonEvent event;

  @override
  Widget build(BuildContext context) => ListTile(
    dense: true,
    leading: Icon(
      sevIcon(event.severity),
      color: sevColor(event.severity),
      size: 20,
    ),
    title: Text(event.message, maxLines: 2, overflow: TextOverflow.ellipsis),
    subtitle: Text(dateTime(event.at)),
  );
}

class LogRow extends StatelessWidget {
  const LogRow({super.key, required this.entry, this.onTap});
  final LogEntry entry;
  final VoidCallback? onTap;

  static Color levelColor(String l) => switch (l) {
    'critical' => AerColors.terracotta,
    'error' => AerColors.terracotta,
    'warning' => AerColors.amber,
    'info' => AerColors.blue,
    _ => AerColors.inkMuted,
  };

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return InkWell(
      key: Key('log-${entry.id}'),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 92,
              child: Text(
                dateTime(entry.at),
                style: text.labelSmall?.copyWith(color: AerColors.inkMuted),
              ),
            ),
            Container(
              width: 74,
              margin: const EdgeInsets.only(right: 8),
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: levelColor(entry.level).withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                entry.level,
                style: text.labelSmall?.copyWith(color: AerColors.ink),
                textAlign: TextAlign.center,
              ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    entry.message,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: text.bodySmall,
                  ),
                  Text(
                    entry.source,
                    style: text.labelSmall?.copyWith(color: AerColors.inkMuted),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            if (entry.incidentId != null)
              const Tooltip(
                message: 'Связано с инцидентом',
                child: Icon(
                  Icons.link_rounded,
                  size: 16,
                  color: AerColors.accent,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Incident with acknowledge and expandable timeline.
class IncidentCard extends StatefulWidget {
  const IncidentCard({
    super.key,
    required this.incident,
    required this.mon,
    this.deviceName,
    this.onChanged,
    this.onOpenDevice,
  });
  final Incident incident;
  final MonitoringController mon;
  final String? deviceName;
  final VoidCallback? onChanged;
  final VoidCallback? onOpenDevice;

  @override
  State<IncidentCard> createState() => _IncidentCardState();
}

class _IncidentCardState extends State<IncidentCard> {
  Incident? _full;
  bool _busy = false;

  @override
  void didUpdateWidget(IncidentCard old) {
    super.didUpdateWidget(old);
    // A fresher list item replaces the locally fetched copy.
    if (old.incident.id != widget.incident.id ||
        old.incident.updatedAt != widget.incident.updatedAt) {
      _full = null;
    }
  }

  Future<void> _ack() async {
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final r = await widget.mon.acknowledge(widget.incident.id);
      if (mounted) setState(() => _full = r);
      widget.onChanged?.call();
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(describeError(e))));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final i = _full ?? widget.incident;
    final c = sevColor(i.severity);
    final status = switch (i.status) {
      'open' => 'Открыт',
      'acknowledged' => 'Подтверждён',
      _ => 'Решён',
    };
    return Card(
      key: Key('incident-${i.id}'),
      margin: const EdgeInsets.only(bottom: 8),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          leading: Icon(
            i.active ? sevIcon(i.severity) : Icons.check_circle_outline_rounded,
            color: i.active ? c : AerColors.sage,
          ),
          title: Text(i.title, style: text.titleSmall),
          subtitle: Text(
            [
              '$status · ${sevLabel(i.severity)}',
              if (widget.deviceName != null) widget.deviceName!,
              'с ${dateTime(i.openedAt)}',
              if (i.occurrences > 1) 'повторов: ${i.occurrences}',
              if (i.resolvedAt != null)
                'восстановлено ${dateTime(i.resolvedAt!)}',
            ].join(' · '),
            style: text.bodySmall,
          ),
          trailing: i.status == 'open'
              ? Tooltip(
                  message: widget.mon.canAct
                      ? 'Отметить, что вы видели инцидент'
                      : 'Нужна связь с Core',
                  child: OutlinedButton(
                    key: Key('ack-${i.id}'),
                    onPressed: _busy || !widget.mon.canAct ? null : _ack,
                    child: const Text('Подтвердить'),
                  ),
                )
              : null,
          onExpansionChanged: (open) async {
            if (open && _full?.timeline.isEmpty != false && widget.mon.canAct) {
              try {
                final f = await widget.mon.api.incident(i.id);
                if (mounted) setState(() => _full = f);
              } catch (_) {}
            }
          },
          childrenPadding: const EdgeInsets.fromLTRB(56, 0, 16, 12),
          expandedCrossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              i.cause.isEmpty
                  ? 'Причина не установлена'
                  : 'Причина: ${i.cause}',
              style: text.bodySmall,
            ),
            if (i.related.isNotEmpty)
              Text(
                'Возможно связано с ${i.related.length} инцидентом зависимостей (корреляция, не причина)',
                style: text.bodySmall?.copyWith(color: AerColors.inkMuted),
              ),
            if (i.lastMessage.isNotEmpty)
              Text(
                'Последнее: ${i.lastMessage}',
                style: text.bodySmall?.copyWith(color: AerColors.inkMuted),
              ),
            const SizedBox(height: 6),
            for (final e in i.timeline)
              Text(
                '${dateTime(e.at)} · ${_kind(e.kind)} — ${e.message}',
                style: text.labelSmall,
              ),
            if (widget.onOpenDevice != null)
              TextButton.icon(
                onPressed: widget.onOpenDevice,
                icon: const Icon(Icons.monitor_heart_outlined, size: 16),
                label: const Text('Диагностика устройства'),
              ),
          ],
        ),
      ),
    );
  }

  static String _kind(String k) => switch (k) {
    'opened' => 'открыт',
    'repeated' => 'повтор',
    'acknowledged' => 'подтверждён',
    'resolved' => 'решён',
    _ => 'заметка',
  };
}
