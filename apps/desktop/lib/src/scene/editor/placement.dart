import 'dart:math' as math;
import 'dart:ui' show Offset;

import '../catalog/scene_catalog.dart';
import '../geometry/iso.dart';
import '../geometry/scene_layout.dart';
import '../model/scene_document.dart';

const _eps = 0.02;

/// Editor limits on top of the format rules (SCENE_FORMAT.md).
abstract final class EditorLimits {
  static const minRoomSide = 2.0;
  static const maxRoomSide = 60.0;
  static const maxRooms = 64;
  static const maxObjects = 2000;
  static const minScale = 0.5;
  static const maxScale = 2.0;

  /// Grid step for snapping (tiles); fine step with Alt.
  static const snap = 0.5;
  static const fineSnap = 0.1;

  /// Wall items count as "on the wall" within this distance from it.
  static const wallGap = 0.35;
}

/// Where an object rests, found by the validator.
sealed class Support {
  const Support();
}

class OnFloor extends Support {
  const OnFloor();
}

class OnTop extends Support {
  const OnTop(this.objectId);
  final String objectId;
}

class OnShelf extends Support {
  const OnShelf(this.objectId);
  final String objectId;
}

class OnWall extends Support {
  const OnWall(this.side);
  final WallSide side;
}

class PlacementCheck {
  const PlacementCheck(this.issues, [this.support]);
  final List<String> issues;
  final Support? support;
  bool get ok => issues.isEmpty;
}

/// Placement rules: room bounds, sizes, placement type (floor / surface /
/// wall / overlay) and collisions that respect height and containers, so a
/// monitor may stand on a desk, a box on a shelf, a rug under furniture and
/// a picture on a wall — while two sofas may not occupy the same space.
class PlacementValidator {
  const PlacementValidator(this.catalog);
  final SceneCatalog catalog;

  /// Checks [o] as if it were in [doc] (an object with the same id in [doc]
  /// is ignored, so moves can be checked before they are committed).
  PlacementCheck checkObject(
    SceneDocument doc,
    SceneObject o, {
    SceneAsset? asset,
  }) {
    final issues = <String>[];
    final a = asset ?? doc.asset(o.assetId);
    final room = doc.room(o.roomId);
    if (a == null) return const PlacementCheck(['Неизвестный предмет']);
    if (room == null) {
      return const PlacementCheck(['Поставьте предмет в комнату']);
    }
    final spec = catalog.placementOf(a);
    final p = o.position;
    if (!p.x.isFinite || !p.y.isFinite || !p.z.isFinite) {
      return const PlacementCheck(['Некорректные координаты']);
    }
    if (o.scale < 0.25 - 1e-9 || o.scale > 4 + 1e-9) {
      issues.add('Масштаб вне допустимых пределов');
    }
    if (a.height * o.scale + p.z > 40) issues.add('Предмет слишком высокий');
    final fp = o.footprint(a);
    if (p.x < -1e-6 ||
        p.y < -1e-6 ||
        p.x + fp.w > room.size.w + 1e-6 ||
        p.y + fp.d > room.size.d + 1e-6) {
      issues.add(
        fp.w > room.size.w || fp.d > room.size.d
            ? 'Предмет больше комнаты «${room.name}»'
            : 'Выходит за пределы комнаты «${room.name}»',
      );
    }
    if (p.z < -1e-6) issues.add('Предмет ниже пола');
    final box = SceneLayout.boxOf(o, a, room);
    final others = [
      for (final x in doc.objectsIn(room.id))
        if (x.id != o.id && doc.asset(x.assetId) != null)
          (
            x,
            doc.asset(x.assetId)!,
            SceneLayout.boxOf(x, doc.asset(x.assetId)!, room),
          ),
    ];

    Support? support;
    switch (spec.placement) {
      case Placement.overlay:
        if (p.z > _eps) issues.add('Ковёр лежит только на полу');
        support = const OnFloor();
      case Placement.floor:
        if (p.z > _eps) issues.add('Этот предмет ставится только на пол');
        support = const OnFloor();
      case Placement.surface:
        support = p.z <= _eps ? const OnFloor() : _supportFor(o, box, others);
        if (support == null) {
          issues.add(
            'Предмет висит в воздухе: поставьте его на пол, стол или полку',
          );
        }
      case Placement.wall:
        support = _wallFor(doc, room, o, fp);
        if (support == null) {
          issues.add('Предмет вешается на заднюю стену (север или запад)');
        }
        if (room.wallHeight > 0 &&
            p.z + a.height * o.scale > room.wallHeight + _eps) {
          issues.add('Не помещается на стене по высоте');
        }
    }

    if (spec.placement != Placement.overlay) {
      for (final (x, xa, xb) in others) {
        final xs = catalog.placementOf(xa);
        if (xs.placement == Placement.overlay) continue;
        final wallA = spec.placement == Placement.wall;
        final wallB = xs.placement == Placement.wall;
        // Wall items only compete with other wall items for wall space.
        if (wallA != wallB) continue;
        if (!_intersects(box, xb)) continue;
        if (_inside(box, xb, xs, x.scale) || _inside(xb, box, spec, o.scale)) {
          continue;
        }
        final name = x.label.isNotEmpty ? x.label : xa.label;
        issues.add('Пересекается с «$name»');
      }
    }
    return PlacementCheck(issues, support);
  }

