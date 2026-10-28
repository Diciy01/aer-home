import 'dart:async';

import 'package:flutter/material.dart';

import '../../core_api/monitoring_api.dart';
import '../../core_api/network_api.dart';
import '../../platform/open_url.dart';
import '../../state/monitoring_controller.dart';
import '../../state/network_controller.dart';
import '../../theme/tokens.dart';
import '../monitoring/mon_widgets.dart';
import '../registry/error_text.dart';

/// Navigation the network view needs from the shell.
class NetworkLinks {
  const NetworkLinks({
    this.showDevice,
    this.diagnostics,
    this.openJournal,
    this.opener = openExternalUrl,
  });

  /// Opens the device card in «Устройства».
  final void Function(String entityId)? showDevice;

  /// Opens Monitoring diagnostics of a device.
  final void Function(String entityId)? diagnostics;

  /// Opens the general Monitoring journal.
  final VoidCallback? openJournal;
  final UrlOpener opener;
}

Color netColor(NetStatus s) => switch (s) {
  NetStatus.up => AerColors.sage,
  NetStatus.down => AerColors.terracotta,
  NetStatus.error => AerColors.amber,
  NetStatus.unconfigured => AerColors.inkMuted,
  NetStatus.unknown => AerColors.lavender,
};

IconData netIcon(NetStatus s) => switch (s) {
  NetStatus.up => Icons.check_circle_rounded,
  NetStatus.down => Icons.cancel_rounded,
  NetStatus.error => Icons.error_outline_rounded,
  NetStatus.unconfigured => Icons.settings_suggest_outlined,
  NetStatus.unknown => Icons.help_outline_rounded,
};

String fmtMs(double? v) => v == null
    ? '—'
    : v < 10
    ? '${v.toStringAsFixed(1)} мс'
    : '${v.round()} мс';

/// «Сеть и ТВ»: what works in the home network and TV streaming, why not,
/// and where to look next.
class NetworkView extends StatefulWidget {
  const NetworkView({
    super.key,
    required this.network,
    this.mon,
    this.links = const NetworkLinks(),
  });
  final NetworkController network;
  final MonitoringController? mon;
  final NetworkLinks links;

  @override
  State<NetworkView> createState() => _NetworkViewState();
}

class _NetworkViewState extends State<NetworkView> {
  @override
  void initState() {
    super.initState();
    unawaited(widget.network.start());
  }

