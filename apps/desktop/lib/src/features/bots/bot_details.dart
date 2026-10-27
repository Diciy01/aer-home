import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core_api/bots_api.dart';
import '../../core_api/monitoring_api.dart';
import '../../state/bots_controller.dart';
import '../../state/monitoring_controller.dart';
import '../../state/registry_controller.dart';
import '../../theme/tokens.dart';
import '../monitoring/device_diagnostics.dart';
import '../monitoring/mon_widgets.dart';
import '../registry/error_text.dart';
import 'add_bot_wizard.dart';
import 'bot_widgets.dart';

/// Tabs of the bot page, in order.
enum BotTab {
  overview,
  load,
  activity,
  logs,
  errors,
  jobs,
  control,
  integration,
}

Future<void> showBotDetails(
  BuildContext context, {
  required BotsController bots,
  required MonitoringController mon,
  required RegistryController registry,
  required String entityId,
  BotTab tab = BotTab.overview,
}) => showDialog<void>(
  context: context,
  builder: (_) => Dialog(
    insetPadding: const EdgeInsets.all(AerSpacing.l),
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 1040, maxHeight: 780),
      child: BotDetails(
        bots: bots,
        mon: mon,
        registry: registry,
        entityId: entityId,
        initialTab: tab,
      ),
    ),
  ),
);

class BotDetails extends StatefulWidget {
  const BotDetails({
    super.key,
    required this.bots,
    required this.mon,
    required this.registry,
    required this.entityId,
    this.initialTab = BotTab.overview,
  });

  final BotsController bots;
  final MonitoringController mon;
  final RegistryController registry;
  final String entityId;
  final BotTab initialTab;

  @override
  State<BotDetails> createState() => _BotDetailsState();
}

