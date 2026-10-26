import 'dart:ui';

import 'package:aer_home_desktop/src/app.dart';
import 'package:aer_home_desktop/src/features/house/house_view.dart';
import 'package:aer_home_desktop/src/scene/geometry/scene_layout.dart';
import 'package:aer_home_desktop/src/scene/model/scene_edit.dart';
import 'package:aer_home_desktop/src/scene/repository/scene_repository.dart';
import 'package:aer_home_desktop/src/state/app_section.dart';
import 'package:aer_home_desktop/src/state/connection_controller.dart';
import 'package:aer_home_desktop/src/state/registry_controller.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';

import '../fake_registry_api.dart';
import '../fixtures.dart';
import 'scene_fixtures.dart';

class H {
  H(this.connection, this.registry, this.sceneApi, this.registryApi);
  final ConnectionController connection;
  final RegistryController registry;
  final FakeSceneApi sceneApi;
  final FakeRegistryApi registryApi;
}

Future<H> pumpHouse(
  WidgetTester tester, {
  Size size = const Size(1366, 768),
  bool bind = true,
  MockClient? core,
}) async {
  await tester.binding.setSurfaceSize(size);
  tester.platformDispatcher.accessibilityFeaturesTestValue =
      const FakeAccessibilityFeatures(disableAnimations: true);
  final registryApi = FakeRegistryApi();
  final sceneApi = FakeSceneApi();
  if (bind) {
    final pc = registryApi.seed('Основной ПК (тест)', 'computer');
    var doc = exampleScene();
    final tower = doc.objects.firstWhere((o) => o.assetId == 'cozy/pc_tower');
    doc = const SceneEdits().bindEntity(doc, tower.id, pc.id);
    sceneApi.stored[doc.sceneId] = StoredScene(
      document: doc,
      revision: 2,
      updatedAt: DateTime.utc(2026),
    );
  }
  final connection = ConnectionController(clientFor(core ?? healthyCore()));
  // Bring the connection up before controllers subscribe, so that every load
  // runs inside the test's fake-async zone.
  await tester.runAsync(connection.refresh);
  final registry = RegistryController(registryApi, connection);
  final scene = sceneControllerFor(
    connection: connection,
    registry: registryApi,
    api: sceneApi,
  );
  await tester.pumpWidget(
    AerHomeApp(
      connection: connection,
      registry: registry,
      scene: scene,
      section: AppSectionController(AppSection.house),
    ),
  );
  registry.reload().ignore();
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
  await tester.pumpAndSettle();
  addTearDown(() {
    scene.dispose();
    registry.dispose();
  });
  return H(connection, registry, sceneApi, registryApi);
}

Future<void> done(WidgetTester tester, H h) async {
  h.connection.dispose();
  await tester.pumpWidget(const SizedBox());
  tester.platformDispatcher.clearAccessibilityFeaturesTestValue();
  await tester.binding.setSurfaceSize(null);
}

HouseViewState houseState(WidgetTester tester) =>
    tester.state<HouseViewState>(find.byType(HouseView));

ObjectGeometry geometryOf(WidgetTester tester, String assetId) =>
    houseState(tester).game.layout!.objects.values
        .firstWhere((g) => g.object.assetId == assetId);

/// A global position where the object is the front-most hit.
Offset pointOn(WidgetTester tester, ObjectGeometry g) {
  final s = houseState(tester);
  final b = g.screenBounds;
  for (var i = 1; i < 12; i++) {
    for (var j = 1; j < 12; j++) {
      final w = Offset(b.left + b.width * i / 12, b.top + b.height * j / 12);
      if (s.game.layout!.hitTest(w)?.object.id == g.object.id) {
        return tester.getTopLeft(find.byKey(const Key('scene-surface'))) +
            s.game.view.worldToScreen(w);
      }
    }
  }
  fail('object ${g.object.label} is not hittable');
}

Future<void> clickAt(WidgetTester tester, Offset p) async {
  await tester.tapAt(p);
  await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 50));
  await tester.pumpAndSettle();
}

void main() {
  _main();
}

