import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core_api/core_client.dart';
import '../core_api/registry_api.dart';
import '../core_api/registry_models.dart';
import '../state/connection_controller.dart';
import 'binding/scene_binding.dart';
import 'editor/draft_store.dart';
import 'geometry/scene_layout.dart';
import 'model/scene_document.dart';
import 'repository/scene_repository.dart';

/// Where the displayed scene came from.
enum SceneSource {
  /// Nothing loaded yet.
  none,

  /// Canonical copy from Core.
  core,

  /// Local offline copy (Core unreachable).
  cache,

  /// Bundled demo layout, not saved anywhere yet.
  bundled,
}

/// Loads the scene (Core → local cache → bundled demo), resolves entity
/// bindings through Registry and keeps the offline cache up to date.
/// Scene never sends commands and never computes device health.
class SceneController extends ChangeNotifier {
  SceneController({
    required SceneApi sceneApi,
    required RegistryApi registryApi,
    required ConnectionController connectionController,
    required SceneCache sceneCache,
    required Future<SceneDocument> Function() bundledLoader,
    String Function(String type)? typeLabel,
    String Function(String capability)? capabilityLabel,
    SceneDraftStore? draftStore,
    LiveStatus? Function(String entityId)? liveStatus,
    this._liveChanges,
  }) : _api = sceneApi,
       _live = liveStatus,
       drafts = draftStore ?? SceneDraftStore.besideCache(sceneCache.file),
       _registry = registryApi,
       _connection = connectionController,
       _cache = sceneCache,
       _bundled = bundledLoader,
       _typeLabel = typeLabel ?? ((t) => t),
       _capabilityLabel = capabilityLabel ?? ((c) => c) {
    _connection.addListener(_onConnection);
    _liveChanges?.addListener(_onLive);
    _wasOnline = _connection.canAct;
  }

  final SceneApi _api;
  final LiveStatus? Function(String)? _live;
  final Listenable? _liveChanges;

  /// Local editor draft storage (next to the offline cache).
  final SceneDraftStore drafts;
  final RegistryApi _registry;
  final ConnectionController _connection;
  final SceneCache _cache;
  final Future<SceneDocument> Function() _bundled;
  final String Function(String) _typeLabel;
  final String Function(String) _capabilityLabel;

  SceneDocument? _document;

  /// The document as last loaded or saved (what Core/cache hold). Differs
  /// from [_document] while the editor shows a working copy.
  SceneDocument? _saved;
  SceneLayout? _layout;
  bool _editing = false;
  String? _preferredSceneId;
  SceneSource _source = SceneSource.none;
  int? _revision;
  DateTime? _cachedAt;
  bool _loading = false;
  bool _saving = false;
  Object? _error;
  Map<String, EntitySnapshot> _snapshots = {};
  RegistryLink _link = RegistryLink.loading;
  Map<String, ObjectPresentation> _presentations = {};
  bool _wasOnline = false;
  bool _disposed = false;
  Future<void>? _inFlight;

  SceneDocument? get document => _document;
  SceneDocument? get savedDocument => _saved;

  /// True while the editor owns the displayed document: reconnects refresh
  /// bindings but never replace the working copy.
  bool get editing => _editing;
  SceneLayout? get layout => _layout;
  SceneSource get source => _source;
  int? get revision => _revision;
  DateTime? get cachedAt => _cachedAt;
  bool get loading => _loading;
  bool get saving => _saving;
  Object? get error => _error;
  RegistryLink get registryLink => _link;
  Map<String, ObjectPresentation> get presentations => _presentations;
  String? get cacheIssue => _cache.lastIssue;

  /// True when the scene can be saved to Core right now.
  bool get canSave => _connection.canAct && _document != null && !_saving;

