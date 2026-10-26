import 'dart:io';

import 'package:aer_home_desktop/src/core_api/core_client.dart';
import 'package:aer_home_desktop/src/scene/binding/scene_binding.dart';
import 'package:aer_home_desktop/src/scene/model/scene_document.dart';
import 'package:aer_home_desktop/src/scene/model/scene_edit.dart';
import 'package:aer_home_desktop/src/scene/repository/scene_repository.dart';
import 'package:aer_home_desktop/src/scene/scene_controller.dart';
import 'package:aer_home_desktop/src/state/connection_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../fake_registry_api.dart';
import '../fixtures.dart';
import 'scene_fixtures.dart';

void main() {
  late Directory dir;
  late FakeSceneApi sceneApi;
  late FakeRegistryApi registry;
  var coreUp = true;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('aer-scene-test-');
    sceneApi = FakeSceneApi();
    registry = FakeRegistryApi();
    coreUp = true;
  });
  tearDown(() => dir.deleteSync(recursive: true));

  Future<(SceneController, ConnectionController)> make() async {
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
    final c = sceneControllerFor(
      connection: connection,
      registry: registry,
      api: sceneApi,
      dataDir: dir,
    );
    addTearDown(c.dispose);
    return (c, connection);
  }

  test('empty Core → bundled demo, explicitly unsaved', () async {
    final (c, _) = await make();
    await c.load();
    expect(c.source, SceneSource.bundled);
    expect(c.document!.demo, isTrue);
    expect(sceneApi.creates, 0, reason: 'nothing is written without the user');
    expect(c.layout!.rooms, hasLength(5));
  });

  test('save stores the demo in Core; next load comes from Core', () async {
    final (c, _) = await make();
    await c.load();
    await c.save();
    expect(c.source, SceneSource.core);
    expect(c.revision, 1);
    final (c2, _) = await make();
    await c2.load();
    expect(c2.source, SceneSource.core);
  });

  test(
    'Core unreachable → offline cache; corrupt cache is set aside',
    () async {
      final (c, _) = await make();
      await c.load();
      await c.save(); // writes cache
      coreUp = false;
      final (offline, _) = await make();
      await offline.load();
      expect(offline.source, SceneSource.cache);
      expect(offline.document!.sceneId, c.document!.sceneId);

      File('${dir.path}/scene-cache.json').writeAsStringSync('{broken');
      final (broken, _) = await make();
      await broken.load();
      expect(broken.source, SceneSource.bundled, reason: 'still shows a house');
      expect(broken.cacheIssue, contains('повреждена'));
      expect(dir.listSync().any((f) => f.path.contains('.corrupt-')), isTrue);
    },
  );

  test('bindings: existing, missing and archived entities', () async {
    final pc = registry.seed('Основной ПК', 'computer');
    final old = registry.seed('Старый сервер', 'server');
    await registry.archive(old.id, 1);
    const ghost = '66666666-6666-4666-8666-666666666666';
    var doc = exampleScene();
    const edits = SceneEdits();
    final objs = doc.objects
        .where((o) => o.layer == SceneLayer.object)
        .toList();
    doc = edits.bindEntity(doc, objs[0].id, pc.id);
    doc = edits.bindEntity(doc, objs[1].id, old.id);
    doc = edits.bindEntity(doc, objs[2].id, ghost);
    sceneApi.stored[doc.sceneId] = StoredScene(
      document: doc,
      revision: 3,
      updatedAt: DateTime.utc(2026),
    );

    final (c, _) = await make();
    await c.load();
    expect(c.registryLink, RegistryLink.live);
    expect(c.presentation(objs[0].id)!.title, 'Основной ПК');
    expect(
      c.presentation(objs[0].id)!.status,
      SceneStatus.unknown,
      reason: 'no Monitoring yet',
    );
    expect(c.presentation(objs[1].id)!.status, SceneStatus.archived);
    expect(c.presentation(objs[2].id)!.binding, BindingState.missing);
  });

  test(
    'Registry outage keeps last known names as stale; reconnection refreshes',
    () async {
      final pc = registry.seed('Основной ПК', 'computer');
      final doc = const SceneEdits().bindEntity(
        exampleScene(),
        exampleScene().objects.first.id,
        pc.id,
      );
      sceneApi.stored[doc.sceneId] = StoredScene(
        document: doc,
        revision: 1,
        updatedAt: DateTime.utc(2026),
      );
      final (c, connection) = await make();
      await c.load();
      final id = doc.objects.first.id;
      expect(c.presentation(id)!.stale, isFalse);

      coreUp = false;
      registry.failWith = const CoreUnreachable('down');
      await connection.refresh();
      expect(c.presentation(id)!.stale, isTrue);
      expect(c.presentation(id)!.title, 'Основной ПК');

      coreUp = true;
      registry.failWith = null;
      await connection.refresh();
      await Future<void>.delayed(Duration.zero);
      await c.load();
      expect(c.presentation(id)!.stale, isFalse);
    },
  );

  test(
    'Core without any scene and no network: still renders bundled layout',
    () async {
      coreUp = false;
      final (c, _) = await make();
      await c.load();
      expect(c.source, SceneSource.bundled);
      expect(c.layout, isNotNull);
      expect(c.canSave, isFalse);
    },
  );
}