  Future<void> _check() async {
    final messenger = ScaffoldMessenger.of(context);
    final msg = await widget.network.checkNow();
    if (msg != null) messenger.showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return ListenableBuilder(
      listenable: widget.network,
      builder: (context, _) {
        final n = widget.network;
        return DefaultTabController(
          length: widget.mon == null ? 1 : 2,
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
                    Text('Сеть и ТВ', style: text.headlineSmall),
                    const SizedBox(width: AerSpacing.m),
                    Flexible(child: _Freshness(n: n)),
                    const SizedBox(width: AerSpacing.s),
                    FilledButton.tonalIcon(
                      key: const Key('net-check-now'),
                      onPressed: n.canAct && !n.checking ? _check : null,
                      icon: n.checking
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.network_check_rounded, size: 18),
                      label: const Text('Проверить сейчас'),
                    ),
                  ],
                ),
              ),
              TabBar(
                isScrollable: true,
                tabAlignment: TabAlignment.start,
                padding: const EdgeInsets.symmetric(horizontal: AerSpacing.m),
                tabs: [
                  const Tab(key: Key('net-tab-overview'), text: 'Обзор'),
                  if (widget.mon != null)
                    const Tab(
                      key: Key('net-tab-journal'),
                      text: 'Журнал проверок',
                    ),
                ],
              ),
              Expanded(
                child: TabBarView(
                  children: [
                    _Body(n: n, links: widget.links),
                    if (widget.mon case final m?)
                      NetworkJournal(mon: m, network: n, links: widget.links),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _Freshness extends StatelessWidget {
  const _Freshness({required this.n});
  final NetworkController n;

  @override
  Widget build(BuildContext context) {
    final at = n.updatedAt;
    final (icon, color, label) = n.isStale
        ? (
            Icons.history_rounded,
            AerColors.amber,
            'Нет связи с Core — показаны данные от ${at == null ? '—' : dateTime(at)}, они устарели',
          )
        : (
            Icons.sync_rounded,
            AerColors.sage,
            at == null ? 'Загрузка…' : 'Обновлено в ${clock(at)}',
          );
    return Row(
      key: const Key('net-freshness'),
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

class _Body extends StatelessWidget {
  const _Body({required this.n, required this.links});
  final NetworkController n;
  final NetworkLinks links;

  @override
  Widget build(BuildContext context) {
    final o = n.overview;
    if (o == null) {
      if (n.error != null) {
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(AerSpacing.l),
            child: Text(
              'Не удалось получить состояние сети: ${describeError(n.error!)}',
              textAlign: TextAlign.center,
            ),
          ),
        );
      }
      return const Center(child: CircularProgressIndicator());
    }
    final text = Theme.of(context).textTheme;
    const w = 430.0;
    Widget section(String title, List<Widget> cards) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(
            top: AerSpacing.l,
            bottom: AerSpacing.s,
          ),
          child: Text(title, style: text.titleMedium),
        ),
        Wrap(
          spacing: AerSpacing.m,
          runSpacing: AerSpacing.m,
          children: [for (final c in cards) SizedBox(width: w, child: c)],
        ),
      ],
    );
    final stale = n.isStale;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(
        AerSpacing.l,
        AerSpacing.m,
        AerSpacing.l,
        AerSpacing.xl,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SummaryBanner(overview: o, stale: stale),
          if (o.summary.level == 'unconfigured') const _SetupHint(),
          section('Интернет и роутер', [
            InternetCard(check: o.internet, stale: stale),
            for (final r in o.routers)
              RouterCard(router: r, stale: stale, links: links),
            if (o.routers.isEmpty)
              const _EmptyCard(
                icon: Icons.router_outlined,
                title: 'Роутер не добавлен',
                text: 'Добавьте роутер в «Устройствах» (тип «Роутер», адрес в домашней сети) — Мониторинг будет проверять его доступность и задержку.',
              ),
          ]),
          section('ТВ и стриминг', [
            for (final s in o.sunshine)
              SunshineCard(sunshine: s, stale: stale, links: links),
            if (o.sunshine.isEmpty)
              const _EmptyCard(
                icon: Icons.cast_outlined,
                title: 'Sunshine не настроен',
                text: 'Укажите сервер в конфигурации Core: network.sunshine (адрес serverinfo и веб-интерфейса). AER только наблюдает: не запускает и не настраивает Sunshine.',
              ),
            for (final tv in o.tvs)
              DeviceCard(device: tv, stale: stale, links: links),
          ]),
          if (o.devices.isNotEmpty)
            section('Устройства сети', [
              for (final d in o.devices)
                DeviceCard(device: d, stale: stale, links: links),
            ]),
          Padding(
            padding: const EdgeInsets.only(
              top: AerSpacing.l,
              bottom: AerSpacing.s,
            ),
            child: Row(
              children: [
                Text('Ошибки и инциденты', style: text.titleMedium),
                const Spacer(),
                if (links.openJournal != null)
                  TextButton.icon(
                    key: const Key('net-open-journal'),
                    onPressed: links.openJournal,
                    icon: const Icon(Icons.receipt_long_outlined, size: 18),
                    label: const Text('Общий журнал'),
                  ),
              ],
            ),
          ),
          NetworkIncidents(overview: o, links: links),
        ],
      ),
    );
  }
}

