import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core_api/monitoring_api.dart';
import '../../state/monitoring_controller.dart';
import '../../state/registry_controller.dart';
import '../../theme/tokens.dart';
import '../registry/entity_visuals.dart';
import '../registry/error_text.dart';
import 'device_diagnostics.dart';
import 'mon_widgets.dart';

/// The Monitoring section: what works, what is broken and where to look.
class MonitoringView extends StatefulWidget {
  const MonitoringView({super.key, required this.mon, required this.registry});
  final MonitoringController mon;
  final RegistryController registry;

  @override
  State<MonitoringView> createState() => _MonitoringViewState();
}

class _MonitoringViewState extends State<MonitoringView> {
  @override
  void initState() {
    super.initState();
    unawaited(widget.mon.start());
  }

  String _type(String t) => widget.registry.catalog?.typeLabel(t) ?? t;

  void _open(String entityId) => showDiagnostics(context, widget.mon, entityId);

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.mon,
      builder: (context, _) {
        final mon = widget.mon;
        return DefaultTabController(
          length: 5,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AerSpacing.l,
                  AerSpacing.m,
                  AerSpacing.l,
                  0,
                ),
                child: Row(
                  children: [
                    Text(
                      'Мониторинг',
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    const SizedBox(width: AerSpacing.m),
                    Flexible(child: FreshnessPill(controller: mon)),
                    const Spacer(),
                    IconButton(
                      key: const Key('mon-refresh'),
                      tooltip: 'Обновить',
                      onPressed: mon.canAct && !mon.loading
                          ? mon.refresh
                          : null,
                      icon: const Icon(Icons.refresh_rounded),
                    ),
                  ],
                ),
              ),
              const TabBar(
                isScrollable: true,
                tabAlignment: TabAlignment.start,
                padding: EdgeInsets.symmetric(horizontal: AerSpacing.m),
                tabs: [
                  Tab(key: Key('mon-tab-overview'), text: 'Обзор'),
                  Tab(key: Key('mon-tab-devices'), text: 'Устройства'),
                  Tab(key: Key('mon-tab-incidents'), text: 'Инциденты'),
                  Tab(key: Key('mon-tab-logs'), text: 'Журнал'),
                  Tab(key: Key('mon-tab-agents'), text: 'Агенты и интеграции'),
                ],
              ),
              Expanded(
                child: mon.overview == null
                    ? _empty(context, mon)
                    : TabBarView(
                        children: [
                          _Overview(mon: mon, type: _type, open: _open),
                          _Devices(mon: mon, type: _type, open: _open),
                          _Incidents(mon: mon, open: _open),
                          _Logs(mon: mon, open: _open),
                          _Agents(mon: mon, registry: widget.registry),
                        ],
                      ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _empty(BuildContext context, MonitoringController mon) {
    final text = Theme.of(context).textTheme;
    if (mon.loading) return const Center(child: CircularProgressIndicator());
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
            mon.error != null
                ? describeError(mon.error!)
                : 'Нет связи с Core и нет сохранённых данных мониторинга',
            style: text.bodyMedium,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: mon.canAct ? mon.refresh : null,
            child: const Text('Повторить'),
          ),
        ],
      ),
    );
  }
}

class _Overview extends StatelessWidget {
  const _Overview({required this.mon, required this.type, required this.open});
  final MonitoringController mon;
  final String Function(String) type;
  final void Function(String) open;

