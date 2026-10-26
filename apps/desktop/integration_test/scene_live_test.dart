// LIVE check of the isometric scene against a running aer-core.
// Requires an isolated Core (AER_DATA_DIR) and client data dir:
//
//   AER_CORE_URL=http://127.0.0.1:18787 AER_CORE_TOKEN_FILE=$D/core.token \
//   AER_DESKTOP_DATA_DIR=$D/desktop AER_SCREENSHOT_DIR=$D/shots \
//   flutter test integration_test/scene_live_test.dart -d linux
//
// With AER_EXPECT_OFFLINE=1 (Core stopped) it checks the offline cache path.
// Registry objects created here are TEST DATA and named "(тест)".
import 'dart:io';
import 'dart:ui' as ui;

import 'package:aer_home_desktop/src/app.dart';
import 'package:aer_home_desktop/src/core_api/core_client.dart';
import 'package:aer_home_desktop/src/core_api/endpoint.dart';
import 'package:aer_home_desktop/src/core_api/registry_api.dart';
import 'package:aer_home_desktop/src/core_api/registry_models.dart';
import 'package:aer_home_desktop/src/features/house/house_view.dart';
import 'package:aer_home_desktop/src/scene/geometry/scene_layout.dart';
import 'package:aer_home_desktop/src/scene/model/scene_edit.dart';
import 'package:aer_home_desktop/src/scene/repository/scene_repository.dart';
import 'package:aer_home_desktop/src/scene/scene_controller.dart';
import 'package:aer_home_desktop/src/state/app_section.dart';
import 'package:aer_home_desktop/src/state/connection_controller.dart';
import 'package:aer_home_desktop/src/state/registry_controller.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:integration_test/integration_test.dart';

final _env = Platform.environment;
final _boundary = GlobalKey();

Future<void> shot(WidgetTester tester, String name) async {
  final dir = _env['AER_SCREENSHOT_DIR'];
  await settle(tester, 300);
  if (dir == null) return;
  await tester.runAsync(() async {
    final ro =
        _boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final dpr = tester.view.devicePixelRatio;
    final image = await ro.toImage(pixelRatio: dpr);
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    await File('$dir/$name.png').writeAsBytes(png!.buffer.asUint8List());
  });
}

Future<void> settle(WidgetTester tester, [int ms = 500]) async {
  await tester.runAsync(() => Future<void>.delayed(Duration(milliseconds: ms)));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
}

HouseViewState house(WidgetTester tester) =>
    tester.state<HouseViewState>(find.byType(HouseView));

Offset pointOn(WidgetTester tester, ObjectGeometry g) {
  final s = house(tester);
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
  fail('object ${g.object.label} is not hittable');
}

