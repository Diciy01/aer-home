import 'dart:ui';

import '../model/scene_document.dart';
import 'iso.dart';

/// Wall thickness and the height of low interior partitions (tiles).
const wallThickness = 0.25;
const partitionHeight = 0.7;
const floorThickness = 0.6;

class RoomGeometry {
  RoomGeometry(this.room)
    : x0 = room.origin.x,
      y0 = room.origin.y,
      x1 = room.origin.x + room.size.w,
      y1 = room.origin.y + room.size.d;

  final SceneRoom room;
  final double x0, y0, x1, y1;

  Box3 get floorBox => Box3(x0, y0, -floorThickness, x1, y1, 0);

  bool contains(double x, double y) => x >= x0 && x < x1 && y >= y0 && y < y1;

  /// Screen rect covering the room floor plus a typical wall height (camera focus).
  Rect get focusBounds =>
      Iso.screenBounds(Box3(x0, y0, 0, x1, y1, room.wallHeight * 0.6));
}

enum WallSide { north, west }

class WallSegment {
  const WallSegment({
    required this.roomId,
    required this.side,
    required this.box,
    required this.tall,
    required this.window,
  });

  final String roomId;
  final WallSide side;
  final Box3 box;

  /// Outer walls are tall; partitions between rooms stay low (cutaway view).
  final bool tall;
  final bool window;
}

class ObjectGeometry {
  ObjectGeometry({
    required this.object,
    required this.asset,
    required this.room,
    required this.box,
  }) : silhouette = Iso.silhouette(box),
       screenBounds = Iso.screenBounds(box);

  final SceneObject object;
  final SceneAsset asset;
  final SceneRoom room;
  final Box3 box;
  final List<Offset> silhouette;
  final Rect screenBounds;

  bool get interactive => object.layer != SceneLayer.floor;

  /// Anchor for labels and status badges: top centre of the box.
  Offset get topAnchor => Iso.project(
    (box.minX + box.maxX) / 2,
    (box.minY + box.maxY) / 2,
    box.maxZ,
  );
}

/// One entry of the painter's order.
sealed class DrawItem {
  const DrawItem();
}

class WallItem extends DrawItem {
  const WallItem(this.wall);
  final WallSegment wall;
}

class ObjectItem extends DrawItem {
  const ObjectItem(this.geometry);
  final ObjectGeometry geometry;
}

/// Everything the renderer and interaction need, computed once per document.
class SceneLayout {
  SceneLayout._(
    this.document,
    this.rooms,
    this.floorObjects,
    this.drawOrder,
    this.objects,
    this.bounds,
  );

  factory SceneLayout.build(SceneDocument doc) {
    final rooms = [for (final r in doc.rooms) RoomGeometry(r)]
      ..sort((a, b) => (a.x0 + a.y0).compareTo(b.x0 + b.y0));

    final objects = <String, ObjectGeometry>{};
    for (final o in doc.objects) {
      final asset = doc.asset(o.assetId);
      final room = doc.room(o.roomId);
      if (asset == null || room == null) continue;
      objects[o.id] = ObjectGeometry(
        object: o,
        asset: asset,
        room: room,
        box: boxOf(o, asset, room),
      );
    }

    final walls = _walls(rooms);
    final floorObjects =
        objects.values.where((g) => g.object.layer == SceneLayer.floor).toList()
          ..sort((a, b) => a.box.depthKey.compareTo(b.box.depthKey));
    final items = <DrawItem>[
      for (final w in walls) WallItem(w),
      for (final g in objects.values)
        if (g.object.layer != SceneLayer.floor) ObjectItem(g),
    ];
    final boxes = [
      for (final i in items)
        switch (i) {
          WallItem(:final wall) => wall.box,
          ObjectItem(:final geometry) => geometry.box,
        },
    ];
    final order = [for (final i in depthOrder(boxes)) items[i]];

    var bounds = Rect.zero;
    var first = true;
    void include(Rect r) {
      bounds = first ? r : bounds.expandToInclude(r);
      first = false;
    }

    for (final r in rooms) {
      include(
        Iso.screenBounds(Box3(r.x0, r.y0, -floorThickness, r.x1, r.y1, 0)),
      );
    }
    for (final w in walls) {
      include(Iso.screenBounds(w.box));
    }
    for (final g in objects.values) {
      include(g.screenBounds);
    }
    return SceneLayout._(doc, rooms, floorObjects, order, objects, bounds);
  }