  /// Every placement problem in a document, by object id.
  Map<String, List<String>> checkDocument(SceneDocument doc) => {
    for (final o in doc.objects)
      if (checkObject(doc, o) case final c when !c.ok) o.id: c.issues,
  };

  /// Checks a new or changed [room] against [doc] (a room with the same id
  /// is replaced): sizes, overlaps with other rooms, objects still inside.
  List<String> checkRoom(SceneDocument doc, SceneRoom room) {
    final issues = <String>[];
    final s = room.size, o = room.origin;
    if (s.w < EditorLimits.minRoomSide - 1e-9 ||
        s.d < EditorLimits.minRoomSide - 1e-9) {
      issues.add('Комната должна быть не меньше 1 × 1 м');
    }
    if (s.w > EditorLimits.maxRoomSide || s.d > EditorLimits.maxRoomSide) {
      issues.add('Комната слишком большая');
    }
    if (o.x.abs() > 500 ||
        o.y.abs() > 500 ||
        (o.x + s.w).abs() > 500 ||
        (o.y + s.d).abs() > 500) {
      issues.add('Слишком далеко от дома');
    }
    for (final r in doc.rooms) {
      if (r.id == room.id) continue;
      if (roomsOverlap(r, room)) {
        issues.add('Накладывается на комнату «${r.name}»');
      }
    }
    if (doc.room(room.id) == null &&
        doc.rooms.length >= EditorLimits.maxRooms) {
      issues.add('Не больше ${EditorLimits.maxRooms} комнат');
    }
    var outside = 0;
    for (final x in doc.objectsIn(room.id)) {
      final a = doc.asset(x.assetId);
      if (a == null) continue;
      final fp = x.footprint(a);
      if (x.position.x + fp.w > s.w + 1e-6 ||
          x.position.y + fp.d > s.d + 1e-6) {
        outside++;
      }
    }
    if (outside > 0) {
      issues.add(
        '$outside ${plural(outside, 'предмет', 'предмета', 'предметов')} '
        'окажется за стеной — сначала передвиньте ${outside == 1 ? 'его' : 'их'}',
      );
    }
    return issues;
  }

  /// Best resting height for a surface item at scene point (worldX, worldY)
  /// in [room]: the top or a shelf of the furniture under it. With
  /// [cursorWorld] (world pixels) each candidate height is tested by
  /// unprojecting the cursor onto that plane, so pointing at a desk top puts
  /// the item on the desk. Returns null for the floor.
  ({double z, String supportId})? surfaceAt(
    SceneDocument doc,
    SceneRoom room,
    double worldX,
    double worldY, {
    required String? excludeId,
    required double itemHeight,
    Offset? cursorWorld,
  }) {
    ({double z, String supportId})? best;
    for (final x in doc.objectsIn(room.id)) {
      if (x.id == excludeId) continue;
      final xa = doc.asset(x.assetId);
      if (xa == null) continue;
      final spec = catalog.placementOf(xa);
      if (!spec.top && spec.shelves.isEmpty) continue;
      final b = SceneLayout.boxOf(x, xa, room);
      final levels = <double>[
        if (spec.top) b.maxZ,
        for (final s in spec.shelves) b.minZ + s * x.scale,
      ]..sort((p, q) => q.compareTo(p));
      for (final z in levels) {
        // The cursor points at a plane of height z: unproject on it.
        var px = worldX, py = worldY;
        if (cursorWorld != null) (px, py) = Iso.unproject(cursorWorld, z: z);
        if (px < b.minX || px > b.maxX || py < b.minY || py > b.maxY) continue;
        final isTop = (z - b.maxZ).abs() < 1e-6;
        if (!isTop) {
          final above = levels
              .where((l) => l > z + 1e-6)
              .fold<double>(b.maxZ, math.min);
          if (z + itemHeight > above + _eps) continue;
        }
        if (best == null || z > best.z) best = (z: z, supportId: x.id);
        break;
      }
    }
    return best;
  }