  ObjectPresentation? presentation(String objectId) => _presentations[objectId];

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _onConnection() {
    final online = _connection.canAct;
    final cameBack = online && !_wasOnline;
    _wasOnline = online;
    if (!online) {
      if (_link == RegistryLink.live) {
        _link = RegistryLink.stale;
        _recompute();
      }
      return;
    }
    if (cameBack && _editing) {
      unawaited(refreshBindings());
      return;
    }
    if (cameBack &&
        (_source != SceneSource.core || _link != RegistryLink.live)) {
      unawaited(load());
    }
  }

  /// Loads the best available scene. Concurrent calls share one load.
  Future<void> load() =>
      _inFlight ??= _load().whenComplete(() => _inFlight = null);

  Future<void> _load() async {
    _loading = true;
    _error = null;
    _notify();
    try {
      var loaded = false;
      if (_connection.canAct) {
        try {
          final scenes = await _api.list();
          _preferredSceneId ??=
              _document?.sceneId ?? (await _cache.read())?.document.sceneId;
          if (scenes.isNotEmpty) {
            final pick =
                scenes.where((s) => s.id == _preferredSceneId).firstOrNull ??
                scenes.first;
            final stored = await _api.get(pick.id);
            _install(
              stored.document,
              SceneSource.core,
              revision: stored.revision,
            );
          } else {
            _install(await _bundled(), SceneSource.bundled);
          }
          loaded = true;
        } catch (e) {
          _error = e;
        }
      }
      if (!loaded) {
        final cached = await _cache.read();
        if (cached != null) {
          _snapshots = cached.snapshots;
          _cachedAt = cached.savedAt;
          _install(
            cached.document,
            SceneSource.cache,
            revision: cached.revision,
          );
          _link = _snapshots.isEmpty
              ? RegistryLink.unavailable
              : RegistryLink.stale;
        } else if (_document == null) {
          _install(await _bundled(), SceneSource.bundled);
          _link = RegistryLink.unavailable;
        }
      }
    } catch (e) {
      _error = e;
    } finally {
      _loading = false;
      _recompute();
    }
    if (_connection.canAct) await refreshBindings();
  }

  void _install(SceneDocument doc, SceneSource source, {int? revision}) {
    _document = doc;
    _saved = doc;
    _preferredSceneId = doc.sceneId;
    _layout = SceneLayout.build(doc);
    _source = source;
    _revision = revision;
    if (doc.boundEntityIds.isEmpty) _link = RegistryLink.live;
  }

  /// Monitoring polls every few seconds: rebuild the house picture only
  /// when something visible actually changed.
  void _onLive() {
    final before = _signature(_presentations);
    final keep = _presentations;
    _recompute(silent: true);
    if (_signature(_presentations) == before) {
      _presentations = keep;
      return;
    }
    _notify();
  }

  static String _signature(Map<String, ObjectPresentation> p) => [
    for (final e in p.entries)
      '${e.key}:${e.value.status?.name}:${e.value.stale}:${e.value.title}:${e.value.live?.openIncidents}:${e.value.note}',
  ].join('|');

  void _recompute({bool silent = false}) {
    final doc = _document;
    if (doc == null) {
      _presentations = {};
    } else {
      _presentations = {
        for (final o in doc.objects)
          o.id: presentObject(
            o,
            doc.asset(o.assetId),
            _snapshots,
            _link,
            o.entityBinding == null
                ? null
                : _live?.call(o.entityBinding!.entityId),
          ),
      };
    }
    if (!silent) _notify();
  }

  /// Re-reads bound entities from Registry. On failure the last known
  /// snapshots stay and are shown as stale.
  Future<void> refreshBindings() async {
    final doc = _document;
    if (doc == null) return;
    final ids = doc.boundEntityIds;
    if (ids.isEmpty) {
      _link = RegistryLink.live;
      _recompute();
      return;
    }
    if (_snapshots.isEmpty) {
      _link = RegistryLink.loading;
      _recompute();
    }
    final fresh = <String, EntitySnapshot>{};
    try {
      for (final id in ids) {
        try {
          fresh[id] = _snapshotOf(await _registry.get(id));
        } on CoreApiException catch (e) {
          if (!e.isNotFound) rethrow;
          fresh[id] = EntitySnapshot.missing(id, DateTime.now());
        }
      }
      _snapshots = fresh;
      _link = RegistryLink.live;
      await _writeCache();
    } catch (_) {
      _link = _snapshots.isEmpty
          ? RegistryLink.unavailable
          : RegistryLink.stale;
    }
    _recompute();
  }