  /// World box of an object: room origin + local position, rotated and
  /// scaled footprint, scaled height. The one place this mapping lives.
  static Box3 boxOf(SceneObject o, SceneAsset asset, SceneRoom room) {
    final fp = o.footprint(asset);
    final x = room.origin.x + o.position.x, y = room.origin.y + o.position.y;
    return Box3(
      x,
      y,
      o.position.z,
      x + fp.w,
      y + fp.d,
      o.position.z + asset.height * o.scale,
    );
  }

  final SceneDocument document;
  final List<RoomGeometry> rooms;
  final List<ObjectGeometry> floorObjects;
  final List<DrawItem> drawOrder;
  final Map<String, ObjectGeometry> objects;

  /// Screen-space bounds of the whole house at zoom 1.
  final Rect bounds;

  RoomGeometry? roomGeometry(String id) =>
      rooms.where((r) => r.room.id == id).firstOrNull;

  /// Topmost interactive object under a world-pixel point. Objects later in
  /// the painter's order cover earlier ones, so the scan runs backwards: an
  /// object hidden behind another is never picked through it.
  ObjectGeometry? hitTest(Offset world) {
    for (final item in drawOrder.reversed) {
      switch (item) {
        case WallItem(:final wall):
          // Tall walls occlude what is behind them.
          if (wall.tall && pointInConvex(Iso.silhouette(wall.box), world)) {
            return null;
          }
        case ObjectItem(:final geometry):
          if (geometry.interactive &&
              geometry.screenBounds.contains(world) &&
              pointInConvex(geometry.silhouette, world)) {
            return geometry;
          }
      }
    }
    return null;
  }

  /// Like [hitTest], but floor decor (rugs) is selectable too: the editor
  /// must reach every object, the viewer ignores rugs.
  ObjectGeometry? hitTestEditable(Offset world) {
    final hit = hitTest(world);
    if (hit != null) return hit;
    for (final g in floorObjects.reversed) {
      if (g.screenBounds.contains(world) &&
          pointInConvex(g.silhouette, world)) {
        return g;
      }
    }
    return null;
  }

  /// Room whose floor is under a world-pixel point.
  RoomGeometry? roomAt(Offset world) {
    final (x, y) = Iso.unproject(world);
    return rooms.where((r) => r.contains(x, y)).firstOrNull;
  }

  static List<WallSegment> _walls(List<RoomGeometry> rooms) {
    bool occupied(double x, double y) => rooms.any((r) => r.contains(x, y));
    final out = <WallSegment>[];
    for (final r in rooms) {
      final h = r.room.wallHeight;
      for (final side in WallSide.values) {
        final length = side == WallSide.north ? r.x1 - r.x0 : r.y1 - r.y0;
        final n = length.ceil();
        // Classify unit segments, then merge runs with equal flags.
        final segs = <(double, double, bool, bool)>[];
        for (var i = 0; i < n; i++) {
          final a = i.toDouble(), b = (i + 1.0).clamp(0.0, length);
          final mid = (a + b) / 2;
          final outside = side == WallSide.north
              ? !occupied(r.x0 + mid, r.y0 - 0.05)
              : !occupied(r.x0 - 0.05, r.y0 + mid);
          final door = !outside && n >= 4 && (i == n ~/ 2 || i == n ~/ 2 - 1);
          if (door) continue;
          final window = outside && n >= 6 && (i == n ~/ 2 || i == n ~/ 2 - 1);
          segs.add((a, b, outside, window));
        }
        var k = 0;
        while (k < segs.length) {
          var (a, b, tall, window) = segs[k];
          while (k + 1 < segs.length &&
              segs[k + 1].$1 == b &&
              segs[k + 1].$3 == tall &&
              segs[k + 1].$4 == window) {
            b = segs[++k].$2;
          }
          k++;
          final height = tall ? h : partitionHeight;
          if (height <= 0) continue;
          final box = side == WallSide.north
              ? Box3(
                  r.x0 + a - (a == 0 ? wallThickness : 0),
                  r.y0 - wallThickness,
                  0,
                  r.x0 + b,
                  r.y0,
                  height,
                )
              : Box3(r.x0 - wallThickness, r.y0 + a, 0, r.x0, r.y0 + b, height);
          out.add(
            WallSegment(
              roomId: r.room.id,
              side: side,
              box: box,
              tall: tall,
              window: window,
            ),
          );
        }
      }
    }
    return out;
  }
}
