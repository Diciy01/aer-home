// LIVE check of Monitoring (M05): a real aer-agent reports to a real,
// isolated Core; the app shows overview, devices, diagnostics with charts,
// incidents, logs, agents, notifications and the live state in the house.
// With AER_EXPECT_OFFLINE=1 (Core stopped) it checks the last known state.
//
//   AER_WINDOW_SIZE=1920x1080 AER_CORE_URL=http://127.0.0.1:18787 \
//   AER_CORE_TOKEN_FILE=$D/core.token AER_DESKTOP_DATA_DIR=$D/desktop \
//   AER_SCREENSHOT_DIR=$D/shots flutter test integration_test/monitoring_live_test.dart -d linux
//
// Registry objects are TEST DATA named "(тест)".
import 'dart:io';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:aer_home_desktop/src/app.dart';
import 'package:aer_home_desktop/src/core_api/core_client.dart';
import 'package:aer_home_desktop/src/core_api/endpoint.dart';
import 'package:aer_home_desktop/src/core_api/monitoring_api.dart';
import 'package:aer_home_desktop/src/core_api/registry_api.dart';
import 'package:aer_home_desktop/src/features/house/house_view.dart';
import 'package:aer_home_desktop/src/scene/binding/scene_binding.dart';
import 'package:aer_home_desktop/src/scene/geometry/scene_layout.dart';
import 'package:aer_home_desktop/src/scene/model/scene_document.dart'
    show SceneStatus;
import 'package:aer_home_desktop/src/scene/model/scene_edit.dart';
import 'package:aer_home_desktop/src/scene/repository/scene_repository.dart';
import 'package:aer_home_desktop/src/scene/scene_controller.dart';
import 'package:aer_home_desktop/src/state/app_section.dart';
import 'package:aer_home_desktop/src/state/connection_controller.dart';
import 'package:aer_home_desktop/src/state/monitoring_controller.dart';
import 'package:aer_home_desktop/src/state/registry_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:integration_test/integration_test.dart';

final _env = Platform.environment;
final _boundary = GlobalKey();

Future<void> settle(WidgetTester tester, [int ms = 400]) async {
  await tester.runAsync(() => Future<void>.delayed(Duration(milliseconds: ms)));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
}

