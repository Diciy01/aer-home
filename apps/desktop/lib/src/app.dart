import 'package:flutter/material.dart';

import 'scene/scene_controller.dart';
import 'state/bots_controller.dart';
import 'state/network_controller.dart';
import 'state/power_controller.dart';
import 'state/remote_controller.dart';
import 'state/monitoring_controller.dart';
import 'shell/app_shell.dart';
import 'state/app_section.dart';
import 'state/connection_controller.dart';
import 'state/registry_controller.dart';
import 'theme/theme.dart';

class AerHomeApp extends StatelessWidget {
  const AerHomeApp({
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

  /// Monitoring (M05); the section is hidden when absent.
  final MonitoringController? monitoring;

  /// Bots (M06); the section is hidden when absent.
  final BotsController? bots;

  /// Remote access (M07); the section is hidden when absent.
  final RemoteController? remote;

  /// Power (M08); the section is hidden when absent.
  final PowerController? power;

  /// Network + TV (M09); the section is hidden when absent.
  final NetworkController? network;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AER HOME',
      debugShowCheckedModeBanner: false,
      theme: buildAerTheme(),
      home: AppShell(
        connection: connection,
        registry: registry,
        scene: scene,
        section: section,
        monitoring: monitoring,
        bots: bots,
        remote: remote,
        power: power,
        network: network,
      ),
    );
  }
}