  @override
  Widget build(BuildContext context) {
    final o = mon.overview!;
    final text = Theme.of(context).textTheme;
    final states = mon.states;
    DeviceState? first(String t) =>
        states.where((s) => s.type == t).firstOrNull;
    final bots = states.where((s) => s.type == 'telegram_bot').toList();
    Widget tile(String key, String label, int n, Color c, IconData i) =>
        SizedBox(
          width: 168,
          child: MonCard(
            key: Key('mon-tile-$key'),
            child: Row(
              children: [
                Icon(i, color: c),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('$n', style: text.headlineSmall),
                      Text(
                        label,
                        style: text.labelMedium?.copyWith(
                          color: AerColors.inkMuted,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
    return ListView(
      padding: const EdgeInsets.all(AerSpacing.l),
      children: [
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            tile(
              'devices',
              'Устройств',
              o.devices,
              AerColors.accent,
              Icons.devices_other_rounded,
            ),
            tile(
              'online',
              'В сети',
              o.count(MonStatus.online),
              AerColors.sage,
              Icons.check_circle_rounded,
            ),
            tile(
              'degraded',
              'Есть проблемы',
              o.count(MonStatus.degraded),
              AerColors.amber,
              Icons.error_rounded,
            ),
            tile(
              'offline',
              'Недоступны',
              o.count(MonStatus.offline),
              AerColors.terracotta,
              Icons.power_off_rounded,
            ),
            tile(
              'unknown',
              'Нет данных',
              o.count(MonStatus.unknown) + o.count(MonStatus.unsupported),
              AerColors.lavender,
              Icons.help_rounded,
            ),
            tile(
              'incidents',
              o.criticalOpen > 0
                  ? 'Инцидентов, критичных ${o.criticalOpen}'
                  : 'Активных инцидентов',
              o.openIncidents,
              o.criticalOpen > 0 ? AerColors.terracotta : AerColors.amber,
              Icons.report_rounded,
            ),
          ],
        ),
        const SizedBox(height: AerSpacing.l),
        LayoutBuilder(
          builder: (context, c) {
            final wide = c.maxWidth > 900;
            final key = [
              _KeyDevice(
                title: 'Домашний сервер',
                state: first('server'),
                type: type,
                open: open,
                empty: 'Сервер не добавлен в Registry',
              ),
              _KeyDevice(
                title: 'Основной ПК',
                state: first('computer'),
                type: type,
                open: open,
                empty: 'Компьютер не добавлен в Registry',
              ),
              _BotsCard(bots: bots, open: open),
            ];
            return wide
                ? IntrinsicHeight(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (final (i, w) in key.indexed) ...[
                          if (i > 0) const SizedBox(width: 12),
                          Expanded(child: w),
                        ],
                      ],
                    ),
                  )
                : Column(
                    children: [
                      for (final w in key)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: w,
                        ),
                    ],
                  );
          },
        ),
        const SizedBox(height: AerSpacing.l),
        Text('Источники данных', style: text.titleMedium),
        const SizedBox(height: 8),
        MonCard(
          child: Column(
            children: [
              for (final i in o.integrations)
                ListTile(
                  key: Key('integration-${i.id}'),
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    switch (i.status) {
                      'ok' => Icons.check_circle_rounded,
                      'disabled' => Icons.pause_circle_outline_rounded,
                      _ => Icons.error_outline_rounded,
                    },
                    color: switch (i.status) {
                      'ok' => AerColors.sage,
                      'disabled' => AerColors.inkMuted,
                      _ => AerColors.amber,
                    },
                  ),
                  title: Text(i.label),
                  subtitle: Text(i.reason),
                ),
              if (o.integrations.isEmpty)
                const Text('Core ещё не сообщил о своих проверках'),
            ],
          ),
        ),
        const SizedBox(height: AerSpacing.l),
        Text('Последние события', style: text.titleMedium),
        const SizedBox(height: 8),
        MonCard(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: o.recentEvents.isEmpty
              ? const Padding(
                  padding: EdgeInsets.all(12),
                  child: Text('Событий пока нет'),
                )
              : Column(
                  children: [
                    for (final e in o.recentEvents) EventRow(event: e),
                  ],
                ),
        ),
      ],
    );
  }
}

class _KeyDevice extends StatelessWidget {
  const _KeyDevice({
    required this.title,
    required this.state,
    required this.type,
    required this.open,
    required this.empty,
  });
  final String title;
  final DeviceState? state;
  final String Function(String) type;
  final void Function(String) open;
  final String empty;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final s = state;
    return MonCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: text.labelLarge?.copyWith(color: AerColors.inkMuted),
          ),
          const SizedBox(height: 6),
          if (s == null)
            Text(empty, style: text.bodyMedium)
          else ...[
            Text(
              s.name,
              style: text.titleMedium,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 6),
            StatusChip(s.status),
            const SizedBox(height: 6),
            Text(
              'Последний контакт: ${ago(s.lastContactAt)}',
              style: text.bodySmall,
            ),
            const SizedBox(height: 4),
            Wrap(
              spacing: 10,
              children: [
                for (final m in _keyLine(s)) Text(m, style: text.bodySmall),
              ],
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () => open(s.entityId),
              child: const Text('Диагностика'),
            ),
          ],
        ],
      ),
    );
  }
}

