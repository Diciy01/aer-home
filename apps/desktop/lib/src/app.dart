import 'package:flutter/material.dart';

import 'shell/app_shell.dart';
import 'state/connection_controller.dart';
import 'state/view_mode.dart';
import 'theme/theme.dart';

class AerHomeApp extends StatelessWidget {
  const AerHomeApp({
    super.key,
    required this.connection,
    required this.viewMode,
  });

  final ConnectionController connection;
  final ViewModeController viewMode;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AER HOME',
      debugShowCheckedModeBanner: false,
      theme: buildAerTheme(),
      home: AppShell(connection: connection, viewMode: viewMode),
    );
  }
}
