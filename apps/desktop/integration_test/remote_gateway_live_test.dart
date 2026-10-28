// LIVE check of M14.5 in the real app on the isolated relay lab
// (tools/remote-lab/relay_lab.py): real aer-core, aer-remote-gateway,
// aer-remote-host with the REAL gnome-remote-desktop of a headless lab
// session, the built-in viewer (FreeRDP 3). One AER HOME plays the owner
// (Core on loopback = «at home») and the remote client through the Gateway.
// Dialogs/clipboard actions happen only inside the lab session; the app
// runs on an isolated Xvfb. Nothing leaves 127.0.0.1.
//
//   L=<lab dir>; DISPLAY=:78 GDK_BACKEND=x11 AER_WINDOW_SIZE=1600x1000 \
//   AER_CORE_URL=http://127.0.0.1:18787 AER_CORE_TOKEN_FILE=$L/core/core.token \
//   AER_DESKTOP_DATA_DIR=$L/desktop AER_RELAY_LAB=$L AER_SCREENSHOT_DIR=$L/shots \
//   flutter test integration_test/remote_gateway_live_test.dart -d linux
//
// All computers, clients and codes are TEST DATA.
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

import 'package:aer_home_desktop/src/remote/gateway_profile.dart';
import 'package:aer_home_desktop/src/state/gateway_remote_controller.dart';
import 'package:aer_remote/aer_remote.dart' as engine;

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

Map<String, dynamic> lab() =>
    jsonDecode(File('${_env['AER_RELAY_LAB']}/lab.json').readAsStringSync())
        as Map<String, dynamic>;

Future<Process> hostDialog(String title, {String prefill = ''}) =>
    Process.start(
      'zenity',
      ['--entry', '--title=$title', '--text=$title', '--entry-text=$prefill'],
      environment: hostEnv(),
      includeParentEnvironment: false,
    );

Future<(String, int)> dialogResult(
  WidgetTester tester,
  Process p,
  Future<String> out,
) async {
  final code = await tester.runAsync(
    () => p.exitCode.timeout(
      const Duration(seconds: 20),
      onTimeout: () {
        p.kill();
        return -1;
      },
    ),
  );
  return ((await tester.runAsync(() => out))!.trim(), code!);
}

Future<void> keys(
  WidgetTester tester,
  List<(LogicalKeyboardKey, PhysicalKeyboardKey)> ks,
) async {
  for (final k in ks) {
    await tester.sendKeyEvent(k.$1, physicalKey: k.$2);
    await settle(tester, 60);
  }
}

Future<void> ctrl(
  WidgetTester tester,
  LogicalKeyboardKey l,
  PhysicalKeyboardKey p,
) async {
  await tester.sendKeyDownEvent(
    LogicalKeyboardKey.controlLeft,
    physicalKey: PhysicalKeyboardKey.controlLeft,
  );
  await tester.sendKeyEvent(l, physicalKey: p);
  await tester.sendKeyUpEvent(
    LogicalKeyboardKey.controlLeft,
    physicalKey: PhysicalKeyboardKey.controlLeft,
  );
  await settle(tester, 300);
}

Future<String> coreState(
  WidgetTester tester,
  String sessionId,
) async => (await tester.runAsync(() async {
  final c = HttpClient();
  final req = await c.getUrl(
    Uri.parse('${_env['AER_CORE_URL']}/api/v1/remote/sessions/$sessionId'),
  );
  req.headers.set(
    'Authorization',
    'Bearer ${File(_env['AER_CORE_TOKEN_FILE']!).readAsStringSync().trim()}',
  );
  final res = await req.close();
  final m = jsonDecode(
    await res.transform(utf8.decoder).join(),
  ) as Map<String, dynamic>;
  c.close();
  return (m['data'] as Map<String, dynamic>)['state'] as String;
}))!;

