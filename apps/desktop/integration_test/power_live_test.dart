// LIVE check of Power (M08): the real app, a real isolated Core and the real
// power agent aer-power-host in CHECK MODE (tools/power-lab). Every power
// action here is SIMULATED: the agent only answers what it would run, and
// Wake-on-LAN goes to a UDP receiver on 127.0.0.1.
//
//   python3 -I tools/power-lab/lab.py up $L 18797 &
//   AER_WINDOW_SIZE=1920x1080 AER_CORE_URL=http://127.0.0.1:18797 \
//   AER_CORE_TOKEN_FILE=$L/data/core.token AER_DESKTOP_DATA_DIR=$L/desktop \
//   AER_SCREENSHOT_DIR=$L/shots AER_POWER_LAB=$L AER_POWER_LAB_TOOLS=$PWD/../../tools/power-lab \
//   flutter test integration_test/power_live_test.dart -d linux
//
// Both computers are TEST DATA of the lab.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:aer_home_desktop/src/app.dart';
import 'package:aer_home_desktop/src/core_api/bots_api.dart';
import 'package:aer_home_desktop/src/core_api/core_client.dart';
import 'package:aer_home_desktop/src/core_api/endpoint.dart';
import 'package:aer_home_desktop/src/core_api/monitoring_api.dart';
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

Future<JobState> waitJob(
  WidgetTester tester,
  PowerController p,
  String entityId,
  bool Function(JobState) done,
) async {
  for (var i = 0; i < 80; i++) {
    final s = p.followed(entityId)?.state;
    if (s != null && done(s)) return s;
    await settle(tester, 250);
  }
  fail('job of $entityId: ${p.followed(entityId)?.state}');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('power through the app against the live lab (SIMULATED)', (
    tester,
  ) async {
    final lab = _env['AER_POWER_LAB'];
    if (_env['AER_CORE_URL'] == null || lab == null) {
      markTestSkipped('AER_CORE_URL / AER_POWER_LAB not set');
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
    final remote = RemoteController(HttpRemoteApi(client), connection);
    final power = PowerController(
      HttpPowerApi(client),
      connection,
      step: const Duration(milliseconds: 400),
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
    final section = AppSectionController(AppSection.power);
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
        ),
      ),
    );
    await tester.runAsync(registry.reload);
    await tester.runAsync(mon.start);
    await tester.runAsync(remote.start);
    await tester.runAsync(power.start);
    await settle(tester, 800);

    final me = power.devices.firstWhere(
      (d) => d.name == 'Этот ПК (стенд, режим проверки)',
    );
    final pc = power.devices.firstWhere(
      (d) => d.name == 'Тестовый ПК для WoL (стенд)',
    );
    expect(me.state, 'online');
    expect(me.activeAgent!.dryRun, isTrue, reason: 'lab agent in check mode');
    expect(me.sameMachine, isTrue, reason: 'Core and agent on one PC');
    expect(me.action(PowerAction.wake)!.available, isFalse);
    expect(find.byKey(const Key('power-same-machine')), findsOneWidget);
    await shot(tester, '01-power-devices');

    // Reboot: plan → explicit confirmation → the real agent answers SIMULATED.
    await tester.tap(find.byKey(Key('power-reboot-${me.entityId}')));
    await settle(tester, 600);
    expect(find.byKey(const Key('power-confirm-dialog')), findsOneWidget);
    await shot(tester, '02-confirm-reboot');
    await tester.tap(find.byKey(const Key('power-confirm-ack')));
    await settle(tester, 200);
    await tester.tap(find.byKey(const Key('power-confirm-go')));
    expect(
      await waitJob(tester, power, me.entityId, (s) => s.terminal),
      JobState.simulated,
    );
    expect(power.followed(me.entityId)!.message, contains('systemctl reboot'));
    await settle(tester, 600);
    await shot(tester, '03-reboot-simulated');

    // OS switch: only Windows is offered; the agent plans BootNext + reboot.
    await tester.tap(find.byKey(Key('power-switch_os-${me.entityId}')));
    await settle(tester, 500);
    await shot(tester, '04-switch-target');
    await tester.tap(find.byKey(const Key('power-target-windows')));
    await settle(tester, 600);
    await shot(tester, '05-confirm-switch');
    await tester.tap(find.byKey(const Key('power-confirm-ack')));
    await settle(tester, 200);
    await tester.tap(find.byKey(const Key('power-confirm-go')));
    await settle(tester, 300);
    await waitJob(
      tester,
      power,
      me.entityId,
      (s) =>
          s.terminal &&
          power.followed(me.entityId)!.action == PowerAction.switchOs,
    );
    final sw = power.followed(me.entityId)!;
    expect(sw.state, JobState.simulated);
    expect(sw.message, contains('--bootnext'));
    await settle(tester, 600);
    await shot(tester, '06-switch-simulated');

    // Wake-on-LAN: the packet goes to the lab receiver on 127.0.0.1.
    final log = File('$lab/wol-received.log');
    final before = await tester.runAsync(
      () async => await log.exists() ? (await log.readAsLines()).length : 0,
    );
    await tester.tap(find.byKey(Key('power-wake-${pc.entityId}')));
    await settle(tester, 600);
    await shot(tester, '07-confirm-wake');
    await tester.tap(find.byKey(const Key('power-confirm-go')));
    await waitJob(tester, power, pc.entityId, (s) => s == JobState.waiting);
    final lines = await tester.runAsync(() => log.readAsLines());
    expect(lines!.length - before!, 3, reason: 'three magic packets');
    expect(lines.last, contains('magic=True mac=00:00:5e:00:53:aa'));
    await settle(tester, 600);
    await shot(tester, '08-wake-waiting');
    // The test PC "boots": a fake power agent says hello (SIMULATED).
    await tester.runAsync(
      () => Process.run('python3', [
        '-I',
        '${_env['AER_POWER_LAB_TOOLS']}/lab.py',
        'fake-boot',
        lab,
      ]),
    );
    expect(
      await waitJob(tester, power, pc.entityId, (s) => s.terminal),
      JobState.succeeded,
    );
    await tester.runAsync(power.refresh);
    await settle(tester, 600);
    await shot(tester, '09-wake-succeeded');

    await tester.tap(find.byKey(const Key('power-tab-history')));
    await settle(tester, 500);
    await shot(tester, '10-history');

    // House: bind the PC tower to this computer; the quick card shows power.
    if (scene.document == null || scene.source == SceneSource.none) {
      await tester.runAsync(scene.load);
    }
    if (scene.source == SceneSource.bundled) {
      await tester.runAsync(() async => scene.save());
    }
    var doc = scene.document!;
    final tower = doc.objects.firstWhere((o) => o.assetId == 'cozy/pc_tower');
    if (tower.entityBinding?.entityId != me.entityId) {
      doc = const SceneEdits().bindEntity(doc, tower.id, me.entityId);
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
    expect(find.byKey(const Key('scene-power-panel')), findsOneWidget);
    expect(find.byKey(const Key('scene-power-reboot')), findsOneWidget);
    expect(find.byKey(const Key('scene-power-wake')), findsNothing);
    await shot(tester, '11-house-power-panel');

    connection.dispose();
    await tester.pumpWidget(const SizedBox());
    registry.dispose();
    scene.dispose();
    mon.dispose();
    bots.dispose();
    remote.dispose();
    power.dispose();
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
