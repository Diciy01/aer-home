import 'package:flutter/material.dart';

import '../features/classic/classic_view.dart';
import '../features/house/house_view.dart';
import '../features/registry/registry_view.dart';
import '../scene/scene_controller.dart';
import '../state/app_section.dart';
import '../state/connection_controller.dart';
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
  });

  final ConnectionController connection;
  final RegistryController registry;
  final SceneController scene;
  final AppSectionController section;

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
              destinations: const [
                NavigationRailDestination(
                  icon: Icon(Icons.cottage_outlined),
                  selectedIcon: Icon(Icons.cottage_rounded),
                  label: Text('Дом'),
                ),
                NavigationRailDestination(
                  icon: Icon(Icons.dashboard_outlined),
                  selectedIcon: Icon(Icons.dashboard_rounded),
                  label: Text('Обзор'),
                ),
                NavigationRailDestination(
                  icon: Icon(Icons.devices_other_outlined),
                  selectedIcon: Icon(Icons.devices_other_rounded),
                  label: Text('Устройства'),
                ),
              ],
            ),
            Expanded(
              child: Column(
                children: [
                  _TopBar(connection: connection),
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
                          )
                        else
                          const SizedBox.shrink(),
                        ClassicView(connection: connection),
                        RegistryView(
                          registry: registry,
                          connection: connection,
                        ),
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
  const _TopBar({required this.connection});

  final ConnectionController connection;

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
