/// Scene format v1 (contracts/scene.schema.json). Pure Dart, no Flutter or
/// Flame types, so the same model can back other renderers.
///
/// Units are tiles (1 tile = 0.5 m). Rooms sit on a shared ground grid;
/// object positions are room-local (min corner of the rotated footprint).
library;

const sceneSchemaVersion = 1;
const sceneProjection = 'isometric-2:1';

/// Visual states a scene object can show. Real states come from Monitoring
/// (not implemented yet); the scene file may only carry demo states.
enum SceneStatus {
  online,
  offline,
  warning,
  critical,
  unknown,
  loading,
  archived,
}

enum SceneLayer { floor, object, wall }

enum BindingRole { primary, secondary }

class Size2 {
  const Size2(this.w, this.d);
  final double w;
  final double d;

  Map<String, Object?> toJson() => {'w': w, 'd': d};
}

class Point2 {
  const Point2(this.x, this.y);
  final double x;
  final double y;

  Map<String, Object?> toJson() => {'x': x, 'y': y};
}

class Point3 {
  const Point3(this.x, this.y, this.z);
  final double x;
  final double y;
  final double z;

  Map<String, Object?> toJson() => {'x': x, 'y': y, 'z': z};
}

class AssetArt {
  const AssetArt({required this.kind, required this.ref, required this.status});
  final String kind; // procedural | sprite
  final String ref;
  final String status; // placeholder | final

  bool get isPlaceholder => status == 'placeholder';

  Map<String, Object?> toJson() => {'kind': kind, 'ref': ref, 'status': status};
}

/// Geometry of a reusable visual asset; art is resolved by the renderer.
class SceneAsset {
  const SceneAsset({
    required this.id,
    required this.label,
    required this.footprint,
    required this.height,
    required this.art,
  });

  final String id;
  final String label;
  final Size2 footprint;
  final double height;
  final AssetArt art;

  Map<String, Object?> toJson() => {
    'id': id,
    'label': label,
    'footprint': footprint.toJson(),
    'height': height,
    'art': art.toJson(),
  };
}

/// Material ids from the material catalog (data-defined, see
/// `scene/catalog/`); [light] is an optional lighting preset.
class RoomStyle {
  const RoomStyle({required this.floor, required this.wall, this.light});
  final String floor;
  final String wall;
  final String? light;

  RoomStyle copyWith({
    String? floor,
    String? wall,
    String? Function()? light,
  }) => RoomStyle(
    floor: floor ?? this.floor,
    wall: wall ?? this.wall,
    light: light != null ? light() : this.light,
  );

  @override
  bool operator ==(Object other) =>
      other is RoomStyle &&
      other.floor == floor &&
      other.wall == wall &&
      other.light == light;

  @override
  int get hashCode => Object.hash(floor, wall, light);

  Map<String, Object?> toJson() => {
    'floor': floor,
    'wall': wall,
    if (light != null) 'light': light,
  };
}

class SceneRoom {
  const SceneRoom({
    required this.id,
    required this.name,
    required this.kind,
    required this.origin,
    required this.size,
    required this.wallHeight,
    required this.style,
    this.metadata = const {},
  });

  final String id;
  final String name;
  final String kind;
  final Point2 origin;
  final Size2 size;
  final double wallHeight;
  final RoomStyle style;
  final Map<String, String> metadata;

  SceneRoom copyWith({
    String? id,
    String? name,
    String? kind,
    Point2? origin,
    Size2? size,
    RoomStyle? style,
  }) => SceneRoom(
    id: id ?? this.id,
    name: name ?? this.name,
    kind: kind ?? this.kind,
    origin: origin ?? this.origin,
    size: size ?? this.size,
    wallHeight: wallHeight,
    style: style ?? this.style,
    metadata: metadata,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'kind': kind,
    'origin': origin.toJson(),
    'size': size.toJson(),
    'wallHeight': wallHeight,
    'style': style.toJson(),
    'metadata': metadata,
  };
}

class EntityBinding {
  const EntityBinding({
    required this.entityId,
    this.role = BindingRole.primary,
  });
  final String entityId;
  final BindingRole role;

  Map<String, Object?> toJson() => {'entityId': entityId, 'role': role.name};
}

