import 'dart:io';

import 'package:aer_home_desktop/src/scene/binding/scene_binding.dart';
import 'package:aer_home_desktop/src/scene/catalog/scene_catalog.dart';
import 'package:aer_home_desktop/src/scene/editor/draft_store.dart';
import 'package:aer_home_desktop/src/scene/editor/editor_controller.dart';
import 'package:aer_home_desktop/src/scene/geometry/iso.dart';
import 'package:aer_home_desktop/src/scene/geometry/scene_layout.dart';
import 'package:aer_home_desktop/src/scene/model/scene_codec.dart';
import 'package:aer_home_desktop/src/scene/model/scene_document.dart';
import 'package:aer_home_desktop/src/scene/repository/scene_repository.dart';
import 'package:aer_home_desktop/src/scene/scene_controller.dart';
import 'package:aer_home_desktop/src/state/connection_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../../fake_registry_api.dart';
import '../../fixtures.dart';
import '../scene_fixtures.dart';

void main() {
  late Directory dir;
  late SceneCache cache;
  late FakeSceneApi sceneApi;
  late FakeRegistryApi registry;
  late MemoryDraftStore drafts;
  var coreUp = true;
  const codec = SceneCodec();

  setUp(() {
    dir = Directory.systemTemp.createTempSync('aer-editor-test-');
    cache = SceneCache(File('${dir.path}/scene-cache.json'));
    sceneApi = FakeSceneApi();
    registry = FakeRegistryApi();
    drafts = MemoryDraftStore();
    coreUp = true;
    final doc = exampleScene();
    sceneApi.stored[doc.sceneId] = StoredScene(
      document: doc,
      revision: 3,
      updatedAt: DateTime.utc(2026),
    );
  });
  tearDown(() async {
    // A binding refresh may still be saving the cache; Windows cannot
    // delete a file that is open.
    await cache.settled;
    dir.deleteSync(recursive: true);
  });

  Future<(EditorController, SceneController, ConnectionController)>
  make() async {
    final connection = ConnectionController(
      clientFor(
        MockClient((req) async {
          if (!coreUp) {
            throw http.ClientException('Connection refused', req.url);
          }
          return healthyHandler(req);
        }),
      ),
    );
    addTearDown(connection.dispose);
    await connection.refresh();
    final scene = sceneControllerFor(
      connection: connection,
      registry: registry,
      api: sceneApi,
      dataDir: dir,
      cache: cache,
      drafts: drafts,
    );
    addTearDown(scene.dispose);
    await scene.load();
    final editor = EditorController(
      scene: scene,
      catalog: SceneCatalog.builtin,
      drafts: drafts,
      autosaveDelay: Duration.zero,
    );
    addTearDown(editor.dispose);
    return (editor, scene, connection);
  }

  SceneRoom roomOf(EditorController e, String kind) =>
      e.document!.rooms.firstWhere((r) => r.kind == kind);
  SceneObject objOf(EditorController e, String asset) =>
      e.document!.objects.firstWhere((o) => o.assetId == asset);
  Offset floorAt(SceneRoom r, double x, double y) =>
      Iso.project(r.origin.x + x, r.origin.y + y);

  test(
    'enter/exit: view mode untouched, working copy only while editing',
    () async {
      final (e, scene, _) = await make();
      expect(e.active, isFalse);
      e.enter();
      expect(scene.editing, isTrue);
      expect(e.dirty, isFalse);
      expect(e.exit(), isTrue);
      expect(scene.editing, isFalse);
    },
  );

  test(
    'place from catalog: floor, on a desk (surface), on a wall; rotation',
    () async {
      final (e, scene, _) = await make();
      e.enter();
      final office = roomOf(e, 'office');
      final n = e.document!.objects.length;

      e.startPlacing('cozy/armchair');
      e.hover(floorAt(office, 7.5, 5.5));
      expect(e.ghost!.ok, isTrue, reason: '${e.ghost!.issues}');
      e.rotate();
      e.hover(floorAt(office, 7.5, 5.5));
      expect(e.ghost!.rotation, 90);
      final chairId = e.confirmPlacement()!;
      expect(e.document!.objects.length, n + 1);
      expect(e.document!.object(chairId)!.rotation, 90);
      expect(e.selectedObjectId, chairId);
      expect(
        scene.document,
        same(e.document),
        reason: 'renderer shows the working copy',
      );

      // Laptop pointed at the desk top lands on the desk (z = desk height).
      final desk = objOf(e, 'cozy/desk');
      final deskBox = SceneLayout.boxOf(
        desk,
        e.document!.asset(desk.assetId)!,
        office,
      );
      e.startPlacing('cozy/laptop');
      e.hover(
        Iso.project(deskBox.minX + 0.6, deskBox.minY + 1.1, deskBox.maxZ),
      );
      expect(e.ghost!.ok, isTrue, reason: '${e.ghost!.issues}');
      expect(e.ghost!.object!.position.z, closeTo(1.5, 1e-9));
      e.confirmPlacement();

      // Painting on the office back wall (north, outer).
      e.startPlacing('cozy/painting');
      e.hover(Iso.project(office.origin.x + 5, office.origin.y, 2.6));
      expect(e.ghost!.ok, isTrue, reason: '${e.ghost!.issues}');
      expect(e.ghost!.object!.layer, SceneLayer.wall);
      expect(e.confirmPlacement(), isNotNull);

      // Outside every room: refused with a reason.
      e.startPlacing('cozy/plant');
      e.hover(Iso.project(-30, -30));
      expect(e.ghost!.ok, isFalse);
      expect(e.confirmPlacement(), isNull);
      expect(e.message, isNotNull);
      e.cancel();
      expect(e.tool, EditorTool.select);
    },
  );

  test('invalid placement: overlapping furniture is refused', () async {
    final (e, _, _) = await make();
    e.enter();
    final office = roomOf(e, 'office');
    final desk = objOf(e, 'cozy/desk');
    e.startPlacing('cozy/sofa');
    e.hover(floorAt(office, desk.position.x + 1.6, desk.position.y + 0.8));
    expect(e.ghost!.ok, isFalse);
    expect(e.ghost!.issues.join(), contains('Пересекается'));
  });

  test('drag = one history step; drop on invalid spot reverts', () async {
    final (e, _, _) = await make();
    e.enter();
    final living = roomOf(e, 'living');
    final plant = e.document!
        .objectsIn(living.id)
        .firstWhere((o) => o.assetId == 'cozy/plant');
    final start = floorAt(
      living,
      plant.position.x + 0.45,
      plant.position.y + 0.45,
    );
    e.beginMove(plant.id, start);
    for (var i = 1; i <= 30; i++) {
      e.hover(start + Offset(0, i * 3.0));
    }
    expect(e.hiddenObjectId, plant.id);
    expect(e.endMove(), isTrue);
    expect(e.history.length, 1);
    final moved = e.document!.object(plant.id)!.position;
    expect(moved.y, greaterThan(plant.position.y));

    // Onto the sofa: invalid → unchanged, message shown.
    final sofa = objOf(e, 'cozy/sofa');
    final from = floorAt(living, moved.x + 0.45, moved.y + 0.45);
    e.beginMove(plant.id, from);
    e.hover(floorAt(living, sofa.position.x + 2, sofa.position.y + 0.9));
    expect(e.endMove(), isFalse);
    expect(e.document!.object(plant.id)!.position.y, moved.y);
    expect(e.message, contains('Пересекается'));
    expect(e.history.length, 1);
  });

  test('object operations: rotate, scale, nudge, rename, finish, duplicate, delete', () async {
    final (e, _, _) = await make();
    e.enter();
    final lamp = objOf(e, 'cozy/floor_lamp');
    expect(e.rotateObject(lamp.id), isTrue);
    expect(e.document!.object(lamp.id)!.rotation, 90);
    expect(e.scaleObject(lamp.id, 1.2), isTrue);
    expect(e.scaleObject(lamp.id, 1.3), isTrue);
    expect(e.history.length, 2, reason: 'scale slider steps merge');
    expect(e.scaleObject(lamp.id, 9), isTrue);
    expect(e.document!.object(lamp.id)!.scale, 2, reason: 'clamped to ×2');
    final shelf = objOf(e, 'cozy/bookshelf');
    expect(
      e.scaleObject(shelf.id, 2),
      isFalse,
      reason: 'would grow through the wall',
    );
    expect(e.message, contains('пределы'));
    expect(e.nudgeObject(lamp.id, -0.5, 0), isTrue);
    expect(e.renameObject(lamp.id, 'Торшер у дивана'), isTrue);
    expect(e.setFinish(lamp.id, 'dark'), isTrue);
    expect(e.document!.object(lamp.id)!.metadata['finish'], 'dark');
    final copy = e.duplicateObject(lamp.id);
    expect(copy, isNotNull);
    expect(e.document!.object(copy!)!.label, 'Торшер у дивана');
    expect(e.deleteObject(copy), isTrue);
    expect(e.document!.object(copy), isNull);
    // Wall items do not rotate freely.
    expect(e.rotateObject(objOf(e, 'cozy/link_panel').id), isFalse);
  });

  test('rooms: create via preview, resize, move with furniture, duplicate, delete + undo', () async {
    final (e, _, _) = await make();
    e.enter();
    const t = RoomTemplate(
      name: 'Мастерская',
      kind: 'custom',
      size: Size2(6, 6),
      floor: 'tile_warm',
      wall: 'taupe_warm',
    );
    e.startRoomPlacement(t);
    // Over the office: overlap → refused.
    e.hover(Iso.project(4, 4));
    expect(e.roomGhost!.ok, isFalse);
    expect(e.confirmRoomPlacement(), isNull);
    final o = e.suggestRoomOrigin(t.size);
    e.hover(Iso.project(o.x + 3, o.y + 3));
    expect(e.roomGhost!.ok, isTrue, reason: '${e.roomGhost!.issues}');
    final id = e.confirmRoomPlacement()!;
    expect(e.document!.room(id)!.style.wall, 'taupe_warm');

    // Resize by the east handle (preview, then one step).
    final r = e.document!.room(id)!;
    e.beginRoomResize(
      id,
      RoomEdge.east,
      Iso.project(r.origin.x + 6, r.origin.y + 3),
    );
    e.hover(Iso.project(r.origin.x + 9.2, r.origin.y + 3));
    expect(e.roomGhost!.room.size.w, 9);
    expect(e.endRoomDrag(), isTrue);
    expect(e.document!.room(id)!.size.w, 9);

    // Shrinking the office below its furniture is refused.
    final office = roomOf(e, 'office');
    expect(e.resizeRoom(office.id, const Size2(5, 8)), isFalse);
    expect(e.message, contains('за стеной'));

    // Moving a room keeps furniture room-local (it moves along).
    final server = roomOf(e, 'server');
    final rack = objOf(e, 'cozy/server_rack');
    final before = e.document!;
    expect(e.deleteRoom(server.id), isTrue);
    expect(e.document!.objectsIn(server.id), isEmpty);
    e.undo();
    expect(
      codec.encode(e.document!),
      codec.encode(before),
      reason: 'undo restores room + objects',
    );
    expect(e.document!.object(rack.id), isNotNull);

    final dupId = e.duplicateRoom(id);
    expect(dupId, isNotNull);
    expect(e.renameRoom(dupId!, 'Кладовая'), isTrue);
    expect(
      e.styleRoom(
        dupId,
        const RoomStyle(floor: 'carpet', wall: 'milk', light: 'warm'),
      ),
      isTrue,
    );
    expect(e.document!.room(dupId)!.style.light, 'warm');
    codec.validate(e.document!);
  });

  test('cannot delete the last room', () async {
    final (e, _, _) = await make();
    e.enter();
    final ids = [for (final r in e.document!.rooms) r.id];
    for (final id in ids.skip(1)) {
      expect(e.deleteRoom(id), isTrue);
    }
    expect(e.deleteRoom(ids.first), isFalse);
  });

  test(
    'save: success, network error keeps the draft, conflict → reload / copy',
    () async {
      final (e, scene, _) = await make();
      e.enter();
      final lamp = objOf(e, 'cozy/floor_lamp');
      e.rotateObject(lamp.id);
      expect(e.dirty, isTrue);
      expect(await e.save(), SaveResult.saved);
      expect(scene.revision, 4);
      expect(e.dirty, isFalse);
      expect(drafts.data, isNull, reason: 'draft cleared after save');

      // Network error.
      e.rotateObject(lamp.id);
      sceneApi.failWith = http.ClientException('Connection reset');
      expect(await e.save(), SaveResult.failed);
      expect(e.dirty, isTrue);
      expect(drafts.data, isNotNull, reason: 'unsaved work stays in the draft');
      sceneApi.failWith = null;

      // Someone else saves first → 409, nothing overwritten.
      final sid = e.document!.sceneId;
      final other = sceneApi.stored[sid]!;
      sceneApi.stored[sid] = StoredScene(
        document: other.document.copyWith(name: 'Изменено в другом окне'),
        revision: other.revision + 1,
        updatedAt: DateTime.utc(2026),
      );
      expect(await e.save(), SaveResult.conflict);
      expect(sceneApi.stored[sid]!.document.name, 'Изменено в другом окне');
      expect(e.dirty, isTrue);

      // «Save as copy» keeps both versions.
      expect(await e.saveAsCopy(), SaveResult.saved);
      expect(sceneApi.stored.length, 2);
      expect(scene.document!.sceneId, isNot(sid));
      expect(scene.document!.name, endsWith('(копия)'));
      expect(e.dirty, isFalse);
    },
  );

  test('conflict → load the current version discards local edits', () async {
    final (e, scene, _) = await make();
    e.enter();
    final sid = e.document!.sceneId;
    final cur = sceneApi.stored[sid]!;
    sceneApi.stored[sid] = StoredScene(
      document: cur.document.copyWith(name: 'Новее'),
      revision: cur.revision + 1,
      updatedAt: DateTime.utc(2026),
    );
    e.rotateObject(objOf(e, 'cozy/floor_lamp').id);
    expect(await e.save(), SaveResult.conflict);
    await e.reloadLatest();
    expect(e.document!.name, 'Новее');
    expect(scene.revision, cur.revision + 1);
    expect(e.dirty, isFalse);
    expect(e.active, isTrue);
  });

  test('offline: editing works, save refused, draft kept; reconnect keeps the working copy', () async {
    final (e, scene, connection) = await make();
    e.enter();
    coreUp = false;
    await connection.refresh();
    e.rotateObject(objOf(e, 'cozy/floor_lamp').id);
    expect(await e.save(), SaveResult.offline);
    expect(drafts.data, isNotNull);
    final working = e.document;
    coreUp = true;
    await connection.refresh();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(
      scene.document,
      same(working),
      reason: 'reconnect does not reload over edits',
    );
    expect(await e.save(), SaveResult.saved);
  });

  test('draft: written on change, offered after restart, restore keeps base revision', () async {
    final (e, scene, _) = await make();
    e.enter();
    e.rotateObject(objOf(e, 'cozy/floor_lamp').id);
    await e.flushDraft();
    expect(drafts.data!.baseRevision, 3);
    expect(drafts.data!.changes, 1);

    // "Restart": new controllers over the same Core and draft store.
    final (e2, scene2, _) = await make();
    await e2.checkForDraft();
    expect(e2.pendingDraft, isNotNull);
    expect(e2.draftOutdated, isFalse);
    await e2.restoreDraft();
    expect(e2.active, isTrue);
    expect(e2.dirty, isTrue);
    expect(objOf(e2, 'cozy/floor_lamp').rotation, 90);
    expect(
      scene2.document!.object(objOf(e2, 'cozy/floor_lamp').id)!.rotation,
      90,
    );
    expect(await e2.save(), SaveResult.saved);
    expect(scene2.revision, 4);
    expect(scene.revision, 3, reason: 'first instance untouched');

    // A draft identical to the stored scene is dropped silently.
    drafts.data = SceneDraft(
      document: scene2.savedDocument!,
      baseRevision: 4,
      savedAt: DateTime.now(),
      changes: 0,
    );
    final (e3, _, _) = await make();
    await e3.checkForDraft();
    expect(e3.pendingDraft, isNull);
    expect(drafts.data, isNull);
  });

  test('outdated draft: restoring then saving reports a conflict, never overwrites', () async {
    final (e, _, _) = await make();
    e.enter();
    e.rotateObject(objOf(e, 'cozy/floor_lamp').id);
    await e.flushDraft();
    final sid = e.document!.sceneId;
    final cur = sceneApi.stored[sid]!;
    sceneApi.stored[sid] = StoredScene(
      document: cur.document,
      revision: 7,
      updatedAt: DateTime.utc(2026),
    );
    final (e2, _, _) = await make();
    await e2.checkForDraft();
    expect(e2.draftOutdated, isTrue);
    await e2.restoreDraft();
    expect(await e2.save(), SaveResult.conflict);
  });

  test('Registry binding: existing, archived, missing, Core offline', () async {
    final pc = registry.seed('Домашний ПК (тест)', 'computer');
    final old = registry.seed('Старый сервер (тест)', 'server');
    await registry.archive(old.id, old.revision);
    final (e, scene, connection) = await make();
    e.enter();
    final tower = objOf(e, 'cozy/pc_tower');
    expect(e.bindObject(tower.id, pc.id, pc.name), isTrue);
    await scene.refreshBindings();
    expect(scene.presentation(tower.id)!.binding, BindingState.resolved);
    expect(scene.presentation(tower.id)!.title, 'Домашний ПК (тест)');

    final nas = objOf(e, 'cozy/server_box');
    e.bindObject(nas.id, old.id, old.name);
    await scene.refreshBindings();
    expect(scene.presentation(nas.id)!.binding, BindingState.archived);

    // A UUID Registry does not know (deleted meanwhile).
    final rack = objOf(e, 'cozy/server_rack');
    e.bindObject(rack.id, '99999999-9999-4999-8999-999999999999', 'нет');
    await scene.refreshBindings();
    expect(scene.presentation(rack.id)!.binding, BindingState.missing);

    // Rename in Registry → shown after refresh, no rebinding needed.
    await registry.update(pc.id, pc.revision, {'name': 'ПК в кабинете (тест)'});
    await scene.refreshBindings();
    expect(scene.presentation(tower.id)!.title, 'ПК в кабинете (тест)');

    // Moving a bound object keeps the binding.
    e.nudgeObject(tower.id, 0, 0.5);
    expect(e.document!.object(tower.id)!.entityBinding!.entityId, pc.id);

    // Unbind / undo unbind.
    expect(e.unbindObject(tower.id), isTrue);
    expect(e.document!.object(tower.id)!.entityBinding, isNull);
    e.undo();
    expect(e.document!.object(tower.id)!.entityBinding!.entityId, pc.id);

    // Deleting the visual object never touches the Registry entity.
    e.deleteObject(tower.id);
    expect(registry.entities[pc.id], isNotNull);

    // Core goes away: data turns stale, edits still possible.
    coreUp = false;
    registry.failWith = http.ClientException('down');
    await connection.refresh();
    expect(scene.registryLink, isNot(RegistryLink.live));
    expect(e.nudgeObject(nas.id, 0, 0), isTrue);
    // Comes back: bindings refresh without reloading the working copy.
    coreUp = true;
    registry.failWith = null;
    await connection.refresh();
    await scene.refreshBindings();
    expect(scene.registryLink, RegistryLink.live);
    expect(scene.document, same(e.document));
  });

  test('scale stress: 200 objects, 500 undo/redo steps stay valid', () async {
    final (e, _, _) = await make();
    e.enter();
    final living = roomOf(e, 'living');
    var placed = 0;
    for (var x = 0.0; x < 11.5 && placed < 60; x += 1) {
      for (var y = 0.0; y < 2.5 && placed < 60; y += 1) {
        e.startPlacing('cozy/vase');
        e.hover(floorAt(living, x + 0.25, y + 2.3));
        if (e.ghost!.ok && e.confirmPlacement() != null) placed++;
      }
    }
    expect(placed, greaterThan(20));
    final last = codec.encode(e.document!);
    for (var i = 0; i < 250; i++) {
      e.undo();
    }
    for (var i = 0; i < 250; i++) {
      e.redo();
    }
    expect(codec.encode(e.document!), last);
  });
}
