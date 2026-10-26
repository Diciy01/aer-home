import 'package:aer_home_desktop/src/app.dart';
import 'package:aer_home_desktop/src/state/app_section.dart';
import 'package:aer_home_desktop/src/state/connection_controller.dart';
import 'package:aer_home_desktop/src/state/registry_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';

import 'fake_registry_api.dart';
import 'fixtures.dart';

void main() {
  Future<ConnectionController> pumpApp(
    WidgetTester tester,
    MockClient http,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1366, 768));
    final connection = ConnectionController(clientFor(http));
    final registry = RegistryController(FakeRegistryApi(), connection);
    addTearDown(registry.dispose);
    await tester.pumpWidget(
      AerHomeApp(
        connection: connection,
        registry: registry,
        section: AppSectionController(AppSection.overview),
      ),
    );
    await tester.runAsync(connection.refresh);
    await tester.pump();
    return connection;
  }

  Future<void> finish(WidgetTester tester, ConnectionController c) async {
    // Stop the poll timer before the test ends.
    c.dispose();
    await tester.pumpWidget(const SizedBox());
    await tester.binding.setSurfaceSize(null);
  }

  testWidgets('without Core the app starts and explains it is offline', (
    tester,
  ) async {
    final c = await pumpApp(tester, deadCore());

    expect(find.text('Состояние системы'), findsOneWidget);
    expect(find.text('Core недоступен'), findsWidgets);
    expect(find.textContaining('действия заблокированы'), findsOneWidget);
    expect(find.textContaining('Connection refused'), findsOneWidget);
    expect(find.text('Демо-режим'), findsNothing);

    await finish(tester, c);
  });

  testWidgets('online Core shows system info and labels demo mode', (
    tester,
  ) async {
    final c = await pumpApp(tester, healthyCore());

    expect(find.text('Core на связи'), findsWidgets);
    expect(find.text('Демо-режим'), findsOneWidget);
    expect(find.textContaining('0.1.0-test'), findsOneWidget);

    await finish(tester, c);
  });

  testWidgets('switching modes keeps the classic view state', (tester) async {
    final c = await pumpApp(tester, healthyCore());

    await tester.tap(find.text('Подробности'));
    await tester.pumpAndSettle();
    expect(find.text(fixtureInstanceId), findsOneWidget);

    await tester.tap(find.text('Дом'));
    await tester.pumpAndSettle();
    expect(find.text('Изометрический дом'), findsOneWidget);
    expect(find.text(fixtureInstanceId), findsNothing);

    await tester.tap(find.text('Обзор'));
    await tester.pumpAndSettle();
    expect(
      find.text(fixtureInstanceId),
      findsOneWidget,
      reason: 'expanded panel survived switch',
    );

    await finish(tester, c);
  });
}
