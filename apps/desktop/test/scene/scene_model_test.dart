import 'dart:convert';
import 'dart:io';

import 'package:aer_home_desktop/src/scene/model/scene_codec.dart';
import 'package:aer_home_desktop/src/scene/model/scene_document.dart';
import 'package:aer_home_desktop/src/scene/model/scene_edit.dart';
import 'package:aer_home_desktop/src/scene/repository/scene_repository.dart';
import 'package:flutter_test/flutter_test.dart';

import 'scene_fixtures.dart';

Map<String, dynamic> exampleJson() =>
    jsonDecode(exampleFile.readAsStringSync()) as Map<String, dynamic>;

Map<String, String> issuesOf(Object? json) {
  try {
    const SceneCodec().decode(json);
  } on SceneFormatException catch (e) {
    return e.issues;
  }
  fail('expected SceneFormatException');
}

void main() {
  const codec = SceneCodec();

  test('example scene decodes: 5 rooms with furniture and devices', () {
    final doc = exampleScene();
    expect(
      doc.rooms.map((r) => r.kind),
      containsAll(['office', 'server', 'living', 'network', 'automation']),
    );
    expect(doc.objects.length, greaterThanOrEqualTo(30));
    for (final r in doc.rooms) {
      expect(
        doc.objectsIn(r.id),
        isNotEmpty,
        reason: '${r.name} must not be empty',
      );
    }
    expect(doc.demo, isTrue);
  });

  testWidgets('bundled demo loads through the app asset bundle', (
    tester,
  ) async {
    final doc = await tester.runAsync(loadBundledDemo);
    expect(doc!.rooms, hasLength(5));
  });

  test('bundled demo asset is identical to examples/home.scene.json', () {
    final bundled = File('assets/scenes/demo_home.scene.json')
        .readAsStringSync();
    expect(bundled, exampleFile.readAsStringSync());
  });

  test('encode → decode round trip is lossless', () {
    final doc = exampleScene();
    final again = codec.decodeString(codec.encode(doc));
    expect(codec.encode(again), codec.encode(doc));
  });

  test('validation mirrors Core rules', () {
    final cases = <String, (void Function(Map<String, dynamic>), String)>{
      'future version': ((d) => d['schemaVersion'] = 2, 'schemaVersion'),
      'scene id not uuid': ((d) => d['sceneId'] = 'home', 'sceneId'),
      'room id not uuid': (
        (d) => (d['rooms'] as List)[0]['id'] = 'room-office',
        'rooms[0].id',
      ),
      'object id not uuid': (
        (d) => (d['objects'] as List)[0]['id'] = 'visual-pc',
        'objects[0].id',
      ),
      'rooms overlap': (
        (d) => (d['rooms'] as List)[1]['origin'] = {'x': 5, 'y': 0},
        'rooms[1]',
      ),
      'outside room': (
        (d) =>
            (d['objects'] as List)[0]['position'] = {'x': 9.5, 'y': 0, 'z': 0},
        'objects[0].position',
      ),
      'negative coordinate': (
        (d) =>
            (d['objects'] as List)[0]['position'] = {'x': -1, 'y': 0, 'z': 0},
        'objects[0].position.x',
      ),
      'rotation 45': (
        (d) => (d['objects'] as List)[0]['rotation'] = 45,
        'objects[0].rotation',
      ),
      'scale': (
        (d) => (d['objects'] as List)[0]['scale'] = 9,
        'objects[0].scale',
      ),
      'unknown asset': (
        (d) => (d['objects'] as List)[0]['assetId'] = 'cozy/piano',
        'objects[0].assetId',
      ),
      'binding not uuid': (
        (d) => (d['objects'] as List)[0]['entityBinding'] = {
          'entityId': 'pc',
          'role': 'primary',
        },
        'objects[0].entityBinding.entityId',
      ),
      'demo state on bound object': (
        (d) => (d['objects'] as List)[4]['entityBinding'] = {
          'entityId': '00000000-0000-4000-8000-000000000001',
          'role': 'primary',
        },
        'objects[4].visualState',
      ),
      'demo state in real scene': (
        (d) => d['demo'] = false,
        'objects[4].visualState',
      ),
      'metrics leaked into scene': (
        (d) => (d['objects'] as List)[0]['cpuLoad'] = 0.5,
        'objects[0].cpuLoad',
      ),
      'legacy deviceBinding': (
        (d) => (d['objects'] as List)[0]['deviceBinding'] = {},
        'objects[0].deviceBinding',
      ),
    };
    for (final MapEntry(key: name, value: (mutate, path)) in cases.entries) {
      final json = exampleJson();
      mutate(json);
      expect(issuesOf(json), contains(path), reason: name);
    }
  });

  test('corrupt JSON is reported, not thrown as a crash', () {
    expect(
      () =>
          codec.decodeString(exampleFile.readAsStringSync().substring(0, 300)),
      throwsA(isA<SceneFormatException>()),
    );
    expect(
      () => codec.decodeString('[]'),
      throwsA(isA<SceneFormatException>()),
    );
    expect(issuesOf(null), contains(''));
  });

  test('rotation swaps footprint; scale multiplies it', () {
    const a = SceneAsset(
      id: 'x',
      label: '',
      footprint: Size2(2, 1),
      height: 1,
      art: AssetArt(kind: 'procedural', ref: 'x', status: 'placeholder'),
    );
    const o = SceneObject(
      id: 'i',
      roomId: 'r',
      assetId: 'x',
      position: Point3(0, 0, 0),
      rotation: 90,
      scale: 1.5,
    );
    final fp = o.footprint(a);
    expect((fp.w, fp.d), (1.5, 3.0));
  });

  group('edit operations (M04 contract)', () {
    const edits = SceneEdits();
    final doc = exampleScene();
    final pc = doc.objects.firstWhere((o) => o.label == 'Основной ПК');
    final office = doc.rooms.firstWhere((r) => r.kind == 'office');

    test('move, rotate, scale, layer return new validated documents', () {
      final moved = edits.moveObject(doc, pc.id, const Point3(0.5, 5, 0));
      expect(moved.object(pc.id)!.position.y, 5);
      expect(
        doc.object(pc.id)!.position.y,
        pc.position.y,
        reason: 'input untouched',
      );
      expect(edits.rotateObject(doc, pc.id, 90).object(pc.id)!.rotation, 90);
      expect(edits.scaleObject(doc, pc.id, 1.2).object(pc.id)!.scale, 1.2);
      expect(
        edits.setLayer(doc, pc.id, SceneLayer.wall).object(pc.id)!.layer,
        SceneLayer.wall,
      );
    });

    test('invalid edits are rejected', () {
      expect(
        () => edits.moveObject(doc, pc.id, const Point3(50, 0, 0)),
        throwsA(isA<SceneFormatException>()),
      );
      expect(
        () => edits.rotateObject(doc, pc.id, 45),
        throwsA(isA<SceneFormatException>()),
      );
      expect(
        () => edits.resizeRoom(doc, office.id, const Size2(2, 2)),
        throwsA(isA<SceneFormatException>()),
        reason: 'objects would fall outside',
      );
      expect(
        () => edits.moveObject(doc, 'nope', const Point3(0, 0, 0)),
        throwsA(isA<SceneFormatException>()),
      );
    });

    test('binding drops the demo state; unbinding keeps the object', () {
      const id = '11111111-1111-4111-8111-111111111111';
      final bound = edits.bindEntity(doc, pc.id, id);
      expect(bound.object(pc.id)!.entityBinding!.entityId, id);
      expect(bound.object(pc.id)!.demoState, isNull);
      expect(bound.boundEntityIds, {id});
      expect(
        edits.unbindEntity(bound, pc.id).object(pc.id)!.entityBinding,
        isNull,
      );
    });

    test('add/remove room and object', () {
      final room = SceneRoom(
        id: '22222222-2222-4222-8222-222222222222',
        name: 'Терраса',
        kind: 'custom',
        origin: const Point2(22, 8),
        size: const Size2(6, 6),
        wallHeight: 0,
        style: const RoomStyle(floor: 'oak', wall: 'cream'),
      );
      final withRoom = edits.addRoom(doc, room);
      expect(withRoom.rooms, hasLength(6));
      final withObj = edits.addObject(
        withRoom,
        const SceneObject(
          id: '33333333-3333-4333-8333-333333333333',
          roomId: '22222222-2222-4222-8222-222222222222',
          assetId: 'cozy/plant',
          position: Point3(1, 1, 0),
        ),
      );
      expect(withObj.objects.length, doc.objects.length + 1);
      final removed = edits.removeRoom(withObj, room.id);
      expect(
        removed.objects.length,
        doc.objects.length,
        reason: 'objects of the room go with it',
      );
      expect(
        () => edits.addRoom(doc, room.copyWith(origin: const Point2(1, 1))),
        throwsA(isA<SceneFormatException>()),
      );
    });
  });
}