class SummaryBanner extends StatelessWidget {
  const SummaryBanner({super.key, required this.overview, this.stale = false});
  final NetworkOverview overview;
  final bool stale;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final s = overview.summary;
    final (color, icon) = switch (s.level) {
      'ok' => (AerColors.sage, Icons.wifi_rounded),
      'warning' => (AerColors.amber, Icons.wifi_find_rounded),
      'critical' => (AerColors.terracotta, Icons.wifi_off_rounded),
      _ => (AerColors.inkMuted, Icons.settings_ethernet_rounded),
    };
    return Container(
      key: const Key('net-summary'),
      padding: const EdgeInsets.all(AerSpacing.m),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(AerRadii.medium),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 30),
          const SizedBox(width: AerSpacing.m),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(s.title, style: text.titleMedium),
                if (s.issues.length > 1)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      s.issues.skip(1).join(' · '),
                      style: text.bodySmall,
                    ),
                  ),
                const SizedBox(height: 4),
                Text(
                  [
                    if (overview.internet.lastCheckAt case final t?)
                      'интернет проверен ${ago(t)}',
                    'проверки каждые ${overview.intervalSec} с',
                    if (stale) 'данные устарели',
                  ].join(' · '),
                  style: text.labelSmall?.copyWith(color: AerColors.inkMuted),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SetupHint extends StatelessWidget {
  const _SetupHint();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: AerSpacing.m),
      child: Text(
        'Что настроить: 1) роутер, ТВ и сетевые устройства — в «Устройствах» с адресом; '
        '2) цели проверки интернета и Sunshine — в конфигурации Core (раздел network, пример deploy/core-network.example.json). '
        'AER не сканирует сеть и не меняет её настройки.',
        key: const Key('net-setup-hint'),
        style: Theme.of(context).textTheme.bodySmall,
      ),
    );
  }
}

class NetStatusChip extends StatelessWidget {
  const NetStatusChip(this.status, {super.key, this.stale = false});
  final NetStatus status;
  final bool stale;

  @override
  Widget build(BuildContext context) {
    final c = netColor(status);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: c.withValues(alpha: 0.5)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(netIcon(status), size: 13, color: c),
          const SizedBox(width: 4),
          Text(
            stale ? '${status.label} · устарело' : status.label,
            style: Theme.of(context).textTheme.labelSmall,
          ),
        ],
      ),
    );
  }
}

/// Card frame shared by the network cards.
class _NetCard extends StatelessWidget {
  const _NetCard({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.status,
    required this.children,
    this.stale = false,
    this.actions = const [],
  });
  final IconData icon;
  final String title;
  final String subtitle;
  final NetStatus status;
  final bool stale;
  final List<Widget> children;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: AerColors.accent),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: text.titleSmall,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (subtitle.isNotEmpty)
                        Text(
                          subtitle,
                          style: text.labelSmall?.copyWith(
                            color: AerColors.inkMuted,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                    ],
                  ),
                ),
                NetStatusChip(status, stale: stale),
              ],
            ),
            const SizedBox(height: 8),
            ...children,
            if (actions.isNotEmpty) ...[
              const SizedBox(height: 6),
              Wrap(spacing: 4, runSpacing: 2, children: actions),
            ],
          ],
        ),
      ),
    );
  }
}

class _Facts extends StatelessWidget {
  const _Facts(this.items);
  final List<(String, String)> items;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Wrap(
      spacing: 16,
      runSpacing: 4,
      children: [
        for (final (k, v) in items)
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                k,
                style: text.labelSmall?.copyWith(color: AerColors.inkMuted),
              ),
              Text(v, style: text.bodyMedium),
            ],
          ),
      ],
    );
  }
}

class _Reason extends StatelessWidget {
  const _Reason(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Text(
      text,
      style: Theme.of(context).textTheme.bodySmall,
      maxLines: 3,
      overflow: TextOverflow.ellipsis,
    ),
  );
}

String _when(DateTime? t) => t == null ? 'никогда' : ago(t);

class InternetCard extends StatelessWidget {
  const InternetCard({super.key, required this.check, this.stale = false});
  final NetCheck check;
  final bool stale;

