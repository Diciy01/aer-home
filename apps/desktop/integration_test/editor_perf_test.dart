// Editor performance measurement (profile mode via test_driver):
//   AER_WINDOW_SIZE=1920x1080 flutter drive --profile \
//     --driver=test_driver/integration_test.dart \
//     --target=integration_test/editor_perf_test.dart -d linux
// Scenes of ~35 (demo), 100 and 200 objects in build mode: dragging an
// object with its preview, hovering a catalog item, undo/redo bursts, and
// (when AER_CORE_URL/AER_CORE_TOKEN_FILE point at an isolated TEST Core)
// saving the 200-object scene. Extra objects are TEST data «(тест)».
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:aer_home_desktop/src/app.dart';
import 'package:aer_home_desktop/src/core_api/core_client.dart';
import 'package:aer_home_desktop/src/core_api/endpoint.dart';
import 'package:aer_home_desktop/src/core_api/registry_api.dart';
import 'package:aer_home_desktop/src/features/house/house_view.dart';
import 'package:aer_home_desktop/src/scene/editor/draft_store.dart';
import 'package:aer_home_desktop/src/scene/editor/editor_commands.dart';
import 'package:aer_home_desktop/src/scene/editor/editor_controller.dart';
import 'package:aer_home_desktop/src/scene/render/scene_game.dart';
import 'package:aer_home_desktop/src/scene/geometry/iso.dart';
import 'package:aer_home_desktop/src/scene/geometry/scene_layout.dart';
import 'package:aer_home_desktop/src/scene/model/scene_document.dart';
import 'package:aer_home_desktop/src/scene/repository/scene_repository.dart';
import 'package:aer_home_desktop/src/scene/scene_controller.dart';
import 'package:aer_home_desktop/src/state/app_section.dart';
import 'package:aer_home_desktop/src/state/connection_controller.dart';
import 'package:aer_home_desktop/src/state/registry_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:integration_test/integration_test.dart';

