import 'package:aer_home_desktop/src/scene/editor/editor_commands.dart';
import 'package:aer_home_desktop/src/scene/model/scene_codec.dart';
import 'package:aer_home_desktop/src/scene/model/scene_document.dart';
import 'package:aer_home_desktop/src/scene/model/scene_edit.dart';
import 'package:flutter_test/flutter_test.dart';

import '../scene_fixtures.dart';

void main() {
  const edits = SceneEdits();
  const codec = SceneCodec();
  late SceneDocument doc;
  SceneRoom room(String kind) => doc.rooms.firstWhere((r) => r.kind == kind);
  SceneObject obj(String asset) =>
      doc.objects.firstWhere((o) => o.assetId == asset);

  setUp(() => doc = exampleScene());

  test('uuid v4 shape', () {
    final ids = {for (var i = 0; i < 200; i++) newUuid()};
    expect(ids.length, 200);
    for (final id in ids) {
      expect(isUuid(id), isTrue, reason: id);
      expect(id[14], '4');
    }
  });

  test('room commands: add, update, duplicate (with objects), remove', () {
    final r = SceneRoom(
      id: newUuid(),
      name: 'Мастерская',
      kind: 'custom',
      origin: const Point2(29, 0),
      size: const Size2(6, 6),
      wallHeight: 5,
      style: const RoomStyle(floor: 'stone_light', wall: 'sage_light'),
    );
    var d = AddRoom(r).apply(doc, edits);
    expect(d.room(r.id)!.style.floor, 'stone_light');
    d = UpdateRoom(
      r.id,
      label: 'x',
      name: 'Студия',
      size: const Size2(8, 6),
    ).apply(d, edits);
    expect(d.room(r.id)!.name, 'Студия');
    expect(d.room(r.id)!.size.w, 8);

    final office = room('office');
    final dup = DuplicateRoom(doc, office.id, origin: const Point2(0, 15));
    final d2 = dup.apply(doc, edits);
    expect(d2.rooms.length, doc.rooms.length + 1);
    expect(d2.objectsIn(dup.newRoomId).length, doc.objectsIn(office.id).length);
    expect(d2.room(dup.newRoomId)!.name, 'Кабинет (копия)');
    // Same command → same ids (redo safe).
    expect(codec.encode(dup.apply(doc, edits)), codec.encode(d2));

    final d3 = RemoveRoom(office.id, office.name).apply(doc, edits);
    expect(d3.room(office.id), isNull);
    expect(d3.objectsIn(office.id), isEmpty);
  });

  test(
    'object commands: add (declares asset), move, rotate, scale, remove',
    () {
      final plant = obj('cozy/plant');
      final asset = const SceneAsset(
        id: 'cozy/vase',
        label: 'Ваза',
        footprint: Size2(0.4, 0.4),
        height: 0.7,
        art: AssetArt(
          kind: 'procedural',
          ref: 'cozy/vase',
          status: 'placeholder',
        ),
      );
      final o = SceneObject(
        id: newUuid(),
        roomId: room('office').id,
        assetId: 'cozy/vase',
        position: const Point3(8, 6, 0),
      );
      final d = AddObject(o, asset).apply(doc, edits);
      expect(d.asset('cozy/vase'), isNotNull);
      expect(d.object(o.id), isNotNull);
      final moved = UpdateObject(
        plant.id,
        label: 'm',
        position: const Point3(1, 5, 0),
      ).apply(doc, edits);
      expect(moved.object(plant.id)!.position.y, 5);
      final turned = UpdateObject(
        plant.id,
        label: 'r',
        rotation: 90,
      ).apply(doc, edits);
      expect(turned.object(plant.id)!.rotation, 90);
      final scaled = UpdateObject(
        plant.id,
        label: 's',
        scale: 1.5,
      ).apply(doc, edits);
      expect(scaled.object(plant.id)!.scale, 1.5);
      expect(
        RemoveObject(plant.id, 'p').apply(doc, edits).object(plant.id),
        isNull,
      );
      // Invalid result is rejected by validation, input untouched.
      expect(
        () => UpdateObject(
          plant.id,
          label: 'x',
          position: const Point3(50, 0, 0),
        ).apply(doc, edits),
        throwsA(isA<SceneFormatException>()),
      );
      expect(doc.object(plant.id)!.position.x, plant.position.x);
    },
  );

  test('duplicate object keeps binding; bind/unbind', () {
    final pc = obj('cozy/pc_tower');
    const entity = '11111111-1111-4111-8111-111111111111';
    var d = BindEntity(pc.id, entity, 'ПК').apply(doc, edits);
    expect(d.object(pc.id)!.entityBinding!.entityId, entity);
    final dup = DuplicateObject(pc.id, 'ПК', const Point3(8, 6, 0));
    d = dup.apply(d, edits);
    expect(d.object(dup.newId)!.entityBinding!.entityId, entity);
    d = UnbindEntity(pc.id, 'ПК').apply(d, edits);
    expect(d.object(pc.id)!.entityBinding, isNull);
    expect(d.object(dup.newId)!.entityBinding, isNotNull);
  });

  test('history: undo/redo series restores exact documents', () {
    final h = EditHistory();
    final docs = <SceneDocument>[doc];
    final plant = obj('cozy/plant');
    final cmds = <EditCommand>[
      UpdateObject(plant.id, label: 'a', position: const Point3(1, 5, 0)),
      UpdateObject(plant.id, label: 'b', rotation: 90),
      RemoveRoom(room('server').id, 'Серверная'),
      BindEntity(
        obj('cozy/pc_tower').id,
        '11111111-1111-4111-8111-111111111111',
        'ПК',
      ),
    ];
    for (final c in cmds) {
      final next = c.apply(docs.last, edits);
      h.record(c.label, docs.last, next);
      docs.add(next);
    }
    var cur = docs.last;
    for (var i = docs.length - 2; i >= 0; i--) {
      cur = h.undo()!;
      expect(identical(cur, docs[i]), isTrue);
    }
    expect(h.undo(), isNull);
    for (var i = 1; i < docs.length; i++) {
      cur = h.redo()!;
      expect(codec.encode(cur), codec.encode(docs[i]));
    }
    expect(h.redo(), isNull);
    // 50 more cycles do not corrupt anything.
    for (var k = 0; k < 50; k++) {
      while (h.canUndo) {
        cur = h.undo()!;
      }
      while (h.canRedo) {
        cur = h.redo()!;
      }
    }
    expect(codec.encode(cur), codec.encode(docs.last));
    codec.validate(cur);
  });

  test('history: new edit clears redo; merge window; limit', () {
    final h = EditHistory(limit: 3);
    final t = DateTime(2026);
    final a = doc, b = doc.copyWith(name: 'b'), c = doc.copyWith(name: 'c');
    h.record('1', a, b, mergeKey: 'k', now: t);
    h.record(
      '2',
      b,
      c,
      mergeKey: 'k',
      now: t.add(const Duration(milliseconds: 500)),
    );
    expect(h.length, 1, reason: 'slider drags collapse into one step');
    expect(h.undo()!.name, a.name);
    expect(h.canRedo, isTrue);
    h.record('3', a, b, now: t.add(const Duration(seconds: 5)));
    expect(h.canRedo, isFalse);
    h.record('4', b, c, mergeKey: 'k', now: t.add(const Duration(seconds: 10)));
    h.record('5', c, b, mergeKey: 'k', now: t.add(const Duration(seconds: 20)));
    h.record('6', b, c, now: t.add(const Duration(seconds: 30)));
    expect(h.length, 3, reason: 'bounded');
    expect(h.labels, ['4', '5', '6']);
  });
}
