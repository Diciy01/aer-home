// LIVE check of Bots (M06): a real, isolated Core supervises the TEST bot
// tools/bot-heartbeat/example_bot.py (process controller from the Core
// config); the app shows the list, the bot page with every tab, runs a
// confirmed restart, opens the wizard and controls the bot from the house.
//
//   AER_WINDOW_SIZE=1920x1080 AER_CORE_URL=http://127.0.0.1:18797 \
//   AER_CORE_TOKEN_FILE=$D/data/core.token AER_DESKTOP_DATA_DIR=$D/desktop \
//   AER_SCREENSHOT_DIR=$D/shots flutter test integration_test/bots_live_test.dart -d linux
//
// Every bot and Registry object here is TEST DATA named "(тест)"/"(пример)";
// none of them is a real working bot.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:aer_home_desktop/src/app.dart';
import 'package:aer_home_desktop/src/core_api/bots_api.dart';
import 'package:aer_home_desktop/src/core_api/core_client.dart';
import 'package:aer_home_desktop/src/core_api/endpoint.dart';
import 'package:aer_home_desktop/src/core_api/monitoring_api.dart';
import 'package:aer_home_desktop/src/core_api/registry_api.dart';
import 'package:aer_home_desktop/src/features/house/house_view.dart';
import 'package:aer_home_desktop/src/scene/binding/scene_binding.dart';
import 'package:aer_home_desktop/src/scene/geometry/scene_layout.dart';
import 'package:aer_home_desktop/src/scene/model/scene_edit.dart';
import 'package:aer_home_desktop/src/scene/repository/scene_repository.dart';
import 'package:aer_home_desktop/src/scene/scene_controller.dart';
import 'package:aer_home_desktop/src/state/app_section.dart';
import 'package:aer_home_desktop/src/state/bots_controller.dart';
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

