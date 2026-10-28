// LIVE check of Network + TV (M09): the real app and a real isolated Core
// against the stubs of tools/network-lab (Sunshine serverinfo, UPnP IGD
// router, TCP listeners). Everything is TEST DATA on 127.0.0.1.
//
//   python3 -I tools/network-lab/lab.py up $L 18798 &
//   AER_WINDOW_SIZE=1920x1080 AER_CORE_URL=http://127.0.0.1:18798 \
//   AER_CORE_TOKEN_FILE=$L/data/core.token AER_DESKTOP_DATA_DIR=$L/desktop \
//   AER_SCREENSHOT_DIR=$L/shots AER_NET_LAB=$L AER_NET_LAB_TOOLS=$PWD/../../tools/network-lab \
//   flutter test integration_test/network_live_test.dart -d linux
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:aer_home_desktop/src/app.dart';
import 'package:aer_home_desktop/src/core_api/bots_api.dart';
import 'package:aer_home_desktop/src/core_api/core_client.dart';
import 'package:aer_home_desktop/src/core_api/endpoint.dart';
import 'package:aer_home_desktop/src/core_api/monitoring_api.dart';
import 'package:aer_home_desktop/src/core_api/network_api.dart';
import 'package:aer_home_desktop/src/core_api/power_api.dart';
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
import 'package:aer_home_desktop/src/state/network_controller.dart';
import 'package:aer_home_desktop/src/state/power_controller.dart';
import 'package:aer_home_desktop/src/state/registry_controller.dart';
import 'package:aer_home_desktop/src/state/remote_controller.dart';
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
    await Directory(dir).create(recursive: true);
    final ro =
        _boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await ro.toImage(pixelRatio: tester.view.devicePixelRatio);
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    await File('$dir/$name.png').writeAsBytes(png!.buffer.asUint8List());
  });
}

Future<void> labSet(WidgetTester tester, String kv) async {
  await tester.runAsync(
    () => Process.run('python3', [
      '-I',
      '${_env['AER_NET_LAB_TOOLS']}/lab.py',
      'set',
      _env['AER_NET_LAB']!,
      kv,
    ]),
  );
}

/// Runs a manual check, waiting out the 5 s rate limit.
Future<void> checkNow(WidgetTester tester, NetworkController n) async {
  await settle(tester, 5300);
  await tester.runAsync(n.checkNow);
  await settle(tester, 400);
}