  @override
  Widget build(BuildContext context) {
    final c = check;
    final text = Theme.of(context).textTheme;
    return _NetCard(
      key: const Key('net-internet'),
      icon: Icons.public_rounded,
      title: 'Интернет',
      subtitle: 'TCP-проверка заданных целей',
      status: c.status,
      stale: stale || c.stale,
      children: [
        _Reason(c.reason),
        if (c.status != NetStatus.unconfigured)
          _Facts([
            ('Задержка', fmtMs(c.latencyMs)),
            ('Последний успех', _when(c.lastOkAt)),
            ('Проверено', _when(c.lastCheckAt)),
          ]),
        for (final t in c.details?.targets ?? const <NetTarget>[])
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Row(
              children: [
                Icon(
                  t.ok ? Icons.check_rounded : Icons.close_rounded,
                  size: 14,
                  color: t.ok ? AerColors.sage : AerColors.terracotta,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    t.target,
                    style: text.labelMedium,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text(
                  t.ok ? fmtMs(t.latencyMs) : t.error,
                  style: text.labelSmall,
                ),
              ],
            ),
          ),
      ],
    );
  }
}

List<Widget> _deviceActions(NetworkLinks links, String id) => [
  if (links.diagnostics != null)
    TextButton(
      key: Key('net-diag-$id'),
      onPressed: () => links.diagnostics!(id),
      child: const Text('Диагностика'),
    ),
  if (links.showDevice != null)
    TextButton(
      key: Key('net-device-$id'),
      onPressed: () => links.showDevice!(id),
      child: const Text('Карточка устройства'),
    ),
];

class RouterCard extends StatelessWidget {
  const RouterCard({
    super.key,
    required this.router,
    required this.links,
    this.stale = false,
  });
  final NetRouter router;
  final NetworkLinks links;
  final bool stale;

  @override
  Widget build(BuildContext context) {
    final d = router.device;
    final w = router.wan;
    final text = Theme.of(context).textTheme;
    return _NetCard(
      key: Key('net-router-${d.entityId}'),
      icon: Icons.router_outlined,
      title: d.name,
      subtitle: d.address.isEmpty ? 'адрес не указан' : d.address,
      status: d.status,
      stale: stale || d.stale,
      actions: _deviceActions(links, d.entityId),
      children: [
        _Reason(d.reason),
        _Facts([
          ('Задержка', fmtMs(d.latencyMs)),
          ('Последний ответ', _when(d.lastContactAt)),
          ('Проверено', _when(d.lastCheckAt)),
        ]),
        const SizedBox(height: 8),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: AerColors.surfaceMuted.withValues(alpha: 0.6),
            borderRadius: BorderRadius.circular(AerRadii.small),
          ),
          child: w == null
              ? Text(
                  router.adapterNote,
                  key: Key('net-router-note-${d.entityId}'),
                  style: text.bodySmall,
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            'WAN по данным роутера (UPnP)',
                            style: text.labelLarge,
                          ),
                        ),
                        NetStatusChip(w.status, stale: w.stale),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(w.reason, style: text.bodySmall),
                    if (w.details case final x?)
                      Text(
                        [
                          if (x.physicalLink.isNotEmpty)
                            'линия: ${x.physicalLink}',
                          if (x.downMbps != null)
                            '↓ ${x.downMbps!.round()} / ↑ ${x.upMbps?.round() ?? '—'} Мбит/с (номинал)',
                          if (x.uptimeSec != null)
                            'подключение: ${fmtDuration(x.uptimeSec!.toDouble())}',
                        ].join(' · '),
                        style: text.labelSmall,
                      ),
                  ],
                ),
        ),
      ],
    );
  }
}

class SunshineCard extends StatelessWidget {
  const SunshineCard({
    super.key,
    required this.sunshine,
    required this.links,
    this.stale = false,
  });
  final NetSunshine sunshine;
  final NetworkLinks links;
  final bool stale;