class _BotDetailsState extends State<BotDetails> {
  BotDetail? _d;
  Object? _error;
  bool _loading = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
    // While the page is open it follows the bot (heartbeat, actions).
    _timer = Timer.periodic(const Duration(seconds: 10), (_) {
      if (widget.bots.canAct) unawaited(_load());
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    if (_loading) return;
    setState(() => _loading = true);
    try {
      final d = await widget.bots.api.get(widget.entityId);
      if (mounted) {
        setState(() {
          _d = d;
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
    final d = _d;
    if (d == null) {
      return SizedBox(
        height: 300,
        child: Center(
          child: _error != null
              ? Text(describeError(_error!))
              : const CircularProgressIndicator(),
        ),
      );
    }
    final b = d.bot;
    return DefaultTabController(
      length: BotTab.values.length,
      initialIndex: widget.initialTab.index,
      child: Column(
        key: const Key('bot-details'),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 8, 0),
            child: Row(
              children: [
                Icon(runtimeIcon(b.runtime), color: AerColors.accent, size: 28),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(b.name, style: text.titleLarge),
                      Text(
                        [
                          runtimeLabel(b.runtime),
                          widget.registry.catalog?.typeLabel(b.type) ?? b.type,
                          if (b.category.isNotEmpty) b.category,
                          if (b.tags.isNotEmpty)
                            b.tags.map((t) => '#$t').join(' '),
                        ].join(' · '),
                        style: text.bodySmall?.copyWith(
                          color: AerColors.inkMuted,
                        ),
                      ),
                    ],
                  ),
                ),
                StatusChip(b.status, stale: widget.bots.isStale),
                const SizedBox(width: 8),
                TextButton.icon(
                  key: const Key('bot-open-monitoring'),
                  onPressed: () =>
                      showDiagnostics(context, widget.mon, b.entityId),
                  icon: const Icon(Icons.monitor_heart_outlined, size: 18),
                  label: const Text('Мониторинг'),
                ),
                IconButton(
                  tooltip: 'Обновить',
                  onPressed: _loading ? null : _load,
                  icon: const Icon(Icons.refresh_rounded),
                ),
                IconButton(
                  tooltip: 'Закрыть',
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
          ),
          const TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            tabs: [
              Tab(key: Key('bot-tab-overview'), text: 'Обзор'),
              Tab(key: Key('bot-tab-load'), text: 'Нагрузка'),
              Tab(key: Key('bot-tab-activity'), text: 'Активность'),
              Tab(key: Key('bot-tab-logs'), text: 'Логи'),
              Tab(key: Key('bot-tab-errors'), text: 'Ошибки'),
              Tab(key: Key('bot-tab-jobs'), text: 'Задания'),
              Tab(key: Key('bot-tab-control'), text: 'Управление'),
              Tab(key: Key('bot-tab-integration'), text: 'Интеграция'),
            ],
          ),
          Expanded(
            child: TabBarView(
              children: [
                _Overview(d: d, mon: widget.mon),
                _Load(mon: widget.mon, entityId: b.entityId),
                _Activity(api: widget.bots.api, entityId: b.entityId),
                _Logs(api: widget.bots.api, entityId: b.entityId),
                _Errors(d: d, bots: widget.bots, mon: widget.mon),
                _Jobs(d: d, bots: widget.bots, onChanged: _load),
                _Control(d: d, bots: widget.bots, onChanged: _load),
                _Integration(
                  d: d,
                  bots: widget.bots,
                  registry: widget.registry,
                  onChanged: _load,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section(this.title, this.child);
  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: AerSpacing.m),
    child: MonCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: Theme.of(context).textTheme.labelLarge
                ?.copyWith(color: AerColors.inkMuted),
          ),
          const SizedBox(height: 8),
          child,
        ],
      ),
    ),
  );
}

String _jobLine(BotJob? j) {
  if (j == null) return 'нет';
  final at = j.finishedAt ?? j.startedAt;
  return '${j.name} · ${at == null ? '—' : dateTime(at)}${j.durationMs == null ? '' : ' · ${fmtMs(j.durationMs)}'}';
}

class _Overview extends StatelessWidget {
  const _Overview({required this.d, required this.mon});
  final BotDetail d;
  final MonitoringController mon;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final b = d.bot;
    final hb = b.heartbeat;
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        _Section(
          'Состояние',
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(b.statusReason, style: text.bodyMedium),
              const SizedBox(height: 12),
              Wrap(
                spacing: 16,
                runSpacing: 12,
                children: [
                  Fact(
                    'Heartbeat',
                    hb.credentials == 0
                        ? 'не настроен'
                        : '${hb.active ? 'приходит' : 'нет сигнала'} · ${ago(hb.lastSeenAt)}',
                  ),
                  Fact(
                    'Интервал / тайм-аут',
                    '${hb.intervalSec} с / ${hb.timeoutSec} с',
                  ),
                  Fact('Последний ответ', ago(b.lastContactAt)),
                  Fact(
                    'Работает',
                    b.uptimeSec == null
                        ? '—'
                        : fmtDuration(b.uptimeSec!.toDouble()),
                  ),
                  Fact(
                    'Версия',
                    b.version.isEmpty ? 'не сообщается' : b.version,
                  ),
                  Fact('CPU', fmtValue(b.cpuPercent, '%')),
                  Fact('RAM', fmtValue(b.memBytes, 'B')),
                  if (b.runtimeState case final rt?)
                    Fact(
                      'Адаптер (${rt.adapter})',
                      '${runtimeStateLabel(rt.state)}${rt.pid > 0 ? ' · PID ${rt.pid}' : ''}',
                    )
                  else
                    const Fact('Управление', 'только мониторинг'),
                  if (b.apiOk != null)
                    Fact(
                      b.type == 'telegram_bot' || b.runtime == 'telegram'
                          ? 'API Telegram'
                          : 'Внешний API (по данным бота)',
                      b.apiOk! ? 'доступен' : 'недоступен',
                    ),
                ],
              ),
            ],
          ),
        ),
        _Section(
          'Последние результаты',
          Wrap(
            spacing: 16,
            runSpacing: 12,
            children: [
              Fact(
                'Последняя ошибка',
                b.lastError.isEmpty
                    ? 'нет'
                    : '${b.lastError}${b.lastErrorAt == null ? '' : ' · ${dateTime(b.lastErrorAt!)}'}',
                width: 460,
              ),
              Fact(
                'Последний успех',
                b.lastSuccessAt == null ? 'нет' : dateTime(b.lastSuccessAt!),
              ),
              Fact('Успешное задание', _jobLine(b.lastJobOk), width: 300),
              Fact('Неудачное задание', _jobLine(b.lastJobFailed), width: 300),
              Fact(
                'Задания за 24 ч',
                '${b.success24h} успешно · ${b.failed24h} с ошибкой · ${b.runningJobs} идут',
              ),
            ],
          ),
        ),
        _Section(
          'Где работает и от чего зависит',
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _RefRow(
                label: 'Сервер',
                ref: b.host,
                empty: 'не указан (связь runs_on в Registry)',
              ),
              if (d.dependencies.isEmpty)
                Text('Зависимостей нет', style: text.bodySmall)
              else
                for (final dep in d.dependencies)
                  _RefRow(label: 'Зависит от', ref: dep),
            ],
          ),
        ),
        _Section(
          'История падений',
          d.crashes.isEmpty
              ? Text('Падений не было', style: text.bodySmall)
              : Column(
                  children: [
                    for (final i in d.crashes.take(8))
                      ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(
                          i.status == 'resolved'
                              ? Icons.check_circle_outline
                              : sevIcon(i.severity),
                          color: i.status == 'resolved'
                              ? AerColors.sage
                              : sevColor(i.severity),
                        ),
                        title: Text(i.title),
                        subtitle: Text(
                          '${dateTime(i.openedAt)}${i.resolvedAt == null ? ' · не решён' : ' → ${dateTime(i.resolvedAt!)}'}'
                          '${i.cause.isEmpty ? '' : ' · ${i.cause}'}',
                        ),
                      ),
                  ],
                ),
        ),
        _Section(
          'История перезапусков',
          d.restarts.isEmpty
              ? Text(
                  'Запусков и перезапусков не зафиксировано',
                  style: text.bodySmall,
                )
              : Column(
                  children: [
                    for (final e in d.restarts.take(10)) EventRow(event: e),
                  ],
                ),
        ),
      ],
    );
  }
}

