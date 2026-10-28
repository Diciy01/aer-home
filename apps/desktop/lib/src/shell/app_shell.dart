import 'package:flutter/material.dart';

import '../features/bots/bot_details.dart';
import '../features/bots/bot_scene_panel.dart';
import '../features/bots/bots_view.dart';
import '../features/classic/classic_view.dart';
import '../features/network/network_view.dart';
import '../features/power/power_view.dart';
import '../features/remote/remote_view.dart';
import '../features/house/house_view.dart';
import '../features/monitoring/device_diagnostics.dart';
import '../features/monitoring/mon_widgets.dart';
import '../features/monitoring/monitoring_view.dart';
import '../features/registry/registry_view.dart';
import '../scene/scene_controller.dart';
import '../state/app_section.dart';
import '../state/bots_controller.dart';
import '../state/network_controller.dart';
import '../state/power_controller.dart';
import '../state/remote_controller.dart';
import '../state/connection_controller.dart';
import '../state/monitoring_controller.dart';
import '../state/registry_controller.dart';
import '../theme/tokens.dart';
import 'status_presentation.dart';

class AppShell extends StatelessWidget {
  const AppShell({
    super.key,
    required this.connection,
    required this.registry,
    required this.scene,
    required this.section,
    this.monitoring,
    this.bots,
    this.remote,
    this.power,
    this.network,
  });

  final ConnectionController connection;
  final RegistryController registry;
  final SceneController scene;
  final AppSectionController section;
  final MonitoringController? monitoring;

  /// Bots (M06); needs Monitoring, hidden when either is absent.
  final BotsController? bots;

  BotsController? get _bots => monitoring == null ? null : bots;

  /// Remote (M07); shown after Bots, needs Monitoring too.
  final RemoteController? remote;

  RemoteController? get _remote => _bots == null ? null : remote;

  /// Power (M08); shown after Remote (navigation indices follow the enum).
  final PowerController? power;

  PowerController? get _power => _remote == null ? null : power;

  void _openRemote(String entityId) => section.value = AppSection.remote;

  /// Network + TV (M09); shown after Power.
  final NetworkController? network;

  NetworkController? get _network => _power == null ? null : network;

  NetworkLinks _netLinks(BuildContext context) => NetworkLinks(
    showDevice: _showInRegistry,
    diagnostics: monitoring == null
        ? null
        : (id) => showDiagnostics(context, monitoring!, id),
    openJournal: monitoring == null
        ? null
        : () => section.value = AppSection.monitoring,
  );

