// LIVE end-to-end check against a running aer-core (never the owner's real data:
// start Core with an isolated AER_DATA_DIR). Skipped unless AER_CORE_URL is set.
//
//   AER_CORE_URL=http://127.0.0.1:18787 AER_CORE_TOKEN_FILE=/tmp/x/core.token \
//   AER_SCREENSHOT_DIR=/tmp/x/shots flutter test integration_test -d linux
import 'dart:io';
import 'dart:ui' as ui;

import 'package:aer_home_desktop/src/app.dart';
import 'package:aer_home_desktop/src/core_api/core_client.dart';
import 'package:aer_home_desktop/src/core_api/endpoint.dart';
import 'package:aer_home_desktop/src/core_api/registry_api.dart';
import 'package:aer_home_desktop/src/state/app_section.dart';
import 'package:aer_home_desktop/src/state/connection_controller.dart';
import 'package:aer_home_desktop/src/state/registry_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:integration_test/integration_test.dart';

final _env = Platform.environment;
final _boundary = GlobalKey();

Future<void> shot(WidgetTester tester, String name) async {
  final dir = _env['AER_SCREENSHOT_DIR'];
  if (dir == null) return;
  await tester.pumpAndSettle();
  await tester.runAsync(() async {
    final ro =
        _boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await ro.toImage(pixelRatio: 1);
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    await File('$dir/$name.png').writeAsBytes(png!.buffer.asUint8List());
  });
}

Future<void> settle(WidgetTester tester, [int ms = 600]) async {
  // Real HTTP: give the event loop time, then let animations finish.
  await tester.runAsync(() => Future<void>.delayed(Duration(milliseconds: ms)));
  await tester.pumpAndSettle();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('registry against a live Core', (tester) async {
    if (_env['AER_CORE_URL'] == null) {
      markTestSkipped('AER_CORE_URL not set');
      return;
    }
    await tester.binding.setSurfaceSize(const Size(1366, 768));
    final endpoint = CoreEndpoint.fromEnvironment();
    final client = CoreClient(
      httpClient: http.Client(),
      baseUri: endpoint.baseUri,
      tokenProvider: endpoint.readToken,
    );
    final connection = ConnectionController(client);
    final registry = RegistryController(HttpRegistryApi(client), connection);
    await tester.pumpWidget(
      RepaintBoundary(
        key: _boundary,
        child: AerHomeApp(
          connection: connection,
          registry: registry,
          section: AppSectionController(AppSection.devices),
        ),
      ),
    );
    await tester.runAsync(connection.refresh);
    await settle(tester);
    expect(connection.link, CoreLink.online);
    await shot(tester, '01-empty');

    Future<void> addViaWizard(
      String typeKey,
      String name, {
      String? address,
      String? tags,
    }) async {
      await tester.tap(find.byKey(const Key('action-add')));
      await tester.pumpAndSettle();
      if (name.contains('Сервер')) await shot(tester, '02-wizard-step1');
      await tester.ensureVisible(find.byKey(Key('type-$typeKey')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(Key('type-$typeKey')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('field-name')), name);
      if (address != null) {
        await tester.enterText(find.byKey(const Key('field-address')), address);
      }
      if (tags != null) {
        await tester.tap(find.text('Расширенные настройки'));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.byKey(const Key('field-tags')));
        await tester.enterText(find.byKey(const Key('field-tags')), tags);
      }
      if (name.contains('Сервер')) await shot(tester, '03-wizard-step2');
      await tester.tap(find.text('Далее'));
      await tester.pumpAndSettle();
      if (name.contains('Сервер')) await shot(tester, '04-wizard-step3');
      await tester.tap(find.byKey(const Key('wizard-save')));
      await settle(tester);
      expect(
        find.text('Добавить объект'),
        findsNothing,
        reason: 'wizard closed for $name',
      );
    }

    // TEST DATA, clearly labelled.
    await addViaWizard(
      'server',
      'Сервер (тест)',
      address: '192.0.2.10',
      tags: 'home, test',
    );
    await addViaWizard('telegram_bot', 'PICO (тест)', tags: 'bots');
    await addViaWizard(
      'website',
      'Сайт (тест)',
      address: 'https://example.org',
    );
    await addViaWizard(
      'computer',
      'Основной ПК (тест)',
      address: '192.0.2.154',
      tags: 'home, dualboot',
    );

    expect(find.text('всего: 4'), findsOneWidget);

    // Relation: bot runs_on server.
    await tester.tap(find.text('PICO (тест)'));
    await settle(tester);
    await tester.tap(find.byKey(const Key('action-add-relation')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('relation-pick')));
    await settle(tester);
    await tester.tap(
      find.descendant(
        of: find.byType(ListTile),
        matching: find.text('Сервер (тест)'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('relation-save')));
    await settle(tester);
    expect(find.text('работает на → Сервер (тест)'), findsOneWidget);
    await shot(tester, '05-details-bot');

    // Edit with real optimistic locking.
    await tester.tap(find.text('Основной ПК (тест)'));
    await settle(tester);
    await tester.tap(find.byKey(const Key('action-edit')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('field-name')),
      'Главный ПК (тест)',
    );
    await tester.tap(find.byKey(const Key('edit-save')));
    await settle(tester);
    expect(find.text('Главный ПК (тест)'), findsWidgets);
    await shot(tester, '06-list-details-pc');

    // Search (Cyrillic, case-insensitive, done by Core).
    await tester.enterText(find.byKey(const Key('registry-search')), 'ГЛАВНЫЙ');
    await settle(tester, 900);
    expect(find.text('всего: 1'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('registry-search')), '');
    await settle(tester, 900);

    // Archive the website, view the archive.
    await tester.tap(find.text('Сайт (тест)'));
    await settle(tester);
    await tester.tap(find.byKey(const Key('action-archive')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm-archive')));
    await settle(tester);
    await tester.tap(find.text('Архив'));
    await settle(tester);
    expect(find.text('в архиве: 1'), findsOneWidget);
    await shot(tester, '07-archive');

    connection.dispose();
    await tester.pumpWidget(const SizedBox());
    registry.dispose();
  });
}