  Future<void> _open(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final uri = Uri.tryParse(sunshine.webUrl);
    final ok = uri != null && await links.opener(uri);
    if (!ok) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text('Не удалось открыть веб-интерфейс Sunshine в браузере'),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = sunshine;
    final c = s.check;
    final x = c.details;
    final text = Theme.of(context).textTheme;
    final streaming = x?.streaming;
    return _NetCard(
      key: Key('net-sunshine-${s.id}'),
      icon: Icons.cast_connected_rounded,
      title: s.name,
      subtitle: x?.version.isNotEmpty ?? false
          ? 'Sunshine ${x!.version}'
          : 'сервер стриминга',
      status: c.status,
      stale: stale || c.stale,
      actions: [
        if (s.webUrl.isNotEmpty)
          FilledButton.tonalIcon(
            key: Key('net-sunshine-open-${s.id}'),
            onPressed: () => _open(context),
            icon: const Icon(Icons.open_in_new_rounded, size: 16),
            label: const Text('Открыть Sunshine'),
          ),
        if (s.entity != null && links.showDevice != null)
          TextButton(
            key: Key('net-sunshine-host-${s.id}'),
            onPressed: () => links.showDevice!(s.entity!.entityId),
            child: const Text('Устройство'),
          ),
        if (s.tv != null && links.showDevice != null)
          TextButton(
            key: Key('net-sunshine-tv-${s.id}'),
            onPressed: () => links.showDevice!(s.tv!.entityId),
            child: const Text('Телевизор'),
          ),
      ],
      children: [
        _Reason(c.reason),
        if (c.status == NetStatus.up && streaming != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              children: [
                Icon(
                  streaming ? Icons.live_tv_rounded : Icons.tv_off_outlined,
                  size: 16,
                  color: streaming ? AerColors.sage : AerColors.inkMuted,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    streaming
                        ? 'Идёт стрим (по данным Sunshine)'
                        : 'Сейчас стрима нет',
                    key: Key('net-sunshine-stream-${s.id}'),
                    style: text.bodyMedium,
                  ),
                ),
              ],
            ),
          ),
        _Facts([
          ('Ответ', fmtMs(c.latencyMs)),
          ('Последний ответ', _when(c.lastOkAt)),
          (
            'Веб-интерфейс',
            switch (x?.webReachable) {
              true => 'порт открыт',
              false => 'не отвечает',
              null => '—',
            },
          ),
        ]),
        if (s.tv case final tv?) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              const Icon(Icons.tv_rounded, size: 16, color: AerColors.inkMuted),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'Телевизор «${tv.name}» — отдельное устройство',
                  style: text.labelMedium,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              NetStatusChip(tv.status, stale: tv.stale),
            ],
          ),
        ],
      ],
    );
  }
}

class DeviceCard extends StatelessWidget {
  const DeviceCard({
    super.key,
    required this.device,
    required this.links,
    this.stale = false,
  });
  final NetDevice device;
  final NetworkLinks links;
  final bool stale;

  @override
  Widget build(BuildContext context) {
    final d = device;
    return _NetCard(
      key: Key('net-dev-${d.entityId}'),
      icon: d.type == 'television' ? Icons.tv_rounded : Icons.lan_outlined,
      title: d.name,
      subtitle: [
        d.type == 'television' ? 'телевизор' : 'сетевое устройство',
        if (d.address.isNotEmpty) d.address,
      ].join(' · '),
      status: d.status,
      stale: stale || d.stale,
      actions: _deviceActions(links, d.entityId),
      children: [
        _Reason(d.reason),
        _Facts([
          ('Задержка', fmtMs(d.latencyMs)),
          ('Последний ответ', _when(d.lastContactAt)),
          if (d.openIncidents > 0) ('Инцидентов', '${d.openIncidents}'),
        ]),
      ],
    );
  }
}

class _EmptyCard extends StatelessWidget {
  const _EmptyCard({
    required this.icon,
    required this.title,
    required this.text,
  });
  final IconData icon;
  final String title;
  final String text;

  @override
  Widget build(BuildContext context) => _NetCard(
    icon: icon,
    title: title,
    subtitle: '',
    status: NetStatus.unconfigured,
    children: [Text(text, style: Theme.of(context).textTheme.bodySmall)],
  );
}