/// Polls Core (outside the fake clock) until [cond] holds.
Future<T> waitFor<T>(
  WidgetTester tester,
  Future<T> Function() read,
  bool Function(T) cond, {
  int seconds = 40,
}) async {
  late T v;
  for (var i = 0; i < seconds * 2; i++) {
    v = (await tester.runAsync(read)) as T;
    if (cond(v)) return v;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 500)),
    );
  }
  fail('condition not reached in $seconds s; last: $v');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('bots against a live Core with an isolated test process', (
    tester,
  ) async {
    if (_env['AER_CORE_URL'] == null || _env['AER_DESKTOP_DATA_DIR'] == null) {
      markTestSkipped('AER_CORE_URL / AER_DESKTOP_DATA_DIR not set');
      return;
    }
    final endpoint = CoreEndpoint.fromEnvironment();
    final client = CoreClient(
      httpClient: http.Client(),
      baseUri: endpoint.baseUri,
      tokenProvider: endpoint.readToken,
    );
    final connection = ConnectionController(client);
    final registryApi = HttpRegistryApi(client);
    final sceneApi = HttpSceneApi(client);
    final botsApi = HttpBotsApi(client);
    await tester.runAsync(connection.refresh);
    final registry = RegistryController(registryApi, connection);
    final cache = SceneCache.defaultLocation();
    final mon = MonitoringController(
      HttpMonitoringApi(client),
      connection,
      cache: MonitoringCache.beside(cache.file),
    );
    final bots = BotsController(botsApi, connection);
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
    final section = AppSectionController(AppSection.bots);
    await tester.pumpWidget(
      RepaintBoundary(
        key: _boundary,
        child: AerHomeApp(
          connection: connection,
          registry: registry,
          scene: scene,
          section: section,
          monitoring: mon,
          bots: bots,
        ),
      ),
    );
    await tester.runAsync(registry.reload);
    await tester.runAsync(mon.start);
    await tester.runAsync(bots.start);
    await settle(tester, 800);

    expect(connection.link, CoreLink.online);
    final test = bots.all.firstWhere((b) => b.name == 'Тестовый бот (пример)');
    final n8n = bots.all.firstWhere((b) => b.runtime == 'n8n');
    // Real signals from the running test process, not demo values.
    final live = await waitFor(
      tester,
      () => botsApi.get(test.entityId),
      (d) => d.bot.status != MonStatus.unknown && d.bot.success24h > 0,
    );
    expect(live.bot.heartbeat.active, isTrue);
    expect(live.bot.version, '0.6.0-example');
    expect(live.bot.runtimeState!.state, 'running');
    final pid = live.bot.runtimeState!.pid;
    await tester.runAsync(bots.refresh);
    await settle(tester);
    expect(find.byKey(Key('bot-${test.entityId}')), findsOneWidget);
    await shot(tester, '01-bots-list');

    await tester.tap(find.byKey(const Key('bots-filter-online')));
    await settle(tester);
    await shot(tester, '02-bots-filter-online');
    await tester.tap(find.byKey(const Key('bots-filter-online')));
    await settle(tester);

    // Bot page, every tab.
    await tester.tap(find.byKey(Key('bot-${test.entityId}')));
    await settle(tester, 900);
    expect(find.byKey(const Key('bot-details')), findsOneWidget);
    await shot(tester, '03-bot-overview');
    for (final (tab, name, wait) in [
      ('load', '04-bot-load', 1500),
      ('activity', '05-bot-activity', 700),
      ('logs', '06-bot-logs', 700),
      ('errors', '07-bot-errors', 700),
      ('jobs', '08-bot-jobs', 700),
      ('control', '09-bot-control', 700),
      ('integration', '10-bot-integration', 500),
    ]) {
      await tester.tap(find.byKey(Key('bot-tab-$tab')));
      await settle(tester, wait);
      await shot(tester, name);
    }

    // A confirmed restart of the isolated test process.
    await tester.tap(find.byKey(const Key('bot-tab-control')));
    await settle(tester, 500);
    await tester.tap(find.byKey(const Key('bot-action-restart')));
    await settle(tester, 700);
    expect(find.byKey(const Key('bot-confirm')), findsOneWidget);
    await shot(tester, '11-confirm-restart');
    await tester.tap(find.byKey(const Key('bot-confirm-ok')));
    await settle(tester, 1500);
    final restarted = await waitFor(
      tester,
      () => botsApi.get(test.entityId),
      (d) =>
          d.bot.runtimeState?.state == 'running' &&
          d.bot.runtimeState!.pid != pid,
    );
    expect(restarted.restarts.any((e) => e.kind == 'bot_restarted'), isTrue);
    final audit = (await tester.runAsync(() => botsApi.audit(test.entityId)))!;
    expect(
      audit.first.action == 'restart' && audit.first.status == 'succeeded',
      isTrue,
    );
    await settle(tester, 900);
    await shot(tester, '12-after-restart-audit');
    await tester.tap(find.byTooltip('Закрыть').last);
    await settle(tester);

    // n8n stub: workflows and executions as jobs.
    await tester.tap(find.byKey(Key('bot-${n8n.entityId}')));
    await settle(tester, 900);
    await tester.tap(find.byKey(const Key('bot-tab-jobs')));
    await settle(tester, 700);
    await shot(tester, '13-n8n-jobs');
    await tester.tap(find.byKey(const Key('bot-tab-integration')));
    await settle(tester, 500);
    await shot(tester, '14-n8n-integration');
    await tester.tap(find.byTooltip('Закрыть').last);
    await settle(tester);

    // Wizard (not saved).
    await tester.tap(find.byKey(const Key('bots-add')));
    await settle(tester, 600);
    await tester.tap(find.byKey(const Key('bot-type-telegram_bot')));
    await tester.enterText(
      find.byKey(const Key('bot-wizard-name')),
      'Новый бот (тест)',
    );
    await settle(tester);
    await shot(tester, '15-wizard-step1');
    for (var i = 0; i < 3; i++) {
      await tester.tap(find.byKey(const Key('bot-wizard-next')));
      await settle(tester, 400);
    }
    await shot(tester, '16-wizard-control');
    await tester.tap(find.text('Отмена'));
    await settle(tester);

    // House: bind the bot character to the test bot (the usual binding).
    if (scene.document == null || scene.source == SceneSource.none) {
      await tester.runAsync(scene.load);
    }
    if (scene.source == SceneSource.bundled) {
      await tester.runAsync(() async => scene.save());
    }
    var doc = scene.document!;
    final robot = doc.objects.firstWhere((o) => o.assetId == 'cozy/bot');
    if (robot.entityBinding?.entityId != test.entityId) {
      doc = const SceneEdits().bindEntity(doc, robot.id, test.entityId);
      await tester.runAsync(
        () => sceneApi.replace(doc.sceneId, scene.revision!, doc),
      );
      await tester.runAsync(scene.load);
    }
    await tester.runAsync(mon.refresh);
    section.value = AppSection.house;
    await settle(tester, 1200);
    final p = scene.presentation(robot.id)!;
    expect(p.binding, BindingState.resolved);
    expect(p.live, isNotNull, reason: 'the bot state reaches the scene');
    final hs = tester.state<HouseViewState>(find.byType(HouseView));
    final g = hs.game.layout!.objects[robot.id]!;
    hs.game.view.focusRect(
      hs.game.layout!.roomGeometry(g.room.id)!.focusBounds,
    );
    await settle(tester, 900);
    await tester.tapAt(_pointOn(tester, hs, g));
    await settle(tester, 1200);
    expect(find.byKey(const Key('scene-bot-panel')), findsOneWidget);
    await shot(tester, '17-house-bot-card');

    // Stop from the house, after confirmation; then start again.
    await tester.tap(find.byKey(const Key('bot-action-stop')));
    await settle(tester, 700);
    await shot(tester, '18-house-confirm-stop');
    await tester.tap(find.byKey(const Key('bot-confirm-ok')));
    await settle(tester, 1500);
    await waitFor(
      tester,
      () => botsApi.get(test.entityId),
      (d) => d.bot.runtimeState?.state == 'stopped',
    );
    await tester.runAsync(bots.refresh);
    await settle(tester, 900);
    await shot(tester, '19-house-stopped');
    await tester.tap(find.byKey(const Key('bot-action-start')));
    await settle(tester, 700);
    await tester.tap(find.byKey(const Key('bot-confirm-ok')));
    await settle(tester, 1500);
    await waitFor(
      tester,
      () => botsApi.get(test.entityId),
      (d) => d.bot.runtimeState?.state == 'running',
    );
    await tester.tap(find.byKey(const Key('scene-bot-open')));
    await settle(tester, 900);
    expect(find.byKey(const Key('bot-details')), findsOneWidget);
    await shot(tester, '20-house-bot-details');
    await tester.tap(find.byTooltip('Закрыть').last);
    await settle(tester);

    connection.dispose();
    await tester.pumpWidget(const SizedBox());
    registry.dispose();
    scene.dispose();
    mon.dispose();
    bots.dispose();
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
