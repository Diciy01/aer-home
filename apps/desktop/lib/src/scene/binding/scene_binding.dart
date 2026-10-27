import '../model/scene_document.dart';

/// Last known Registry facts about a bound entity (cached for offline use).
/// Scene keeps only what it displays; Registry stays the source of truth.
class EntitySnapshot {
  const EntitySnapshot({
    required this.id,
    required this.found,
    this.name = '',
    this.type = '',
    this.typeLabel = '',
    this.archived = false,
    this.capabilities = const [],
    this.capabilityLabels = const {},
    required this.fetchedAt,
  });

  factory EntitySnapshot.missing(String id, DateTime at) =>
      EntitySnapshot(id: id, found: false, fetchedAt: at);

  factory EntitySnapshot.fromJson(Map<String, dynamic> j) => EntitySnapshot(
    id: j['id'] as String,
    found: j['found'] as bool,
    name: j['name'] as String? ?? '',
    type: j['type'] as String? ?? '',
    typeLabel: j['typeLabel'] as String? ?? '',
    archived: j['archived'] as bool? ?? false,
    capabilities: [
      for (final c in j['capabilities'] as List? ?? const []) '$c',
    ],
    capabilityLabels: {
      for (final e in (j['capabilityLabels'] as Map? ?? const {}).entries)
        '${e.key}': '${e.value}',
    },
    fetchedAt: DateTime.parse(j['fetchedAt'] as String),
  );

  final String id;

  /// False when Registry answered 404 for this UUID.
  final bool found;
  final String name;
  final String type;
  final String typeLabel;
  final bool archived;
  final List<String> capabilities;

  /// Human labels captured at fetch time, so cards stay readable offline.
  final Map<String, String> capabilityLabels;
  final DateTime fetchedAt;

  Map<String, Object?> toJson() => {
    'id': id,
    'found': found,
    'name': name,
    'type': type,
    'typeLabel': typeLabel,
    'archived': archived,
    'capabilities': capabilities,
    'capabilityLabels': capabilityLabels,
    'fetchedAt': fetchedAt.toUtc().toIso8601String(),
  };
}

/// Real state of a bound entity from Monitoring (M05). Scene knows only
/// this small model, never Monitoring's API or tables.
class LiveStatus {
  const LiveStatus({
    required this.status,
    required this.note,
    this.stale = false,
    this.lastContactAt,
    this.openIncidents = 0,
  });

  final SceneStatus status;
  final String note;

  /// The value is the last known one (client offline or data outdated).
  final bool stale;
  final DateTime? lastContactAt;
  final int openIncidents;
}

/// How fresh the Registry knowledge is.
enum RegistryLink { loading, live, stale, unavailable }

enum BindingState { unbound, resolved, missing, archived, pending, unavailable }

/// What the scene shows for one object.
class ObjectPresentation {
  const ObjectPresentation({
    required this.title,
    required this.subtitle,
    required this.binding,
    this.status,
    this.isDemo = false,
    this.stale = false,
    required this.note,
    this.snapshot,
    this.live,
  });

  final String title;
  final String subtitle;
  final BindingState binding;

  /// Null for decorative objects: no badge at all.
  final SceneStatus? status;

  /// The status is an explicitly marked test value from a demo scene.
  final bool isDemo;

  /// Registry data comes from the cache, not from a live answer.
  final bool stale;
  final String note;
  final EntitySnapshot? snapshot;

  /// Monitoring state, when known.
  final LiveStatus? live;

  bool get isBound => binding != BindingState.unbound;
}

/// Combines a scene object with Registry knowledge and the Monitoring state.
/// Never invents a healthy state: without monitoring data a real entity
/// shows `unknown`; stale data is marked as such.
ObjectPresentation presentObject(
  SceneObject o,
  SceneAsset? asset,
  Map<String, EntitySnapshot> snapshots,
  RegistryLink link, [
  LiveStatus? live,
]) {
  final fallbackTitle = o.label.isNotEmpty
      ? o.label
      : (asset?.label ?? o.assetId);
  final assetLabel = asset?.label ?? o.assetId;
  final b = o.entityBinding;
  if (b == null) {
    final demo = o.demoState;
    return ObjectPresentation(
      title: fallbackTitle,
      subtitle: fallbackTitle == assetLabel ? 'Объект сцены' : assetLabel,
      binding: BindingState.unbound,
      status: demo,
      isDemo: demo != null,
      note: demo != null
          ? 'Тестовое состояние демо-сцены — не данные устройства'
          : 'Декор: не привязан к Registry',
    );
  }
  final snap = snapshots[b.entityId];
  final stale = link != RegistryLink.live;
  if (snap == null) {
    return switch (link) {
      RegistryLink.loading => ObjectPresentation(
        title: fallbackTitle,
        subtitle: assetLabel,
        binding: BindingState.pending,
        status: SceneStatus.loading,
        note: 'Загружаем сведения из Registry…',
      ),
      _ => ObjectPresentation(
        title: fallbackTitle,
        subtitle: assetLabel,
        binding: BindingState.unavailable,
        status: SceneStatus.unknown,
        stale: true,
        note: 'Registry недоступен, сведений об объекте нет',
      ),
    };
  }
  if (!snap.found) {
    return ObjectPresentation(
      title: fallbackTitle,
      subtitle: assetLabel,
      binding: BindingState.missing,
      status: SceneStatus.unknown,
      stale: stale,
      note: 'Объект Registry не найден (привязка указывает на удалённый UUID)',
      snapshot: snap,
    );
  }
  if (snap.archived) {
    return ObjectPresentation(
      title: snap.name,
      subtitle: snap.typeLabel.isEmpty ? snap.type : snap.typeLabel,
      binding: BindingState.archived,
      status: SceneStatus.archived,
      stale: stale,
      note: 'Объект в архиве Registry',
      snapshot: snap,
    );
  }
  return ObjectPresentation(
    title: snap.name,
    subtitle: snap.typeLabel.isEmpty ? snap.type : snap.typeLabel,
    binding: BindingState.resolved,
    status: live?.status ?? SceneStatus.unknown,
    stale: stale || (live?.stale ?? false),
    note: live?.note ?? 'Нет данных мониторинга для этого объекта',
    snapshot: snap,
    live: live,
  );
}
