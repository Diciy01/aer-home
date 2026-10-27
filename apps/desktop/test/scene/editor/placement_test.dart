import 'package:aer_home_desktop/src/scene/catalog/scene_catalog.dart';
import 'package:aer_home_desktop/src/scene/editor/placement.dart';
import 'package:aer_home_desktop/src/scene/model/scene_document.dart';
import 'package:flutter_test/flutter_test.dart';

import '../scene_fixtures.dart';

void main() {
  final catalog = SceneCatalog.builtin;
  final v = PlacementValidator(catalog);
  late SceneDocument doc;
  SceneObject byAsset(String a) =>
      doc.objects.firstWhere((o) => o.assetId == a);
  SceneRoom room(String kind) => doc.rooms.firstWhere((r) => r.kind == kind);

  setUp(() => doc = exampleScene());

  test('catalog geometry matches every asset of the demo scene', () {
    for (final a in doc.assets) {
      final c = catalog.asset(a.id);
      expect(c, isNotNull, reason: '${a.id} missing from the catalog');
      expect(c!.footprint.w, a.footprint.w, reason: a.id);
      expect(c.footprint.d, a.footprint.d, reason: a.id);
      expect(c.height, a.height, reason: a.id);
    }
    // Layer in the scene agrees with the catalog placement type.
    for (final o in doc.objects) {
      expect(catalog.asset(o.assetId)!.layer, o.layer, reason: o.assetId);
    }
  });

  test('the demo house is fully valid: on desks, on shelves, rugs, wall', () {
    expect(v.checkDocument(doc), isEmpty);
    expect(
      v.checkObject(doc, byAsset('cozy/monitor')).support,
      isA<OnTop>(),
      reason: 'monitor stands on the desk',
    );
    expect(
      v.checkObject(doc, byAsset('cozy/server_box')).support,
      isA<OnShelf>(),
    );
    expect(
      v.checkObject(doc, byAsset('cozy/link_panel')).support,
      isA<OnWall>(),
    );
    expect(v.checkObject(doc, byAsset('cozy/desk')).support, isA<OnFloor>());
  });

  test('out of room bounds and oversize', () {
    final desk = byAsset('cozy/desk');
    final out = desk.copyWith(position: const Point3(8, 0.3, 0));
    expect(v.checkObject(doc, out).issues.join(), contains('пределы'));
    final huge = desk.copyWith(scale: 4);
    expect(v.checkObject(doc, huge).ok, isFalse);
  });

  test('furniture may not overlap; rug under furniture is fine', () {
    final chair = byAsset('cozy/office_chair');
    // Chair pushed into the desk volume.
    final bad = chair.copyWith(position: const Point3(3.1, 0.6, 0));
    expect(v.checkObject(doc, bad).issues.join(), contains('Пересекается'));
    // Chair standing on the rug area.
    final onRug = chair.copyWith(position: const Point3(3.0, 4.0, 0));
    expect(v.checkObject(doc, onRug).ok, isTrue);
    // A rug can be anywhere on the floor, under the desk too.
    final rug = byAsset('cozy/rug').copyWith(position: const Point3(1.5, 0, 0));
    expect(v.checkObject(doc, rug).ok, isTrue);
  });

  test('surface items need support; floor-only items stay on the floor', () {
    final lamp = byAsset('cozy/desk_lamp');
    // Lifted into the air away from the desk.
    final floating = lamp.copyWith(position: const Point3(8, 5, 1.5));
    expect(v.checkObject(doc, floating).issues.join(), contains('висит'));
    // On the floor it is fine too.
    expect(
      v.checkObject(doc, lamp.copyWith(position: const Point3(8, 5, 0))).ok,
      isTrue,
    );
    final plant = byAsset('cozy/plant');
    expect(
      v
          .checkObject(
            doc,
            plant.copyWith(position: const Point3(2.5, 0.5, 1.5)),
          )
          .issues
          .join(),
      contains('только на пол'),
    );
  });

  test(
    'shelf levels hold items; too tall items do not fit between shelves',
    () {
      final box = byAsset('cozy/server_box');
      final top = box.copyWith(
        position: Point3(box.position.x, box.position.y, 3.0),
      );
      expect(
        v.checkObject(doc, top).support,
        isA<OnTop>(),
        reason: 'on the shelf top',
      );
      final server = room('server');
      final s = v.surfaceAt(
        doc,
        server,
        server.origin.x + 3.5,
        server.origin.y + 0.7,
        excludeId: null,
        itemHeight: 0.9,
      );
      expect(s, isNotNull);
      expect(s!.z, 3.0, reason: 'highest free level under the point');
    },
  );

  test('wall items hang on outer back walls only', () {
    final panel = byAsset('cozy/link_panel');
    expect(v.checkObject(doc, panel).ok, isTrue);
    // Rotated away from the wall.
    expect(v.checkObject(doc, panel.copyWith(rotation: 0)).ok, isFalse);
    // Pulled into the room.
    expect(
      v
          .checkObject(doc, panel.copyWith(position: const Point3(3, 4.6, 1.6)))
          .ok,
      isFalse,
    );
    // Too high for the wall.
    expect(
      v
          .checkObject(
            doc,
            panel.copyWith(position: const Point3(0.05, 4.6, 4.5)),
          )
          .issues
          .join(),
      contains('высоте'),
    );
  });

  test('rooms: overlap, size limits and objects left outside', () {
    final office = room('office');
    expect(v.checkRoom(doc, office), isEmpty);
    expect(
      v.checkRoom(doc, office.copyWith(origin: const Point2(5, 0))).join(),
      contains('Накладывается'),
    );
    expect(
      v.checkRoom(doc, office.copyWith(size: const Size2(1, 8))).join(),
      contains('не меньше'),
    );
    final shrunk = v.checkRoom(doc, office.copyWith(size: const Size2(6, 8)));
    expect(shrunk.join(), contains('окажется за стеной'));
    expect(plural(1, 'предмет', 'предмета', 'предметов'), 'предмет');
    expect(plural(3, 'предмет', 'предмета', 'предметов'), 'предмета');
    expect(plural(11, 'предмет', 'предмета', 'предметов'), 'предметов');
  });

  test('catalog search and categories', () {
    expect(catalog.assets.length, greaterThanOrEqualTo(26));
    for (final c in [
      'furniture',
      'computers',
      'servers',
      'network',
      'media',
      'automation',
      'decor',
    ]) {
      expect(catalog.search(category: c), isNotEmpty, reason: c);
    }
    expect(
      catalog.search(query: 'монитор').map((a) => a.id),
      contains('cozy/monitor'),
    );
    expect(
      catalog.search(query: 'стол', category: 'furniture').length,
      greaterThanOrEqualTo(2),
    );
    expect(catalog.search(query: 'нет-такого'), isEmpty);
  });

  test('materials and lights are data; unknown ids fall back', () {
    for (final f in ['oak', 'tile_warm', 'stone_light', 'carpet']) {
      expect(catalog.floors[f], isNotNull, reason: f);
    }
    for (final w in ['milk', 'beige', 'sand', 'sage_light', 'taupe_warm']) {
      expect(catalog.walls[w], isNotNull, reason: w);
    }
    // Every material used by the demo is known.
    for (final r in doc.rooms) {
      expect(catalog.floors[r.style.floor], isNotNull);
      expect(catalog.walls[r.style.wall], isNotNull);
    }
    expect(catalog.floor('marble_from_future').id, 'unknown');
    expect(catalog.light(null), isNull);
    expect(catalog.light('warm')!.tint.a, greaterThan(0));
  });
}
