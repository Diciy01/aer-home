// LIVE check of the M04 house editor against a running aer-core, driven
// through the real UI with a mouse: build mode, catalog, placing, dragging,
// rooms, Registry binding, undo/redo, save, conflict, draft recovery and an
// app "restart" (fresh controllers over the same data). Requires an
// isolated Core (AER_DATA_DIR) and client data dir:
//
//   AER_WINDOW_SIZE=1920x1080 AER_CORE_URL=http://127.0.0.1:18787 \
//   AER_CORE_TOKEN_FILE=$D/core.token AER_DESKTOP_DATA_DIR=$D/desktop \
//   AER_SCREENSHOT_DIR=$D/shots flutter test integration_test/editor_live_test.dart -d linux
//
// Registry objects created here are TEST DATA and named "(тест)".
import 'dart:io';
import 'dart:ui' as ui;

import 'package:aer_home_desktop/src/app.dart';
import 'package:aer_home_desktop/src/core_api/core_client.dart';
import 'package:aer_home_desktop/src/core_api/endpoint.dart';
import 'package:aer_home_desktop/src/core_api/registry_api.dart';
import 'package:aer_home_desktop/src/core_api/registry_models.dart';
import 'package:aer_home_desktop/src/features/house/house_view.dart';
import 'package:aer_home_desktop/src/scene/editor/editor_controller.dart';
import 'package:aer_home_desktop/src/scene/geometry/iso.dart';
import 'package:aer_home_desktop/src/scene/model/scene_document.dart';
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
    final image = await ro.toImage(pixelRatio: tester.view.devicePixelRatio);
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    await File('$dir/$name.png').writeAsBytes(png!.buffer.asUint8List());
  });
}

Future<void> settle(WidgetTester tester, [int ms = 400]) async {
  await tester.runAsync(() => Future<void>.delayed(Duration(milliseconds: ms)));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
}

HouseViewState house(WidgetTester tester) =>
    tester.state<HouseViewState>(find.byType(HouseView));

/// Global screen point of a scene point (tiles).
Offset scenePoint(WidgetTester tester, double x, double y, [double z = 0]) {
  final s = house(tester);
  return tester.getTopLeft(find.byKey(const Key('scene-surface'))) +
      s.game.view.worldToScreen(Iso.project(x, y, z));
}

/// A visible, hittable point on an object.
Offset objectPoint(WidgetTester tester, String objectId) {
  final s = house(tester);
  final layout = s.game.layout!;
  final g = layout.objects[objectId]!;
  final b = g.screenBounds;
  for (var i = 1; i < 14; i++) {
    for (var j = 1; j < 14; j++) {
      final w = Offset(b.left + b.width * i / 14, b.top + b.height * j / 14);
      if (layout.hitTestEditable(w)?.object.id == objectId) {
        return tester.getTopLeft(find.byKey(const Key('scene-surface'))) +
            s.game.view.worldToScreen(w);
      }
    }
  }
  fail('object ${g.object.label} is not hittable');
}

class App {
  App(
    this.connection,
    this.registry,
    this.scene,
    this.sceneApi,
    this.registryApi,
  );
  final ConnectionController connection;
  final RegistryController registry;
  final SceneController scene;
  final HttpSceneApi sceneApi;
  final HttpRegistryApi registryApi;

  Future<void> dispose(WidgetTester tester) async {
    connection.dispose();
    await tester.pumpWidget(const SizedBox());
    registry.dispose();
    scene.dispose();
  }
}

/// Starts the app the way main() does (fresh controllers, same data dirs).
Future<App> launch(WidgetTester tester) async {
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
  await tester.pumpWidget(
    RepaintBoundary(
      key: _boundary,
      child: AerHomeApp(
        connection: connection,
        registry: registry,
        scene: scene,
        section: AppSectionController(AppSection.house),
      ),
    ),
  );
  await tester.runAsync(registry.reload);
  await tester.runAsync(scene.load);
  await settle(tester, 900);
  return App(connection, registry, scene, sceneApi, registryApi);
}

