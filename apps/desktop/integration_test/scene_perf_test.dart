// Scene performance measurement (run in profile mode via test_driver).
// Uses the bundled demo layout without Core; the stress case adds a TEST
// room with 70 extra objects (>100 in total).
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:aer_home_desktop/src/app.dart';
import 'package:aer_home_desktop/src/core_api/core_client.dart';
import 'package:aer_home_desktop/src/core_api/registry_api.dart';
import 'package:aer_home_desktop/src/features/house/house_view.dart';
import 'package:aer_home_desktop/src/scene/binding/scene_binding.dart';
import 'package:aer_home_desktop/src/scene/geometry/scene_layout.dart';
import 'package:aer_home_desktop/src/scene/model/scene_document.dart';
import 'package:aer_home_desktop/src/scene/model/scene_edit.dart';
import 'package:aer_home_desktop/src/scene/repository/scene_repository.dart';
import 'package:aer_home_desktop/src/scene/scene_controller.dart';
import 'package:aer_home_desktop/src/state/app_section.dart';
import 'package:aer_home_desktop/src/state/connection_controller.dart';
import 'package:aer_home_desktop/src/state/registry_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:integration_test/integration_test.dart';

String _uuid(math.Random r) {
  String h(int n) =>
      List.generate(n, (_) => r.nextInt(16).toRadixString(16)).join();
  return '${h(8)}-${h(4)}-4${h(3)}-${'89ab'[r.nextInt(4)]}${h(3)}-${h(12)}';
}

SceneDocument stressScene(SceneDocument base) {
  final r = math.Random(42);
  const edits = SceneEdits();
  final roomId = _uuid(r);
  var doc = edits.addRoom(
    base,
    SceneRoom(
      id: roomId,
      name: 'Склад (тест)',
      kind: 'custom',
      origin: const Point2(0, 15),
      size: const Size2(24, 15),
      wallHeight: 0,
      style: const RoomStyle(floor: 'concrete', wall: 'cream'),
    ),
  );
  const assets = [
    'cozy/crate',
    'cozy/plant',
    'cozy/server_box',
    'cozy/bot',
    'cozy/terminal',
    'cozy/side_table',
    'cozy/pc_tower',
  ];
  final objects = [...doc.objects];
  for (var i = 0; i < 10; i++) {
    for (var j = 0; j < 7; j++) {
      final asset = assets[(i * 7 + j) % assets.length];
      objects.add(
        SceneObject(
          id: _uuid(r),
          roomId: roomId,
          assetId: asset,
          label: 'Тест $i-$j',
          position: Point3(0.3 + 2.4 * i, 0.3 + 2 * j, 0),
          demoState: (i + j) % 5 == 0 ? SceneStatus.critical : null,
        ),
      );
    }
  }
  doc = doc.copyWith(objects: objects);
  return doc;
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('scene performance', (tester) async {
    final client = CoreClient(
      httpClient: http.Client(),
      baseUri: Uri.parse('http://127.0.0.1:9'),
      tokenProvider: () async => null,
    );
    final connection = ConnectionController(client);
    final registryApi = HttpRegistryApi(client);
    final registry = RegistryController(registryApi, connection);
    final dir = Directory.systemTemp.createTempSync('aer-perf-');
    final scene = SceneController(
      sceneApi: HttpSceneApi(client),
      registryApi: registryApi,
      connectionController: connection,
      sceneCache: SceneCache(File('${dir.path}/scene-cache.json')),
      bundledLoader: loadBundledDemo,
    );
    await tester.pumpWidget(
      AerHomeApp(
        connection: connection,
        registry: registry,
        scene: scene,
        section: AppSectionController(AppSection.house),
      ),
    );
    await scene.load();
    await Future<void>.delayed(const Duration(seconds: 2));
    await tester.pump();
    final state = tester.state<HouseViewState>(find.byType(HouseView));
    final game = state.game;
    final view = game.view;
    final report = binding.reportData ??= <String, dynamic>{};
    report['viewport'] =
        '${view.viewport.width.toInt()}x${view.viewport.height.toInt()}';
    report['objects_demo'] = game.layout!.objects.length;

    Future<void> run(
      String key,
      Duration length,
      void Function(int tick) step,
    ) async {
      final frames0 = game.framesRendered;
      final sw = Stopwatch()..start();
      await binding.watchPerformance(() async {
        var tick = 0;
        final t = Timer.periodic(
          const Duration(milliseconds: 16),
          (_) => step(tick++),
        );
        await Future<void>.delayed(length);
        t.cancel();
      }, reportKey: key);
      report['${key}_scene_fps'] =
          (game.framesRendered - frames0) / (sw.elapsedMilliseconds / 1000);
    }

    final center = Offset(view.viewport.width / 2, view.viewport.height / 2);
    await run('idle_animated', const Duration(seconds: 3), (_) {});
    await run('pan', const Duration(seconds: 4), (t) {
      view.panBy(Offset(t % 120 < 60 ? 7 : -7, t % 80 < 40 ? 3 : -3));
      game.userMovedCamera = true;
      game.wake();
    });
    await run('zoom', const Duration(seconds: 4), (t) {
      view.zoomAt(center, t % 100 < 50 ? 1.02 : 1 / 1.02);
      game.wake();
    });
    final rooms = game.layout!.rooms;
    await run('room_flights', const Duration(seconds: 4), (t) {
      if (t % 30 == 0) {
        view.focusRect(rooms[(t ~/ 30) % rooms.length].focusBounds);
        game.wake();
      }
    });

    final stressDoc = stressScene(game.layout!.document);
    final stress = SceneLayout.build(stressDoc);
    game.setScene(stress, {
      for (final o in stressDoc.objects)
        o.id: presentObject(
          o,
          stressDoc.asset(o.assetId),
          const {},
          RegistryLink.live,
        ),
    }, resetCamera: true);
    report['objects_stress'] = stress.objects.length;
    await Future<void>.delayed(const Duration(seconds: 1));
    await run('stress_pan', const Duration(seconds: 4), (t) {
      view.panBy(Offset(t % 120 < 60 ? 7 : -7, t % 80 < 40 ? 3 : -3));
      game.wake();
    });
    await run('stress_zoom', const Duration(seconds: 4), (t) {
      view.zoomAt(center, t % 100 < 50 ? 1.02 : 1 / 1.02);
      game.wake();
    });

    connection.dispose();
    await tester.pumpWidget(const SizedBox());
    registry.dispose();
    scene.dispose();
    dir.deleteSync(recursive: true);
  });
}