ObjectGeometry byAsset(WidgetTester tester, String asset) =>
    house(tester).game.layout!.objects.values
        .firstWhere((g) => g.object.assetId == asset);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('isometric house against a live Core', (tester) async {
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
    final connection = ConnectionController(client);
    final registryApi = HttpRegistryApi(client);
    final sceneApi = HttpSceneApi(client);
    await tester.runAsync(connection.refresh);
    final registry = RegistryController(registryApi, connection);
    final scene = SceneController(
      sceneApi: sceneApi,
      registryApi: registryApi,
      connectionController: connection,
      sceneCache: SceneCache.defaultLocation(),
      bundledLoader: loadBundledDemo,
      typeLabel: (t) => registry.catalog?.typeLabel(t) ?? t,
      capabilityLabel: (c) => registry.catalog?.capabilityLabel(c) ?? c,
    );
    final section = AppSectionController(AppSection.house);
    await tester.pumpWidget(
      RepaintBoundary(
        key: _boundary,
        child: AerHomeApp(
          connection: connection,
          registry: registry,
          scene: scene,
          section: section,
        ),
      ),
    );
    await tester.runAsync(registry.reload);
    await tester.runAsync(scene.load);
    await settle(tester, 800);

    if (offline) {
      expect(connection.link, CoreLink.offline);
      expect(scene.source, SceneSource.cache);
      expect(find.textContaining('Офлайн-копия'), findsOneWidget);
      await shot(tester, '20-offline-cache');
      await tester.tapAt(pointOn(tester, byAsset(tester, 'cozy/pc_tower')));
      await settle(tester, 500);
      await shot(tester, '21-offline-selected-stale');
      return;
    }

    expect(connection.link, CoreLink.online);
    if (scene.source == SceneSource.bundled) {
      await shot(tester, '01-demo-unsaved');
      await tester.tap(find.byKey(const Key('scene-save')));
      await settle(tester, 800);
      ScaffoldMessenger.of(tester.element(find.byType(HouseView)))
          .hideCurrentSnackBar();
      await settle(tester);
    }
    expect(scene.source, SceneSource.core);

    // Bind three objects to TEST Registry entities via the M04 edit contract
    // (the editor UI itself is M04; this only proves UUID bindings end to end).
    late RegistryEntity pc, tv, nas;
    await tester.runAsync(() async {
      pc = await registryApi.create(
        const EntityDraft(
          name: 'Основной ПК (тест)',
          type: 'computer',
          address: '192.0.2.154',
        ),
      );
      tv = await registryApi.create(
        const EntityDraft(name: 'Mini TV (тест)', type: 'television'),
      );
      nas = await registryApi.create(
        const EntityDraft(name: 'Старый сервер (тест)', type: 'server'),
      );
      nas = await registryApi.archive(nas.id, nas.revision);
    });
    var doc = scene.document!;
    const edits = SceneEdits();
    String objId(String asset) =>
        doc.objects.firstWhere((o) => o.assetId == asset).id;
    doc = edits.bindEntity(doc, objId('cozy/pc_tower'), pc.id);
    doc = edits.bindEntity(doc, objId('cozy/tv_stick'), tv.id);
    doc = edits.bindEntity(doc, objId('cozy/server_box'), nas.id);
    await tester.runAsync(() async {
      final stored = await sceneApi.replace(doc.sceneId, scene.revision!, doc);
      expect(stored.revision, greaterThan(1));
    });
    await tester.runAsync(scene.load);
    await settle(tester, 800);
    expect(
      scene.presentation(objId('cozy/pc_tower'))!.title,
      'Основной ПК (тест)',
    );

    await tester.tap(find.byKey(const Key('scene-reset')));
    await settle(tester);
    await shot(tester, '02-house-overview');

    for (final kind in [
      'office',
      'living',
      'server',
      'network',
      'automation',
    ]) {
      await tester.tap(find.byKey(Key('room-$kind')));
      await settle(tester, 700);
      await shot(tester, '03-room-$kind');
    }

    await tester.tap(find.byKey(const Key('room-office')));
    await settle(tester, 700);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(pointOn(tester, byAsset(tester, 'cozy/monitor')));
    await settle(tester);
    await shot(tester, '04-hover');
    final pcPoint = pointOn(tester, byAsset(tester, 'cozy/pc_tower'));
    await tester.tapAt(pcPoint);
    await settle(tester, 600);
    expect(find.byKey(const Key('scene-quick-card')), findsOneWidget);
    expect(find.text('Неизвестно'), findsOneWidget);
    await shot(tester, '05-selected-device');

    await tester.tapAt(pcPoint);
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tapAt(pcPoint);
    await settle(tester, 800);
    expect(find.byKey(const Key('entity-details')), findsOneWidget);
    await shot(tester, '06-registry-details');
    registry.clearSelection();
    await settle(tester);

    await tester.tap(find.byKey(const Key('room-server')));
    await settle(tester, 700);
    await tester.tapAt(
      pointOn(tester, byAsset(tester, 'cozy/server_rack')),
      buttons: kSecondaryMouseButton,
    );
    await settle(tester);
    await shot(tester, '07-context-menu');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);

    await tester.tap(find.byKey(const Key('room-server')));
    await settle(tester, 700);
    await tester.tapAt(pointOn(tester, byAsset(tester, 'cozy/server_box')));
    await settle(tester, 600);
    await shot(tester, '08-archived-binding');

    final view = house(tester).game.view;
    for (var i = 0; i < 12; i++) {
      await tester.tap(find.byKey(const Key('scene-zoom-out')));
      await tester.pump();
    }
    await settle(tester);
    expect(view.zoom, closeTo(view.minZoom, 1e-6));
    await shot(tester, '09-zoom-min');
    await tester.tap(find.byKey(const Key('room-automation')));
    await settle(tester, 700);
    for (var i = 0; i < 12; i++) {
      await tester.tap(find.byKey(const Key('scene-zoom-in')));
      await tester.pump();
    }
    await settle(tester);
    expect(view.zoom, view.maxZoom);
    await shot(tester, '10-zoom-max');

    await tester.tap(find.byKey(const Key('scene-reset')));
    await tester.tap(find.byKey(const Key('scene-legend-toggle')));
    await settle(tester);
    await shot(tester, '11-legend');

    section.value = AppSection.overview;
    await settle(tester);
    section.value = AppSection.house;
    await settle(tester);
    expect(
      find.byKey(const Key('scene-legend')),
      findsOneWidget,
      reason: 'state kept across mode switch',
    );

    connection.dispose();
    await tester.pumpWidget(const SizedBox());
    registry.dispose();
    scene.dispose();
  });
}
