// LIVE check of the BUILT-IN viewer in AER HOME (M14.3): the real app, the
// isolated Core of the relay lab (tools/remote-lab/relay_lab.py, direct
// route as in M07), the host agent with the REAL gnome-remote-desktop of
// the headless lab session, and the desktop shown INSIDE the app through
// native/aer_rdp (FreeRDP 3). Dialogs are opened only inside the lab session.
//
//   L=<lab dir>; AER_WINDOW_SIZE=1600x1000 AER_CORE_URL=http://127.0.0.1:18787 \
//   AER_CORE_TOKEN_FILE=$L/core/core.token AER_DESKTOP_DATA_DIR=$L/desktop \
//   AER_RELAY_LAB=$L AER_SCREENSHOT_DIR=$L/shots \
//   flutter test integration_test/remote_embedded_live_test.dart -d linux
//
// The host «Тестовый хост Wayland (стенд)» is TEST DATA.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:aer_home_desktop/src/app.dart';
import 'package:aer_home_desktop/src/core_api/bots_api.dart';
import 'package:aer_home_desktop/src/core_api/core_client.dart';
import 'package:aer_home_desktop/src/core_api/endpoint.dart';
import 'package:aer_home_desktop/src/core_api/monitoring_api.dart';
import 'package:aer_home_desktop/src/core_api/registry_api.dart';
import 'package:aer_home_desktop/src/core_api/remote_api.dart';
import 'package:aer_home_desktop/src/scene/repository/scene_repository.dart';
import 'package:aer_home_desktop/src/scene/scene_controller.dart';
import 'package:aer_home_desktop/src/state/app_section.dart';
import 'package:aer_home_desktop/src/state/bots_controller.dart';
import 'package:aer_home_desktop/src/state/connection_controller.dart';
import 'package:aer_home_desktop/src/state/monitoring_controller.dart';
import 'package:aer_home_desktop/src/state/registry_controller.dart';
import 'package:aer_home_desktop/src/state/remote_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:integration_test/integration_test.dart';

import 'package:aer_home_desktop/src/remote/remote_desktop_view.dart';
import 'package:flutter/services.dart';

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

Future<bool> rdpListening() async =>
    (await Process.run('ss', ['-ltn'])).stdout.toString().contains(':33891 ');

Map<String, String> hostEnv() {
  final lab =
      jsonDecode(
            File('${_env['AER_RELAY_LAB']}/lab.json').readAsStringSync(),
          )['labDir']
          as String;
  final env = <String, String>{...Platform.environment}..remove('DISPLAY');
  for (final line in File('$lab/env.sh').readAsLinesSync()) {
    if (!line.startsWith('export ')) continue;
    for (final kv in line.substring(7).split(' ')) {
      final i = kv.indexOf('=');
      if (i > 0) env[kv.substring(0, i)] = kv.substring(i + 1);
    }
  }
  env['WAYLAND_DISPLAY'] = 'aer-remote-test';
  env['GDK_BACKEND'] = 'wayland';
  env['DBUS_SESSION_BUS_ADDRESS'] = File('$lab/bus').readAsStringSync().trim();
  return env;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('built-in remote desktop inside AER HOME against the live lab', (
    tester,
  ) async {
    if (_env['AER_CORE_URL'] == null || _env['AER_RELAY_LAB'] == null) {
      markTestSkipped('AER_CORE_URL / AER_RELAY_LAB not set');
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
      sourceName: 'AER HOME (встроенный просмотр, стенд)',
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
      remote.embeddedAvailable,
      isTrue,
      reason: 'libaer_rdp.so in the bundle',
    );

    await tester.tap(find.byKey(Key('remote-connect-${host.entityId}')));
    await settle(tester, 500);
    expect(find.byKey(const Key('remote-embedded-switch')), findsOneWidget);
    await shot(tester, 'e01-connect-dialog');
    await tester.tap(find.byKey(const Key('remote-connect-go')));
    for (
      var i = 0;
      i < 80 && find.byKey(const Key('remote-desktop-page')).evaluate().isEmpty;
      i++
    ) {
      await settle(tester, 250);
      if (remote.active?.phase == RemotePhase.failed) {
        fail(remote.active!.message);
      }
    }
    expect(find.byKey(const Key('remote-desktop-page')), findsOneWidget);
    expect(remote.active!.viewer, isNotNull);
    final view = tester.state<RemoteDesktopViewState>(
      find.byType(RemoteDesktopView),
    );
    for (var i = 0; i < 80 && view.painted == 0; i++) {
      await settle(tester, 250);
    }
    expect(view.painted, greaterThan(0), reason: 'frames painted in the app');
    for (
      var i = 0;
      i < 40 && remote.active?.session?.state != RemoteState.connected;
      i++
    ) {
      await settle(tester, 250);
    }
    expect(remote.active!.session!.state, RemoteState.connected);
    await settle(tester, 2500);
    await shot(tester, 'e02-desktop-in-app');

    // A dialog on the lab host; type into it with the app's keyboard path.
    final zen = await tester.runAsync(
      () => Process.start(
        'zenity',
        ['--entry', '--title=AER HOME', '--text=Встроенный просмотр'],
        environment: hostEnv(),
        includeParentEnvironment: false,
      ),
    );
    final out = zen!.stdout.transform(utf8.decoder).join();
    final before = view.painted;
    for (var i = 0; i < 60 && view.painted < before + 1; i++) {
      await settle(tester, 250);
    }
    await settle(tester, 2000);
    await shot(tester, 'e03-host-dialog-in-app');
    for (final k in [
      (LogicalKeyboardKey.keyA, PhysicalKeyboardKey.keyA),
      (LogicalKeyboardKey.keyE, PhysicalKeyboardKey.keyE),
      (LogicalKeyboardKey.keyR, PhysicalKeyboardKey.keyR),
      (LogicalKeyboardKey.space, PhysicalKeyboardKey.space),
      (LogicalKeyboardKey.digit7, PhysicalKeyboardKey.digit7),
      (LogicalKeyboardKey.enter, PhysicalKeyboardKey.enter),
    ]) {
      await tester.sendKeyEvent(k.$1, physicalKey: k.$2);
      await settle(tester, 60);
    }
    final code = await tester.runAsync(
      () => zen.exitCode.timeout(
        const Duration(seconds: 20),
        onTimeout: () {
          zen.kill();
          return -1;
        },
      ),
    );
    final typed = await tester.runAsync(() => out);
    expect(
      (typed!.trim(), code),
      ('aer 7', 0),
      reason: 'keys from AER HOME reached the host',
    );
    await settle(tester, 1500);
    await shot(tester, 'e04-after-typing');

    // End from the desktop page: the host closes RDP, the page closes.
    await tester.tap(find.byKey(const Key('remote-desktop-end')));
    for (var i = 0; i < 40 && (await tester.runAsync(rdpListening))!; i++) {
      await settle(tester, 150);
    }
    expect(
      await tester.runAsync(rdpListening),
      isFalse,
      reason: 'RDP closed after the end',
    );
    await settle(tester, 800);
    expect(find.byKey(const Key('remote-desktop-page')), findsNothing);
    expect(remote.active!.live, isFalse);
    expect(remote.active!.viewer, isNull);
    await shot(tester, 'e05-after-end');
  });
}