class _RefRow extends StatelessWidget {
  const _RefRow({required this.label, required this.ref, this.empty = ''});
  final String label;
  final EntityRef? ref;
  final String empty;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final r = ref;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 110,
            child: Text(
              label,
              style: text.labelMedium?.copyWith(color: AerColors.inkMuted),
            ),
          ),
          if (r == null)
            Text(empty, style: text.bodySmall)
          else ...[
            Text(r.name, style: text.bodyMedium),
            const SizedBox(width: 8),
            StatusChip(r.status, dense: true),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                r.reason,
                style: text.bodySmall?.copyWith(color: AerColors.inkMuted),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _Load extends StatelessWidget {
  const _Load({required this.mon, required this.entityId});
  final MonitoringController mon;
  final String entityId;

  @override
  Widget build(BuildContext context) => FutureBuilder<DeviceState>(
    future: mon.api.state(entityId),
    builder: (context, snap) {
      if (snap.hasError) return Center(child: Text(describeError(snap.error!)));
      final st = snap.data;
      if (st == null) return const Center(child: CircularProgressIndicator());
      const order = [
        'process.cpu_percent',
        'process.rss_bytes',
        'docker.cpu_percent',
        'docker.mem_bytes',
        'docker.net_rx_rate',
        'docker.net_tx_rate',
        'bot.api_ok',
      ];
      // CPU first: the chart opens on the bot's load, not on a flag.
      final metrics =
          st.keyMetrics.where((m) => order.contains(m.metric)).toList()
            ..sort((a, b) => order.indexOf(a.metric) - order.indexOf(b.metric));
      if (metrics.isEmpty) {
        return const Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'Нагрузка не измеряется: процесс запускает не Core, контейнер не связан, '
              'а heartbeat не присылает CPU/RAM (библиотека aer_heartbeat 0.2+ присылает их на Linux).',
              textAlign: TextAlign.center,
            ),
          ),
        );
      }
      return MetricCharts(api: mon.api, entityId: entityId, metrics: metrics);
    },
  );
}

