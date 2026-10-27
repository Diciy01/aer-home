import 'dart:ui' show Color;

import '../model/scene_document.dart';
import 'scene_catalog_data.dart';

/// How an asset may be placed (docs/SCENE_EDITOR.md, «Проверка размещения»).
enum Placement { floor, surface, wall, overlay }

class CatalogCategory {
  const CatalogCategory(this.id, this.label, this.icon);
  final String id;
  final String label;

  /// Symbolic icon name; the UI maps it to an icon.
  final String icon;
}

/// One placeable asset: geometry plus editor metadata.
class CatalogAsset {
  const CatalogAsset({
    required this.id,
    required this.label,
    required this.category,
    required this.group,
    required this.footprint,
    required this.height,
    required this.placement,
    this.bindable = false,
    this.top = false,
    this.shelves = const [],
    this.wallZ = 1.6,
    this.keywords = '',
  });

  final String id;
  final String label;
  final String category;

  /// Sub-group shown in the catalog («Столы», «Мониторы»…).
  final String group;
  final Size2 footprint;
  final double height;
  final Placement placement;

  /// Represents a technical device that can be bound to Registry.
  final bool bindable;

  /// Other objects may stand on its top surface.
  final bool top;

  /// Heights (local, unscaled) of inner shelves items may stand on.
  final List<double> shelves;

  /// Default height of the lower edge for wall placement.
  final double wallZ;
  final String keywords;

  SceneLayer get layer => switch (placement) {
    Placement.overlay => SceneLayer.floor,
    Placement.wall => SceneLayer.wall,
    _ => SceneLayer.object,
  };

  /// The asset declaration a scene document needs to use this item.
  SceneAsset toSceneAsset() => SceneAsset(
    id: id,
    label: label,
    footprint: footprint,
    height: height,
    art: AssetArt(kind: 'procedural', ref: id, status: 'placeholder'),
  );

  bool matches(String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return true;
    final hay = '$label $group $keywords $id'.toLowerCase();
    return q.split(RegExp(r'\s+')).every(hay.contains);
  }
}

/// Floor material. [texture] is reserved for a real texture ref; until then
/// [pattern] selects a procedural drawer.
class FloorMaterial {
  const FloorMaterial(
    this.id,
    this.label,
    this.color,
    this.pattern, [
    this.texture,
  ]);
  final String id;
  final String label;
  final Color color;
  final String pattern;
  final String? texture;
}

class WallMaterial {
  const WallMaterial(this.id, this.label, this.color, [this.texture]);
  final String id;
  final String label;
  final Color color;
  final String? texture;
}

class LightPreset {
  const LightPreset(this.id, this.label, this.tint);
  final String id;
  final String label;

  /// Overlay colour; its alpha is the strength (0 = no change).
  final Color tint;
}

class RoomKind {
  const RoomKind(this.id, this.label);
  final String id;
  final String label;
}

/// Assets, materials and lighting presets for the editor and the renderer.
class SceneCatalog {
  SceneCatalog._({
    required this.categories,
    required this.assets,
    required this.floors,
    required this.walls,
    required this.lights,
    required this.roomKinds,
    required this.finishes,
  });