List<String> _keyLine(DeviceState s) {
  String? f(String id, String label) {
    final m = s.metric(id);
    return m == null ? null : '$label ${fmtValue(m.value, m.unit)}';
  }

  final disks =
      s.keyMetrics
          .where((m) => m.metric == 'disk.used_percent' && m.value != null)
          .toList()
        ..sort((a, b) => b.value!.compareTo(a.value!));
  return [
    ?f('cpu.usage', 'CPU'),
    ?f('mem.used_percent', 'RAM'),
    if (disks.isNotEmpty)
      'Диск ${disks.first.label} ${fmtValue(disks.first.value, '%')}',
    ?f('cpu.temperature', '🌡'),
  ];
}

class _BotsCard extends StatelessWidget {
  const _BotsCard({required this.bots, required this.open});
  final List<DeviceState> bots;
  final void Function(String) open;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final ok = bots.where((b) => b.status == MonStatus.online).length;
    return MonCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Боты',
            style: text.labelLarge?.copyWith(color: AerColors.inkMuted),
          ),
          const SizedBox(height: 6),
          if (bots.isEmpty)
            Text('Ботов в Registry нет', style: text.bodyMedium)
          else ...[
            Text('$ok из ${bots.length} в порядке', style: text.titleMedium),
            const SizedBox(height: 6),
            for (final b in bots.take(4))
              InkWell(
                onTap: () => open(b.entityId),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(
                    children: [
                      Icon(
                        monIcon(b.status),
                        size: 16,
                        color: monColor(b.status),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          b.name,
                          style: text.bodySmall,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      Text(
                        ago(b.lastContactAt),
                        style: text.labelSmall?.copyWith(
                          color: AerColors.inkMuted,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }
}

class _Devices extends StatefulWidget {
  const _Devices({required this.mon, required this.type, required this.open});
  final MonitoringController mon;
  final String Function(String) type;
  final void Function(String) open;

  @override
  State<_Devices> createState() => _DevicesState();
}

class _DevicesState extends State<_Devices> {
  MonStatus? _filter;

  @override
  Widget build(BuildContext context) {
    final all = widget.mon.states
      ..sort((a, b) {
        int rank(MonStatus s) => switch (s) {
          MonStatus.offline => 0,
          MonStatus.degraded => 1,
          MonStatus.unknown => 2,
          MonStatus.online => 3,
          MonStatus.unsupported => 4,
        };
        final r = rank(a.status).compareTo(rank(b.status));
        return r != 0 ? r : a.name.compareTo(b.name);
      });
    final items = _filter == null
        ? all
        : all.where((s) => s.status == _filter).toList();
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AerSpacing.l,
            AerSpacing.m,
            AerSpacing.l,
            0,
          ),
          child: Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              ChoiceChip(
                label: Text('Все · ${all.length}'),
                selected: _filter == null,
                onSelected: (_) => setState(() => _filter = null),
              ),
              for (final s in MonStatus.values)
                if (all.any((d) => d.status == s))
                  ChoiceChip(
                    label: Text(
                      '${monLabel(s)} · ${all.where((d) => d.status == s).length}',
                    ),
                    selected: _filter == s,
                    onSelected: (_) =>
                        setState(() => _filter = _filter == s ? null : s),
                  ),
            ],
          ),
        ),
        Expanded(
          child: items.isEmpty
              ? const Center(child: Text('Нет устройств в Registry'))
              : GridView.builder(
                  padding: const EdgeInsets.all(AerSpacing.l),
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 380,
                    mainAxisExtent: 196,
                    crossAxisSpacing: 12,
                    mainAxisSpacing: 12,
                  ),
                  itemCount: items.length,
                  itemBuilder: (context, i) => DeviceCard(
                    state: items[i],
                    typeLabel: widget.type(items[i].type),
                    stale: widget.mon.isStale,
                    onOpen: () => widget.open(items[i].entityId),
                  ),
                ),
        ),
      ],
    );
  }
}