class _Activity extends StatelessWidget {
  const _Activity({required this.api, required this.entityId});
  final BotsApi api;
  final String entityId;

  @override
  Widget build(BuildContext context) => FutureBuilder<List<MonEvent>>(
    future: api.activity(entityId),
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

class _Logs extends StatefulWidget {
  const _Logs({required this.api, required this.entityId, this.level});
  final BotsApi api;
  final String entityId;
  final String? level;

  @override
  State<_Logs> createState() => _LogsState();
}

class _LogsState extends State<_Logs> {
  final List<LogEntry> _items = [];
  int? _next;
  late String? _level = widget.level;
  String _q = '';
  Object? _error;
  bool _loading = false;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    unawaited(_load(reset: true));
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  Future<void> _load({bool reset = false}) async {
    setState(() => _loading = true);
    try {
      final p = await widget.api.logs(
        widget.entityId,
        level: _level,
        q: _q,
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

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  key: const Key('bot-logs-search'),
                  decoration: const InputDecoration(
                    isDense: true,
                    prefixIcon: Icon(Icons.search_rounded),
                    hintText: 'Поиск в логах бота',
                  ),
                  onChanged: (v) {
                    _q = v;
                    _debounce?.cancel();
                    _debounce = Timer(
                      const Duration(milliseconds: 350),
                      () => _load(reset: true),
                    );
                  },
                ),
              ),
              const SizedBox(width: 12),
              DropdownButton<String?>(
                value: _level,
                items: const [
                  DropdownMenuItem(value: null, child: Text('Все уровни')),
                  DropdownMenuItem(value: 'info', child: Text('Info и выше')),
                  DropdownMenuItem(
                    value: 'warning',
                    child: Text('Предупреждения и выше'),
                  ),
                  DropdownMenuItem(
                    value: 'error',
                    child: Text('Только ошибки'),
                  ),
                ],
                onChanged: (v) {
                  setState(() => _level = v);
                  unawaited(_load(reset: true));
                },
              ),
            ],
          ),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.all(8),
            child: Text(
              describeError(_error!),
              style: const TextStyle(color: AerColors.terracotta),
            ),
          ),
        Expanded(
          child: _items.isEmpty && !_loading
              ? const Center(child: Text('Записей нет'))
              : ListView(
                  children: [
                    for (final l in _items) LogRow(entry: l),
                    if (_next != null)
                      Center(
                        child: TextButton(
                          onPressed: _loading ? null : () => _load(),
                          child: const Text('Показать ещё'),
                        ),
                      ),
                  ],
                ),
        ),
      ],
    );
  }
}

class _Errors extends StatelessWidget {
  const _Errors({required this.d, required this.bots, required this.mon});
  final BotDetail d;
  final BotsController bots;
  final MonitoringController mon;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final b = d.bot;
    final active = d.crashes.where((i) => i.active).toList();
    return Column(
      children: [
        if (b.lastError.isNotEmpty || active.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (b.lastError.isNotEmpty)
                  Text(
                    'Последняя ошибка${b.lastErrorAt == null ? '' : ' (${dateTime(b.lastErrorAt!)})'}: ${b.lastError}',
                    key: const Key('bot-last-error'),
                    style: text.bodyMedium?.copyWith(
                      color: AerColors.terracotta,
                    ),
                  ),
                for (final i in active)
                  IncidentCard(incident: i, mon: mon, deviceName: b.name),
              ],
            ),
          ),
        Expanded(
          child: _Logs(api: bots.api, entityId: b.entityId, level: 'error'),
        ),
      ],
    );
  }
}

class _Jobs extends StatefulWidget {
  const _Jobs({required this.d, required this.bots, required this.onChanged});
  final BotDetail d;
  final BotsController bots;
  final VoidCallback onChanged;