Future<void> scrollTo(WidgetTester tester, Finder f) async {
  await tester.scrollUntilVisible(
    f,
    250,
    scrollable: find.byType(Scrollable).last,
  );
  await settle(tester, 300);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('network + TV through the app against the stub lab', (
    tester,
  ) async {
    final lab = _env['AER_NET_LAB'];
    if (_env['AER_CORE_URL'] == null || lab == null) {
      markTestSkipped('AER_CORE_URL / AER_NET_LAB not set');
      return;
    }
    final ids = jsonDecode(
      File('$lab/lab.json').readAsStringSync(),
    ) as Map<String, dynamic>;
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
    final remote = RemoteController(HttpRemoteApi(client), connection);
    final power = PowerController(HttpPowerApi(client), connection);
    final network = NetworkController(HttpNetworkApi(client), connection);
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
    final section = AppSectionController(AppSection.network);
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
          power: power,
          network: network,
        ),
      ),
    );
    await tester.runAsync(registry.reload);
    await tester.runAsync(mon.start);
    await tester.runAsync(network.start);
    await settle(tester, 800);

    var o = network.overview!;
    expect(o.summary.level, 'ok', reason: o.summary.title);
    expect(o.internet.status, NetStatus.up);
    expect(o.routers.single.wan!.status, NetStatus.up);
    expect(o.tvs.single.status, NetStatus.unconfigured);
    expect(o.sunshine.single.check.details!.streaming, isFalse);
    await shot(tester, '01-network-overview');

    // A stream starts.
    await labSet(tester, 'sunshine=busy');
    await checkNow(tester, network);
    expect(network.overview!.sunshine.single.check.details!.streaming, isTrue);
    await scrollTo(tester, find.byKey(const Key('net-sunshine-lab')));
    await shot(tester, '02-sunshine-streaming');

    // Problems: the router reports WAN down, serverinfo answers 401.
    await labSet(tester, 'sunshine=401');
    await labSet(tester, 'wan=down');
    await checkNow(tester, network);
    await checkNow(tester, network); // second failure confirms
    o = network.overview!;
    expect(o.summary.level, 'critical', reason: o.summary.title);
    expect(o.routers.single.wan!.status, NetStatus.down);
    expect(o.sunshine.single.check.status, NetStatus.error);
    expect(o.incidents.length, 2);
    await tester.drag(find.byType(Scrollable).last, const Offset(0, 3000));
    await settle(tester, 300);
    await shot(tester, '03-problems-top');
    await scrollTo(tester, find.byKey(const Key('net-incidents')));
    await shot(tester, '04-problems-incidents');

    await tester.tap(find.byKey(const Key('net-tab-journal')));
    await settle(tester, 1200);
    expect(find.byKey(const Key('net-journal')), findsOneWidget);
    await shot(tester, '05-journal');
    await tester.tap(find.byKey(const Key('net-tab-overview')));
    await settle(tester, 400);

    // Recovery resolves the incidents.
    await labSet(tester, 'sunshine=free');
    await labSet(tester, 'wan=up');
    await checkNow(tester, network);
    o = network.overview!;
    expect(o.summary.level, 'ok', reason: o.summary.title);
    expect(o.incidents, isEmpty);
    await tester.drag(find.byType(Scrollable).last, const Offset(0, 3000));
    await settle(tester, 300);
    await shot(tester, '06-recovered');

    // Core paused: the last data stays, marked as old.
    final pid = ids['corePid'] as int;
    await tester.runAsync(() => Process.run('kill', ['-STOP', '$pid']));
    await tester.runAsync(
      () => connection.refresh().timeout(
        const Duration(seconds: 20),
        onTimeout: () {},
      ),
    );
    await settle(tester, 600);
    expect(network.isStale, isTrue);
    await shot(tester, '07-core-unavailable');
    await tester.runAsync(() => Process.run('kill', ['-CONT', '$pid']));
    await tester.runAsync(connection.refresh);
    await tester.runAsync(network.refresh);
    await settle(tester, 600);
    expect(network.isStale, isFalse);

    section.value = AppSection.overview;
    await settle(tester, 800);
    expect(find.byKey(const Key('classic-network')), findsOneWidget);
    await shot(tester, '08-classic-overview');

    // House: the router object shows the network panel.
    if (scene.document == null || scene.source == SceneSource.none) {
      await tester.runAsync(scene.load);
    }
    if (scene.source == SceneSource.bundled) {
      await tester.runAsync(() async => scene.save());
    }
    var doc = scene.document!;
    final routerObj = doc.objects.firstWhere((x) => x.assetId == 'cozy/router');
    final routerId = ids['router'] as String;
    if (routerObj.entityBinding?.entityId != routerId) {
      doc = const SceneEdits().bindEntity(doc, routerObj.id, routerId);
      await tester.runAsync(
        () => sceneApi.replace(doc.sceneId, scene.revision!, doc),
      );
      await tester.runAsync(scene.load);
    }
    section.value = AppSection.house;
    await settle(tester, 1200);
    final hs = tester.state<HouseViewState>(find.byType(HouseView));
    final g = hs.game.layout!.objects[routerObj.id]!;
    hs.game.view.focusRect(
      hs.game.layout!.roomGeometry(g.room.id)!.focusBounds,
    );
    await settle(tester, 900);
    await tester.tapAt(_pointOn(tester, hs, g));
    await settle(tester, 1200);
    expect(find.byKey(const Key('scene-network-panel')), findsOneWidget);
    await shot(tester, '09-house-router-panel');

    connection.dispose();
    await tester.pumpWidget(const SizedBox());
    registry.dispose();
    scene.dispose();
    mon.dispose();
    bots.dispose();
    remote.dispose();
    power.dispose();
    network.dispose();
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