void _main() {
  testWidgets('house renders five rooms with a room switcher and source info', (
    tester,
  ) async {
    final h = await pumpHouse(tester);
    expect(find.byKey(const Key('scene-surface')), findsOneWidget);
    for (final kind in [
      'office',
      'server',
      'living',
      'network',
      'automation',
    ]) {
      expect(find.byKey(Key('room-$kind')), findsOneWidget);
    }
    expect(find.text('Сцена из Core · версия 2'), findsOneWidget);
    expect(find.text('Состояния — тестовые'), findsOneWidget);
    expect(houseState(tester).game.layout!.objects.length, greaterThan(30));
    await done(tester, h);
  });

  testWidgets(
    'click selects an object and opens the quick card; empty space clears',
    (tester) async {
      final h = await pumpHouse(tester);
      await clickAt(
        tester,
        pointOn(tester, geometryOf(tester, 'cozy/server_rack')),
      );
      expect(find.byKey(const Key('scene-quick-card')), findsOneWidget);
      expect(find.text('Серверная стойка'), findsOneWidget);
      expect(find.text('Объект сцены'), findsOneWidget);
      expect(
        find.text('В сети · тест'),
        findsOneWidget,
        reason: 'demo state is labelled as test',
      );

      await clickAt(
        tester,
        tester.getTopLeft(find.byKey(const Key('scene-surface'))) +
            const Offset(6, 400),
      );
      expect(find.byKey(const Key('scene-quick-card')), findsNothing);
      await done(tester, h);
    },
  );

  testWidgets(
    'bound object shows Registry name, unknown state and opens details',
    (tester) async {
      final h = await pumpHouse(tester);
      final tower = geometryOf(tester, 'cozy/pc_tower');
      await clickAt(tester, pointOn(tester, tower));
      expect(find.text('Основной ПК (тест)'), findsWidgets);
      expect(
        find.text('Неизвестно'),
        findsOneWidget,
        reason: 'no Monitoring: never "online"',
      );
      expect(find.text('В сети'), findsNothing);

      final p = pointOn(tester, tower);
      await tester.tapAt(p);
      await tester.pump(const Duration(milliseconds: 60));
      await tester.tapAt(p);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('entity-details')), findsOneWidget);
      expect(find.text('Компьютер'), findsWidgets);
      await done(tester, h);
    },
  );

  testWidgets('right click opens the context menu; properties are read-only', (
    tester,
  ) async {
    final h = await pumpHouse(tester);
    await tester.tapAt(
      pointOn(tester, geometryOf(tester, 'cozy/sofa')),
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();
    for (final item in ['Открыть', 'Информация', 'Найти в Registry']) {
      expect(find.text(item), findsOneWidget);
    }
    final props = find.descendant(
      of: find.byType(PopupMenuItem<String>),
      matching: find.text('Свойства'),
    );
    expect(props, findsOneWidget);
    await tester.tap(props);
    await tester.pumpAndSettle();
    expect(find.text('Свойства: Диван'), findsOneWidget);
    expect(find.textContaining('M04'), findsOneWidget);
    await done(tester, h);
  });

  testWidgets('"find in Registry" switches to the devices section', (
    tester,
  ) async {
    final h = await pumpHouse(tester);
    await tester.tapAt(
      pointOn(tester, geometryOf(tester, 'cozy/pc_tower')),
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Найти в Registry'));
    await tester.pumpAndSettle();
    expect(find.text('Устройства и сервисы'), findsOneWidget);
    expect(h.registry.selected?.name, 'Основной ПК (тест)');
    await done(tester, h);
  });

  testWidgets('hover shows a label', (tester) async {
    final h = await pumpHouse(tester);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(pointOn(tester, geometryOf(tester, 'cozy/tv')));
    await tester.pumpAndSettle();
    expect(find.text('Телевизор'), findsOneWidget);
    expect(find.text('Не в сети · тест'), findsOneWidget);
    await done(tester, h);
  });

  testWidgets('camera: buttons, wheel at cursor, room focus and reset', (
    tester,
  ) async {
    final h = await pumpHouse(tester);
    final view = houseState(tester).game.view;
    final z0 = view.zoom;
    await tester.tap(find.byKey(const Key('scene-zoom-in')));
    await tester.pump();
    expect(view.zoom, greaterThan(z0));

    final surface = tester.getTopLeft(find.byKey(const Key('scene-surface')));
    final cursor = const Offset(500, 300);
    final worldBefore = view.screenToWorld(cursor);
    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(pointer.hover(surface + cursor));
    await tester.sendEventToBinding(pointer.scroll(const Offset(0, -120)));
    await tester.pump();
    expect((view.screenToWorld(cursor) - worldBefore).distance, lessThan(0.01));

    await tester.tap(find.byKey(const Key('room-server')));
    await tester.pumpAndSettle();
    final server = houseState(tester).game.layout!.rooms
        .firstWhere((r) => r.room.kind == 'server');
    expect((view.center - server.focusBounds.center).distance, lessThan(1));

    await tester.tap(find.byKey(const Key('scene-reset')));
    await tester.pumpAndSettle();
    expect(
      view.zoom,
      closeTo(
        view
            .fitZoom(view.sceneBounds, padding: 32)
            .clamp(view.minZoom, view.maxZoom),
        1e-6,
      ),
    );

    await tester.drag(
      find.byKey(const Key('scene-surface')),
      const Offset(-200, 80),
    );
    await tester.pumpAndSettle();
    expect(view.sceneBounds.contains(view.center), isTrue);
    await done(tester, h);
  });

  testWidgets('switching Дом / Обзор keeps the selection', (tester) async {
    final h = await pumpHouse(tester);
    await clickAt(tester, pointOn(tester, geometryOf(tester, 'cozy/router')));
    expect(find.text('Роутер'), findsWidgets);
    await tester.tap(find.text('Обзор'));
    await tester.pumpAndSettle();
    expect(find.text('Состояние системы'), findsOneWidget);
    await tester.tap(find.text('Дом'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('scene-quick-card')), findsOneWidget);
    await done(tester, h);
  });

  testWidgets('without Core the bundled layout is shown; saving needs Core', (
    tester,
  ) async {
    final h = await pumpHouse(tester, bind: false, core: deadCore());
    expect(find.byKey(const Key('room-all')), findsOneWidget);
    expect(find.text('Демо-планировка · не сохранена в Core'), findsOneWidget);
    final save = tester.widget<ButtonStyleButton>(
      find.byKey(const Key('scene-save')),
    );
    expect(save.onPressed, isNull);
    await done(tester, h);
  });

  testWidgets('demo layout can be saved to Core', (tester) async {
    final h = await pumpHouse(tester, bind: false);
    await tester.tap(find.byKey(const Key('scene-save')));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();
    expect(h.sceneApi.stored, hasLength(1));
    expect(find.text('Сцена из Core · версия 1'), findsOneWidget);
    await done(tester, h);
  });

  for (final size in const [
    Size(1366, 768),
    Size(1920, 1080),
    Size(2560, 1440),
    Size(3840, 2160),
    Size(1024, 640),
  ]) {
    testWidgets(
      'no overflow and house framed at ${size.width.toInt()}×${size.height.toInt()}',
      (tester) async {
        final h = await pumpHouse(tester, size: size);
        final view = houseState(tester).game.view;
        final b = houseState(tester).game.layout!.bounds;
        final tl = view.worldToScreen(b.topLeft),
            br = view.worldToScreen(b.bottomRight);
        final surface = tester.getSize(find.byKey(const Key('scene-surface')));
        expect(
          tl.dx >= -1 &&
              tl.dy >= -1 &&
              br.dx <= surface.width + 1 &&
              br.dy <= surface.height + 1,
          isTrue,
          reason: 'whole house visible after load',
        );
        await clickAt(tester, pointOn(tester, geometryOf(tester, 'cozy/bot')));
        expect(find.byKey(const Key('scene-quick-card')), findsOneWidget);
        expect(tester.takeException(), isNull);
        await done(tester, h);
      },
    );
  }
}