  EntitySnapshot _snapshotOf(RegistryEntity e) => EntitySnapshot(
    id: e.id,
    found: true,
    name: e.name,
    type: e.type,
    typeLabel: _typeLabel(e.type),
    archived: e.archived,
    capabilities: e.capabilities,
    capabilityLabels: {for (final c in e.capabilities) c: _capabilityLabel(c)},
    fetchedAt: DateTime.now(),
  );

  Future<void> _writeCache() async {
    // Only saved states go to the offline cache, never an editor draft.
    final doc = _saved;
    if (doc == null || _source == SceneSource.cache) return;
    try {
      await _cache.write(doc, _revision, _snapshots);
      _cachedAt = DateTime.now();
    } catch (_) {
      // Cache is a convenience; failing to write it must not break the view.
    }
  }

  /// Shows an editor working copy. Nothing is persisted; new bindings are
  /// resolved through Registry when Core is reachable.
  void previewDocument(SceneDocument doc) {
    _document = doc;
    _layout = SceneLayout.build(doc);
    final unknown = doc.boundEntityIds.difference(_snapshots.keys.toSet());
    _recompute();
    if (unknown.isNotEmpty && _connection.canAct) unawaited(refreshBindings());
  }

  void beginEditing() {
    _editing = true;
    _notify();
  }

  /// Leaves edit mode; with [restoreSaved] the last saved document is shown
  /// again (unsaved edits discarded).
  void endEditing({bool restoreSaved = false}) {
    _editing = false;
    final saved = _saved;
    if (restoreSaved && saved != null && !identical(saved, _document)) {
      _document = saved;
      _layout = SceneLayout.build(saved);
      _recompute();
    } else {
      _notify();
    }
  }

  /// Stores the current document as a new scene (conflict resolution «save
  /// as a separate copy»); the copy becomes the active scene.
  Future<void> saveAsCopy({required String newSceneId}) async {
    final doc = _document;
    if (doc == null) return;
    final name = '${doc.name} (копия)';
    final copy = doc.copyWith(
      sceneId: newSceneId,
      name: name.runes.length > 120
          ? String.fromCharCodes(name.runes.take(120))
          : name,
    );
    _saving = true;
    _notify();
    try {
      final stored = await _api.create(copy);
      _install(stored.document, SceneSource.core, revision: stored.revision);
      await _writeCache();
    } finally {
      _saving = false;
      _recompute();
    }
  }

  /// Saves the current document to Core: creates it the first time (bundled
  /// demo), otherwise replaces it with optimistic locking. A stale revision
  /// fails with a CONFLICT [CoreApiException]; nothing is overwritten.
  /// [baseRevision] is the revision the edits started from (the editor
  /// passes it, e.g. for a restored draft); defaults to the loaded revision.
  Future<void> save({int? baseRevision}) async {
    final doc = _document;
    if (doc == null) return;
    final rev = baseRevision ?? _revision;
    _saving = true;
    _notify();
    try {
      final stored = _source != SceneSource.bundled && rev != null
          ? await _api.replace(doc.sceneId, rev, doc)
          : await _api.create(doc);
      _install(stored.document, SceneSource.core, revision: stored.revision);
      await _writeCache();
    } finally {
      _saving = false;
      _recompute();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _connection.removeListener(_onConnection);
    _liveChanges?.removeListener(_onLive);
    super.dispose();
  }
}