Future<void> shot(WidgetTester tester, String name) async {
  await settle(tester, 300);
  final dir = _env['AER_SCREENSHOT_DIR'];
  if (dir == null) return;
  await tester.runAsync(() async {
    final ro =
        _boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await ro.toImage(pixelRatio: tester.view.devicePixelRatio);
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    await File('$dir/$name.png').writeAsBytes(png!.buffer.asUint8List());
  });
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('monitoring against a live Core with a real agent', (
    tester,
  ) async {
    if (_env['AER_CORE_URL'] == null || _env['AER_DESKTOP_DATA_DIR'] == null) {
      markTestSkipped('AER_CORE_URL / AER_DESKTOP_DATA_DIR not set');
      return;
    }
    final offline = _env['AER_EXPECT_OFFLINE'] == '1';
    final endpoint = CoreEndpoint.fromEnvironment();
    final client = CoreClient(
      httpClient: http.Client(),
      baseUri: endpoint.baseUri,
      tokenProvider: endpoint.readToken,
    );
    // Optional Windows stand setup through the app's own API client. A quiet
    // Event Log may be empty: seed an explicitly synthetic UTF-8 warning rather
    // than causing a real OS failure. Real metrics still come from aer-agent.
    if (!offline && _env['AER_TEST_AGENT_BIN'] != null) {
      if (endpoint.baseUri.host != '127.0.0.1' ||
          endpoint.baseUri.port == 8787) {
        fail('agent fixture requires an isolated loopback Core');
      }
      await tester.runAsync(() async {
        final entity = await client.request(
          'POST',
          '/registry/entities',
          body: {'name': 'Рабочий ПК (тест)', 'type': 'computer'},
        ) as Map<String, dynamic>;
        final (_, token) = await HttpMonitoringApi(client)
            .createAgent(entity['id'] as String, 'Windows M10 test', 'host');
        final dir = Directory(_env['AER_DESKTOP_DATA_DIR']!);
        await dir.create(recursive: true);
        final tokenPath = '${dir.path}/test-agent.token';
        await File(tokenPath).writeAsString(token);
        final config = File('${dir.path}/test-agent.json');
        await config.writeAsString(
          jsonEncode({
            'coreUrl': endpoint.baseUri.toString(),
            'tokenFile': tokenPath,
            'intervalSec': 5,
            'collectors': {
              'systemLogs': false,
              'services': ['Spooler'],
            },
          }),
        );
        final agent = await Process.start(_env['AER_TEST_AGENT_BIN']!, [
          '-config',
          config.path,
        ]);
        final output = StringBuffer();
        agent.stdout.transform(utf8.decoder).listen(output.write);
        agent.stderr.transform(utf8.decoder).listen(output.write);
        addTearDown(() async {
          agent.kill(); // Only the child this test created; graceful Run cancellation is tested in Go.
          await agent.exitCode;
          expect(
            output.toString().contains(token),
            false,
            reason: 'no token in agent logs',
          );
        });
        final reporter = http.Client();
        try {
          final response = await reporter.post(
            endpoint.baseUri.resolve('/api/v1/monitoring/agent/report'),
            headers: {
              'Authorization': 'Bearer $token',
              'Content-Type': 'application/json',
            },
            body: jsonEncode({
              'agent': {
                'version': 'test-fixture',
                'os': Platform.operatingSystem,
              },
              'samples': [],
              'logs': [
                {
                  'at': DateTime.now().toUtc().toIso8601String(),
                  'level': 'warning',
                  'source': 'aer.test.fixture',
                  'message': 'Тестовый журнал M10: проверка UTF-8',
                },
              ],
            }),
          );
          expect(response.statusCode, 200);
        } finally {
          reporter.close();
        }
        await Future<void>.delayed(const Duration(seconds: 6));
      });
    }
    final connection = ConnectionController(client);
    final registryApi = HttpRegistryApi(client);
    final sceneApi = HttpSceneApi(client);
    await tester.runAsync(connection.refresh);
    final registry = RegistryController(registryApi, connection);
    final cache = SceneCache.defaultLocation();
    final mon = MonitoringController(
      HttpMonitoringApi(client),
      connection,
      cache: MonitoringCache.beside(cache.file),
    );
    final scene = SceneController(
      sceneApi: sceneApi,
      registryApi: registryApi,
      connectionController: connection,
      sceneCache: cache,
      bundledLoader: loadBundledDemo,
      typeLabel: (t) => registry.catalog?.typeLabel(t) ?? t,
      liveStatus: (id) => liveStatusOf(mon, id),
      liveChanges: mon,
    );
    final section = AppSectionController(AppSection.monitoring);
    await tester.pumpWidget(
      RepaintBoundary(
        key: _boundary,
        child: AerHomeApp(
          connection: connection,
          registry: registry,
          scene: scene,
          section: section,
          monitoring: mon,
        ),
      ),
    );
    await tester.runAsync(registry.reload);
    await tester.runAsync(mon.start);
    await settle(tester, 800);

    if (offline) {
      expect(connection.link, CoreLink.offline);
      expect(mon.isStale, isTrue, reason: 'cached state shown as stale');
      expect(find.textContaining('устарели'), findsOneWidget);
      await shot(tester, '20-offline-last-known');
      await tester.tap(find.byKey(const Key('mon-tab-devices')));
      await settle(tester);
      expect(find.textContaining('устарело'), findsWidgets);
      await shot(tester, '21-offline-devices');
      section.value = AppSection.house;
      await tester.runAsync(scene.load);
      await settle(tester, 900);
      await shot(tester, '22-offline-house');
      connection.dispose();
      await tester.pumpWidget(const SizedBox());
      return;
    }

    expect(connection.link, CoreLink.online);
    expect(mon.freshness, MonFreshness.live);
    final pc = mon.states.firstWhere((s) => s.name == 'Рабочий ПК (тест)');
    expect(pc.agents, isNotEmpty);
    expect(
      pc.metric('cpu.usage')?.value,
      isNotNull,
      reason: 'real CPU value from the agent',
    );
    expect(find.byKey(const Key('mon-tile-devices')), findsOneWidget);
    await shot(tester, '01-monitoring-overview');

    await tester.tap(find.byKey(const Key('mon-tab-devices')));
    await settle(tester);
    expect(find.byKey(Key('device-${pc.entityId}')), findsOneWidget);
    await shot(tester, '02-device-cards');

    await tester.tap(find.byKey(Key('device-${pc.entityId}')));
    await settle(tester, 900);
    expect(find.byKey(const Key('diagnostics')), findsOneWidget);
    await shot(tester, '03-diagnostics-overview');
    await tester.tap(find.text('Метрики'));
    await settle(tester);
    await shot(tester, '04-diagnostics-metrics');
    await tester.tap(find.text('Графики'));
    await settle(tester, 1200);
    expect(find.byKey(const Key('metric-chart')), findsOneWidget);
    await shot(tester, '05-diagnostics-chart');
    await tester.tap(find.text('История событий'));
    await settle(tester, 600);
    await shot(tester, '06-diagnostics-events');
    await tester.tap(find.byKey(const Key('diagnostics-close')));
    await settle(tester);

    await tester.tap(find.byKey(const Key('mon-tab-incidents')));
    await settle(tester, 900);
    await shot(tester, '07-incidents');
    final ack = find.byWidgetPredicate(
      (w) =>
          w.key is ValueKey<String> &&
          (w.key! as ValueKey<String>).value.startsWith('ack-'),
    );
    if (ack.evaluate().isNotEmpty) {
      await tester.tap(ack.first);
      await settle(tester, 900);
      await shot(tester, '08-incident-acknowledged');
    }

    await tester.tap(find.byKey(const Key('mon-tab-logs')));
    await settle(tester, 900);
    await tester.enterText(find.byKey(const Key('logs-search')), 'ssh');
    await settle(tester, 900);
    await shot(tester, '09-logs-search');
    await tester.enterText(find.byKey(const Key('logs-search')), '');
    await settle(tester, 900);
    final firstLog = find.byWidgetPredicate(
      (w) =>
          w.key is ValueKey<String> &&
          (w.key! as ValueKey<String>).value.startsWith('log-'),
    );
    expect(firstLog, findsWidgets);
    await tester.tap(firstLog.first);
    await settle(tester);
    expect(find.byKey(const Key('log-details')), findsOneWidget);
    await shot(tester, '10-log-details');
    await tester.tap(find.text('Закрыть').last);
    await settle(tester);

    await tester.tap(find.byKey(const Key('mon-tab-agents')));
    await settle(tester, 900);
    expect(find.byKey(const Key('docker-reason')), findsOneWidget);
    await shot(tester, '11-agents-docker');

    await tester.tap(find.byKey(const Key('notifications-bell')));
    await settle(tester, 900);
    expect(find.byKey(const Key('notifications')), findsOneWidget);
    await shot(tester, '12-notifications');
    await tester.tap(find.text('Закрыть').last);
    await settle(tester);

    // House: bind the PC tower to the real-agent PC; the badge follows Monitoring.
    if (scene.document == null || scene.source == SceneSource.none) {
      await tester.runAsync(scene.load);
    }
    if (scene.source == SceneSource.bundled) {
      await tester.runAsync(() async => scene.save());
    }
    var doc = scene.document!;
    final tower = doc.objects.firstWhere((o) => o.assetId == 'cozy/pc_tower');
    if (tower.entityBinding?.entityId != pc.entityId) {
      doc = const SceneEdits().bindEntity(doc, tower.id, pc.entityId);
      await tester.runAsync(
        () => sceneApi.replace(doc.sceneId, scene.revision!, doc),
      );
      await tester.runAsync(scene.load);
    }
    section.value = AppSection.house;
    await settle(tester, 1200);
    final p = scene.presentation(tower.id)!;
    expect(p.binding, BindingState.resolved);
    expect(p.live, isNotNull, reason: 'monitoring state reaches the scene');
    expect(p.status, isNot(SceneStatus.unknown));
    final hs = tester.state<HouseViewState>(find.byType(HouseView));
    final g = hs.game.layout!.objects[tower.id]!;
    hs.game.view.focusRect(
      hs.game.layout!.roomGeometry(g.room.id)!.focusBounds,
    );
    await settle(tester, 900);
    final point = _pointOn(tester, hs, g);
    await tester.tapAt(point);
    await settle(tester, 900);
    expect(find.byKey(const Key('scene-open-diagnostics')), findsOneWidget);
    expect(find.byKey(const Key('quick-card-live')), findsOneWidget);
    await shot(tester, '13-house-live-status');
    await tester.tap(find.byKey(const Key('scene-open-diagnostics')));
    await settle(tester, 900);
    expect(find.byKey(const Key('diagnostics')), findsOneWidget);
    await shot(tester, '14-house-diagnostics');
    await tester.tap(find.byKey(const Key('diagnostics-close')));
    await settle(tester);

    connection.dispose();
    await tester.pumpWidget(const SizedBox());
    registry.dispose();
    scene.dispose();
    mon.dispose();
  });
}

Offset _pointOn(WidgetTester tester, HouseViewState s, ObjectGeometry g) {
  final b = g.screenBounds;
  for (var i = 1; i < 14; i++) {
    for (var j = 1; j < 14; j++) {
      final w = Offset(b.left + b.width * i / 14, b.top + b.height * j / 14);
      if (s.game.layout!.hitTest(w)?.object.id == g.object.id) {
        return tester.getTopLeft(find.byKey(const Key('scene-surface'))) +
            s.game.view.worldToScreen(w);
      }
    }
  }
  fail('not hittable');
}