  @override
  State<_Jobs> createState() => _JobsState();
}

class _JobsState extends State<_Jobs> {
  final List<BotJob> _items = [];
  String? _next;
  int _total = 0;
  JobStatus? _status;
  Object? _error;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load(reset: true));
  }

  Future<void> _load({bool reset = false}) async {
    setState(() => _loading = true);
    try {
      final p = await widget.bots.api.jobs(
        widget.d.bot.entityId,
        status: _status?.name,
        before: reset ? null : _next,
      );
      if (!mounted) return;
      setState(() {
        if (reset) _items.clear();
        _items.addAll(p.items);
        _next = p.nextBefore;
        _total = p.total;
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
    final retry = widget.d.action('job.retry');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Wrap(
            spacing: 8,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text('Всего: $_total', style: text.labelLarge),
              for (final s in JobStatus.values)
                ChoiceChip(
                  label: Text(jobLook(s).$3),
                  selected: _status == s,
                  onSelected: (on) {
                    setState(() => _status = on ? s : null);
                    unawaited(_load(reset: true));
                  },
                ),
            ],
          ),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.all(8),
            child: Text(
              describeError(_error!),
              style: const TextStyle(color: AerColors.terracotta),
            ),
          ),
        Expanded(
          child: _items.isEmpty && !_loading
              ? Center(
                  child: Text(
                    'Заданий нет. Бот сообщает о них через heartbeat (job_started/job_finished), n8n — через свои выполнения.',
                    style: text.bodyMedium,
                    textAlign: TextAlign.center,
                  ),
                )
              : ListView(
                  key: const Key('bot-jobs'),
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  children: [
                    for (final j in _items)
                      ListTile(
                        dense: true,
                        leading: JobChip(j.status),
                        title: Text(j.name),
                        subtitle: Text(
                          [
                            if (j.startedAt != null)
                              'начало ${dateTime(j.startedAt!)}',
                            if (j.finishedAt != null)
                              'конец ${clock(j.finishedAt!)}',
                            if (j.durationMs != null) fmtMs(j.durationMs),
                            if (j.error.isNotEmpty)
                              j.error
                            else if (j.result.isNotEmpty)
                              j.result,
                            if (j.retryOf.isNotEmpty) 'повтор',
                          ].join(' · '),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: j.retryable && j.status == JobStatus.failed
                            ? Tooltip(
                                message: retry?.available == true
                                    ? 'Повторить после подтверждения'
                                    : (retry?.reason ?? ''),
                                child: IconButton(
                                  key: Key('job-retry-${j.id}'),
                                  icon: const Icon(Icons.replay_rounded),
                                  onPressed:
                                      retry?.available == true &&
                                          widget.bots.canAct
                                      ? () async {
                                          await runBotAction(
                                            context,
                                            widget.bots,
                                            entityId: widget.d.bot.entityId,
                                            action: 'job.retry',
                                            jobId: j.id,
                                          );
                                          widget.onChanged();
                                          await _load(reset: true);
                                        }
                                      : null,
                                ),
                              )
                            : null,
                      ),
                    if (_next != null)
                      Center(
                        child: TextButton(
                          onPressed: _loading ? null : () => _load(),
                          child: const Text('Показать ещё'),
                        ),
                      ),
                  ],
                ),
        ),
      ],
    );
  }
}

class _Control extends StatefulWidget {
  const _Control({
    required this.d,
    required this.bots,
    required this.onChanged,
  });
  final BotDetail d;
  final BotsController bots;
  final VoidCallback onChanged;

  @override
  State<_Control> createState() => _ControlState();
}

class _ControlState extends State<_Control> {
  late Future<List<BotActionRecord>> _audit = widget.bots.api.audit(
    widget.d.bot.entityId,
  );