class DeviceCard extends StatelessWidget {
  const DeviceCard({
    super.key,
    required this.state,
    required this.typeLabel,
    required this.stale,
    required this.onOpen,
  });
  final DeviceState state;
  final String typeLabel;
  final bool stale;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final s = state;
    return Card(
      key: Key('device-${s.entityId}'),
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
                  Icon(entityIcon(s.type), color: AerColors.accent),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          s.name,
                          style: text.titleSmall,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          typeLabel,
                          style: text.labelSmall?.copyWith(
                            color: AerColors.inkMuted,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (s.openIncidents > 0)
                    Tooltip(
                      message: 'Активных инцидентов: ${s.openIncidents}',
                      child: Badge(
                        label: Text('${s.openIncidents}'),
                        backgroundColor: sevColor(
                          s.worstSeverity ?? MonSeverity.warning,
                        ),
                        child: const Icon(Icons.report_outlined, size: 20),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              StatusChip(s.status, stale: stale, dense: true),
              const SizedBox(height: 6),
              Text(
                s.reason,
                style: text.bodySmall,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              const Spacer(),
              Wrap(
                spacing: 10,
                children: [
                  for (final m in _keyLine(s)) Text(m, style: text.labelMedium),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                'Последний контакт: ${ago(s.lastContactAt)}',
                style: text.labelSmall?.copyWith(color: AerColors.inkMuted),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Incidents extends StatefulWidget {
  const _Incidents({required this.mon, required this.open});
  final MonitoringController mon;
  final void Function(String) open;

  @override
  State<_Incidents> createState() => _IncidentsState();
}

class _IncidentsState extends State<_Incidents> {
  String _status = 'active';
  String? _severity;
  List<Incident>? _items;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    if (!widget.mon.canAct) {
      setState(
        () => _error = 'Нет связи с Core: список инцидентов недоступен, показан обзор последнего известного состояния',
      );
      return;
    }
    widget.mon.api
        .incidents(status: _status, severity: _severity)
        .then(
          (v) => mounted
              ? setState(() {
                  _items = v;
                  _error = null;
                })
              : null,
          onError: (Object e) => mounted ? setState(() => _error = e) : null,
        );
  }

  @override
  Widget build(BuildContext context) {
    final names = {for (final s in widget.mon.states) s.entityId: s.name};
    final items = _items;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AerSpacing.l,
            AerSpacing.m,
            AerSpacing.l,
            0,
          ),
          child: Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final (v, l) in const [
                ('active', 'Активные'),
                ('resolved', 'Решённые'),
                ('', 'Все'),
              ])
                ChoiceChip(
                  key: Key('inc-filter-$v'),
                  label: Text(l),
                  selected: _status == v,
                  onSelected: (_) => setState(() {
                    _status = v;
                    _load();
                  }),
                ),
              const SizedBox(width: 12),
              for (final s in MonSeverity.values.reversed)
                FilterChip(
                  label: Text(sevLabel(s)),
                  selected: _severity == s.name,
                  onSelected: (on) => setState(() {
                    _severity = on ? s.name : null;
                    _load();
                  }),
                ),
            ],
          ),
        ),
        Expanded(
          child: _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      _error is String
                          ? _error! as String
                          : describeError(_error!),
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              : items == null
              ? const Center(child: CircularProgressIndicator())
              : items.isEmpty
              ? Center(
                  child: Text(
                    _status == 'active'
                        ? 'Активных инцидентов нет — всё спокойно'
                        : 'Инцидентов нет',
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.all(AerSpacing.l),
                  children: [
                    for (final i in items)
                      IncidentCard(
                        key: ValueKey(i.id),
                        incident: i,
                        mon: widget.mon,
                        deviceName: i.entityId == null
                            ? null
                            : names[i.entityId],
                        onChanged: _load,
                        onOpenDevice: i.entityId == null
                            ? null
                            : () => widget.open(i.entityId!),
                      ),
                  ],
                ),
        ),
      ],
    );
  }
}

class _Logs extends StatefulWidget {
  const _Logs({required this.mon, required this.open});
  final MonitoringController mon;
  final void Function(String) open;

  @override
  State<_Logs> createState() => _LogsState();
}

class _LogsState extends State<_Logs> {
  final _q = TextEditingController();
  String? _level = 'warning';
  String? _entity;
  Duration? _period = const Duration(hours: 24);
  final List<LogEntry> _items = [];
  int? _next;
  bool _loading = false;
  Object? _error;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _load(reset: true);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _q.dispose();
    super.dispose();
  }

