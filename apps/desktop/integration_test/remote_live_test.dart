// LIVE check of Remote (M07): the real app, a real isolated Core, the host
// agent aer-remote-host on the isolated lab host (tools/remote-lab) and
// Remmina started BY THE APP on an isolated Xvfb display. Proves the path
// «Подключиться» → one-time grant → RDP image, the file channel and the end.
//
//   AER_WINDOW_SIZE=1920x1080 AER_CORE_URL=http://127.0.0.1:18797 \
//   AER_CORE_TOKEN_FILE=$D/data/core.token AER_DESKTOP_DATA_DIR=$D/desktop \
//   AER_SCREENSHOT_DIR=$D/shots AER_REMOTE_CLIENT="$R/tools/remote-lab/lab-client.sh $LAB :77" \
//   AER_REMOTE_FREERDP_DIR=$LAB/client/config/freerdp AER_REMOTE_CLIENT_SHOTS=$D/shots \
//   flutter test integration_test/remote_live_test.dart -d linux
//
// The host «Тестовый хост Wayland (стенд)» is TEST DATA (headless GNOME lab).
import 'dart:io';
import 'dart:ui' as ui;

import 'package:aer_home_desktop/src/app.dart';
import 'package:aer_home_desktop/src/core_api/bots_api.dart';
import 'package:aer_home_desktop/src/core_api/core_client.dart';
import 'package:aer_home_desktop/src/core_api/endpoint.dart';
import 'package:aer_home_desktop/src/core_api/monitoring_api.dart';
import 'package:aer_home_desktop/src/core_api/registry_api.dart';
import 'package:aer_home_desktop/src/core_api/remote_api.dart';
import 'package:aer_home_desktop/src/features/house/house_view.dart';
import 'package:aer_home_desktop/src/scene/geometry/scene_layout.dart';
import 'package:aer_home_desktop/src/scene/model/scene_edit.dart';
import 'package:aer_home_desktop/src/scene/repository/scene_repository.dart';
import 'package:aer_home_desktop/src/scene/scene_controller.dart';
import 'package:aer_home_desktop/src/state/app_section.dart';
import 'package:aer_home_desktop/src/state/bots_controller.dart';
import 'package:aer_home_desktop/src/state/connection_controller.dart';
import 'package:aer_home_desktop/src/state/monitoring_controller.dart';
import 'package:aer_home_desktop/src/state/registry_controller.dart';
import 'package:aer_home_desktop/src/state/remote_controller.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:integration_test/integration_test.dart';

final _env = Platform.environment;
final _boundary = GlobalKey();

Future<void> settle(WidgetTester tester, [int ms = 400]) async {
  await tester.runAsync(() => Future<void>.delayed(Duration(milliseconds: ms)));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
}

Future<void> shot(WidgetTester tester, String name) async {
  await settle(tester, 300);
  final dir = _env['AER_SCREENSHOT_DIR'];
  if (dir == null) return;
  await tester.runAsync(() async {
    final ro =
        _boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await ro.toImage(pixelRatio: tester.view.devicePixelRatio);
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    await File('$dir/$name.png').writeAsBytes(png!.buffer.asUint8List());
  });
}

/// Screenshot of the isolated client display (what the RDP client shows).
Future<void> clientShot(WidgetTester tester, String name) async {
  final dir = _env['AER_REMOTE_CLIENT_SHOTS'];
  if (dir == null) return;
  await tester.runAsync(() async {
    await Process.run(
      'python3',
      ['-I', '${_env['AER_REMOTE_LAB_TOOLS']}/shot.py', '$dir/$name.png'],
      environment: {'DISPLAY': ':77'},
    );
  });
}

