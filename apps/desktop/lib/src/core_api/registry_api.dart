import 'core_client.dart';
import 'registry_models.dart';

/// Registry operations used by the desktop client. Tests substitute an
/// in-memory implementation.
abstract interface class RegistryApi {
  Future<RegistryCatalog> catalog();
  Future<EntityPage> list(EntityQuery query);
  Future<RegistryEntity> get(String id);
  Future<RegistryEntity> create(EntityDraft draft);

  /// [changes] holds only the fields to change; null clears parentId/address.
  Future<RegistryEntity> update(
    String id,
    int revision,
    Map<String, Object?> changes,
  );
  Future<RegistryEntity> archive(String id, int revision);
  Future<RegistryEntity> restore(String id, int revision);
  Future<RegistryEntity> setCapabilities(
    String id,
    int revision,
    List<String> capabilities,
  );
  Future<List<RelationView>> relations(String id);
  Future<Relation> addRelation(
    String fromId,
    String kind,
    String targetId, {
    String label = '',
  });
  Future<void> deleteRelation(String relationId);
}

/// [RegistryApi] over the Core REST API.
class HttpRegistryApi implements RegistryApi {
  HttpRegistryApi(this._client);

  final CoreClient _client;

  Future<Map<String, dynamic>> _object(
    String method,
    String path, {
    Map<String, Object?>? query,
    Object? body,
  }) async =>
      await _client.request(method, path, query: query, body: body)
          as Map<String, dynamic>;

  Future<List<Map<String, dynamic>>> _list(String path) async => [
    for (final x in await _client.request('GET', path) as List<dynamic>)
      x as Map<String, dynamic>,
  ];

  @override
  Future<RegistryCatalog> catalog() async {
    final results = await Future.wait([
      _list('/registry/types'),
      _list('/registry/capabilities'),
      _list('/registry/relation-kinds'),
    ]);
    return RegistryCatalog(
      types: results[0].map(EntityType.fromJson).toList(),
      capabilities: results[1].map(CapabilityInfo.fromJson).toList(),
      relationKinds: results[2].map(RelationKind.fromJson).toList(),
    );
  }

  @override
  Future<EntityPage> list(EntityQuery query) async => EntityPage.fromJson(
    await _object('GET', '/registry/entities', query: query.toQuery()),
  );

  @override
  Future<RegistryEntity> get(String id) async =>
      RegistryEntity.fromJson(await _object('GET', '/registry/entities/$id'));

  @override
  Future<RegistryEntity> create(EntityDraft draft) async =>
      RegistryEntity.fromJson(
        await _object('POST', '/registry/entities', body: draft.toJson()),
      );

  @override
  Future<RegistryEntity> update(
    String id,
    int revision,
    Map<String, Object?> changes,
  ) async => RegistryEntity.fromJson(
    await _object(
      'PATCH',
      '/registry/entities/$id',
      body: {...changes, 'revision': revision},
    ),
  );

  @override
  Future<RegistryEntity> archive(String id, int revision) async =>
      RegistryEntity.fromJson(
        await _object(
          'POST',
          '/registry/entities/$id/archive',
          body: {'revision': revision},
        ),
      );

  @override
  Future<RegistryEntity> restore(String id, int revision) async =>
      RegistryEntity.fromJson(
        await _object(
          'POST',
          '/registry/entities/$id/restore',
          body: {'revision': revision},
        ),
      );

  @override
  Future<RegistryEntity> setCapabilities(
    String id,
    int revision,
    List<String> capabilities,
  ) async => RegistryEntity.fromJson(
    await _object(
      'PUT',
      '/registry/entities/$id/capabilities',
      body: {'revision': revision, 'capabilities': capabilities},
    ),
  );

  @override
  Future<List<RelationView>> relations(String id) async => [
    for (final r in await _list('/registry/entities/$id/relations'))
      RelationView.fromJson(r),
  ];

  @override
  Future<Relation> addRelation(
    String fromId,
    String kind,
    String targetId, {
    String label = '',
  }) async => Relation.fromJson(
    await _object(
      'POST',
      '/registry/entities/$fromId/relations',
      body: {
        'kind': kind,
        'targetId': targetId,
        'label': ?(label.isEmpty ? null : label),
      },
    ),
  );

  @override
  Future<void> deleteRelation(String relationId) async {
    await _client.request('DELETE', '/registry/relations/$relationId');
  }
}
