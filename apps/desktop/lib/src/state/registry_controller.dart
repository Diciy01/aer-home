import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core_api/registry_api.dart';
import '../core_api/registry_models.dart';
import 'connection_controller.dart';

/// State of the Registry screen: catalog, current listing, selection.
///
/// Listing failures keep the previous items so the UI can show them as stale.
/// Mutations throw to the caller (dialogs show the error) and refresh state
/// on success.
class RegistryController extends ChangeNotifier {
  RegistryController(
    this._api,
    this._connection, {
    this.searchDebounce = const Duration(milliseconds: 300),
  }) {
    _connection.addListener(_onConnectionChanged);
  }

  final RegistryApi _api;
  final ConnectionController _connection;
  final Duration searchDebounce;

  RegistryCatalog? _catalog;
  List<RegistryEntity> _items = const [];
  int _total = 0;
  EntityQuery _query = const EntityQuery();
  bool _loading = false;
  bool _loadingMore = false;
  Object? _error;
  DateTime? _loadedAt;
  String? _selectedId;
  RegistryEntity? _selected;
  RegistryEntity? _selectedParent;
  List<RelationView> _relations = const [];
  bool _relationsLoading = false;
  Object? _relationsError;
  Timer? _debounce;
  int _generation = 0;
  bool _disposed = false;

  RegistryCatalog? get catalog => _catalog;
  List<RegistryEntity> get items => _items;
  int get total => _total;
  EntityQuery get query => _query;
  bool get loading => _loading;
  bool get loadingMore => _loadingMore;
  Object? get error => _error;
  DateTime? get loadedAt => _loadedAt;
  bool get hasMore => _items.length < _total;
  RegistryEntity? get selected => _selected;
  RegistryEntity? get selectedParent => _selectedParent;
  List<RelationView> get relations => _relations;
  bool get relationsLoading => _relationsLoading;
  Object? get relationsError => _relationsError;

  /// Changes are only allowed while Core is reachable and authorised.
  bool get canEdit => _connection.canAct && _catalog != null;

  /// True when shown data may be outdated (last load failed or Core is away).
  bool get isStale =>
      _loadedAt != null && (_error != null || !_connection.canAct);

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _onConnectionChanged() {
    // Core came back: reload what failed or was never loaded.
    if (_connection.canAct &&
        (_catalog == null || _error != null) &&
        !_loading) {
      unawaited(reload());
    } else {
      _notify();
    }
  }

  /// Loads the catalog (once) and the first page of the current query.
  Future<void> reload() async {
    final gen = ++_generation;
    _loading = true;
    _notify();
    try {
      _catalog ??= await _api.catalog();
      final page = await _api.list(_query.copyWith(offset: 0));
      if (gen != _generation) return;
      _items = page.items;
      _total = page.total;
      _error = null;
      _loadedAt = DateTime.now();
      if (_selectedId != null) {
        final fresh = page.items.where((e) => e.id == _selectedId);
        if (fresh.isNotEmpty) _selected = fresh.first;
      }
    } catch (e) {
      if (gen != _generation) return;
      _error = e;
    } finally {
      if (gen == _generation) {
        _loading = false;
        _notify();
      }
    }
  }

  Future<void> loadMore() async {
    if (_loadingMore || !hasMore) return;
    _loadingMore = true;
    _notify();
    try {
      final page = await _api.list(_query.copyWith(offset: _items.length));
      _items = [..._items, ...page.items];
      _total = page.total;
      _error = null;
    } catch (e) {
      _error = e;
    } finally {
      _loadingMore = false;
      _notify();
    }
  }

  /// Updates the search text; the listing reloads after a short pause.
  void setSearch(String text) {
    if (text == _query.text) return;
    _query = EntityQuery(
      text: text,
      type: _query.type,
      archived: _query.archived,
    );
    _debounce?.cancel();
    _debounce = Timer(searchDebounce, () => unawaited(reload()));
    _notify();
  }

