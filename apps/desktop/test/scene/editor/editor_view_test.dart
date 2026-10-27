// Widget tests of the house editor UI (fake Core in memory).
import 'package:aer_home_desktop/src/scene/editor/editor_controller.dart';
import 'package:aer_home_desktop/src/scene/geometry/iso.dart';
import 'package:aer_home_desktop/src/scene/geometry/scene_layout.dart';
import 'package:aer_home_desktop/src/scene/model/scene_codec.dart';
import 'package:aer_home_desktop/src/scene/model/scene_document.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../house_view_test.dart';
import '../scene_fixtures.dart';

const _codec = SceneCodec();

Future<void> enterEditor(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('house-edit')));
  await tester.pumpAndSettle();
  expect(houseState(tester).editor.active, isTrue);
}

EditorController editorOf(WidgetTester tester) => houseState(tester).editor;

SceneObject objOf(WidgetTester tester, String asset) =>
    editorOf(tester).document!.objects.firstWhere((o) => o.assetId == asset);

/// Global point of a scene point (tiles) on the surface.
Offset scenePoint(WidgetTester tester, double x, double y, [double z = 0]) =>
    tester.getTopLeft(find.byKey(const Key('scene-surface'))) +
    houseState(tester).game.view.worldToScreen(Iso.project(x, y, z));

/// A point where [id] is the front-most editable object.
Offset editablePoint(WidgetTester tester, String id) {
  final s = houseState(tester);
  final layout = s.game.layout!;
  final g = layout.objects[id]!;
  final b = g.screenBounds;
  for (var i = 1; i < 12; i++) {
    for (var j = 1; j < 12; j++) {
      final w = Offset(b.left + b.width * i / 12, b.top + b.height * j / 12);
      if (layout.hitTestEditable(w)?.object.id == id) {
        return tester.getTopLeft(find.byKey(const Key('scene-surface'))) +
            s.game.view.worldToScreen(w);
      }
    }
  }
  fail('not hittable: ${g.object.assetId}');
}

Future<void> ctrl(
  WidgetTester tester,
  LogicalKeyboardKey key, {
  bool shift = false,
}) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyEvent(key);
  if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await tester.pump();
}

Future<void> mouseDrag(WidgetTester tester, Offset from, Offset to) async {
  final g = await tester.startGesture(from, kind: PointerDeviceKind.mouse);
  for (var i = 1; i <= 8; i++) {
    await g.moveTo(Offset.lerp(from, to, i / 8)!);
    await tester.pump(const Duration(milliseconds: 16));
  }
  await g.up();
  await tester.pumpAndSettle();
}

