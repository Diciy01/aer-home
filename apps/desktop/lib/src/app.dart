import 'package:flutter/material.dart';

import 'scene/scene_controller.dart';
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
  });

  final ConnectionController connection;
  final RegistryController registry;
  final SceneController scene;
  final AppSectionController section;

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
      ),
    );
  }
}