  Support? _supportFor(
    SceneObject o,
    Box3 box,
    List<(SceneObject, SceneAsset, Box3)> others,
  ) {
    final cx = (box.minX + box.maxX) / 2, cy = (box.minY + box.maxY) / 2;
    for (final (x, xa, xb) in others) {
      final spec = catalog.placementOf(xa);
      if (spec.top && (xb.maxZ - box.minZ).abs() < _eps) {
        if (cx >= xb.minX &&
            cx <= xb.maxX &&
            cy >= xb.minY &&
            cy <= xb.maxY &&
            _overlapArea(box, xb) >= 0.6 * box.w * box.d) {
          return OnTop(x.id);
        }
      }
      for (final s in spec.shelves) {
        if ((xb.minZ + s * x.scale - box.minZ).abs() < _eps &&
            _containsXY(xb, box)) {
          return OnShelf(x.id);
        }
      }
    }
    return null;
  }

  Support? _wallFor(
    SceneDocument doc,
    SceneRoom room,
    SceneObject o,
    Size2 fp,
  ) {
    bool outsideAt(double x, double y) => !doc.rooms.any(
      (r) =>
          x >= r.origin.x &&
          x < r.origin.x + r.size.w &&
          y >= r.origin.y &&
          y < r.origin.y + r.size.d,
    );
    final p = o.position;
    if (o.rotation == 0 &&
        p.y <= EditorLimits.wallGap &&
        outsideAt(room.origin.x + p.x + fp.w / 2, room.origin.y - 0.05)) {
      return const OnWall(WallSide.north);
    }
    if (o.rotation == 90 &&
        p.x <= EditorLimits.wallGap &&
        outsideAt(room.origin.x - 0.05, room.origin.y + p.y + fp.d / 2)) {
      return const OnWall(WallSide.west);
    }
    return null;
  }
}

bool roomsOverlap(SceneRoom a, SceneRoom b) =>
    a.origin.x < b.origin.x + b.size.w - 1e-6 &&
    b.origin.x < a.origin.x + a.size.w - 1e-6 &&
    a.origin.y < b.origin.y + b.size.d - 1e-6 &&
    b.origin.y < a.origin.y + a.size.d - 1e-6;

bool _intersects(Box3 a, Box3 b) =>
    a.minX < b.maxX - _eps &&
    b.minX < a.maxX - _eps &&
    a.minY < b.maxY - _eps &&
    b.minY < a.maxY - _eps &&
    a.minZ < b.maxZ - _eps &&
    b.minZ < a.maxZ - _eps;

bool _containsXY(Box3 outer, Box3 inner) =>
    outer.minX <= inner.minX + _eps &&
    outer.maxX >= inner.maxX - _eps &&
    outer.minY <= inner.minY + _eps &&
    outer.maxY >= inner.maxY - _eps;

/// [inner] stands on one of [outer]'s shelves, within its volume.
bool _inside(
  Box3 inner,
  Box3 outer,
  CatalogAsset outerSpec,
  double outerScale,
) {
  if (outerSpec.shelves.isEmpty || !_containsXY(outer, inner)) return false;
  final onShelf = outerSpec.shelves.any(
    (s) => (outer.minZ + s * outerScale - inner.minZ).abs() < _eps,
  );
  return onShelf && inner.maxZ <= outer.maxZ + _eps;
}

double _overlapArea(Box3 a, Box3 b) {
  final w = math.min(a.maxX, b.maxX) - math.max(a.minX, b.minX);
  final d = math.min(a.maxY, b.maxY) - math.max(a.minY, b.minY);
  return w <= 0 || d <= 0 ? 0 : w * d;
}

/// Russian plural form: 1 предмет, 2 предмета, 5 предметов.
String plural(int n, String one, String few, String many) {
  final m10 = n % 10, m100 = n % 100;
  if (m10 == 1 && m100 != 11) return one;
  if (m10 >= 2 && m10 <= 4 && (m100 < 12 || m100 > 14)) return few;
  return many;
}

/// Tiles → «3,5 м» (1 tile = 0.5 m).
String metersLabel(double tiles) {
  final m = tiles / 2;
  final t = m == m.roundToDouble()
      ? m.toStringAsFixed(0)
      : m.toStringAsFixed(m * 10 == (m * 10).roundToDouble() ? 1 : 2);
  return '${t.replaceAll('.', ',')} м';
}
