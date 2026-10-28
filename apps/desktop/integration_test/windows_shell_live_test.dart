import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('Windows shell tray, hide/restore and notification submission', (
    tester,
  ) async {
    if (!Platform.isWindows) {
      markTestSkipped('Windows shell only');
      return;
    }
    await tester.pumpWidget(
      const MaterialApp(home: Text('AER HOME shell test')),
    );
    const shell = MethodChannel('aer.home/desktop');
    Future<Map<Object?, Object?>> status() async =>
        (await shell.invokeMapMethod<Object?, Object?>('status'))!;
    expect((await status())['tray'], true);
    await shell.invokeMethod<void>('hide');
    expect((await status())['visible'], false);
    await shell.invokeMethod<void>('show');
    expect((await status())['visible'], true);
    expect(
      await shell.invokeMethod<bool>('notifyUnread', 2),
      true,
      reason: 'Shell accepted a generic notification; visual delivery depends on Windows policy',
    );
  });
}
