// TEST DOUBLES ONLY — in-memory Core scene storage and helpers.
import 'dart:io';

import 'package:aer_home_desktop/src/core_api/core_client.dart';
import 'package:aer_home_desktop/src/core_api/registry_api.dart';
import 'package:aer_home_desktop/src/scene/binding/scene_binding.dart';
import 'package:aer_home_desktop/src/scene/editor/draft_store.dart';
import 'package:aer_home_desktop/src/scene/model/scene_codec.dart';
import 'package:aer_home_desktop/src/scene/model/scene_document.dart';
import 'package:aer_home_desktop/src/scene/repository/scene_repository.dart';
import 'package:aer_home_desktop/src/scene/scene_controller.dart';
import 'package:aer_home_desktop/src/state/connection_controller.dart';

/// The shared reference document (repository root examples/).
final exampleFile = File('../../examples/home.scene.json');
SceneDocument exampleScene() =>
    const SceneCodec().decodeString(exampleFile.readAsStringSync());

class FakeSceneApi implements SceneApi {
  final Map<String, StoredScene> stored = {};
  Object? failWith;
  int creates = 0;

  void _guard() {
    if (failWith != null) throw failWith!;
  }

  @override
  Future<List<SceneSummary>> list() async {
    _guard();
    return [
      for (final s in stored.values)
        SceneSummary(
          id: s.document.sceneId,
          name: s.document.name,
          revision: s.revision,
          demo: s.document.demo,
        ),
    ];
  }

  @override
  Future<StoredScene> get(String id) async {
    _guard();
    final s = stored[id];
    if (s == null) {
      throw const CoreApiException(
        statusCode: 404,
        code: 'NOT_FOUND',
        message: 'Сцена не найдена',
      );
    }
    return s;
  }

  @override
  Future<StoredScene> create(SceneDocument doc) async {
    _guard();
    creates++;
    const SceneCodec().validate(doc);
    return stored[doc.sceneId] = StoredScene(
      document: doc,
      revision: 1,
      updatedAt: DateTime.utc(2026, 10, 26),
    );
  }

  @override
  Future<StoredScene> replace(
    String id,
    int revision,
    SceneDocument doc,
  ) async {
    _guard();
    final cur = stored[id]!;
    if (cur.revision != revision) {
      throw const CoreApiException(
        statusCode: 409,
        code: 'CONFLICT',
        message: 'stale',
        details: {'reason': 'revision_mismatch'},
      );
    }
    return stored[id] = StoredScene(
      document: doc,
      revision: revision + 1,
      updatedAt: DateTime.utc(2026, 10, 26),
    );
  }
}

/// In-memory cache for widget tests (real file I/O cannot complete inside
/// the fake-async test zone).
class MemorySceneCache extends SceneCache {
  MemorySceneCache() : super(File('/nonexistent/scene-cache.json'));
  CachedScene? data;

  @override
  Future<CachedScene?> read() async => data;

  @override
  Future<void> write(
    SceneDocument doc,
    int? revision,
    Map<String, EntitySnapshot> snapshots,
  ) async {
    data = CachedScene(
      document: doc,
      revision: revision,
      savedAt: DateTime.now(),
      snapshots: snapshots,
    );
  }
}

SceneController sceneControllerFor({
  required ConnectionController connection,
  required RegistryApi registry,
  FakeSceneApi? api,
  Directory? dataDir,
  SceneDraftStore? drafts,
}) => SceneController(
  sceneApi: api ?? FakeSceneApi(),
  registryApi: registry,
  connectionController: connection,
  sceneCache: dataDir == null
      ? MemorySceneCache()
      : SceneCache(File('${dataDir.path}/scene-cache.json')),
  bundledLoader: () async => exampleScene(),
  draftStore:
      drafts ??
      (dataDir == null
          ? MemoryDraftStore()
          : SceneDraftStore(File('${dataDir.path}/scene-draft.json'))),
);