Future<void> waitFor(
  WidgetTester tester,
  String what,
  bool Function() cond, {
  int tries = 80,
}) async {
  for (var i = 0; i < tries && !cond(); i++) {
    await settle(tester, 250);
  }
  expect(cond(), isTrue, reason: what);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'AER HOME through the own Gateway: clients, pairing, viewer, rights, revoke',
    (tester) async {
      if (_env['AER_CORE_URL'] == null || _env['AER_RELAY_LAB'] == null) {
        markTestSkipped('AER_CORE_URL / AER_RELAY_LAB not set');
        return;
      }
      final results = <String>[];
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
      // The credential goes to a 0600 file of the isolated data dir: the
      // user's real keyring is never touched by tests.
      final data = Directory(_env['AER_DESKTOP_DATA_DIR']!);
      final embedded = RemoteController.defaultEmbedded();
      final gateway = GatewayRemoteController(
        profiles: GatewayProfileStore(File('${data.path}/remote-gateway.json')),
        credentials: FileCredentialStore(
          File('${data.path}/remote-gateway.credential'),
        ),
        embedded: embedded,
        deviceName: 'AER HOME (стенд Gateway)',
        poll: const Duration(milliseconds: 500),
      );
      final remote = RemoteController(
        HttpRemoteApi(client),
        connection,
        sourceName: 'AER HOME (стенд Gateway)',
        embedded: embedded,
        gateway: gateway,
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
      final info = lab();
      final host = remote.hosts.firstWhere(
        (h) => h.name == 'Тестовый хост Wayland (стенд)',
      );
      expect(remote.embeddedAvailable, isTrue);

      // 1. Owner at home: «Клиенты» → new client with this computer, clipboard + files.
      await tester.tap(find.byKey(const Key('remote-tab-clients')));
      await settle(tester, 500);
      for (var i = 0; i < 20 && remote.gatewayInfo == null; i++) {
        await tester.runAsync(remote.refresh);
        await settle(tester, 500);
      }
      expect(
        remote.gatewayInfo?.certSha256,
        info['fingerprint'],
        reason: 'Gateway reported its fingerprint to Core',
      );
      await tester.tap(find.byKey(const Key('remote-client-new')));
      await settle(tester, 400);
      await tester.enterText(
        find.byKey(const Key('remote-client-name')),
        'AER HOME вне дома (стенд)',
      );
      await tester.tap(find.byKey(Key('remote-client-host-${host.entityId}')));
      await tester.tap(find.byKey(const Key('remote-client-files')));
      await settle(tester, 200);
      await shot(tester, 'g01-new-client');
      await tester.tap(find.byKey(const Key('remote-client-save')));
      await settle(tester, 800);
      final code = tester
          .widget<SelectableText>(find.byKey(const Key('remote-pairing-code')))
          .data!;
      expect(code, matches(RegExp(r'^[A-Z0-9]{4}-[A-Z0-9]{4}-[A-Z0-9]{4}$')));
      await shot(tester, 'g02-pairing-code');
      await tester.tap(find.byKey(const Key('remote-pairing-done')));
      await settle(tester, 500);
      final rc = remote.clients.firstWhere(
        (c) => c.name == 'AER HOME вне дома (стенд)',
      );
      expect(rc.pairPending, isTrue);
      results.add(
        'owner: client created, one-time code shown once, Gateway fingerprint known to Core',
      );

      // 2. The same app «outside»: add the server, compare and pin, pair.
      await tester.tap(find.byKey(const Key('remote-tab-gateway')));
      await settle(tester, 500);
      final gwAddr = (info['gateway'] as String).replaceFirst('https://', '');
      await tester.enterText(find.byKey(const Key('gw-address')), gwAddr);
      await tester.tap(find.byKey(const Key('gw-probe')));
      await waitFor(
        tester,
        'fingerprint shown',
        () => find.byKey(const Key('gw-fingerprint')).evaluate().isNotEmpty,
      );
      expect(
        tester
            .widget<SelectableText>(find.byKey(const Key('gw-fingerprint')))
            .data,
        info['fingerprint'],
      );
      expect(find.textContaining('Совпадает с отпечатком'), findsOneWidget);
      expect(
        tester.widget<FilledButton>(find.byKey(const Key('gw-pair'))).onPressed,
        isNull,
        reason: 'no pairing before the explicit confirmation',
      );
      await shot(tester, 'g03-fingerprint');
      await tester.tap(find.byKey(const Key('gw-confirm')));
      await settle(tester, 200);
      await tester.enterText(find.byKey(const Key('gw-code')), code);
      await tester.tap(find.byKey(const Key('gw-pair')));
      await waitFor(
        tester,
        'paired',
        () => gateway.phase == GatewayPhase.ready && gateway.hosts.isNotEmpty,
      );
      await settle(tester, 500);
      await shot(tester, 'g04-paired-hosts');
      final cred = await tester.runAsync(
        () => File('${data.path}/remote-gateway.credential').readAsString(),
      );
      expect(cred, startsWith('aerc1.'));
      final mode = await tester.runAsync(
        () async => (await Process.run('stat', [
          '-c',
          '%a',
          '${data.path}/remote-gateway.credential',
        ])).stdout.toString().trim(),
      );
      expect(mode, '600');
      final profileText = await tester.runAsync(
        () => File('${data.path}/remote-gateway.json').readAsString(),
      );
      expect(profileText, isNot(contains('aerc1')));
      // The code is one-time: a second pairing with it is refused.
      final replay = await tester.runAsync(() async {
        final c = engine.GatewayClient(
          engine.GatewayServer.parse(gwAddr, info['fingerprint'] as String),
        );
        try {
          await c.pair(code);
          return 0;
        } on engine.RemoteEngineException catch (e) {
          return e.status;
        } finally {
          c.close();
        }
      });
      expect(replay, 401, reason: 'pairing code reused');
      // A wrong pin never reaches the API.
      final pinErr = await tester.runAsync(() async {
        final c = engine.GatewayClient(
          engine.GatewayServer.parse(gwAddr, 'ab' * 32),
        )..credential = cred;
        try {
          await c.hosts();
          return 'accepted';
        } catch (e) {
          return GatewayRemoteController.describe(e);
        } finally {
          c.close();
        }
      });
      expect(pinErr, contains('не совпадает'));
      results.add(
        'client: fingerprint probed = Gateway, pinned after confirmation, paired; credential in a 0600 file, not in the profile; code reuse → 401; wrong pin refused',
      );

      // 3. Session through the Gateway in the built-in viewer.
      await tester.tap(find.byKey(Key('gw-connect-${host.entityId}')));
      await waitFor(
        tester,
        'desktop page',
        () =>
            find.byKey(const Key('remote-desktop-page')).evaluate().isNotEmpty,
      );
      final view = tester.state<RemoteDesktopViewState>(
        find.byType(RemoteDesktopView),
      );
      await waitFor(tester, 'frames painted', () => view.painted > 0);
      final sid = gateway.active!.conn!.session!.id;
      expect(gateway.active!.conn!.session!.route, 'relay');
      for (
        var i = 0;
        i < 40 && await coreState(tester, sid) != 'connected';
        i++
      ) {
        await settle(tester, 250);
      }
      expect(await coreState(tester, sid), 'connected');
      await settle(tester, 2000);
      await shot(tester, 'g05-desktop-through-gateway');

      // Keyboard.
      var d = (await tester.runAsync(() => hostDialog('AER Gateway')))!;
      var out = d.stdout.transform(utf8.decoder).join();
      await settle(tester, 3000);
      await shot(tester, 'g06-host-dialog');
      await keys(tester, [
        (LogicalKeyboardKey.keyG, PhysicalKeyboardKey.keyG),
        (LogicalKeyboardKey.keyW, PhysicalKeyboardKey.keyW),
        (LogicalKeyboardKey.space, PhysicalKeyboardKey.space),
        (LogicalKeyboardKey.digit5, PhysicalKeyboardKey.digit5),
        (LogicalKeyboardKey.enter, PhysicalKeyboardKey.enter),
      ]);
      expect(await dialogResult(tester, d, out), ('gw 5', 0));
      results.add(
        'session via Gateway: route relay, Core connected, image painted, keyboard «gw 5» reached the host',
      );

      // Clipboard app → host (the app's own clipboard, Ctrl+V in the viewer).
      await tester.runAsync(
        () => Clipboard.setData(const ClipboardData(text: 'aer-gw-clip-in')),
      );
      d = (await tester.runAsync(() => hostDialog('AER clip in')))!;
      out = d.stdout.transform(utf8.decoder).join();
      await settle(tester, 3000);
      await ctrl(tester, LogicalKeyboardKey.keyV, PhysicalKeyboardKey.keyV);
      await settle(tester, 800);
      await keys(tester, [
        (LogicalKeyboardKey.enter, PhysicalKeyboardKey.enter),
      ]);
      expect((await dialogResult(tester, d, out)).$1, 'aer-gw-clip-in');
      // Clipboard host → app.
      d = (await tester.runAsync(
        () => hostDialog('AER clip out', prefill: 'aer-gw-clip-out'),
      ))!;
      out = d.stdout.transform(utf8.decoder).join();
      await settle(tester, 3000);
      await ctrl(tester, LogicalKeyboardKey.keyA, PhysicalKeyboardKey.keyA);
      await ctrl(tester, LogicalKeyboardKey.keyC, PhysicalKeyboardKey.keyC);
      String? local;
      for (var i = 0; i < 30 && local != 'aer-gw-clip-out'; i++) {
        await settle(tester, 300);
        local = (await tester.runAsync(
          () => Clipboard.getData(Clipboard.kTextPlain),
        ))?.text;
      }
      expect(local, 'aer-gw-clip-out');
      await keys(tester, [
        (LogicalKeyboardKey.enter, PhysicalKeyboardKey.enter),
      ]);
      await dialogResult(tester, d, out);
      results.add(
        'clipboard both ways through the app (Ctrl+V offers the local clipboard; host copy lands in the app clipboard)',
      );

      // Files through the relay with the real host agent.
      final files = gateway.active!.files!;
      final tmp = (await tester.runAsync(() async {
        final dir = await Directory.systemTemp.createTemp('aer-gw-live-');
        final f = File('${dir.path}/gw-file.txt');
        await f.writeAsString('файл через Gateway ${DateTime.now()}\n' * 500);
        return f;
      }))!;
      final name = 'gw-${DateTime.now().millisecondsSinceEpoch}.txt';
      await tester.runAsync(() => files.upload(tmp, name));
      final onHost = await tester.runAsync(
        () => File('${info['exchangeDir']}/$name').readAsString(),
      );
      expect(onHost, await tester.runAsync(tmp.readAsString));
      results.add(
        'files: upload through the relay landed in the host exchange folder',
      );

      // 4. Network drop → the viewer reconnects by itself.
      final reconnectsBefore =
          (gateway.active!.viewer! as engine.EmbeddedRdpViewer).reconnects;
      gateway.active!.conn!.rdp!.drop();
      await waitFor(tester, 'viewer reconnected', () {
        final v = gateway.active!.viewer! as engine.EmbeddedRdpViewer;
        return v.reconnects > reconnectsBefore && v.statusName == 'connected';
      });
      await settle(tester, 1500);
      expect(await coreState(tester, sid), 'connected');
      await shot(tester, 'g07-after-reconnect');
      results.add(
        'drop → automatic reconnect on a fresh ticket, Core connected',
      );

      // 5. Normal end from the desktop page.
      await tester.tap(find.byKey(const Key('remote-desktop-end')));
      for (var i = 0; i < 40 && (await tester.runAsync(rdpListening))!; i++) {
        await settle(tester, 150);
      }
      expect(await tester.runAsync(rdpListening), isFalse);
      expect(await coreState(tester, sid), 'disconnected');
      await settle(tester, 500);
      expect(gateway.active!.live, isFalse);
      results.add('end: disconnected, RDP closed, page closed');

      // 6. Rights: the owner removes clipboard and files; a new session has neither.
      await tester.runAsync(
        () => remote.updateClient(
          rc.id,
          name: rc.name,
          hosts: rc.hosts,
          clipboard: false,
          files: false,
        ),
      );
      await tester.tap(find.byKey(Key('gw-connect-${host.entityId}')));
      await waitFor(
        tester,
        'desktop page again',
        () =>
            find.byKey(const Key('remote-desktop-page')).evaluate().isNotEmpty,
      );
      final a2 = gateway.active!;
      final sid2 = a2.conn!.session!.id;
      final secretsSeen = <String>[
        cred!,
        code,
        a2.conn!.grant!.password,
        ...a2.conn!.grant!.tickets.values,
      ];
      expect(a2.viewer!.clipboardAllowed, isFalse);
      expect(a2.files, isNull);
      expect(a2.conn!.grant!.files, isFalse);
      final filesTicket = await tester.runAsync(() async {
        try {
          await a2.conn!.api.ticket(sid2, 'files');
          return 0;
        } on engine.RemoteEngineException catch (e) {
          return e.status;
        }
      });
      expect(filesTicket, 403, reason: 'no files ticket without the right');
      final view2 = tester.state<RemoteDesktopViewState>(
        find.byType(RemoteDesktopView),
      );
      await waitFor(tester, 'frames painted (2)', () => view2.painted > 0);
      await tester.runAsync(
        () => Clipboard.setData(const ClipboardData(text: 'must-not-arrive')),
      );
      d = (await tester.runAsync(() => hostDialog('AER no clip')))!;
      out = d.stdout.transform(utf8.decoder).join();
      await settle(tester, 3000);
      await ctrl(tester, LogicalKeyboardKey.keyV, PhysicalKeyboardKey.keyV);
      await settle(tester, 800);
      await keys(tester, [
        (LogicalKeyboardKey.enter, PhysicalKeyboardKey.enter),
      ]);
      final noClip = await dialogResult(tester, d, out);
      expect(noClip.$1, isNot(contains('must-not-arrive')));
      results.add(
        'rights removed: no clipboard (Ctrl+V delivered nothing), no files channel, files ticket → 403',
      );

      // 7. Revoke during the live session from «Клиенты».
      await tester.tap(find.byTooltip('Свернуть (сеанс продолжается)'));
      await settle(tester, 400);
      await tester.tap(find.byKey(const Key('remote-tab-clients')));
      await settle(tester, 400);
      await tester.tap(find.byKey(Key('remote-client-revoke-${rc.id}')));
      await settle(tester, 300);
      final t0 = DateTime.now();
      await tester.tap(find.byKey(const Key('remote-client-revoke-confirm')));
      for (var i = 0; i < 60 && (await tester.runAsync(rdpListening))!; i++) {
        await settle(tester, 100);
      }
      final cut = DateTime.now().difference(t0);
      expect(
        await tester.runAsync(rdpListening),
        isFalse,
        reason: 'RDP closed after revoke',
      );
      expect(await coreState(tester, sid2), 'revoked');
      await waitFor(tester, 'app saw the revoke', () => !gateway.active!.live);
      expect(gateway.active!.state.name, 'revoked');
      expect(gateway.active!.viewer, isNull);
      await waitFor(
        tester,
        'credential refused',
        () => gateway.phase == GatewayPhase.unauthorized,
      );
      await shot(tester, 'g08-revoked-clients');
      await tester.tap(find.byKey(const Key('remote-tab-gateway')));
      await settle(tester, 400);
      await shot(tester, 'g09-revoked-gateway-tab');
      results.add(
        'revoke during a live session: RDP closed ${cut.inMilliseconds} ms after the click, Core revoked, app session ended, credential refused',
      );

      // 8. No secrets in the logs of Core, Gateway and the host agent.
      final dir = _env['AER_RELAY_LAB']!;
      final logs = await tester.runAsync(
        () async => [
          for (final f in ['core.log', 'gateway.log', 'agent.log'])
            await File('$dir/$f').readAsString(),
        ].join('\n'),
      );
      for (final s in secretsSeen.where((s) => s.length > 8)) {
        expect(
          logs!.contains(s),
          isFalse,
          reason: 'secret in logs: ${s.substring(0, 6)}…',
        );
      }
      final secretPart = cred.split('.').last;
      expect(logs!.contains(secretPart), isFalse);
      results.add(
        'no credential, pairing code, RDP password or ticket in Core/Gateway/agent logs',
      );
      await tester.runAsync(
        () =>
            File('$dir/gateway_live_results.txt')
                .writeAsString(results.join('\n')),
      );
    },
  );
}
