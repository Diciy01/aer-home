import 'package:aer_home_desktop/src/scene/geometry/iso.dart';
import 'package:aer_home_desktop/src/scene/geometry/scene_layout.dart';
import 'package:aer_home_desktop/src/scene/model/scene_document.dart';
import 'package:flutter_test/flutter_test.dart';

import 'scene_fixtures.dart';

void main() {
  test('projection matches the documented 2:1 formula', () {
    expect(Iso.project(0, 0, 0), Offset.zero);
    expect(Iso.project(1, 0, 0), const Offset(32, 16));
    expect(Iso.project(0, 1, 0), const Offset(-32, 16));
    expect(Iso.project(0, 0, 1), const Offset(0, -36));
  });

  test('unproject inverts project on any plane', () {
    for (final (x, y, z) in [
      (0.0, 0.0, 0.0),
      (3.5, 7.25, 0.0),
      (12.0, 2.0, 1.5),
      (-4.0, 9.0, 3.0),
    ]) {
      final (ux, uy) = Iso.unproject(Iso.project(x, y, z), z: z);
      expect(ux, closeTo(x, 1e-9));
      expect(uy, closeTo(y, 1e-9));
    }
  });

  test('box silhouette is a convex hexagon and contains its centre', () {
    const b = Box3(0, 0, 0, 2, 1, 1);
    final hull = Iso.silhouette(b);
    expect(hull, hasLength(6));
    expect(pointInConvex(hull, Iso.project(1, 0.5, 0.5)), isTrue);
    expect(pointInConvex(hull, const Offset(500, 500)), isFalse);
  });

  test(
    'depth: separating axis decides, stacked items come after their support',
    () {
      const desk = Box3(0, 0, 0, 3, 2, 1.5),
          monitor = Box3(1, 0.2, 1.5, 2, 0.6, 2.5);
      expect(isBehind(desk, monitor), isTrue);
      const back = Box3(0, 0, 0, 1, 1, 1), front = Box3(0, 2, 0, 1, 3, 1);
      expect(isBehind(back, front), isTrue);
      expect(isBehind(front, back), isFalse);
      const shelf = Box3(0, 0, 0, 3, 1, 3),
          item = Box3(0.5, 0.1, 1, 1.5, 0.9, 1.8);
      expect(
        isBehind(shelf, item),
        isTrue,
        reason: 'container before contents',
      );
      final order = depthOrder([monitor, front, desk, back]);
      expect(
        order.indexOf(2) < order.indexOf(0),
        isTrue,
        reason: 'desk before monitor',
      );
      expect(
        order.indexOf(3) < order.indexOf(1),
        isTrue,
        reason: 'back before front',
      );
    },
  );

  group('demo layout', () {
    final layout = SceneLayout.build(exampleScene());
    ObjectGeometry obj(String label) =>
        layout.objects.values.firstWhere((g) => g.object.label == label);
    int pos(ObjectGeometry g) =>
        layout.drawOrder.indexWhere((i) => i is ObjectItem && i.geometry == g);

    test('every object has geometry and walls exist', () {
      expect(layout.objects, hasLength(layout.document.objects.length));
      expect(layout.drawOrder.whereType<WallItem>(), isNotEmpty);
      expect(
        layout.drawOrder.whereType<WallItem>().where((w) => w.wall.tall),
        isNotEmpty,
      );
      expect(
        layout.floorObjects.every((g) => g.object.layer == SceneLayer.floor),
        isTrue,
      );
    });

    test('monitor is drawn after the desk, items after their shelf', () {
      expect(pos(obj('Рабочий стол')) < pos(obj('Монитор')), isTrue);
      expect(pos(obj('Стеллаж')) < pos(obj('Домашний сервер')), isTrue);
      expect(pos(obj('Тумба')) < pos(obj('Телевизор')), isTrue);
    });

    test('hit test returns the front-most object, never the hidden one', () {
      final monitor = obj('Монитор'), desk = obj('Рабочий стол');
      final onMonitor = Iso.project(
        (monitor.box.minX + monitor.box.maxX) / 2,
        monitor.box.maxY,
        monitor.box.minZ + 0.5,
      );
      expect(layout.hitTest(onMonitor)?.object.id, monitor.object.id);
      expect(
        pointInConvex(desk.silhouette, onMonitor),
        isTrue,
        reason: 'desk silhouette overlaps there too',
      );
      final onDeskTop = Iso.project(
        desk.box.maxX - 0.3,
        desk.box.maxY - 0.2,
        desk.box.maxZ,
      );
      expect(layout.hitTest(onDeskTop)?.object.id, desk.object.id);
    });

    test('rugs are not hit-testable; floor maps to its room', () {
      final rug = layout.floorObjects.first;
      final c = Iso.project(
        (rug.box.minX + rug.box.maxX) / 2,
        (rug.box.minY + rug.box.maxY) / 2,
        0,
      );
      expect(layout.hitTest(c)?.object.layer, isNot(SceneLayer.floor));
      expect(layout.roomAt(c)?.room.id, rug.room.id);
      expect(layout.roomAt(const Offset(99999, 99999)), isNull);
    });

    test('bounds cover every room', () {
      for (final r in layout.rooms) {
        expect(
          layout.bounds.contains(Iso.project(r.x0 + 0.1, r.y0 + 0.1)),
          isTrue,
        );
        expect(
          layout.bounds.contains(Iso.project(r.x1 - 0.1, r.y1 - 0.1)),
          isTrue,
        );
      }
    });
  });
}
