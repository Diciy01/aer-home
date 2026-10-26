// TEST DOUBLE ONLY — an in-memory Registry used by widget tests.
// It mimics Core's revision, archive and validation rules closely enough to
// exercise the UI; the real rules are tested in Go (core/internal/modules/registry).
import 'package:aer_home_desktop/src/core_api/core_client.dart';
import 'package:aer_home_desktop/src/core_api/registry_api.dart';
import 'package:aer_home_desktop/src/core_api/registry_models.dart';

RegistryCatalog testCatalog() => RegistryCatalog(
  types: const [
    EntityType(
      id: 'computer',
      label: 'Компьютер',
      description: 'ПК',
      group: 'hardware',
      icon: 'computer',
      addressMode: 'optional',
      defaultCapabilities: ['network.ping', 'power.reboot'],
    ),
    EntityType(
      id: 'server',
      label: 'Сервер',
      description: 'Сервер',
      group: 'hardware',
      icon: 'server',
      addressMode: 'optional',
      defaultCapabilities: ['network.ping'],
    ),
    EntityType(
      id: 'website',
      label: 'Сайт',
      description: 'Сайт',
      group: 'network',
      icon: 'web',
      addressMode: 'required',
      addressHint: 'https://…',
      defaultCapabilities: ['monitoring.http'],
    ),
    EntityType(
      id: 'telegram_bot',
      label: 'Telegram-бот',
      description: 'Бот',
      group: 'software',
      icon: 'bot',
      addressMode: 'none',
      defaultCapabilities: ['monitoring.heartbeat'],
    ),
  ],
  capabilities: const [
    CapabilityInfo(
      id: 'network.ping',
      label: 'Ping',
      description: '',
      module: 'network',
    ),
    CapabilityInfo(
      id: 'power.reboot',
      label: 'Перезагрузка',
      description: '',
      module: 'power',
    ),
    CapabilityInfo(
      id: 'power.wake',
      label: 'Wake-on-LAN',
      description: '',
      module: 'power',
    ),
    CapabilityInfo(
      id: 'monitoring.http',
      label: 'HTTP-проверка',
      description: '',
      module: 'monitoring',
    ),
    CapabilityInfo(
      id: 'monitoring.heartbeat',
      label: 'Heartbeat',
      description: '',
      module: 'monitoring',
    ),
  ],
  relationKinds: const [
    RelationKind(
      id: 'runs_on',
      label: 'работает на',
      description: '',
      acyclic: true,
    ),
    RelationKind(
      id: 'connected_to',
      label: 'подключён к',
      description: '',
      acyclic: false,
    ),
    RelationKind(
      id: 'custom',
      label: 'своя связь',
      description: '',
      acyclic: false,
    ),
  ],
);

CoreApiException _validation(Map<String, String> fields) => CoreApiException(
  statusCode: 422,
  code: 'VALIDATION_FAILED',
  message: 'Проверьте введённые данные',
  details: {'fields': fields},
);

CoreApiException _conflict(String reason, String message, [int? rev]) =>
    CoreApiException(
      statusCode: 409,
      code: 'CONFLICT',
      message: message,
      details: {'reason': reason, 'currentRevision': ?rev},
    );

class FakeRegistryApi implements RegistryApi {
  FakeRegistryApi();

  final catalogData = testCatalog();
  final Map<String, RegistryEntity> entities = {};
  final List<Relation> relationsData = [];

  /// When set, every call throws it (simulates Core going away).
  Object? failWith;
  final List<String> calls = [];
  int _seq = 0;
  final _t0 = DateTime.utc(2026, 10, 26, 12);

  String _id() {
    _seq++;
    return '00000000-0000-4000-8000-${_seq.toString().padLeft(12, '0')}';
  }

  void _guard(String call) {
    calls.add(call);
    if (failWith != null) throw failWith!;
  }

  /// Adds an entity directly (test setup).
  RegistryEntity seed(
    String name,
    String type, {
    List<String> tags = const [],
    String? address,
  }) {
    final e = RegistryEntity(
      id: _id(),
      name: name,
      type: type,
      icon: catalogData.type(type)!.icon,
      tags: tags,
      address: address,
      capabilities: catalogData.type(type)!.defaultCapabilities,
      revision: 1,
      createdAt: _t0,
      updatedAt: _t0,
    );
    entities[e.id] = e;
    return e;
  }

  RegistryEntity _copy(
    RegistryEntity e, {
    String? name,
    String? type,
    String? description,
    List<String>? tags,
    Object? address = _keep,
    Object? parentId = _keep,
    List<String>? capabilities,
    bool? archived,
  }) => RegistryEntity(
    id: e.id,
    name: name ?? e.name,
    type: type ?? e.type,
    description: description ?? e.description,
    icon: e.icon,
    tags: tags ?? e.tags,
    parentId: identical(parentId, _keep) ? e.parentId : parentId as String?,
    address: identical(address, _keep) ? e.address : address as String?,
    capabilities: capabilities ?? e.capabilities,
    revision: e.revision + 1,
    createdAt: e.createdAt,
    updatedAt: e.updatedAt.add(const Duration(minutes: 1)),
    archived: archived ?? e.archived,
    archivedAt: (archived ?? e.archived) ? _t0 : null,
  );