/// Demo scene grown to [total] objects with a TEST storage room.
SceneDocument grown(SceneDocument base, int total) {
  final extra = total - base.objects.length;
  if (extra <= 0) return base;
  const kinds = [
    ('cozy/crate', Size2(1.0, 0.8)),
    ('cozy/plant', Size2(0.9, 0.9)),
    ('cozy/server_box', Size2(1.0, 0.9)),
    ('cozy/bot', Size2(0.8, 0.8)),
    ('cozy/terminal', Size2(1.0, 1.0)),
    ('cozy/side_table', Size2(1.4, 1.0)),
    ('cozy/pc_tower', Size2(0.6, 1.2)),
  ];
  const perRow = 12;
  final rows = (extra / perRow).ceil();
  final roomId = newUuid();
  final room = SceneRoom(
    id: roomId,
    name: 'Склад (тест)',
    kind: 'custom',
    origin: const Point2(0, 15),
    size: Size2(perRow * 2.4, math.max(4, rows * 2.0 + 0.5)),
    wallHeight: 5,
    style: const RoomStyle(floor: 'concrete', wall: 'cream'),
  );
  final objects = [...base.objects];
  for (var i = 0; i < extra; i++) {
    final (asset, _) = kinds[i % kinds.length];
    objects.add(
      SceneObject(
        id: newUuid(),
        roomId: roomId,
        assetId: asset,
        label: 'Тест ${i + 1}',
        position: Point3(
          0.3 + 2.4 * (i % perRow),
          0.3 + 2.0 * (i ~/ perRow),
          0,
        ),
      ),
    );
  }
  return base.copyWith(rooms: [...base.rooms, room], objects: objects);
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('editor performance', (tester) async {
    final client = CoreClient(
      httpClient: http.Client(),
      baseUri: Uri.parse('http://127.0.0.1:9'),
      tokenProvider: () async => null,
    );
    final connection = ConnectionController(client);
    final registryApi = HttpRegistryApi(client);
    final registry = RegistryController(registryApi, connection);
    final dir = Directory.systemTemp.createTempSync('aer-editor-perf-');
    final base = await loadBundledDemo();
    final report = binding.reportData ??= <String, dynamic>{};
    late SceneController scene;
    late HouseViewState state;
    late SceneGame game;
    late EditorController editor;

    /// Mounts the app on a fresh scene controller (as after a restart).
    Future<void> mount(SceneDocument doc) async {
      await tester.pumpWidget(const SizedBox());
      scene = SceneController(
        sceneApi: HttpSceneApi(client),
        registryApi: registryApi,
        connectionController: connection,
        sceneCache: SceneCache(File('${dir.path}/scene-cache.json')),
        bundledLoader: () async => doc,
        draftStore: SceneDraftStore(File('${dir.path}/scene-draft.json')),
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
      await Future<void>.delayed(const Duration(seconds: 1));
      await tester.pump();
      state = tester.state<HouseViewState>(find.byType(HouseView));
      game = state.game;
      editor = state.editor;
    }

    Future<void> run(
      String key,
      Duration length,
      void Function(int tick) step,
    ) async {
      var frames = 0;
      var seconds = 1.0;
      await binding.watchPerformance(() async {
        // Count scene repaints inside the measured window only.
        final frames0 = game.framesRendered;
        final sw = Stopwatch()..start();
        var tick = 0;
        final t = Timer.periodic(
          const Duration(milliseconds: 16),
          (_) => step(tick++),
        );
        await Future<void>.delayed(length);
        t.cancel();
        frames = game.framesRendered - frames0;
        seconds = sw.elapsedMilliseconds / 1000;
      }, reportKey: key);
      report['${key}_scene_fps'] = frames / seconds;
    }

    for (final total in [35, 100, 200]) {
      await mount(grown(base, total));
      editor.enter();
      await Future<void>.delayed(const Duration(milliseconds: 600));
      report['objects_$total'] = editor.document!.objects.length;

      // Drag the office desk lamp around with its live preview.
      final office = editor.document!.rooms.firstWhere(
        (r) => r.kind == 'office',
      );
      final plant = editor.document!
          .objectsIn(office.id)
          .firstWhere((o) => o.assetId == 'cozy/plant');
      final start = Iso.project(office.origin.x + 0.65, office.origin.y + 0.65);
      editor.beginMove(plant.id, start);
      await run('drag_$total', const Duration(seconds: 4), (t) {
        final a = t / 20;
        editor.hover(
          start + Offset(math.sin(a) * 140 + 140, math.cos(a) * 60 + 70),
        );
      });
      editor.cancel();

      // Hover a catalog item over the house (placement preview).
      editor.startPlacing('cozy/armchair');
      final living = editor.document!.rooms.firstWhere(
        (r) => r.kind == 'living',
      );
      final c = Iso.project(living.origin.x + 6, living.origin.y + 4);
      await run('place_hover_$total', const Duration(seconds: 3), (t) {
        editor.hover(c + Offset(math.sin(t / 15) * 120, math.cos(t / 15) * 50));
      });
      editor.cancel();

      // 20 real edits, then undo/redo: each step rebuilds layout + picture.
      final lamp = editor.document!.objects.firstWhere(
        (o) => o.assetId == 'cozy/floor_lamp',
      );
      for (var i = 0; i < 20; i++) {
        editor.rotateObject(lamp.id);
      }
      report['undo_steps_$total'] = editor.history.length;
      final opTimes = <int>[];
      await run('undo_redo_$total', const Duration(seconds: 3), (t) {
        if (t % 4 != 0) return;
        final sw = Stopwatch()..start();
        (t ~/ 4) % 2 == 0 ? editor.undo() : editor.redo();
        opTimes.add(sw.elapsedMicroseconds);
      });
      opTimes.sort();
      report['undo_redo_${total}_op_ms_avg'] =
          opTimes.fold<int>(0, (a, b) => a + b) / opTimes.length / 1000;
      report['undo_redo_${total}_op_ms_p90'] =
          opTimes[(opTimes.length * 0.9).floor()] / 1000;

      // Layout + validation cost of one committed edit.
      final sw = Stopwatch()..start();
      for (var i = 0; i < 10; i++) {
        SceneLayout.build(editor.document!);
      }
      report['layout_build_${total}_ms'] = sw.elapsedMicroseconds / 10000;
    }

    // Saving the large scene to an isolated TEST Core, if configured.
    final env = Platform.environment;
    if (env['AER_CORE_URL'] != null) {
      final endpoint = CoreEndpoint.fromEnvironment();
      final live = HttpSceneApi(
        CoreClient(
          httpClient: http.Client(),
          baseUri: endpoint.baseUri,
          tokenProvider: endpoint.readToken,
        ),
      );
      final big = editor.document!.copyWith(
        sceneId: newUuid(),
        name: 'Нагрузочная сцена (тест)',
      );
      final sw = Stopwatch()..start();
      final created = await live.create(big);
      report['save_200_create_ms'] = sw.elapsedMilliseconds;
      sw
        ..reset()
        ..start();
      final replaced = await live.replace(
        created.document.sceneId,
        created.revision,
        big,
      );
      report['save_200_replace_ms'] = sw.elapsedMilliseconds;
      report['save_200_revision'] = replaced.revision;
      report['save_200_bytes'] = big.toJson().toString().length;
    }

    await editor.discardAndExit();
    connection.dispose();
    await tester.pumpWidget(const SizedBox());
    registry.dispose();
    dir.deleteSync(recursive: true);
  });
}
