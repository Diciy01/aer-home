/// Registry data types mirroring contracts/openapi.yaml 0.3.0.
library;

class EntityType {
  const EntityType({
    required this.id,
    required this.label,
    required this.description,
    required this.group,
    required this.icon,
    required this.addressMode,
    this.addressHint,
    required this.defaultCapabilities,
  });

  factory EntityType.fromJson(Map<String, dynamic> j) => EntityType(
    id: j['id'] as String,
    label: j['label'] as String,
    description: j['description'] as String,
    group: j['group'] as String,
    icon: j['icon'] as String,
    addressMode: j['addressMode'] as String,
    addressHint: j['addressHint'] as String?,
    defaultCapabilities: _strings(j['defaultCapabilities']),
  );

  final String id;
  final String label;
  final String description;

  /// hardware | network | software | virtual
  final String group;
  final String icon;

  /// none | optional | required
  final String addressMode;
  final String? addressHint;
  final List<String> defaultCapabilities;

  bool get hasAddress => addressMode != 'none';
  bool get addressRequired => addressMode == 'required';
}

class CapabilityInfo {
  const CapabilityInfo({
    required this.id,
    required this.label,
    required this.description,
    required this.module,
  });

  factory CapabilityInfo.fromJson(Map<String, dynamic> j) => CapabilityInfo(
    id: j['id'] as String,
    label: j['label'] as String,
    description: j['description'] as String,
    module: j['module'] as String,
  );

  final String id;
  final String label;
  final String description;
  final String module;
}

class RelationKind {
  const RelationKind({
    required this.id,
    required this.label,
    required this.description,
    required this.acyclic,
  });

  factory RelationKind.fromJson(Map<String, dynamic> j) => RelationKind(
    id: j['id'] as String,
    label: j['label'] as String,
    description: j['description'] as String,
    acyclic: j['acyclic'] as bool,
  );

  final String id;
  final String label;
  final String description;
  final bool acyclic;

  bool get needsLabel => id == 'custom';
}

/// Types, capabilities and relation kinds served by Core.
class RegistryCatalog {
  RegistryCatalog({
    required this.types,
    required this.capabilities,
    required this.relationKinds,
  });

  final List<EntityType> types;
  final List<CapabilityInfo> capabilities;
  final List<RelationKind> relationKinds;

  late final Map<String, EntityType> _types = {for (final t in types) t.id: t};
  late final Map<String, CapabilityInfo> _caps = {
    for (final c in capabilities) c.id: c,
  };
  late final Map<String, RelationKind> _kinds = {
    for (final k in relationKinds) k.id: k,
  };

  EntityType? type(String id) => _types[id];
  CapabilityInfo? capability(String id) => _caps[id];
  RelationKind? relationKind(String id) => _kinds[id];

  String typeLabel(String id) => _types[id]?.label ?? id;
  String capabilityLabel(String id) => _caps[id]?.label ?? id;
  String relationLabel(String id) => _kinds[id]?.label ?? id;
}

class SecretRef {
  const SecretRef(this.name, this.ref);

  factory SecretRef.fromJson(Map<String, dynamic> j) =>
      SecretRef(j['name'] as String, j['ref'] as String);

  final String name;

  /// Pointer such as `env:PICO_TOKEN`, never the secret itself.
  final String ref;

  Map<String, Object?> toJson() => {'name': name, 'ref': ref};
}

class RegistryEntity {
  const RegistryEntity({
    required this.id,
    required this.name,
    required this.type,
    this.description = '',
    this.icon = '',
    this.tags = const [],
    this.parentId,
    this.discovery = 'manual',
    this.address,
    this.secretRefs = const [],
    this.attributes = const {},
    this.capabilities = const [],
    required this.revision,
    required this.createdAt,
    required this.updatedAt,
    this.archived = false,
    this.archivedAt,
  });

  factory RegistryEntity.fromJson(Map<String, dynamic> j) => RegistryEntity(
    id: j['id'] as String,
    name: j['name'] as String,
    type: j['type'] as String,
    description: j['description'] as String,
    icon: j['icon'] as String,
    tags: _strings(j['tags']),
    parentId: j['parentId'] as String?,
    discovery: j['discovery'] as String,
    address: j['address'] as String?,
    secretRefs: [
      for (final s in j['secretRefs'] as List<dynamic>)
        SecretRef.fromJson(s as Map<String, dynamic>),
    ],
    attributes: Map<String, dynamic>.from(j['attributes'] as Map),
    capabilities: _strings(j['capabilities']),
    revision: j['revision'] as int,
    createdAt: DateTime.parse(j['createdAt'] as String),
    updatedAt: DateTime.parse(j['updatedAt'] as String),
    archived: j['archived'] as bool,
    archivedAt: j['archivedAt'] == null
        ? null
        : DateTime.parse(j['archivedAt'] as String),
  );

