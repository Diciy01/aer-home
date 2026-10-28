import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;

import '../../core_api/core_client.dart';
import '../binding/scene_binding.dart';
import '../model/scene_codec.dart';
import '../model/scene_document.dart';

/// A scene as stored by Core.
class StoredScene {
  const StoredScene({
    required this.document,
    required this.revision,
    required this.updatedAt,
  });
  final SceneDocument document;
  final int revision;
  final DateTime updatedAt;
}

class SceneSummary {
  const SceneSummary({
    required this.id,
    required this.name,
    required this.revision,
    required this.demo,
  });
  final String id;
  final String name;
  final int revision;
  final bool demo;
}

/// Canonical scene storage in Core (`/api/v1/scenes`).
abstract interface class SceneApi {
  Future<List<SceneSummary>> list();
  Future<StoredScene> get(String id);
  Future<StoredScene> create(SceneDocument doc);
  Future<StoredScene> replace(String id, int revision, SceneDocument doc);
}

class HttpSceneApi implements SceneApi {
  HttpSceneApi(this._client, [this._codec = const SceneCodec()]);
  final CoreClient _client;
  final SceneCodec _codec;

  StoredScene _record(Object? data) {
    final m = data as Map<String, dynamic>;
    return StoredScene(
      document: _codec.decode(m['document']),
      revision: m['revision'] as int,
      updatedAt: DateTime.parse(m['updatedAt'] as String),
    );
  }

  @override
  Future<List<SceneSummary>> list() async => [
    for (final s in await _client.request('GET', '/scenes') as List<dynamic>)
      SceneSummary(
        id: (s as Map<String, dynamic>)['id'] as String,
        name: s['name'] as String,
        revision: s['revision'] as int,
        demo: s['demo'] as bool,
      ),
  ];

  @override
  Future<StoredScene> get(String id) async =>
      _record(await _client.request('GET', '/scenes/$id'));

  @override
  Future<StoredScene> create(SceneDocument doc) async =>
      _record(await _client.request('POST', '/scenes', body: doc.toJson()));

  @override
  Future<StoredScene> replace(
    String id,
    int revision,
    SceneDocument doc,
  ) async => _record(
    await _client.request(
      'PUT',
      '/scenes/$id',
      body: {'revision': revision, 'document': doc.toJson()},
    ),
  );
}

/// What the client keeps locally so the house is visible without Core.
class CachedScene {
  const CachedScene({
    required this.document,
    required this.revision,
    required this.savedAt,
    required this.snapshots,
  });

  final SceneDocument document;

  /// Core revision the cache was taken from (null for an unsaved demo).
  final int? revision;
  final DateTime savedAt;
  final Map<String, EntitySnapshot> snapshots;
}

/// Local, non-canonical cache: `<data>/aer-home/desktop/scene-cache.json`.
/// Writes are atomic (temp file + rename); a corrupt file is set aside, never
/// silently overwritten with nothing.
class SceneCache {
  SceneCache(this.file, [this._codec = const SceneCodec()]);

  factory SceneCache.defaultLocation([Map<String, String>? env]) {
    final e = env ?? Platform.environment;
    final sep = Platform.pathSeparator;
    final override = e['AER_DESKTOP_DATA_DIR'];
    final String dir;
    if (override != null && override.isNotEmpty) {
      dir = override;
    } else if (Platform.isWindows) {
      dir = [e['LOCALAPPDATA'] ?? '.', 'aer-home', 'desktop'].join(sep);
    } else {
      final xdg = e['XDG_DATA_HOME'];
      dir = xdg != null && xdg.isNotEmpty
          ? [xdg, 'aer-home', 'desktop'].join(sep)
          : [
              e['HOME'] ?? '.',
              '.local',
              'share',
              'aer-home',
              'desktop',
            ].join(sep);
    }
    return SceneCache(File('$dir${sep}scene-cache.json'));
  }

  final File file;
  final SceneCodec _codec;

  /// Last load problem (for diagnostics), e.g. a corrupt cache that was moved aside.
  String? lastIssue;

  Future<CachedScene?> read() async {
    if (!await file.exists()) return null;
    try {
      final m = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      if (m['cacheVersion'] != 1) {
        throw const FormatException('unknown cache version');
      }
      return CachedScene(
        document: _codec.decode(m['document']),
        revision: m['revision'] as int?,
        savedAt: DateTime.parse(m['savedAt'] as String),
        snapshots: {
          for (final s in (m['snapshots'] as List<dynamic>))
            (s as Map<String, dynamic>)['id'] as String:
                EntitySnapshot.fromJson(s),
        },
      );
    } catch (e) {
      final aside = File(
        '${file.path}.corrupt-${DateTime.now().millisecondsSinceEpoch}',
      );
      try {
        await file.rename(aside.path);
      } catch (_) {}
      await pruneCorruptCopies(file, keep: 3);
      lastIssue =
          'Локальная копия сцены повреждена и отложена в ${aside.path}: $e';
      return null;
    }
  }

  Future<void> _pending = Future.value();

  /// Completes when every write started so far has finished.
  Future<void> get settled => _pending;

  /// Writes are serialized: load and binding refresh may both save at once,
  /// and on Windows a second writer cannot open or rename the shared temp
  /// file while the first still holds it.
  Future<void> write(
    SceneDocument doc,
    int? revision,
    Map<String, EntitySnapshot> snapshots,
  ) {
    final next = _pending.then((_) => _write(doc, revision, snapshots));
    _pending = next.catchError((_) {});
    return next;
  }

  Future<void> _write(
    SceneDocument doc,
    int? revision,
    Map<String, EntitySnapshot> snapshots,
  ) async {
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(
      jsonEncode({
        'cacheVersion': 1,
        'savedAt': DateTime.now().toUtc().toIso8601String(),
        'revision': revision,
        'document': doc.toJson(),
        'snapshots': [for (final s in snapshots.values) s.toJson()],
      }),
      flush: true,
    );
    await tmp.rename(file.path);
  }
}

/// The bundled demo layout (identical to examples/home.scene.json).
Future<SceneDocument> loadBundledDemo([
  SceneCodec codec = const SceneCodec(),
]) async => codec.decodeString(
  await rootBundle.loadString('assets/scenes/demo_home.scene.json'),
);

/// Keeps only the newest [keep] `<file>.corrupt-<ms>` copies next to [file],
/// so repeated corruption cannot fill the disk with backups.
Future<void> pruneCorruptCopies(File file, {int keep = 3}) async {
  final dir = file.parent;
  if (!await dir.exists()) return;
  final prefix = '${file.uri.pathSegments.last}.corrupt-';
  final aside = <File>[
    await for (final e in dir.list())
      if (e is File && e.uri.pathSegments.last.startsWith(prefix)) e,
  ]..sort((a, b) => b.path.compareTo(a.path));
  for (final f in aside.skip(keep)) {
    try {
      await f.delete();
    } on FileSystemException {
      // Best effort.
    }
  }
}