  void setTypeFilter(String? type) {
    if (type == _query.type) return;
    _query = EntityQuery(
      text: _query.text,
      type: type,
      archived: _query.archived,
    );
    unawaited(reload());
  }

  void setArchivedView(bool archived) {
    if (archived == _query.archived) return;
    _query = EntityQuery(
      text: _query.text,
      type: _query.type,
      archived: archived,
    );
    clearSelection();
    unawaited(reload());
  }

  /// Selects an entity and loads its relations and parent.
  Future<void> select(RegistryEntity entity) async {
    _selectedId = entity.id;
    _selected = entity;
    _selectedParent = null;
    _relations = const [];
    _relationsError = null;
    _notify();
    await _loadSelectionDetails();
  }

  /// Loads an entity by id and selects it (used by the scene to open cards).
  Future<RegistryEntity> selectById(String id) async {
    final e = await _api.get(id);
    await select(e);
    return e;
  }

  void clearSelection() {
    _selectedId = null;
    _selected = null;
    _selectedParent = null;
    _relations = const [];
    _notify();
  }

  Future<void> _loadSelectionDetails() async {
    final entity = _selected;
    if (entity == null) return;
    _relationsLoading = true;
    _notify();
    try {
      final rels = await _api.relations(entity.id);
      final parent = entity.parentId == null
          ? null
          : await _api.get(entity.parentId!);
      if (_selectedId != entity.id) return;
      _relations = rels;
      _selectedParent = parent;
      _relationsError = null;
    } catch (e) {
      if (_selectedId == entity.id) _relationsError = e;
    } finally {
      if (_selectedId == entity.id) _relationsLoading = false;
      _notify();
    }
  }

  void _replace(RegistryEntity e) {
    final inView = e.archived == _query.archived;
    final index = _items.indexWhere((x) => x.id == e.id);
    if (index >= 0 && inView) {
      _items = [..._items]..[index] = e;
    } else if (index >= 0) {
      _items = [..._items]..removeAt(index);
      _total--;
    }
    if (_selectedId == e.id) _selected = e;
    _notify();
  }

  Future<RegistryEntity> create(EntityDraft draft) async {
    final e = await _api.create(draft);
    await reload();
    await select(e);
    return e;
  }

  Future<RegistryEntity> update(
    RegistryEntity entity,
    Map<String, Object?> changes,
  ) async {
    final e = await _api.update(entity.id, entity.revision, changes);
    _replace(e);
    await _loadSelectionDetails();
    return e;
  }

  /// Reloads one entity (e.g. after a revision conflict).
  Future<RegistryEntity> refreshEntity(String id) async {
    final e = await _api.get(id);
    _replace(e);
    return e;
  }

  Future<RegistryEntity> archive(RegistryEntity entity) async {
    final e = await _api.archive(entity.id, entity.revision);
    _replace(e);
    return e;
  }

  Future<RegistryEntity> restore(RegistryEntity entity) async {
    final e = await _api.restore(entity.id, entity.revision);
    _replace(e);
    return e;
  }

  Future<RegistryEntity> setCapabilities(
    RegistryEntity entity,
    List<String> capabilities,
  ) async {
    final e = await _api.setCapabilities(
      entity.id,
      entity.revision,
      capabilities,
    );
    _replace(e);
    return e;
  }

  Future<void> addRelation(
    RegistryEntity from,
    String kind,
    String targetId, {
    String label = '',
  }) async {
    await _api.addRelation(from.id, kind, targetId, label: label);
    await _loadSelectionDetails();
  }

  Future<void> deleteRelation(String relationId) async {
    await _api.deleteRelation(relationId);
    await _loadSelectionDetails();
  }

  /// Searches active entities for pickers (parent, relation target).
  Future<List<RegistryEntity>> searchActive(String text) async =>
      (await _api.list(EntityQuery(text: text, limit: 20))).items;

  @override
  void dispose() {
    _disposed = true;
    _debounce?.cancel();
    _connection.removeListener(_onConnectionChanged);
    super.dispose();
  }
}