class NetworkIncidents extends StatelessWidget {
  const NetworkIncidents({
    super.key,
    required this.overview,
    required this.links,
  });
  final NetworkOverview overview;
  final NetworkLinks links;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    if (overview.incidents.isEmpty) {
      return Text(
        'Открытых инцидентов нет',
        key: const Key('net-no-incidents'),
        style: text.bodySmall,
      );
    }
    final names = {for (final d in overview.allDevices) d.entityId: d.name};
    return Card(
      key: const Key('net-incidents'),
      child: Column(
        children: [
          for (final i in overview.incidents)
            ListTile(
              dense: true,
              leading: Icon(
                Icons.warning_amber_rounded,
                color: i.severity == MonSeverity.critical
                    ? AerColors.terracotta
                    : AerColors.amber,
              ),
              title: Text(i.title),
              subtitle: Text(
                [
                  'с ${dateTime(i.openedAt)}',
                  if (i.entityId != null && names[i.entityId] != null)
                    names[i.entityId]!,
                  if (i.lastMessage.isNotEmpty) i.lastMessage,
                ].join(' · '),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: i.entityId != null && links.showDevice != null
                  ? IconButton(
                      tooltip: 'Карточка устройства',
                      onPressed: () => links.showDevice!(i.entityId!),
                      icon: const Icon(Icons.open_in_new_rounded, size: 18),
                    )
                  : null,
              onTap: links.openJournal,
            ),
        ],
      ),
    );
  }
}

/// «Журнал проверок»: Monitoring logs of the net.* sources.
class NetworkJournal extends StatefulWidget {
  const NetworkJournal({
    super.key,
    required this.mon,
    required this.network,
    required this.links,
  });
  final MonitoringController mon;
  final NetworkController network;
  final NetworkLinks links;

  @override
  State<NetworkJournal> createState() => _NetworkJournalState();
}

class _NetworkJournalState extends State<NetworkJournal> {
  final List<LogEntry> _items = [];
  bool _loading = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (!widget.mon.canAct) {
      setState(() => _error = 'Нет связи с Core: журнал хранится на сервере');
      return;
    }
    setState(() => _loading = true);
    try {
      final p = await widget.mon.api.logs(source: 'net.', limit: 200);
      if (!mounted) return;
      setState(() {
        _items
          ..clear()
          ..addAll(p.items);
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
    final names = {
      for (final d
          in widget.network.overview?.allDevices ?? const <NetDevice>[])
        d.entityId: d.name,
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AerSpacing.l,
            AerSpacing.s,
            AerSpacing.l,
            0,
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'Смены состояния и сбои проверок интернета, роутера и Sunshine (повтор сбоя — не чаще раза в 5 минут). '
                  'Доступность устройств — в журнале Мониторинга.',
                  style: text.bodySmall,
                ),
              ),
              IconButton(
                key: const Key('net-journal-refresh'),
                tooltip: 'Обновить',
                onPressed: _loading ? null : _load,
                icon: const Icon(Icons.refresh_rounded),
              ),
              if (widget.links.openJournal != null)
                TextButton(
                  onPressed: widget.links.openJournal,
                  child: const Text('Общий журнал'),
                ),
            ],
          ),
        ),
        Expanded(
          child: _error != null
              ? Center(
                  child: Text(
                    _error is String
                        ? _error as String
                        : describeError(_error!),
                  ),
                )
              : _items.isEmpty
              ? Center(
                  child: _loading
                      ? const CircularProgressIndicator()
                      : const Text('Записей пока нет'),
                )
              : ListView(
                  key: const Key('net-journal'),
                  padding: const EdgeInsets.all(AerSpacing.m),
                  children: [
                    for (final e in _items)
                      ListTile(
                        dense: true,
                        leading: Icon(
                          e.level == 'info'
                              ? Icons.check_circle_outline
                              : Icons.warning_amber_rounded,
                          size: 18,
                          color: e.level == 'info'
                              ? AerColors.sage
                              : AerColors.amber,
                        ),
                        title: Text(e.message),
                        subtitle: Text(
                          [
                            dateTime(e.at),
                            e.source,
                            if (e.entityId != null && names[e.entityId] != null)
                              names[e.entityId]!,
                          ].join(' · '),
                        ),
                        trailing:
                            e.entityId != null &&
                                widget.links.showDevice != null
                            ? IconButton(
                                tooltip: 'Карточка устройства',
                                onPressed: () =>
                                    widget.links.showDevice!(e.entityId!),
                                icon: const Icon(
                                  Icons.open_in_new_rounded,
                                  size: 18,
                                ),
                              )
                            : null,
                      ),
                  ],
                ),
        ),
      ],
    );
  }
}