class SceneObject {
  const SceneObject({
    required this.id,
    required this.roomId,
    required this.assetId,
    this.label = '',
    required this.position,
    this.rotation = 0,
    this.scale = 1,
    this.layer = SceneLayer.object,
    this.entityBinding,
    this.demoState,
    this.metadata = const {},
  });

  final String id;
  final String roomId;
  final String assetId;
  final String label;
  final Point3 position;
  final int rotation;
  final double scale;
  final SceneLayer layer;
  final EntityBinding? entityBinding;

  /// Explicit test state (demo scenes only, never on bound objects).
  final SceneStatus? demoState;
  final Map<String, String> metadata;

  /// Footprint after rotation and scale.
  Size2 footprint(SceneAsset a) {
    final w = a.footprint.w * scale, d = a.footprint.d * scale;
    return rotation == 90 || rotation == 270 ? Size2(d, w) : Size2(w, d);
  }

  SceneObject copyWith({
    String? id,
    String? roomId,
    Point3? position,
    int? rotation,
    double? scale,
    SceneLayer? layer,
    EntityBinding? Function()? entityBinding,
    SceneStatus? Function()? demoState,
    String? label,
    Map<String, String>? metadata,
  }) => SceneObject(
    id: id ?? this.id,
    roomId: roomId ?? this.roomId,
    assetId: assetId,
    label: label ?? this.label,
    position: position ?? this.position,
    rotation: rotation ?? this.rotation,
    scale: scale ?? this.scale,
    layer: layer ?? this.layer,
    entityBinding: entityBinding != null ? entityBinding() : this.entityBinding,
    demoState: demoState != null ? demoState() : this.demoState,
    metadata: metadata ?? this.metadata,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'roomId': roomId,
    'assetId': assetId,
    'label': label,
    'position': position.toJson(),
    'rotation': rotation,
    'scale': scale,
    'layer': layer.name,
    'entityBinding': entityBinding?.toJson(),
    'visualState': demoState == null ? null : {'demo': demoState!.name},
    'metadata': metadata,
  };
}

class SceneDocument {
  SceneDocument({
    this.schemaVersion = sceneSchemaVersion,
    required this.sceneId,
    required this.name,
    this.demo = false,
    this.projection = sceneProjection,
    required this.assets,
    required this.rooms,
    required this.objects,
    this.metadata = const {},
  });

  final int schemaVersion;
  final String sceneId;
  final String name;
  final bool demo;
  final String projection;
  final List<SceneAsset> assets;
  final List<SceneRoom> rooms;
  final List<SceneObject> objects;
  final Map<String, String> metadata;

  late final Map<String, SceneAsset> _assets = {
    for (final a in assets) a.id: a,
  };
  late final Map<String, SceneRoom> _rooms = {for (final r in rooms) r.id: r};
  late final Map<String, SceneObject> _objects = {
    for (final o in objects) o.id: o,
  };

  SceneAsset? asset(String id) => _assets[id];
  SceneRoom? room(String id) => _rooms[id];
  SceneObject? object(String id) => _objects[id];

  Iterable<SceneObject> objectsIn(String roomId) =>
      objects.where((o) => o.roomId == roomId);

  /// UUIDs of Registry entities referenced by this scene.
  Set<String> get boundEntityIds => {
    for (final o in objects)
      if (o.entityBinding != null) o.entityBinding!.entityId,
  };

  SceneDocument copyWith({
    String? sceneId,
    String? name,
    List<SceneRoom>? rooms,
    List<SceneObject>? objects,
    List<SceneAsset>? assets,
    bool? demo,
  }) => SceneDocument(
    schemaVersion: schemaVersion,
    sceneId: sceneId ?? this.sceneId,
    name: name ?? this.name,
    demo: demo ?? this.demo,
    projection: projection,
    assets: assets ?? this.assets,
    rooms: rooms ?? this.rooms,
    objects: objects ?? this.objects,
    metadata: metadata,
  );

  Map<String, Object?> toJson() => {
    'schemaVersion': schemaVersion,
    'sceneId': sceneId,
    'name': name,
    'demo': demo,
    'projection': projection,
    'assets': [for (final a in assets) a.toJson()],
    'rooms': [for (final r in rooms) r.toJson()],
    'objects': [for (final o in objects) o.toJson()],
    'metadata': metadata,
  };
}