  /// Parses catalog data (see `scene_catalog_data.dart`). Throws
  /// [FormatException] on malformed entries.
  factory SceneCatalog.fromJson(Map<String, Object?> j) {
    List<Map<String, Object?>> list(String key) => [
      for (final e in (j[key] as List? ?? const []))
        (e as Map).cast<String, Object?>(),
    ];
    double d(Object? v) => (v as num).toDouble();
    final categories = [
      for (final c in list('categories'))
        CatalogCategory(
          c['id']! as String,
          c['label']! as String,
          c['icon']! as String,
        ),
    ];
    final catIds = {for (final c in categories) c.id};
    final assets = <String, CatalogAsset>{};
    for (final a in list('assets')) {
      final id = a['id']! as String;
      final fp = a['footprint']! as List;
      final placement = Placement.values.byName(a['placement']! as String);
      final cat = a['category']! as String;
      if (!catIds.contains(cat)) {
        throw FormatException('asset $id: unknown category $cat');
      }
      if (assets.containsKey(id)) throw FormatException('asset $id twice');
      assets[id] = CatalogAsset(
        id: id,
        label: a['label']! as String,
        category: cat,
        group: a['group'] as String? ?? '',
        footprint: Size2(d(fp[0]), d(fp[1])),
        height: d(a['height']),
        placement: placement,
        bindable: a['bindable'] as bool? ?? false,
        top: a['top'] as bool? ?? false,
        shelves: [for (final s in (a['shelves'] as List? ?? const [])) d(s)],
        wallZ: a['wallZ'] == null ? 1.6 : d(a['wallZ']),
        keywords: a['keywords'] as String? ?? '',
      );
    }
    return SceneCatalog._(
      categories: categories,
      assets: assets,
      floors: {
        for (final f in list('floors'))
          f['id']! as String: FloorMaterial(
            f['id']! as String,
            f['label']! as String,
            Color(f['color']! as int),
            f['pattern']! as String,
            f['texture'] as String?,
          ),
      },
      walls: {
        for (final w in list('walls'))
          w['id']! as String: WallMaterial(
            w['id']! as String,
            w['label']! as String,
            Color(w['color']! as int),
            w['texture'] as String?,
          ),
      },
      lights: {
        for (final l in list('lights'))
          l['id']! as String: LightPreset(
            l['id']! as String,
            l['label']! as String,
            Color(l['tint']! as int),
          ),
      },
      roomKinds: [
        for (final k in list('roomKinds'))
          RoomKind(k['id']! as String, k['label']! as String),
      ],
      finishes: {
        for (final f in list('finishes'))
          f['id']! as String: LightPreset(
            f['id']! as String,
            f['label']! as String,
            Color(f['tint']! as int),
          ),
      },
    );
  }

  /// The built-in catalog shipped with the app.
  static final SceneCatalog builtin = SceneCatalog.fromJson(sceneCatalogData);

  final List<CatalogCategory> categories;
  final Map<String, CatalogAsset> assets;
  final Map<String, FloorMaterial> floors;
  final Map<String, WallMaterial> walls;
  final Map<String, LightPreset> lights;
  final List<RoomKind> roomKinds;

  /// Object finishes (tint presets, same shape as lights).
  final Map<String, LightPreset> finishes;

  static const fallbackFloor = FloorMaterial(
    'unknown',
    'Неизвестный материал',
    Color(0xFFD9C9B4),
    'plain',
  );
  static const fallbackWall = WallMaterial(
    'unknown',
    'Неизвестный цвет',
    Color(0xFFF2E5D0),
  );

  /// Unknown ids (e.g. from a newer client) are drawn with a neutral fallback.
  FloorMaterial floor(String id) => floors[id] ?? fallbackFloor;
  WallMaterial wall(String id) => walls[id] ?? fallbackWall;
  LightPreset? light(String? id) => id == null ? null : lights[id];

  CatalogAsset? asset(String id) => assets[id];

  Iterable<CatalogAsset> search({String query = '', String? category}) =>
      assets.values.where(
        (a) => (category == null || a.category == category) && a.matches(query),
      );

  String roomKindLabel(String id) =>
      roomKinds.where((k) => k.id == id).firstOrNull?.label ?? id;

  /// Placement rules for an asset in a document. Assets missing from the
  /// catalog (custom documents) behave as plain floor furniture.
  CatalogAsset placementOf(SceneAsset a) =>
      assets[a.id] ??
      CatalogAsset(
        id: a.id,
        label: a.label,
        category: 'decor',
        group: '',
        footprint: a.footprint,
        height: a.height,
        placement: Placement.floor,
      );
}