  Widget? _entityPanel(BuildContext context, String entityId) {
    final r = _remote;
    final bot = _botPanel(context, entityId);
    if (r == null) return bot;
    final pw = _power;
    final powerPanel = pw == null
        ? null
        : ListenableBuilder(
            listenable: Listenable.merge([pw, r]),
            builder: (context, _) {
              final d = pw.deviceFor(entityId);
              if (d == null) return const SizedBox.shrink();
              return Padding(
                padding: const EdgeInsets.only(top: 6),
                child: PowerScenePanel(
                  power: pw,
                  device: d,
                  onOpen: () => section.value = AppSection.power,
                  onOpenRemote: r.hostFor(entityId) == null
                      ? null
                      : () => _openRemote(entityId),
                ),
              );
            },
          );
    final remotePanel = ListenableBuilder(
      listenable: r,
      builder: (context, _) {
        final h = r.hostFor(entityId);
        if (h == null) return const SizedBox.shrink();
        return RemoteScenePanel(
          remote: r,
          host: h,
          onOpen: () => section.value = AppSection.remote,
        );
      },
    );
    final nw = _network;
    final networkPanel = nw == null
        ? null
        : ListenableBuilder(
            listenable: nw,
            builder: (context, _) {
              if (nw.deviceFor(entityId) == null &&
                  nw.sunshineFor(entityId).isEmpty) {
                return const SizedBox.shrink();
              }
              return Padding(
                padding: const EdgeInsets.only(top: 6),
                child: NetworkScenePanel(
                  network: nw,
                  entityId: entityId,
                  onOpen: () => section.value = AppSection.network,
                  links: _netLinks(context),
                ),
              );
            },
          );
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [?bot, remotePanel, ?powerPanel, ?networkPanel],
    );
  }

  Widget? _botPanel(BuildContext context, String entityId) {
    final b = _bots;
    if (b == null) return null;
    return ListenableBuilder(
      listenable: b,
      builder: (context, _) {
        final bot = b.botFor(entityId);
        if (bot == null) return const SizedBox.shrink();
        return BotScenePanel(
          bots: b,
          bot: bot,
          onOpen: (tab) => showBotDetails(
            context,
            bots: b,
            mon: monitoring!,
            registry: registry,
            entityId: entityId,
            tab: tab,
          ),
        );
      },
    );
  }

  void _showInRegistry(String entityId) {
    section.value = AppSection.devices;
    registry.selectById(entityId).ignore();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: ValueListenableBuilder<AppSection>(
        valueListenable: section,
        builder: (context, mode, _) => Row(
          children: [
            NavigationRail(
              selectedIndex: mode.index,
              onDestinationSelected: (i) =>
                  section.value = AppSection.values[i],
              labelType: NavigationRailLabelType.all,
              leading: const Padding(
                padding: EdgeInsets.symmetric(vertical: AerSpacing.m),
                child: _Wordmark(),
              ),
              destinations: [
                const NavigationRailDestination(
                  icon: Icon(Icons.cottage_outlined),
                  selectedIcon: Icon(Icons.cottage_rounded),
                  label: Text('Дом'),
                ),
                const NavigationRailDestination(
                  icon: Icon(Icons.dashboard_outlined),
                  selectedIcon: Icon(Icons.dashboard_rounded),
                  label: Text('Обзор'),
                ),
                const NavigationRailDestination(
                  icon: Icon(Icons.devices_other_outlined),
                  selectedIcon: Icon(Icons.devices_other_rounded),
                  label: Text('Устройства'),
                ),
                if (monitoring != null)
                  const NavigationRailDestination(
                    icon: Icon(Icons.monitor_heart_outlined),
                    selectedIcon: Icon(Icons.monitor_heart_rounded),
                    label: Text('Мониторинг'),
                  ),
                if (_bots != null)
                  const NavigationRailDestination(
                    icon: Icon(Icons.smart_toy_outlined),
                    selectedIcon: Icon(Icons.smart_toy_rounded),
                    label: Text('Боты'),
                  ),
                if (_remote != null)
                  const NavigationRailDestination(
                    icon: Icon(Icons.cast_connected_outlined),
                    selectedIcon: Icon(Icons.cast_connected_rounded),
                    label: Text(
                      'Удалённый\nдоступ',
                      textAlign: TextAlign.center,
                    ),
                  ),
                if (_power != null)
                  const NavigationRailDestination(
                    icon: Icon(Icons.power_settings_new_outlined),
                    selectedIcon: Icon(Icons.power_settings_new_rounded),
                    label: Text('Питание'),
                  ),
                if (_network != null)
                  const NavigationRailDestination(
                    icon: Icon(Icons.lan_outlined),
                    selectedIcon: Icon(Icons.lan_rounded),
                    label: Text('Сеть и ТВ', textAlign: TextAlign.center),
                  ),
              ],
            ),
            Expanded(
              child: Column(
                children: [
                  _TopBar(connection: connection, monitoring: monitoring),
                  Expanded(
                    // Both views stay mounted: switching keeps their state.
                    child: IndexedStack(
                      index: mode.index,
                      children: [
                        if (section.visited.contains(AppSection.house))
                          HouseView(
                            scene: scene,
                            registry: registry,
                            onShowInRegistry: _showInRegistry,
                            onOpenDiagnostics: monitoring == null
                                ? null
                                : (id) =>
                                      showDiagnostics(context, monitoring!, id),
                            entityPanel: _bots == null
                                ? null
                                : (id) => _entityPanel(context, id),
                          )
                        else
                          const SizedBox.shrink(),
                        ClassicView(
                          connection: connection,
                          network: _network,
                          onOpenNetwork: () =>
                              section.value = AppSection.network,
                        ),
                        RegistryView(
                          registry: registry,
                          connection: connection,
                        ),
                        if (monitoring != null)
                          section.visited.contains(AppSection.monitoring)
                              ? MonitoringView(
                                  mon: monitoring!,
                                  registry: registry,
                                )
                              : const SizedBox.shrink(),
                        if (_bots case final b?)
                          section.visited.contains(AppSection.bots)
                              ? BotsView(
                                  bots: b,
                                  mon: monitoring!,
                                  registry: registry,
                                )
                              : const SizedBox.shrink(),
                        if (_remote case final r?)
                          section.visited.contains(AppSection.remote)
                              ? RemoteView(remote: r)
                              : const SizedBox.shrink(),
                        if (_power case final pw?)
                          section.visited.contains(AppSection.power)
                              ? PowerView(power: pw, onOpenRemote: _openRemote)
                              : const SizedBox.shrink(),
                        if (_network case final nw?)
                          section.visited.contains(AppSection.network)
                              ? NetworkView(
                                  network: nw,
                                  mon: monitoring,
                                  links: _netLinks(context),
                                )
                              : const SizedBox.shrink(),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Wordmark extends StatelessWidget {
  const _Wordmark();

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: AerColors.accentSoft,
            borderRadius: BorderRadius.circular(AerRadii.small),
          ),
          child: const Icon(Icons.home_work_outlined, color: AerColors.ink),
        ),
        const SizedBox(height: AerSpacing.xs),
        Text(
          'AER HOME',
          style: Theme.of(context).textTheme.labelSmall
              ?.copyWith(letterSpacing: 1.2, fontWeight: FontWeight.w700),
        ),
      ],
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({required this.connection, this.monitoring});

  final ConnectionController connection;
  final MonitoringController? monitoring;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 56,
      padding: const EdgeInsets.symmetric(horizontal: AerSpacing.l),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AerColors.border)),
      ),
      child: ListenableBuilder(
        listenable: connection,
        builder: (context, _) {
          final p = LinkPresentation.of(connection.link);
          final demo = connection.info?.demo ?? false;
          return Row(
            children: [
              if (demo) const _DemoBadge(),
              const Spacer(),
              if (monitoring case final mon?) _Bell(mon: mon),
              const SizedBox(width: AerSpacing.s),
              Semantics(
                label: 'Состояние связи: ${p.label}',
                child: Chip(
                  avatar: Icon(p.icon, size: 18, color: p.color),
                  label: Text(p.label),
                  backgroundColor: AerColors.surface,
                  side: BorderSide(color: p.color.withValues(alpha: 0.6)),
                  shape: const StadiumBorder(),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _DemoBadge extends StatelessWidget {
  const _DemoBadge();

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'Core запущен в режиме development: данные могут быть тестовыми',
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AerSpacing.m,
          vertical: AerSpacing.xs,
        ),
        decoration: BoxDecoration(
          color: AerColors.lavender.withValues(alpha: 0.25),
          borderRadius: BorderRadius.circular(AerRadii.large),
          border: Border.all(color: AerColors.lavender),
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.science_outlined, size: 16, color: AerColors.ink),
            SizedBox(width: AerSpacing.xs),
            Text('Демо-режим'),
          ],
        ),
      ),
    );
  }
}

/// Notification center: unread count, list, «прочитать все».
class _Bell extends StatelessWidget {
  const _Bell({required this.mon});
  final MonitoringController mon;

  Future<void> _open(BuildContext context) async {
    if (mon.canAct) {
      try {
        await mon.loadNotifications();
      } catch (_) {}
    }
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => ListenableBuilder(
        listenable: mon,
        builder: (context, _) {
          final text = Theme.of(context).textTheme;
          final items = mon.notifications;
          return AlertDialog(
            key: const Key('notifications'),
            title: const Text('Уведомления'),
            content: SizedBox(
              width: 520,
              height: 420,
              child: !mon.canAct && items.isEmpty
                  ? const Center(
                      child: Text(
                        'Нет связи с Core: уведомления хранятся на сервере',
                      ),
                    )
                  : items.isEmpty
                  ? const Center(child: Text('Уведомлений нет'))
                  : ListView(
                      children: [
                        for (final n in items)
                          ListTile(
                            dense: true,
                            leading: Icon(
                              sevIcon(n.severity),
                              color: sevColor(n.severity),
                            ),
                            title: Text(
                              n.title,
                              style: n.read
                                  ? text.bodyMedium
                                  : text.bodyMedium?.copyWith(
                                      fontWeight: FontWeight.w700,
                                    ),
                            ),
                            subtitle: Text(
                              [
                                dateTime(n.at),
                                if (n.body.isNotEmpty) n.body,
                                if (n.telegram == 'sent')
                                  'отправлено в Telegram',
                              ].join(' · '),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            onTap: n.entityId == null
                                ? null
                                : () {
                                    Navigator.pop(context);
                                    showDiagnostics(context, mon, n.entityId!);
                                  },
                          ),
                      ],
                    ),
            ),
            actions: [
              TextButton(
                key: const Key('notifications-read-all'),
                onPressed: mon.canAct && mon.unread > 0
                    ? mon.markAllRead
                    : null,
                child: const Text('Прочитать все'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Закрыть'),
              ),
            ],
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: mon,
    builder: (context, _) => IconButton(
      key: const Key('notifications-bell'),
      tooltip: 'Уведомления',
      onPressed: () => _open(context),
      icon: Badge(
        isLabelVisible: mon.unread > 0,
        label: Text('${mon.unread}'),
        child: const Icon(Icons.notifications_outlined),
      ),
    ),
  );
}