  Future<void> _load({bool reset = false}) async {
    if (!widget.mon.canAct) {
      setState(() => _error = 'Нет связи с Core: журнал хранится на сервере');
      return;
    }
    setState(() => _loading = true);
    try {
      final p = await widget.mon.api.logs(
        q: _q.text,
        level: _level,
        entityId: _entity,
        from: _period == null ? null : DateTime.now().subtract(_period!),
        before: reset ? null : _next,
      );
      if (!mounted) return;
      setState(() {
        if (reset) _items.clear();
        _items.addAll(p.items);
        _next = p.nextBefore;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _details(LogEntry e) {
    final names = {for (final s in widget.mon.states) s.entityId: s.name};
    showDialog<void>(
      context: context,
      builder: (context) {
        final text = Theme.of(context).textTheme;
        return AlertDialog(
          key: const Key('log-details'),
          title: Text('${e.level.toUpperCase()} · ${dateTime(e.at)}'),
          content: SizedBox(
            width: 560,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  SelectableText(e.message, style: text.bodyMedium),
                  const SizedBox(height: 12),
                  Text('Источник: ${e.source}', style: text.bodySmall),
                  if (e.entityId != null)
                    Text(
                      'Устройство: ${names[e.entityId] ?? e.entityId}',
                      style: text.bodySmall,
                    ),
                  if (e.correlationId.isNotEmpty)
                    Text(
                      'Корреляция: ${e.correlationId}',
                      style: text.bodySmall,
                    ),
                  if (e.fields != null) ...[
                    const SizedBox(height: 8),
                    for (final f in e.fields!.entries)
                      Text('${f.key}: ${f.value}', style: text.bodySmall),
                  ],
                  const SizedBox(height: 8),
                  Text(
                    'Секреты (токены, пароли, ключи) удаляются из записей до сохранения.',
                    style: text.labelSmall?.copyWith(color: AerColors.inkMuted),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            if (e.incidentId != null)
              TextButton(
                key: const Key('log-open-incident'),
                onPressed: () async {
                  Navigator.pop(context);
                  final inc = await widget.mon.api.incident(e.incidentId!);
                  if (!mounted) return;
                  await showDialog<void>(
                    context: this.context,
                    builder: (_) => Dialog(
                      child: SizedBox(
                        width: 640,
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.all(12),
                          child: IncidentCard(incident: inc, mon: widget.mon),
                        ),
                      ),
                    ),
                  );
                },
                child: const Text('Инцидент'),
              ),
            if (e.entityId != null)
              TextButton(
                key: const Key('log-open-device'),
                onPressed: () {
                  Navigator.pop(context);
                  widget.open(e.entityId!);
                },
                child: const Text('Устройство'),
              ),
            FilledButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Закрыть'),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final devices = widget.mon.states..sort((a, b) => a.name.compareTo(b.name));
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AerSpacing.l,
            AerSpacing.m,
            AerSpacing.l,
            8,
          ),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SizedBox(
                width: 280,
                child: TextField(
                  key: const Key('logs-search'),
                  controller: _q,
                  decoration: const InputDecoration(
                    isDense: true,
                    prefixIcon: Icon(Icons.search_rounded),
                    hintText: 'Поиск по сообщению или источнику',
                  ),
                  onChanged: (_) {
                    _debounce?.cancel();
                    _debounce = Timer(
                      const Duration(milliseconds: 300),
                      () => _load(reset: true),
                    );
                  },
                ),
              ),
              DropdownButton<String?>(
                key: const Key('logs-level'),
                value: _level,
                items: const [
                  DropdownMenuItem(value: null, child: Text('Все уровни')),
                  DropdownMenuItem(value: 'info', child: Text('Info и выше')),
                  DropdownMenuItem(
                    value: 'warning',
                    child: Text('Warning и выше'),
                  ),
                  DropdownMenuItem(value: 'error', child: Text('Error и выше')),
                  DropdownMenuItem(
                    value: 'critical',
                    child: Text('Только critical'),
                  ),
                ],
                onChanged: (v) => setState(() {
                  _level = v;
                  _load(reset: true);
                }),
              ),
              DropdownButton<String?>(
                key: const Key('logs-device'),
                value: _entity,
                items: [
                  const DropdownMenuItem(
                    value: null,
                    child: Text('Все устройства'),
                  ),
                  for (final d in devices)
                    DropdownMenuItem(
                      value: d.entityId,
                      child: Text(d.name, overflow: TextOverflow.ellipsis),
                    ),
                ],
                onChanged: (v) => setState(() {
                  _entity = v;
                  _load(reset: true);
                }),
              ),
              for (final (l, d) in const [
                ('1 ч', Duration(hours: 1)),
                ('24 ч', Duration(hours: 24)),
                ('7 д', Duration(days: 7)),
                ('Всё', null),
              ])
                ChoiceChip(
                  label: Text(l),
                  selected: _period == d,
                  onSelected: (_) => setState(() {
                    _period = d;
                    _load(reset: true);
                  }),
                ),
            ],
          ),
        ),
        Expanded(
          child: _error != null
              ? Center(
                  child: Text(
                    _error is String
                        ? _error! as String
                        : describeError(_error!),
                  ),
                )
              : _items.isEmpty && !_loading
              ? const Center(child: Text('Записей не найдено'))
              : ListView.builder(
                  itemCount: _items.length + (_next != null ? 1 : 0),
                  itemBuilder: (context, i) {
                    if (i == _items.length) {
                      return Center(
                        child: TextButton(
                          key: const Key('logs-more'),
                          onPressed: _loading ? null : _load,
                          child: const Text('Показать ещё'),
                        ),
                      );
                    }
                    return LogRow(
                      entry: _items[i],
                      onTap: () => _details(_items[i]),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _Agents extends StatefulWidget {
  const _Agents({required this.mon, required this.registry});
  final MonitoringController mon;
  final RegistryController registry;

  @override
  State<_Agents> createState() => _AgentsState();
}

class _AgentsState extends State<_Agents> {
  List<MonAgent>? _agents;
  (IntegrationStatus, List<DockerContainer>)? _docker;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    if (!widget.mon.canAct) {
      setState(() => _error = 'Нет связи с Core');
      return;
    }
    widget.mon.api.agents().then(
      (v) => mounted ? setState(() => _agents = v) : null,
      onError: (Object e) => mounted ? setState(() => _error = e) : null,
    );
    widget.mon.api.containers().then(
      (v) => mounted ? setState(() => _docker = v) : null,
      onError: (_) {},
    );
  }

  Future<void> _create() async {
    final states = widget.mon.states..sort((a, b) => a.name.compareTo(b.name));
    String? entity = states.firstOrNull?.entityId;
    String kind = 'host';
    final name = TextEditingController(text: 'agent');
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, set) => AlertDialog(
          title: const Text('Новые учётные данные агента'),
          content: SizedBox(
            width: 460,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<String>(
                  initialValue: entity,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Устройство из Registry',
                  ),
                  items: [
                    for (final s in states)
                      DropdownMenuItem(value: s.entityId, child: Text(s.name)),
                  ],
                  onChanged: (v) => set(() => entity = v),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: name,
                  decoration: const InputDecoration(
                    labelText: 'Название (например, ubuntu или windows)',
                  ),
                ),
                const SizedBox(height: 8),
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'host', label: Text('Агент ОС')),
                    ButtonSegment(value: 'bot', label: Text('Heartbeat бота')),
                  ],
                  selected: {kind},
                  onSelectionChanged: (v) => set(() => kind = v.first),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Отмена'),
            ),
            FilledButton(
              onPressed: entity == null
                  ? null
                  : () => Navigator.pop(context, true),
              child: const Text('Создать'),
            ),
          ],
        ),
      ),
    );
    if (ok != true || entity == null || !mounted) return;
    try {
      final (_, token) = await widget.mon.api.createAgent(
        entity!,
        name.text,
        kind,
      );
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Токен агента'),
          content: SizedBox(
            width: 520,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Токен показывается один раз. Сохраните его в файл с правами 600 на устройстве и укажите путь в tokenFile конфигурации агента (docs/AGENTS.md).',
                ),
                const SizedBox(height: 8),
                SelectableText(
                  token,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Clipboard.setData(ClipboardData(text: token)),
              child: const Text('Скопировать'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Готово'),
            ),
          ],
        ),
      );
      _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(describeError(e))));
      }
    }
  }

  Future<void> _revoke(MonAgent a) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Отозвать доступ «${a.name}»?'),
        content: const Text(
          'Агент сразу перестанет приниматься Core. Восстановить нельзя — только создать новые учётные данные.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: AerColors.terracotta,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Отозвать'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await widget.mon.api.revokeAgent(a.id);
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    if (_error != null) {
      return Center(
        child: Text(
          _error is String ? _error! as String : describeError(_error!),
        ),
      );
    }
    final names = {for (final s in widget.mon.states) s.entityId: s.name};
    final agents = _agents;
    return ListView(
      padding: const EdgeInsets.all(AerSpacing.l),
      children: [
        Row(
          children: [
            Expanded(
              child: Text('Агенты и heartbeat ботов', style: text.titleMedium),
            ),
            FilledButton.tonalIcon(
              key: const Key('agent-create'),
              onPressed: _create,
              icon: const Icon(Icons.add_rounded),
              label: const Text('Добавить'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        MonCard(
          child: agents == null
              ? const Center(child: CircularProgressIndicator())
              : agents.isEmpty
              ? const Text(
                  'Агентов пока нет. Добавьте учётные данные и запустите aer-agent на устройстве (установка — вручную, docs/AGENTS.md).',
                )
              : Column(
                  children: [
                    for (final a in agents)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(
                          a.kind == 'bot'
                              ? Icons.smart_toy_outlined
                              : Icons.memory_rounded,
                          color: a.revokedAt != null
                              ? AerColors.inkMuted
                              : (a.active ? AerColors.sage : AerColors.amber),
                        ),
                        title: Text(
                          '${a.name} → ${names[a.entityId] ?? 'объект в архиве'}',
                        ),
                        subtitle: Text(
                          [
                            a.revokedAt != null
                                ? 'доступ отозван'
                                : (a.active ? 'присылает данные' : 'молчит'),
                            'последний отчёт ${ago(a.lastSeenAt)}',
                            if (a.osVersion.isNotEmpty) a.osVersion,
                          ].join(' · '),
                        ),
                        trailing: a.revokedAt == null
                            ? TextButton(
                                onPressed: () => _revoke(a),
                                child: const Text('Отозвать'),
                              )
                            : null,
                      ),
                  ],
                ),
        ),
        const SizedBox(height: AerSpacing.l),
        Text('Docker (только наблюдение)', style: text.titleMedium),
        const SizedBox(height: 8),
        MonCard(
          child: _docker == null
              ? const Text('Загрузка…')
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          _docker!.$1.status == 'ok'
                              ? Icons.check_circle_rounded
                              : Icons.error_outline_rounded,
                          color: _docker!.$1.status == 'ok'
                              ? AerColors.sage
                              : AerColors.amber,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _docker!.$1.reason,
                            key: const Key('docker-reason'),
                          ),
                        ),
                      ],
                    ),
                    if (_docker!.$2.isNotEmpty) const Divider(height: 20),
                    for (final c in _docker!.$2)
                      ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: Text('${c.name} · ${c.image}'),
                        subtitle: Text(
                          [
                            c.state +
                                (c.health.isNotEmpty ? ' (${c.health})' : ''),
                            if (c.exitCode != null)
                              'код ${c.exitCode}${c.oomKilled ? ', OOMKilled' : ''}',
                            if (c.cpuPercent != null)
                              'CPU ${fmtValue(c.cpuPercent, '%')}',
                            if (c.memBytes != null)
                              'RAM ${fmtBytes(c.memBytes!)}',
                            'перезапусков ${c.restartCount}',
                            if (c.changedAt != null)
                              'изменён ${ago(c.changedAt)}',
                            if (c.lastErrors.isNotEmpty)
                              'последняя ошибка: ${c.lastErrors.last}',
                          ].join(' · '),
                        ),
                      ),
                    if (_docker!.$1.status != 'ok' && _docker!.$2.isNotEmpty)
                      Text(
                        'Список контейнеров — последний известный, Docker сейчас не отвечает.',
                        style: text.bodySmall?.copyWith(color: AerColors.amber),
                      ),
                  ],
                ),
        ),
      ],
    );
  }
}