  RegistryEntity _locked(String id, int revision) {
    final e = entities[id];
    if (e == null) {
      throw const CoreApiException(
        statusCode: 404,
        code: 'NOT_FOUND',
        message: 'Объект не найден',
      );
    }
    if (e.revision != revision) {
      throw _conflict('revision_mismatch', 'Объект был изменён', e.revision);
    }
    return e;
  }

  @override
  Future<RegistryCatalog> catalog() async {
    _guard('catalog');
    return catalogData;
  }

  @override
  Future<EntityPage> list(EntityQuery q) async {
    _guard('list');
    final terms = q.text
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .where((t) => t.isNotEmpty);
    final all =
        entities.values.where((e) {
          if (e.archived != q.archived) return false;
          if (q.type != null && e.type != q.type) return false;
          final hay = [
            e.name,
            e.description,
            e.address ?? '',
            ...e.tags,
          ].join(' ').toLowerCase();
          return terms.every(hay.contains);
        }).toList()..sort(
          (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
        );
    final items = all.skip(q.offset).take(q.limit).toList();
    return EntityPage(
      items: items,
      total: all.length,
      limit: q.limit,
      offset: q.offset,
    );
  }

  @override
  Future<RegistryEntity> get(String id) async {
    _guard('get');
    final e = entities[id];
    if (e == null) {
      throw const CoreApiException(
        statusCode: 404,
        code: 'NOT_FOUND',
        message: 'Объект не найден',
      );
    }
    return e;
  }

  @override
  Future<RegistryEntity> create(EntityDraft d) async {
    _guard('create');
    final type = catalogData.type(d.type);
    final errors = <String, String>{};
    if (d.name.trim().isEmpty) errors['name'] = 'Укажите название';
    if (type == null) errors['type'] = 'Неизвестный тип объекта';
    if (type != null && type.addressRequired && (d.address ?? '').isEmpty) {
      errors['address'] = 'Для этого типа нужен адрес';
    }
    if ((d.address ?? '').contains('@')) {
      errors['address'] = 'Не указывайте логин и пароль в адресе';
    }
    if (errors.isNotEmpty) throw _validation(errors);
    final e = RegistryEntity(
      id: _id(),
      name: d.name.trim(),
      type: d.type,
      description: d.description,
      icon: type!.icon,
      tags: d.tags,
      parentId: d.parentId,
      address: (d.address ?? '').isEmpty ? null : d.address,
      capabilities: type.defaultCapabilities,
      revision: 1,
      createdAt: _t0,
      updatedAt: _t0,
    );
    entities[e.id] = e;
    return e;
  }

  @override
  Future<RegistryEntity> update(
    String id,
    int revision,
    Map<String, Object?> c,
  ) async {
    _guard('update');
    final e = _locked(id, revision);
    if (e.archived) throw _conflict('archived', 'Объект в архиве');
    if (c.containsKey('name') && (c['name'] as String).isEmpty) {
      throw _validation({'name': 'Укажите название'});
    }
    return entities[id] = _copy(
      e,
      name: c['name'] as String?,
      type: c['type'] as String?,
      description: c['description'] as String?,
      tags: (c['tags'] as List<String>?),
      address: c.containsKey('address') ? c['address'] : _keep,
      parentId: c.containsKey('parentId') ? c['parentId'] : _keep,
    );
  }

  @override
  Future<RegistryEntity> archive(String id, int revision) async {
    _guard('archive');
    final e = _locked(id, revision);
    if (e.archived) throw _conflict('state', 'Объект уже в архиве');
    return entities[id] = _copy(e, archived: true);
  }

  @override
  Future<RegistryEntity> restore(String id, int revision) async {
    _guard('restore');
    final e = _locked(id, revision);
    if (!e.archived) throw _conflict('state', 'Объект не в архиве');
    return entities[id] = _copy(e, archived: false);
  }

  @override
  Future<RegistryEntity> setCapabilities(
    String id,
    int revision,
    List<String> caps,
  ) async {
    _guard('setCapabilities');
    final e = _locked(id, revision);
    return entities[id] = _copy(e, capabilities: caps);
  }

  @override
  Future<List<RelationView>> relations(String id) async {
    _guard('relations');
    return [
      for (final r in relationsData)
        if (r.fromId == id || r.toId == id)
          RelationView(
            relation: r,
            outgoing: r.fromId == id,
            peer: () {
              final p = entities[r.fromId == id ? r.toId : r.fromId]!;
              return EntitySummary(
                id: p.id,
                name: p.name,
                type: p.type,
                archived: p.archived,
              );
            }(),
          ),
    ];
  }

  @override
  Future<Relation> addRelation(
    String fromId,
    String kind,
    String targetId, {
    String label = '',
  }) async {
    _guard('addRelation');
    if (relationsData.any(
      (r) =>
          r.toId == fromId &&
          r.fromId == targetId &&
          r.kind == kind &&
          kind == 'runs_on',
    )) {
      throw _conflict(
        'cycle',
        'Связь «работает на» создаст циклическую зависимость',
      );
    }
    final r = Relation(
      id: _id(),
      fromId: fromId,
      toId: targetId,
      kind: kind,
      label: label,
    );
    relationsData.add(r);
    return r;
  }

  @override
  Future<void> deleteRelation(String relationId) async {
    _guard('deleteRelation');
    relationsData.removeWhere((r) => r.id == relationId);
  }
}

const _keep = Object();