  void _reload() {
    widget.onChanged();
    setState(() {
      _audit = widget.bots.api.audit(widget.d.bot.entityId);
    });
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final b = widget.d.bot;
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        _Section(
          'Управление',
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                b.monitorOnly
                    ? 'Управляющий адаптер не выбран — бот только наблюдается. '
                          'Адаптеры (процесс, служба systemd, Docker) объявляются в конфигурации Core.'
                    : 'Через адаптер «${b.controllerId}». Перед остановкой и перезапуском AER HOME спросит подтверждение.',
                style: text.bodyMedium,
              ),
              const SizedBox(height: 12),
              BotActionButtons(
                bots: widget.bots,
                entityId: b.entityId,
                actions: widget.d.actions,
                onDone: _reload,
              ),
              for (final a
                  in widget.d.actions
                      .where((a) => !a.available && a.id != 'job.retry')
                      .take(1))
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    a.reason,
                    style: text.bodySmall?.copyWith(color: AerColors.inkMuted),
                  ),
                ),
            ],
          ),
        ),
        _Section(
          'Журнал действий',
          FutureBuilder<List<BotActionRecord>>(
            future: _audit,
            builder: (context, snap) {
              final items = snap.data;
              if (items == null) return const LinearProgressIndicator();
              if (items.isEmpty) {
                return Text('Действий ещё не было', style: text.bodySmall);
              }
              return Column(
                key: const Key('bot-audit'),
                children: [
                  for (final r in items)
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(
                        actionIcon(r.action),
                        color: switch (r.status) {
                          'succeeded' => AerColors.sage,
                          'failed' => AerColors.terracotta,
                          'rejected' => AerColors.amber,
                          _ => AerColors.blue,
                        },
                      ),
                      title: Text(
                        '${dateTime(r.requestedAt)} · ${r.action} · ${switch (r.status) {
                          'succeeded' => 'выполнено',
                          'failed' => 'ошибка',
                          'rejected' => 'отклонено',
                          _ => 'выполняется',
                        }}',
                      ),
                      subtitle: Text(
                        r.message,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}

class _Integration extends StatelessWidget {
  const _Integration({
    required this.d,
    required this.bots,
    required this.registry,
    required this.onChanged,
  });
  final BotDetail d;
  final BotsController bots;
  final RegistryController registry;
  final VoidCallback onChanged;

  Future<void> _issue(BuildContext context) async {
    try {
      final token = await bots.api.issueCredential(d.bot.entityId);
      if (!context.mounted) return;
      await showHeartbeatToken(context, token);
      onChanged();
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(describeError(e))));
      }
    }
  }

  Future<void> _archive(BuildContext context) async {
    final b = d.bot;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          b.archived
              ? 'Восстановить «${b.name}»?'
              : 'Перенести «${b.name}» в архив?',
        ),
        content: Text(
          b.archived
              ? 'Бот снова появится в списке и мониторинге.'
              : 'Объект Registry уйдёт в архив, мониторинг перестанет его проверять. '
                    'Сам бот при этом не останавливается, история сохраняется.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            key: const Key('bot-archive-ok'),
            onPressed: () => Navigator.pop(context, true),
            child: Text(b.archived ? 'Восстановить' : 'В архив'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await bots.setArchived(b.entityId, !b.archived);
      onChanged();
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(describeError(e))));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final b = d.bot;
    final ig = d.integration;
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        _Section(
          'Настройки',
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 16,
                runSpacing: 12,
                children: [
                  Fact('Среда', runtimeLabel(b.runtime)),
                  Fact(
                    'Источник логов',
                    logSourceLabels[b.logSource] ?? b.logSource,
                  ),
                  Fact(
                    'Управляющий адаптер',
                    b.controllerId.isEmpty
                        ? 'нет (только мониторинг)'
                        : b.controllerId,
                  ),
                  if (b.container.isNotEmpty) Fact('Контейнер', b.container),
                  if (b.n8nInstanceId.isNotEmpty) Fact('n8n', b.n8nInstanceId),
                  if (b.telegramTokenId.isNotEmpty)
                    Fact('Файл токена (getMe)', b.telegramTokenId),
                  Fact(
                    'Учётных данных heartbeat',
                    '${b.heartbeat.credentials}',
                  ),
                  if (b.heartbeat.library.isNotEmpty)
                    Fact('Библиотека heartbeat', b.heartbeat.library),
                ],
              ),
              if (b.notes.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(b.notes, style: text.bodySmall),
              ],
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.tonalIcon(
                    key: const Key('bot-edit'),
                    onPressed: bots.canAct
                        ? () async {
                            final id = await showAddBotWizard(
                              context,
                              bots: bots,
                              registry: registry,
                              existing: b,
                            );
                            if (id != null) onChanged();
                          }
                        : null,
                    icon: const Icon(Icons.edit_outlined, size: 18),
                    label: const Text('Изменить'),
                  ),
                  OutlinedButton.icon(
                    key: const Key('bot-issue-credential'),
                    onPressed: bots.canAct ? () => _issue(context) : null,
                    icon: const Icon(Icons.key_outlined, size: 18),
                    label: const Text('Новый токен heartbeat'),
                  ),
                  OutlinedButton.icon(
                    key: const Key('bot-archive'),
                    onPressed: bots.canAct ? () => _archive(context) : null,
                    icon: Icon(
                      b.archived
                          ? Icons.unarchive_outlined
                          : Icons.archive_outlined,
                      size: 18,
                    ),
                    label: Text(b.archived ? 'Восстановить' : 'В архив'),
                  ),
                ],
              ),
            ],
          ),
        ),
        if (ig != null)
          _Section(
            'Интеграция: ${ig.label}',
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      ig.status == 'ok'
                          ? Icons.check_circle_outline
                          : Icons.error_outline,
                      color: ig.status == 'ok'
                          ? AerColors.sage
                          : AerColors.amber,
                    ),
                    const SizedBox(width: 8),
                    Expanded(child: Text(ig.reason, style: text.bodyMedium)),
                  ],
                ),
                if (ig.checkedAt != null)
                  Text(
                    'Проверено ${ago(ig.checkedAt)}',
                    style: text.labelSmall,
                  ),
                if (ig.workflows.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text('Workflows (только просмотр):', style: text.labelLarge),
                  for (final w in ig.workflows)
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(
                        w.active
                            ? Icons.play_circle_outline
                            : Icons.pause_circle_outline,
                        color: w.active ? AerColors.sage : AerColors.inkMuted,
                      ),
                      title: Text(w.name),
                      subtitle: Text(
                        'id ${w.id} · ${w.active ? 'активен' : 'выключен'}',
                      ),
                    ),
                ],
              ],
            ),
          ),
        _Section(
          'Подключение heartbeat',
          SelectableText(
            'Python (stdlib): tools/bot-heartbeat/aer_heartbeat.py\n'
            'hb = Heartbeat("http://<core>:8787", token_file="/path/bot.token", version="1.0")\n'
            'hb.start(); hb.success(); hb.error("…"); j = hb.job_started("…"); hb.job_finished(j, ok=True)\n'
            'Токен хранится в файле с правами 0600, не в коде и не в логах.',
            style: text.bodySmall?.copyWith(fontFamily: 'monospace'),
          ),
        ),
      ],
    );
  }
}

/// Shows a one-time heartbeat token with a copy button.
Future<void> showHeartbeatToken(BuildContext context, String token) =>
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        key: const Key('bot-token'),
        title: const Text('Токен heartbeat'),
        content: SizedBox(
          width: 520,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Показывается один раз. Сохраните его в файл с правами 0600 рядом с ботом '
                'и укажите путь в token_file. В AER HOME хранится только хеш.',
              ),
              const SizedBox(height: 12),
              SelectableText(
                token,
                style: const TextStyle(fontFamily: 'monospace'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton.icon(
            onPressed: () => Clipboard.setData(ClipboardData(text: token)),
            icon: const Icon(Icons.copy_rounded, size: 18),
            label: const Text('Копировать'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Готово'),
          ),
        ],
      ),
    );