/// The network part of the house quick card: the device's own network
/// state, a router's WAN, and Sunshine servers tied to it — each separate.
class NetworkScenePanel extends StatelessWidget {
  const NetworkScenePanel({
    super.key,
    required this.network,
    required this.entityId,
    required this.onOpen,
    this.links = const NetworkLinks(),
  });
  final NetworkController network;
  final String entityId;
  final VoidCallback onOpen;
  final NetworkLinks links;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final d = network.deviceFor(entityId);
    final r = network.routerFor(entityId);
    final suns = network.sunshineFor(entityId);
    final stale = network.isStale;
    Widget line(
      String label,
      NetStatus s,
      String trailing, {
      bool st = false,
    }) => Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: text.labelLarge,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (trailing.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: Text(trailing, style: text.labelSmall),
            ),
          NetStatusChip(s, stale: st || stale),
        ],
      ),
    );
    return Container(
      key: const Key('scene-network-panel'),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AerColors.surfaceMuted.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(AerRadii.small),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.lan_outlined, size: 16, color: AerColors.accent),
              const SizedBox(width: 6),
              Text('Сеть и ТВ', style: text.labelLarge),
            ],
          ),
          if (d != null)
            line('В сети', d.status, fmtMs(d.latencyMs), st: d.stale),
          if (r?.wan case final w?)
            line('WAN (UPnP)', w.status, '', st: w.stale),
          if (r != null && r.wan == null)
            Text(
              'API роутера не настроен: только доступность',
              style: text.labelSmall,
            ),
          for (final s in suns) ...[
            line(
              s.name,
              s.check.status,
              s.check.details?.streaming == true ? 'идёт стрим' : '',
              st: s.check.stale,
            ),
          ],
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final s in suns)
                if (s.webUrl.isNotEmpty)
                  OutlinedButton(
                    key: Key('scene-net-sunshine-${s.id}'),
                    style: OutlinedButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                    ),
                    onPressed: () async {
                      final u = Uri.tryParse(s.webUrl);
                      if (u != null) await links.opener(u);
                    },
                    child: const Text('Открыть Sunshine'),
                  ),
              OutlinedButton(
                key: const Key('scene-net-open'),
                style: OutlinedButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
                onPressed: onOpen,
                child: const Text('Сеть и ТВ'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Compact network status for the classic «Обзор».
class NetworkSummaryCard extends StatelessWidget {
  const NetworkSummaryCard({
    super.key,
    required this.network,
    required this.onOpen,
  });
  final NetworkController network;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: network,
      builder: (context, _) {
        final o = network.overview;
        final text = Theme.of(context).textTheme;
        return Card(
          key: const Key('classic-network'),
          child: Padding(
            padding: const EdgeInsets.all(AerSpacing.l),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(child: Text('Сеть и ТВ', style: text.titleMedium)),
                    TextButton(onPressed: onOpen, child: const Text('Открыть')),
                  ],
                ),
                const SizedBox(height: 8),
                if (o == null)
                  Text(
                    network.error == null
                        ? 'Загрузка…'
                        : 'Нет данных: ${describeError(network.error!)}',
                    style: text.bodySmall,
                  )
                else ...[
                  SummaryBanner(overview: o, stale: network.isStale),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: [
                      _Pill('Интернет', o.internet.status),
                      for (final r in o.routers)
                        _Pill(r.device.name, r.device.status),
                      for (final s in o.sunshine) _Pill(s.name, s.check.status),
                      for (final tv in o.tvs) _Pill(tv.name, tv.status),
                    ],
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill(this.label, this.status);
  final String label;
  final NetStatus status;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(netIcon(status), size: 14, color: netColor(status)),
      const SizedBox(width: 4),
      Text(
        '$label: ${status.label}',
        style: Theme.of(context).textTheme.labelMedium,
      ),
    ],
  );
}