void main() {
  for (final size in const [Size(1366, 768), Size(1920, 1080)]) {
    testWidgets(
      'build mode fits ${size.width.toInt()}×${size.height.toInt()} without overflow',
      (tester) async {
        final h = await pumpHouse(tester, size: size);
        await enterEditor(tester);
        for (final k in [
          'editor-top-bar',
          'editor-side-panel',
          'editor-history-panel',
          'editor-status-bar',
          'editor-undo',
          'editor-redo',
          'editor-save',
          'editor-exit',
        ]) {
          expect(find.byKey(Key(k)), findsOneWidget, reason: k);
        }
        // Every panel state.
        await tester.tap(find.byKey(const Key('catalog-cat-servers')));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('catalog-item-cozy/server_rack')),
          findsOneWidget,
        );
        await clickAt(
          tester,
          editablePoint(tester, objOf(tester, 'cozy/pc_tower').id),
        );
        expect(find.byKey(const Key('editor-inspector')), findsOneWidget);
        await tester.ensureVisible(
          find.byKey(const Key('inspector-advanced'), skipOffstage: false),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('inspector-advanced')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('editor-tab-1')));
        await tester.pumpAndSettle();
        final room = editorOf(tester).document!.rooms.first;
        await tester.tap(find.byKey(Key('editor-room-${room.id}')));
        await tester.pumpAndSettle();
        expect(editorOf(tester).selectedRoomId, room.id);
        await tester.tap(find.byKey(const Key('editor-tab-2')));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        // The scene keeps a usable area next to the panels.
        final surface = tester.getSize(find.byKey(const Key('scene-surface')));
        expect(surface.width, greaterThan(size.width * 0.4));
        await done(tester, h);
      },
    );
  }

  testWidgets('view mode: dragging furniture pans the camera, never moves it', (
    tester,
  ) async {
    final h = await pumpHouse(tester);
    final s = houseState(tester);
    final before = _codec.encode(s.widget.scene.document!);
    final desk = s.game.layout!.objects.values.firstWhere(
      (g) => g.object.assetId == 'cozy/desk',
    );
    final from = pointOn(tester, desk);
    final c0 = s.game.view.center;
    await mouseDrag(tester, from, from + const Offset(120, 40));
    expect(_codec.encode(s.widget.scene.document!), before);
    expect(s.game.view.center, isNot(c0));
    await done(tester, h);
  });

  testWidgets(
    'build mode: a click only selects; dragging the selected item moves it once',
    (tester) async {
      final h = await pumpHouse(tester);
      await enterEditor(tester);
      final e = editorOf(tester);
      final chair = objOf(tester, 'cozy/office_chair');
      final p = editablePoint(tester, chair.id);

      // Drag on an unselected object: the camera pans, the chair stays.
      final c0 = houseState(tester).game.view.center;
      await mouseDrag(tester, p, p + const Offset(0, 60));
      expect(e.document!.object(chair.id)!.position.y, chair.position.y);
      expect(houseState(tester).game.view.center, isNot(c0));

      await clickAt(tester, editablePoint(tester, chair.id));
      expect(e.selectedObjectId, chair.id);
      expect(e.history.length, 0);

      final q = editablePoint(tester, chair.id);
      final down = q + (scenePoint(tester, 0, 1.5) - scenePoint(tester, 0, 0));
      await mouseDrag(tester, q, down);
      expect(e.history.length, 1, reason: 'the whole drag is one step');
      expect(
        e.document!.object(chair.id)!.position.y,
        greaterThan(chair.position.y),
      );
      expect(e.tool, EditorTool.select);
      await done(tester, h);
    },
  );

  testWidgets('catalog: search, categories, click-to-place and drag-and-drop', (
    tester,
  ) async {
    final h = await pumpHouse(tester);
    await enterEditor(tester);
    final e = editorOf(tester);
    await tester.enterText(find.byKey(const Key('catalog-search')), 'ноут');
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('catalog-item-cozy/laptop')), findsOneWidget);
    expect(find.byKey(const Key('catalog-item-cozy/desk')), findsNothing);
    await tester.enterText(find.byKey(const Key('catalog-search')), '');
    await tester.tap(find.byKey(const Key('catalog-cat-decor')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('catalog-item-cozy/plant')), findsOneWidget);
    expect(
      find.byKey(const Key('catalog-item-cozy/server_rack')),
      findsNothing,
    );

    // Click an item, hover, click on the floor.
    final living = e.document!.rooms.firstWhere((r) => r.kind == 'living');
    final n = e.document!.objects.length;
    await tester.tap(find.byKey(const Key('catalog-item-cozy/plant')));
    await tester.pump();
    expect(e.tool, EditorTool.place);
    final target = scenePoint(
      tester,
      living.origin.x + 1.5,
      living.origin.y + 3,
    );
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: target - const Offset(5, 5));
    await mouse.moveTo(target);
    await tester.pump();
    expect(e.ghost?.ok, isTrue, reason: '${e.ghost?.issues}');
    await tester.tapAt(target);
    await tester.pumpAndSettle();
    expect(e.document!.objects.length, n + 1);
    await mouse.removePointer();

    // Drag a rug from the catalog onto the automation room.
    await tester.enterText(find.byKey(const Key('catalog-search')), 'ковёр');
    await tester.pumpAndSettle();
    final auto = e.document!.rooms.firstWhere((r) => r.kind == 'automation');
    final drop = scenePoint(tester, auto.origin.x + 6, auto.origin.y + 4.5);
    final from = tester.getCenter(
      find.byKey(const Key('catalog-item-cozy/rug')),
    );
    // Mouse drag (a long touch-press would open the tile's tooltip instead).
    final g = await tester.startGesture(from, kind: PointerDeviceKind.mouse);
    await tester.pump(const Duration(milliseconds: 16));
    for (var i = 1; i <= 10; i++) {
      await g.moveTo(Offset.lerp(from, drop, i / 10)!);
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(e.tool, EditorTool.place);
    await g.up();
    await tester.pumpAndSettle();
    expect(e.document!.objects.length, n + 2);
    final rug = e.document!.object(e.selectedObjectId!)!;
    expect(rug.assetId, 'cozy/rug');
    expect(rug.roomId, auto.id);
    expect(rug.layer, SceneLayer.floor);
    await done(tester, h);
  });

  testWidgets(
    'hotkeys: undo/redo, R, G, Ctrl+D, Delete, Esc, F, 0; not while typing',
    (tester) async {
      final h = await pumpHouse(tester);
      await enterEditor(tester);
      final e = editorOf(tester);
      final lamp = objOf(tester, 'cozy/floor_lamp');
      await clickAt(tester, editablePoint(tester, lamp.id));
      expect(e.selectedObjectId, lamp.id);

      await tester.sendKeyEvent(LogicalKeyboardKey.keyR);
      await tester.pump();
      expect(e.document!.object(lamp.id)!.rotation, 90);
      await ctrl(tester, LogicalKeyboardKey.keyZ);
      expect(e.document!.object(lamp.id)!.rotation, 0);
      await ctrl(tester, LogicalKeyboardKey.keyZ, shift: true);
      expect(e.document!.object(lamp.id)!.rotation, 90);
      await ctrl(tester, LogicalKeyboardKey.keyZ);
      await ctrl(tester, LogicalKeyboardKey.keyY);
      expect(e.document!.object(lamp.id)!.rotation, 90);

      final grid = e.gridVisible;
      await tester.sendKeyEvent(LogicalKeyboardKey.keyG);
      await tester.pump();
      expect(e.gridVisible, !grid);

      final n = e.document!.objects.length;
      await ctrl(tester, LogicalKeyboardKey.keyD);
      await tester.pumpAndSettle();
      expect(e.document!.objects.length, n + 1);
      final copy = e.selectedObjectId!;
      await tester.sendKeyEvent(LogicalKeyboardKey.delete);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('editor-delete-dialog')), findsOneWidget);
      await tester.tap(find.byKey(const Key('delete-confirm')));
      await tester.pumpAndSettle();
      expect(e.document!.object(copy), isNull);

      // F focuses the selection, 0 frames the whole house.
      await clickAt(tester, editablePoint(tester, lamp.id));
      final view = houseState(tester).game.view;
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.pumpAndSettle();
      final g = houseState(tester).game.layout!.objects[lamp.id]!;
      expect((view.center - g.screenBounds.center).distance, lessThan(2));
      await tester.sendKeyEvent(LogicalKeyboardKey.digit0);
      await tester.pumpAndSettle();
      expect((view.center - view.sceneBounds.center).distance, lessThan(2));

      // Typing a name: R/Delete/Ctrl+Z go to the text field, not the editor.
      final rot = e.document!.object(lamp.id)!.rotation;
      final steps = e.history.length;
      await tester.tap(find.byKey(const Key('inspector-object-name')));
      await tester.pump();
      await tester.enterText(
        find.byKey(const Key('inspector-object-name')),
        'Rr',
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.keyR);
      await tester.sendKeyEvent(LogicalKeyboardKey.delete);
      await ctrl(tester, LogicalKeyboardKey.keyZ);
      await tester.pump();
      expect(e.document!.object(lamp.id), isNotNull);
      expect(e.document!.object(lamp.id)!.rotation, rot);
      expect(e.history.length, steps);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(e.document!.object(lamp.id)!.label, isNotEmpty);

      // Esc clears the selection.
      await clickAt(tester, editablePoint(tester, lamp.id));
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(e.selectedObjectId, isNull);
      await done(tester, h);
    },
  );

  testWidgets(
    'inspector: rotate, scale, finish, unbind; room size and materials',
    (tester) async {
      final h = await pumpHouse(tester);
      await enterEditor(tester);
      final e = editorOf(tester);
      final lamp = objOf(tester, 'cozy/floor_lamp');
      await clickAt(tester, editablePoint(tester, lamp.id));
      await tester.tap(find.byKey(const Key('inspector-rotate')));
      await tester.pumpAndSettle();
      expect(e.document!.object(lamp.id)!.rotation, 90);
      await tester.drag(
        find.byKey(const Key('inspector-scale')),
        const Offset(30, 0),
      );
      await tester.pumpAndSettle();
      expect(e.document!.object(lamp.id)!.scale, greaterThan(1));
      await tester.ensureVisible(
        find.byKey(const Key('finish-sage'), skipOffstage: false),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('finish-sage')));
      await tester.pumpAndSettle();
      expect(e.document!.object(lamp.id)!.metadata['finish'], 'sage');

      final pc = objOf(tester, 'cozy/pc_tower');
      expect(pc.entityBinding, isNotNull);
      houseState(tester).focusObject(pc.id);
      await tester.pumpAndSettle();
      await clickAt(tester, editablePoint(tester, pc.id));
      expect(find.text('Основной ПК (тест)'), findsWidgets);
      await tester.tap(find.byKey(const Key('inspector-unbind')));
      await tester.pumpAndSettle();
      expect(e.document!.object(pc.id)!.entityBinding, isNull);

      // Room inspector.
      await tester.tap(find.byKey(const Key('editor-tab-1')));
      await tester.pumpAndSettle();
      final living = e.document!.rooms.firstWhere((r) => r.kind == 'living');
      await tester.tap(find.byKey(Key('editor-room-${living.id}')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const Key('floor-stone_light'), skipOffstage: false),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('floor-stone_light')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const Key('wall-sage_light'), skipOffstage: false),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('wall-sage_light')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const Key('light-dim'), skipOffstage: false),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('light-dim')));
      await tester.pumpAndSettle();
      final style = e.document!.room(living.id)!.style;
      expect(
        [style.floor, style.wall, style.light],
        ['stone_light', 'sage_light', 'dim'],
      );
      // Living room touches the server room on the east: growing is refused.
      final w = e.document!.room(living.id)!.size.w;
      await tester.ensureVisible(
        find.byKey(const Key('Ширина-plus'), skipOffstage: false),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('Ширина-plus')));
      await tester.pumpAndSettle();
      expect(e.document!.room(living.id)!.size.w, w);
      expect(find.textContaining('Накладывается'), findsOneWidget);
      await done(tester, h);
    },
  );

  testWidgets('leaving build mode with changes asks; keep / discard / save', (
    tester,
  ) async {
    final h = await pumpHouse(tester);
    await enterEditor(tester);
    final e = editorOf(tester);
    e.rotateObject(objOf(tester, 'cozy/floor_lamp').id);
    await tester.pump();
    await tester.tap(find.byKey(const Key('editor-exit')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('editor-unsaved-dialog')), findsOneWidget);
    await tester.tap(find.byKey(const Key('unsaved-keep')));
    await tester.pumpAndSettle();
    expect(e.active, isTrue);
    expect(e.dirty, isTrue);

    await tester.tap(find.byKey(const Key('editor-exit')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('unsaved-save')));
    await tester.pumpAndSettle();
    expect(e.active, isFalse);
    expect(h.sceneApi.stored.values.first.revision, 3);
    expect(find.byKey(const Key('house-edit')), findsOneWidget);

    // Discard path.
    await enterEditor(tester);
    final lamp = objOf(tester, 'cozy/floor_lamp');
    e.rotateObject(lamp.id);
    await tester.pump();
    await ctrl(tester, LogicalKeyboardKey.keyS);
    await tester.pumpAndSettle();
    expect(h.sceneApi.stored.values.first.revision, 4, reason: 'Ctrl+S saves');
    e.rotateObject(lamp.id);
    await tester.pump();
    await tester.tap(find.byKey(const Key('editor-exit')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('unsaved-discard')));
    await tester.pumpAndSettle();
    expect(e.active, isFalse);
    expect(
      houseState(tester).widget.scene.document!.object(lamp.id)!.rotation,
      180,
    );
    await done(tester, h);
  });

  testWidgets('switching app sections keeps unsaved edits', (tester) async {
    final h = await pumpHouse(tester);
    await enterEditor(tester);
    final e = editorOf(tester);
    e.rotateObject(objOf(tester, 'cozy/floor_lamp').id);
    await tester.pump();
    await tester.tap(find.text('Обзор'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Дом'));
    await tester.pumpAndSettle();
    expect(e.active, isTrue);
    expect(e.dirty, isTrue);
    expect(find.byKey(const Key('editor-top-bar')), findsOneWidget);
    await done(tester, h);
  });

  testWidgets('a found draft is offered and restored from the banner', (
    tester,
  ) async {
    final h = await pumpHouse(
      tester,
      draftEdit: (doc) {
        final lamp = doc.objects.firstWhere(
          (o) => o.assetId == 'cozy/floor_lamp',
        );
        return doc.copyWith(
          objects: [
            for (final o in doc.objects)
              o.id == lamp.id ? o.copyWith(rotation: 270) : o,
          ],
        );
      },
    );
    expect(find.byKey(const Key('draft-banner')), findsOneWidget);
    await tester.tap(find.byKey(const Key('draft-restore')));
    await tester.pumpAndSettle();
    final e = editorOf(tester);
    expect(e.active, isTrue);
    expect(objOf(tester, 'cozy/floor_lamp').rotation, 270);
    expect(e.dirty, isTrue);
    await done(tester, h);
  });

  test('ObjectGeometry box helper agrees with the layout', () {
    // Guard for the shared mapping used by renderer, validator and editor.
    final layout = SceneLayout.build(exampleScene());
    for (final g in layout.objects.values) {
      final b = SceneLayout.boxOf(g.object, g.asset, g.room);
      expect(b.minX, g.box.minX);
      expect(b.maxZ, g.box.maxZ);
    }
  });
}