SceneObject objOf(SceneDocument d, String asset) =>
    d.objects.firstWhere((o) => o.assetId == asset);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('house editor end to end against a live Core', (tester) async {
    if (_env['AER_CORE_URL'] == null || _env['AER_DESKTOP_DATA_DIR'] == null) {
      markTestSkipped('AER_CORE_URL / AER_DESKTOP_DATA_DIR not set');
      return;
    }
    var app = await launch(tester);
    expect(app.connection.link, CoreLink.online);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);

    if (app.scene.source == SceneSource.bundled) {
      await tester.tap(find.byKey(const Key('scene-save')));
      await settle(tester, 800);
    }
    expect(app.scene.source, SceneSource.core);
    final rev0 = app.scene.revision!;

    late RegistryEntity pc, server;
    await tester.runAsync(() async {
      pc = await app.registryApi.create(
        const EntityDraft(name: 'Домашний ПК (тест)', type: 'computer'),
      );
      server = await app.registryApi.create(
        const EntityDraft(name: 'Домашний сервер (тест)', type: 'server'),
      );
    });
    await tester.runAsync(app.registry.reload);
    await shot(tester, '01-house-overview');

    // --- Build mode ---------------------------------------------------------
    await tester.tap(find.byKey(const Key('house-edit')));
    await settle(tester, 700);
    final s = house(tester);
    final editor = s.editor;
    expect(editor.active, isTrue);
    expect(find.byKey(const Key('editor-top-bar')), findsOneWidget);
    await shot(tester, '02-build-mode');

    // Catalog: category + search.
    await tester.tap(find.byKey(const Key('catalog-cat-computers')));
    await settle(tester);
    expect(find.byKey(const Key('catalog-item-cozy/monitor')), findsOneWidget);
    expect(find.byKey(const Key('catalog-item-cozy/sofa')), findsNothing);
    await tester.tap(find.byKey(const Key('catalog-cat-all')));
    await tester.enterText(find.byKey(const Key('catalog-search')), 'раст');
    await settle(tester);
    expect(find.byKey(const Key('catalog-item-cozy/plant')), findsOneWidget);
    await shot(tester, '03-catalog');

    // Place a plant in the living room with the mouse.
    var doc = editor.document!;
    final living = doc.rooms.firstWhere((r) => r.kind == 'living');
    final before = doc.objects.length;
    await tester.tap(find.byKey(const Key('catalog-item-cozy/plant')));
    await settle(tester, 200);
    final target = scenePoint(
      tester,
      living.origin.x + 2,
      living.origin.y + 6.5,
    );
    await mouse.moveTo(target - const Offset(30, 10));
    await tester.pump();
    await mouse.moveTo(target);
    await settle(tester, 200);
    expect(editor.ghost, isNotNull);
    expect(editor.ghost!.ok, isTrue, reason: '${editor.ghost!.issues}');
    await shot(tester, '04-placing-item');
    await tester.tapAt(target);
    await settle(tester);
    doc = editor.document!;
    expect(doc.objects.length, before + 1);
    final plantId = editor.selectedObjectId!;
    expect(doc.object(plantId)!.roomId, living.id);
    await tester.enterText(find.byKey(const Key('catalog-search')), '');
    await settle(tester);

    // Drag the selected plant with the mouse (one history step).
    final steps = editor.history.length;
    final from = objectPoint(tester, plantId);
    final p0 = doc.object(plantId)!.position;
    // Towards the back wall: free floor (the sofa is in front).
    final to = from + (scenePoint(tester, 0, -3) - scenePoint(tester, 0, 0));
    await mouse.moveTo(from);
    await mouse.down(from);
    await tester.pump();
    for (var i = 1; i <= 10; i++) {
      await mouse.moveTo(Offset.lerp(from, to, i / 10)!);
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(editor.tool, EditorTool.moveObject);
    expect(editor.ghost!.ok, isTrue, reason: '${editor.ghost!.issues}');
    await shot(tester, '05-dragging-item');
    await mouse.up();
    await settle(tester);
    final p1 = editor.document!.object(plantId)!.position;
    expect(p1.y, lessThan(p0.y - 2), reason: 'moved by mouse');
    expect(editor.history.length, steps + 1);

    // A plain click on an unselected object only selects it.
    final desk = objOf(editor.document!, 'cozy/desk');
    final deskPos = desk.position;
    await tester.tapAt(objectPoint(tester, desk.id));
    await settle(tester);
    expect(editor.selectedObjectId, desk.id);
    expect(editor.document!.object(desk.id)!.position.x, deskPos.x);

    // Rotate, duplicate and delete via keys / inspector.
    final lamp = objOf(editor.document!, 'cozy/floor_lamp');
    await tester.tapAt(objectPoint(tester, lamp.id));
    await settle(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyR);
    await settle(tester);
    expect(editor.document!.object(lamp.id)!.rotation, 90);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyD);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await settle(tester);
    final copyId = editor.selectedObjectId!;
    expect(copyId, isNot(lamp.id));
    await tester.sendKeyEvent(LogicalKeyboardKey.delete);
    await settle(tester);
    expect(find.byKey(const Key('editor-delete-dialog')), findsOneWidget);
    await tester.tap(find.byKey(const Key('delete-confirm')));
    await settle(tester);
    expect(editor.document!.object(copyId), isNull);

    // Bind the PC tower to a Registry device through the wizard.
    final tower = objOf(editor.document!, 'cozy/pc_tower');
    s.focusObject(tower.id);
    await settle(tester, 700);
    await tester.tapAt(objectPoint(tester, tower.id));
    await settle(tester);
    expect(editor.selectedObjectId, tower.id);
    await shot(tester, '06-properties-panel');
    await tester.tap(find.byKey(const Key('inspector-bind')));
    await settle(tester, 700);
    expect(find.byKey(const Key('bind-dialog')), findsOneWidget);
    await tester.enterText(find.byKey(const Key('bind-search')), 'тест');
    await settle(tester, 700);
    await tester.tap(find.byKey(Key('bind-item-${pc.id}')));
    await settle(tester);
    await shot(tester, '08-bind-wizard');
    await tester.tap(find.byKey(const Key('bind-confirm')));
    await settle(tester, 900);
    expect(editor.document!.object(tower.id)!.entityBinding!.entityId, pc.id);
    expect(app.scene.presentation(tower.id)!.title, 'Домашний ПК (тест)');
    await shot(tester, '05-selected-bound-item');

    // Server box → home server.
    final nas = objOf(editor.document!, 'cozy/server_box');
    editor.bindObject(nas.id, server.id, server.name);
    await settle(tester, 700);

    // New room through the dialog, placed next to the house.
    final rooms0 = editor.document!.rooms.length;
    await tester.tap(find.text('Комнаты'));
    await settle(tester);
    await tester.tap(find.byKey(const Key('editor-new-room')));
    await settle(tester);
    await tester.enterText(
      find.byKey(const Key('new-room-name')),
      'Мастерская (тест)',
    );
    await tester.tap(find.byKey(const Key('new-floor-stone_light')));
    await tester.tap(find.byKey(const Key('new-wall-sage_light')));
    await settle(tester);
    await tester.tap(find.byKey(const Key('new-room-place')));
    await settle(tester, 700);
    expect(editor.tool, EditorTool.placeRoom);
    expect(editor.roomGhost!.ok, isTrue, reason: '${editor.roomGhost!.issues}');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await settle(tester, 700);
    expect(editor.document!.rooms.length, rooms0 + 1);
    final room = editor.document!.rooms.last;
    expect(editor.selectedRoomId, room.id);
    expect(room.style.floor, 'stone_light');

    // Resize it by dragging the east handle with the mouse.
    final w0 = room.size.w;
    final handle = scenePoint(
      tester,
      room.origin.x + room.size.w,
      room.origin.y + room.size.d / 2,
    );
    final further = scenePoint(
      tester,
      room.origin.x + room.size.w + 2.2,
      room.origin.y + room.size.d / 2,
    );
    await mouse.moveTo(handle);
    await mouse.down(handle);
    await tester.pump();
    for (var i = 1; i <= 8; i++) {
      await mouse.moveTo(Offset.lerp(handle, further, i / 8)!);
      await tester.pump(const Duration(milliseconds: 16));
    }
    await shot(tester, '07-room-editing');
    await mouse.up();
    await settle(tester);
    expect(editor.document!.room(room.id)!.size.w, w0 + 2);

    // Restyle via the inspector and add furniture into the new room.
    await tester.tap(find.byKey(const Key('light-warm')));
    await settle(tester);
    expect(editor.document!.room(room.id)!.style.light, 'warm');
    editor.startPlacing('cozy/desk');
    final r2 = editor.document!.room(room.id)!;
    editor.hover(Iso.project(r2.origin.x + 3, r2.origin.y + 2));
    expect(
      editor.confirmPlacement(),
      isNotNull,
      reason: '${editor.ghost?.issues}',
    );
    await settle(tester);

    // Undo / redo a series: the model is restored exactly.
    final snapshot = editor.document!;
    final encoded = snapshot.toJson().toString();
    for (var i = 0; i < 4; i++) {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
    }
    expect(editor.document!.toJson().toString(), isNot(encoded));
    for (var i = 0; i < 4; i++) {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
    }
    expect(editor.document!.toJson().toString(), encoded);
    await settle(tester);

    // Save to Core.
    await tester.tap(find.byKey(const Key('editor-save')));
    await settle(tester, 900);
    expect(editor.dirty, isFalse);
    final rev1 = app.scene.revision!;
    expect(rev1, greaterThan(rev0));
    late StoredScene stored;
    await tester.runAsync(
      () async => stored = await app.sceneApi.get(snapshot.sceneId),
    );
    expect(stored.document.rooms.length, rooms0 + 1);
    expect(stored.document.object(tower.id)!.entityBinding!.entityId, pc.id);

    // Conflict: someone else saves a newer revision meanwhile.
    final other = stored.document.copyWith(
      name: 'Дом (изменён в другом окне, тест)',
    );
    await tester.runAsync(
      () => app.sceneApi.replace(other.sceneId, stored.revision, other),
    );
    editor.renameObject(plantId, 'Фикус');
    await settle(tester);
    await tester.tap(find.byKey(const Key('editor-save')));
    await settle(tester, 900);
    expect(find.byKey(const Key('editor-conflict-dialog')), findsOneWidget);
    await shot(tester, '11-conflict');
    await tester.tap(find.byKey(const Key('conflict-reload')));
    await settle(tester, 900);
    expect(editor.document!.name, 'Дом (изменён в другом окне, тест)');
    expect(editor.document!.object(plantId)!.label, isNot('Фикус'));
    expect(editor.dirty, isFalse);

    // Leave an unsaved change in a draft and exit the editor keeping it.
    editor.rotateObject(plantId);
    await tester.runAsync(editor.flushDraft);
    expect(editor.dirty, isTrue);
    await shot(tester, '12-unsaved-state');

    // --- Restart: fresh controllers over the same Core and data dir ----------
    await mouse.removePointer();
    await app.dispose(tester);
    app = await launch(tester);
    await settle(tester, 900);
    final h2 = house(tester);
    expect(
      app.scene.document!.rooms.length,
      rooms0 + 1,
      reason: 'saved room is back',
    );
    expect(
      app.scene.document!.object(tower.id)!.entityBinding!.entityId,
      pc.id,
    );
    expect(
      h2.editor.pendingDraft,
      isNotNull,
      reason: 'draft offered after restart',
    );
    expect(find.byKey(const Key('draft-banner')), findsOneWidget);
    await shot(tester, '10-reopened-after-save');
    await tester.tap(find.byKey(const Key('draft-restore')));
    await settle(tester, 700);
    expect(h2.editor.active, isTrue);
    expect(h2.editor.document!.object(plantId)!.rotation, 90);
    await h2.editor.discardAndExit();
    await settle(tester);

    // Reference office close-up in view mode.
    await tester.tap(find.byKey(const Key('room-office')));
    await settle(tester, 900);
    await shot(tester, '09-reference-office');

    await app.dispose(tester);
  });
}