  final String id;
  final String name;
  final String type;
  final String description;
  final String icon;
  final List<String> tags;
  final String? parentId;
  final String discovery;
  final String? address;
  final List<SecretRef> secretRefs;
  final Map<String, dynamic> attributes;
  final List<String> capabilities;
  final int revision;
  final DateTime createdAt;
  final DateTime updatedAt;
  final bool archived;
  final DateTime? archivedAt;
}

class EntityPage {
  const EntityPage({
    required this.items,
    required this.total,
    required this.limit,
    required this.offset,
  });

  factory EntityPage.fromJson(Map<String, dynamic> j) => EntityPage(
    items: [
      for (final e in j['items'] as List<dynamic>)
        RegistryEntity.fromJson(e as Map<String, dynamic>),
    ],
    total: j['total'] as int,
    limit: j['limit'] as int,
    offset: j['offset'] as int,
  );

  final List<RegistryEntity> items;
  final int total;
  final int limit;
  final int offset;
}

/// Which entities to list.
class EntityQuery {
  const EntityQuery({
    this.text = '',
    this.type,
    this.archived = false,
    this.limit = 50,
    this.offset = 0,
  });

  final String text;
  final String? type;
  final bool archived;
  final int limit;
  final int offset;

  EntityQuery copyWith({int? offset}) => EntityQuery(
    text: text,
    type: type,
    archived: archived,
    limit: limit,
    offset: offset ?? this.offset,
  );

  Map<String, Object?> toQuery() => {
    if (text.trim().isNotEmpty) 'q': text.trim(),
    'type': ?type,
    'archived': archived ? 'true' : 'false',
    'limit': limit,
    'offset': offset,
  };
}

/// Data collected by the add wizard. Only [name] and [type] are required.
class EntityDraft {
  const EntityDraft({
    required this.name,
    required this.type,
    this.address,
    this.description = '',
    this.tags = const [],
    this.parentId,
  });

  final String name;
  final String type;
  final String? address;
  final String description;
  final List<String> tags;
  final String? parentId;

  Map<String, Object?> toJson() => {
    'name': name,
    'type': type,
    if (address != null && address!.trim().isNotEmpty) 'address': address,
    if (description.trim().isNotEmpty) 'description': description,
    if (tags.isNotEmpty) 'tags': tags,
    'parentId': ?parentId,
  };
}

class Relation {
  const Relation({
    required this.id,
    required this.fromId,
    required this.toId,
    required this.kind,
    required this.label,
  });

  factory Relation.fromJson(Map<String, dynamic> j) => Relation(
    id: j['id'] as String,
    fromId: j['fromId'] as String,
    toId: j['toId'] as String,
    kind: j['kind'] as String,
    label: j['label'] as String,
  );

  final String id;
  final String fromId;
  final String toId;
  final String kind;
  final String label;
}

class EntitySummary {
  const EntitySummary({
    required this.id,
    required this.name,
    required this.type,
    required this.archived,
  });

  factory EntitySummary.fromJson(Map<String, dynamic> j) => EntitySummary(
    id: j['id'] as String,
    name: j['name'] as String,
    type: j['type'] as String,
    archived: j['archived'] as bool,
  );

  final String id;
  final String name;
  final String type;
  final bool archived;
}

/// A relation seen from one entity.
class RelationView {
  const RelationView({
    required this.relation,
    required this.outgoing,
    required this.peer,
  });

  factory RelationView.fromJson(Map<String, dynamic> j) => RelationView(
    relation: Relation.fromJson(j),
    outgoing: j['direction'] == 'outgoing',
    peer: EntitySummary.fromJson(j['peer'] as Map<String, dynamic>),
  );

  final Relation relation;
  final bool outgoing;
  final EntitySummary peer;
}

/// Splits "a, b  c" into normalised tags.
List<String> parseTags(String input) => {
  for (final t in input.split(RegExp(r'[,\s]+')))
    if (t.trim().isNotEmpty) t.trim().toLowerCase(),
}.toList();

List<String> _strings(Object? v) => [for (final x in v as List<dynamic>) '$x'];