Future<bool> rdpListening() async =>
    (await Process.run('ss', ['-ltn'])).stdout.toString().contains(':33891 ');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('remote desktop through the app against the live lab', (
    tester,
  ) async {
    if (_env['AER_CORE_URL'] == null || _env['AER_REMOTE_CLIENT'] == null) {
      markTestSkipped('AER_CORE_URL / AER_REMOTE_CLIENT not set');
      return;
    }
    final endpoint = CoreEndpoint.fromEnvironment();
    final client = CoreClient(
      httpClient: http.Client(),
      baseUri: endpoint.baseUri,
      tokenProvider: endpoint.readToken,
    );
    final connection = ConnectionController(client);
    await tester.runAsync(connection.refresh);
    final registryApi = HttpRegistryApi(client);
    final sceneApi = HttpSceneApi(client);
    final registry = RegistryController(registryApi, connection);
    final cache = SceneCache.defaultLocation();
    final mon = MonitoringController(
      HttpMonitoringApi(client),
      connection,
      cache: MonitoringCache.beside(cache.file),
    );
    final bots = BotsController(HttpBotsApi(client), connection);
    final remote = RemoteController(
      HttpRemoteApi(client),
      connection,
      sourceName: 'AER HOME (живая проверка)',
    );
    final scene = SceneController(
      sceneApi: sceneApi,
      registryApi: registryApi,
      connectionController: connection,
      sceneCache: cache,
      bundledLoader: loadBundledDemo,
      typeLabel: (t) => registry.catalog?.typeLabel(t) ?? t,
      liveStatus: (id) => liveStatusOf(mon, id),
      liveChanges: mon,
    );
    final section = AppSectionController(AppSection.remote);
    await tester.pumpWidget(
      RepaintBoundary(
        key: _boundary,
        child: AerHomeApp(
          connection: connection,
          registry: registry,
          scene: scene,
          section: section,
          monitoring: mon,
          bots: bots,
          remote: remote,
        ),
      ),
    );
    await tester.runAsync(registry.reload);
    await tester.runAsync(mon.start);
    await tester.runAsync(remote.start);
    await settle(tester, 800);

    final host = remote.hosts.firstWhere(
      (h) => h.name == 'Тестовый хост Wayland (стенд)',
    );
    expect(host.canConnect, isTrue, reason: host.reason);
    expect(
      await tester.runAsync(rdpListening),
      isFalse,
      reason: 'RDP closed until a session',
    );
    await shot(tester, '01-remote-hosts');

    await tester.tap(find.byKey(Key('remote-connect-${host.entityId}')));
    await settle(tester, 500);
    await shot(tester, '02-connect-dialog');
    await tester.tap(find.byKey(const Key('remote-connect-go')));
    for (
      var i = 0;
      i < 60 && remote.active?.phase != RemotePhase.running;
      i++
    ) {
      await settle(tester, 250);
      if (remote.active?.phase == RemotePhase.failed) {
        fail(remote.active!.message);
      }
    }
    expect(remote.active!.phase, RemotePhase.running);
    expect(await tester.runAsync(rdpListening), isTrue);
    for (
      var i = 0;
      i < 40 && remote.active?.session?.state != RemoteState.connected;
      i++
    ) {
      await settle(tester, 250);
    }
    expect(
      remote.active!.session!.state,
      RemoteState.connected,
      reason: 'the host agent saw the RDP connection',
    );
    await settle(tester, 2500);
    await clientShot(tester, '03-client-remote-desktop');
    await shot(tester, '04-session-panel');

    // Real file transfer over the pinned HTTPS channel to the host agent.
    final files = remote.active!.files!;
    final tmp = await tester.runAsync(() async {
      final d = await Directory.systemTemp.createTemp('aer-live-');
      final f = File('${d.path}/live-check.txt');
      await f.writeAsString(
        'AER Remote live file check (тест) ${DateTime.now()}\n' * 2000,
      );
      return f;
    });
    await tester.runAsync(() => files.upload(tmp!, 'live-check.txt'));
    final list = await tester.runAsync(files.list);
    expect(list!.any((f) => f.name == 'live-check.txt'), isTrue);
    final back = await tester.runAsync(
      () => files.download(
        'live-check.txt',
        Directory('${tmp!.parent.path}/back'),
      ),
    );
    final same = await tester.runAsync(
      () async =>
          sha256.convert(await tmp!.readAsBytes()) ==
          sha256.convert(await back!.readAsBytes()),
    );
    expect(same, isTrue);
    await settle(tester, 800);

    // End from the app: the host closes RDP, the client window goes away.
    await tester.tap(find.byKey(const Key('remote-end')));
    for (var i = 0; i < 40 && (await tester.runAsync(rdpListening))!; i++) {
      await settle(tester, 100);
    }
    expect(
      await tester.runAsync(rdpListening),
      isFalse,
      reason: 'RDP closed after the end',
    );
    await settle(tester, 1000);
    await tester.runAsync(remote.refresh);
    await settle(tester, 500);
    await shot(tester, '05-after-end');
    await tester.tap(find.byKey(const Key('remote-tab-history')));
    await settle(tester, 500);
    await shot(tester, '06-history');

    // House: bind the PC tower to the lab host; the quick card offers Remote.
    if (scene.document == null || scene.source == SceneSource.none) {
      await tester.runAsync(scene.load);
    }
    if (scene.source == SceneSource.bundled) {
      await tester.runAsync(() async => scene.save());
    }
    var doc = scene.document!;
    final tower = doc.objects.firstWhere((o) => o.assetId == 'cozy/pc_tower');
    if (tower.entityBinding?.entityId != host.entityId) {
      doc = const SceneEdits().bindEntity(doc, tower.id, host.entityId);
      await tester.runAsync(
        () => sceneApi.replace(doc.sceneId, scene.revision!, doc),
      );
      await tester.runAsync(scene.load);
    }
    section.value = AppSection.house;
    await settle(tester, 1200);
    final hs = tester.state<HouseViewState>(find.byType(HouseView));
    final g = hs.game.layout!.objects[tower.id]!;
    hs.game.view.focusRect(
      hs.game.layout!.roomGeometry(g.room.id)!.focusBounds,
    );
    await settle(tester, 900);
    await tester.tapAt(_pointOn(tester, hs, g));
    await settle(tester, 1200);
    expect(find.byKey(const Key('scene-remote-panel')), findsOneWidget);
    expect(find.byKey(const Key('scene-remote-connect')), findsOneWidget);
    await shot(tester, '07-house-remote-panel');

    connection.dispose();
    await tester.pumpWidget(const SizedBox());
    registry.dispose();
    scene.dispose();
    mon.dispose();
    bots.dispose();
    remote.dispose();
  });
}

Offset _pointOn(WidgetTester tester, HouseViewState s, ObjectGeometry g) {
  final b = g.screenBounds;
  for (var i = 1; i < 14; i++) {
    for (var j = 1; j < 14; j++) {
      final w = Offset(b.left + b.width * i / 14, b.top + b.height * j / 14);
      if (s.game.layout!.hitTest(w)?.object.id == g.object.id) {
        return tester.getTopLeft(find.byKey(const Key('scene-surface'))) +
            s.game.view.worldToScreen(w);
      }
    }
  }
  fail('not hittable');
}
