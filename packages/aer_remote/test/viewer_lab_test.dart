// LIVE check of the built-in viewer (M14.3) against the isolated relay lab
// (tools/remote-lab/relay_lab.py): REAL gnome-remote-desktop in a headless
// GNOME session, real aer-core / aer-remote-gateway / aer-remote-host on
// loopback, and the viewer = native/aer_rdp (FreeRDP 3) through this engine.
//
//   python3 -I tools/remote-lab/relay_lab.py up DIR
//   AER_RELAY_LAB=DIR AER_RDP_LIB=native/aer_rdp/build/libaer_rdp.so \
//     dart test test/viewer_lab_test.dart
//   python3 -I tools/remote-lab/relay_lab.py down DIR
//
// Host-side actions (dialogs) run INSIDE the lab session only. Frames are
// written as PPM to DIR/frames for inspection. All data is TEST DATA.
@Tags(['lab'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:aer_remote/aer_remote.dart';
import 'package:crypto/crypto.dart';
import 'package:test/test.dart';

final _labDir = Platform.environment['AER_RELAY_LAB'];
final Object _skip = _labDir == null
    ? 'set AER_RELAY_LAB (tools/remote-lab/relay_lab.py)'
    : false;

late Map<String, dynamic> info;

Map<String, String> _hostEnv() {
  final lab = info['labDir'] as String;
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

/// A text dialog on the lab host; completes with (stdout, exit code).
Future<(String, int)> hostDialog(String title, {String prefill = ''}) async {
  final p = await Process.start(
    'zenity',
    ['--entry', '--title=$title', '--text=$title', '--entry-text=$prefill'],
    environment: _hostEnv(),
    includeParentEnvironment: false,
  );
  final out = p.stdout.transform(utf8.decoder).join();
  unawaited(p.stderr.drain<void>());
  final code = await p.exitCode.timeout(
    const Duration(seconds: 60),
    onTimeout: () {
      p.kill();
      return -1;
    },
  );
  return ((await out).trim(), code);
}

Future<int> ownerPost(String path) async {
  final c = HttpClient();
  final req = await c.postUrl(Uri.parse('${info['coreUrl']}/api/v1$path'));
  req.headers.set(
    'Authorization',
    'Bearer ${File(info['ownerTokenFile'] as String).readAsStringSync().trim()}',
  );
  final res = await req.close();
  await res.drain<void>();
  c.close();
  return res.statusCode;
}

Future<List<String>> ownerEvents(String sessionId) async {
  final c = HttpClient();
  final req = await c.getUrl(
    Uri.parse('${info['coreUrl']}/api/v1/remote/sessions/$sessionId'),
  );
  req.headers.set(
    'Authorization',
    'Bearer ${File(info['ownerTokenFile'] as String).readAsStringSync().trim()}',
  );
  final res = await req.close();
  final body = jsonDecode(
    await res.transform(utf8.decoder).join(),
  ) as Map<String, dynamic>;
  c.close();
  return [
    for (final e in (body['data'] as Map<String, dynamic>)['events'] as List)
      (e as Map<String, dynamic>)['kind'] as String,
  ];
}

Future<void> until(
  String what,
  FutureOr<bool> Function() cond, {
  int seconds = 30,
}) async {
  final end = DateTime.now().add(Duration(seconds: seconds));
  while (DateTime.now().isBefore(end)) {
    if (await cond()) return;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  fail('timeout: $what');
}

void savePpm(RdpFrame f, String name) {
  final dir = Directory('$_labDir/frames')..createSync(recursive: true);
  final b = BytesBuilder()
    ..add(ascii.encode('P6\n${f.width} ${f.height}\n255\n'));
  final px = f.bgra;
  final rgb = List<int>.filled(f.width * f.height * 3, 0);
  for (var i = 0, j = 0; i < px.length; i += 4, j += 3) {
    rgb[j] = px[i + 2];
    rgb[j + 1] = px[i + 1];
    rgb[j + 2] = px[i];
  }
  b.add(rgb);
  File('${dir.path}/$name.ppm').writeAsBytesSync(b.toBytes());
}

int changedPixels(RdpFrame a, RdpFrame b) {
  if (a.width != b.width || a.height != b.height) return a.width * a.height;
  var n = 0;
  for (var i = 0; i < a.bgra.length; i += 4) {
    if (a.bgra[i] != b.bgra[i] ||
        a.bgra[i + 1] != b.bgra[i + 1] ||
        a.bgra[i + 2] != b.bgra[i + 2]) {
      n++;
    }
  }
  return n;
}

const _letters = 'abcdefghijklmnopqrstuvwxyz';
const _digits = '1234567890';

/// Types lowercase latin, digits and spaces with physical scancodes.
Future<void> typeText(EmbeddedRdpViewer v, String s) async {
  for (final ch in s.split('')) {
    int hid;
    if (_letters.contains(ch)) {
      hid = 0x04 + _letters.indexOf(ch);
    } else if (_digits.contains(ch)) {
      hid = 0x1E + _digits.indexOf(ch);
    } else {
      hid = 0x2C; // space
    }
    final sc = hidToRdpScancode[hid]!;
    v.key(sc, true);
    v.key(sc, false);
    await Future<void>.delayed(const Duration(milliseconds: 40));
  }
}

Future<void> chord(EmbeddedRdpViewer v, List<int> hids) async {
  for (final h in hids) {
    v.key(hidToRdpScancode[h]!, true);
    await Future<void>.delayed(const Duration(milliseconds: 30));
  }
  for (final h in hids.reversed) {
    v.key(hidToRdpScancode[h]!, false);
    await Future<void>.delayed(const Duration(milliseconds: 30));
  }
}

const ctrl = 0xE0, keyA = 0x04, keyC = 0x06, keyV = 0x19, enter = 0x28;

Future<void> click(EmbeddedRdpViewer v, int x, int y) async {
  v.mouse(RdpPointer.move, x, y);
  await Future<void>.delayed(const Duration(milliseconds: 150));
  v.mouse(RdpPointer.down | RdpPointer.button1, x, y);
  await Future<void>.delayed(const Duration(milliseconds: 80));
  v.mouse(RdpPointer.button1, x, y);
}

void main() {
  late GatewayServer server;
  late GatewayClient api;
  final log = <String>[];

  setUpAll(() {
    if (_labDir == null) return;
    info = jsonDecode(
      File('$_labDir/lab.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    server = GatewayServer.parse(
      info['gateway'] as String,
      info['fingerprint'] as String,
    );
    api = GatewayClient(server);
  });
  tearDownAll(() {
    if (_labDir == null) return;
    File('$_labDir/viewer_results.txt').writeAsStringSync(log.join('\n'));
    api.close();
  });

  test(
    'built-in viewer through the Gateway: pin, image, input, clipboard, files, reconnect, end',
    () async {
      expect(
        RdpNative.load(),
        isNotNull,
        reason: 'set AER_RDP_LIB to the built libaer_rdp.so',
      );
      await api.pair(info['pairingCode'] as String, deviceName: 'viewer lab');
      final conn = RemoteConnection(
        api,
        poll: const Duration(milliseconds: 300),
      );
      final states = <RemoteState>[];
      conn.updates.listen((u) => states.add(u.state));
      await conn.start(info['hostId'] as String);
      addTearDown(() async {
        if (!(await api.session(conn.session!.id)).state.terminal) {
          await conn.end();
        }
      });
      final g = conn.grant!;
      ViewerTarget target({String? pin}) => ViewerTarget(
        host: '127.0.0.1',
        port: conn.rdp!.port,
        username: g.username,
        password: g.password,
        certPem: g.certPem,
        certSha256: pin ?? g.certSha256,
        clipboard: g.clipboard,
      );
      Future<RemoteState> core() async =>
          (await api.session(conn.session!.id)).state;

      // 1. Pinning: another certificate fingerprint → refused before any login.
      final bad = EmbeddedRdpViewer.tryCreate()!;
      await bad.open(target(pin: 'ab' * 32));
      await until(
        'wrong pin refused',
        () =>
            bad.status == ViewerStatus.failed ||
            bad.status == ViewerStatus.closed,
      );
      expect(bad.lastError, contains('certificate'));
      expect(bad.lastFrame, isNull);
      await bad.close();
      log.add('pin: wrong fingerprint refused (${bad.lastError})');

      // 2. Image.
      final v = EmbeddedRdpViewer(
        RdpNative.load()!,
        width: 1280,
        height: 800,
        canReconnect: () async => !(await core()).terminal,
      );
      await v.open(target());
      await until('connected', () => v.status == ViewerStatus.connected);
      await until('first frame', () => v.lastFrame != null);
      await Future<void>.delayed(const Duration(seconds: 2));
      final desk = v.lastFrame!;
      savePpm(desk, '01-desktop');
      expect(desk.width, 1280);
      expect(desk.height, 800);
      final distinct = <int>{};
      for (var i = 0; i < desk.bgra.length; i += 4 * 997) {
        distinct.add(
          desk.bgra[i] << 16 | desk.bgra[i + 1] << 8 | desk.bgra[i + 2],
        );
      }
      expect(
        distinct.length,
        greaterThan(20),
        reason: 'a real desktop, not a blank frame',
      );
      await until(
        'Core: connected',
        () async => await core() == RemoteState.connected,
      );
      log.add(
        'image: ${desk.width}x${desk.height}, ${distinct.length} sampled colours',
      );

      // 3. Keyboard + image update.
      var dialog = hostDialog('AER embed keys');
      try {
        await until(
          'dialog visible',
          () => changedPixels(desk, v.lastFrame!) > 5000,
          seconds: 20,
        );
      } finally {
        savePpm(v.lastFrame!, '02-wait');
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
      final withDialog = v.lastFrame!;
      savePpm(withDialog, '02-dialog');
      final changed = changedPixels(desk, withDialog);
      expect(
        changed,
        greaterThan(5000),
        reason: 'the dialog must appear in the image',
      );
      await typeText(v, 'aer embed 42');
      await chord(v, [enter]);
      var (out, code) = await dialog;
      expect((out, code), ('aer embed 42', 0));
      log.add(
        'image update: $changed pixels changed when a dialog opened; keyboard: "$out" exit $code',
      );

      // 4. Mouse: Cancel button of the same dialog (centred, fixed size).
      dialog = hostDialog('AER embed mouse');
      await Future<void>.delayed(const Duration(seconds: 3));
      savePpm(v.lastFrame!, '03-mouse-dialog');
      await click(v, 640 - 75, 400 + 89);
      (out, code) = await dialog;
      expect(code, 1, reason: 'Cancel clicked');
      log.add('mouse: Cancel clicked → exit $code');

      // 5. Clipboard client → host.
      dialog = hostDialog('AER clip in');
      await Future<void>.delayed(const Duration(seconds: 3));
      expect(v.pushClipboard('aer-clip-to-host-5'), isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 500));
      await chord(v, [ctrl, keyV]);
      await Future<void>.delayed(const Duration(milliseconds: 800));
      await chord(v, [enter]);
      (out, code) = await dialog;
      expect(out, 'aer-clip-to-host-5');
      log.add('clipboard client→host: "$out"');

      // 6. Clipboard host → client.
      final remote = v.remoteClipboard
          .firstWhere((t) => t == 'aer-clip-to-client-6')
          .timeout(const Duration(seconds: 15));
      dialog = hostDialog('AER clip out', prefill: 'aer-clip-to-client-6');
      await Future<void>.delayed(const Duration(seconds: 3));
      await chord(v, [ctrl, keyA]);
      await chord(v, [ctrl, keyC]);
      expect(await remote, 'aer-clip-to-client-6');
      await chord(v, [enter]);
      await dialog;
      log.add('clipboard host→client: received');

      // 7. Files through the real host agent (end-to-end TLS pinned to the host).
      final up = 'm14-report-${DateTime.now().millisecondsSinceEpoch}.txt';
      final fc = pinnedHttpClient(g.certSha256);
      final body = utf8.encode(
        'отчёт через настоящий хост ${DateTime.now().toIso8601String()}',
      );
      final put = await fc.putUrl(
        Uri.https('127.0.0.1:${conn.files!.port}', '/v1/files/$up'),
      );
      put.headers
        ..set('Authorization', 'Bearer ${g.filesToken}')
        ..set('X-AER-SHA256', sha256.convert(body).toString());
      put.add(body);
      final putRes = await put.close();
      final putText = await putRes.transform(utf8.decoder).join();
      expect(putRes.statusCode, 201, reason: putText);
      expect(File('${info['exchangeDir']}/$up').readAsBytesSync(), body);
      File('${info['exchangeDir']}/from-host.txt')
          .writeAsStringSync('файл с хоста');
      final get = await fc.getUrl(
        Uri.https('127.0.0.1:${conn.files!.port}', '/v1/files/from-host.txt'),
      );
      get.headers.set('Authorization', 'Bearer ${g.filesToken}');
      final getRes = await get.close();
      final got = await getRes.transform(utf8.decoder).join();
      expect((getRes.statusCode, got), (200, 'файл с хоста'));
      final noTok = await fc.getUrl(
        Uri.https('127.0.0.1:${conn.files!.port}', '/v1/files'),
      );
      final noTokRes = await noTok.close();
      await noTokRes.drain<void>();
      expect(noTokRes.statusCode, 401);
      fc.close(force: true);
      log.add(
        'files: upload ${body.length} B and download through the real host agent, no token → 401',
      );

      // 8. Network drop → automatic reconnect (fresh ticket).
      final before = v.reconnects;
      conn.rdp!.drop();
      await until(
        'viewer reconnected',
        () => v.reconnects > before && v.status == ViewerStatus.connected,
        seconds: 40,
      );
      await until(
        'Core: connected again',
        () async => await core() == RemoteState.connected,
        seconds: 20,
      );
      final events = await ownerEvents(conn.session!.id);
      expect(
        events.where((e) => e == 'tunnel_opened').length,
        greaterThanOrEqualTo(3),
        reason: 'rdp + files + the reconnected rdp leg: $events',
      );
      final after = v.lastFrame!;
      savePpm(after, '04-after-reconnect');
      log.add(
        'reconnect: connection dropped → viewer reconnected by itself (${v.reconnects}) on a fresh ticket, Core connected; Core states seen by the engine: ${states.map((s) => s.name).join(" → ")}',
      );

      // 9. Normal end: host closes RDP, the viewer stops without retrying.
      await conn.end();
      await until(
        'viewer closed after end',
        () => v.status == ViewerStatus.closed,
        seconds: 20,
      );
      expect(await core(), RemoteState.disconnected);
      await until('RDP port closed', () async {
        try {
          (await Socket.connect('127.0.0.1', info['rdpPort'] as int)).destroy();
          return false;
        } on SocketException {
          return true;
        }
      });
      await v.close();
      log.add('end: disconnected, viewer closed, RDP port closed');
    },
    timeout: const Timeout(Duration(minutes: 5)),
    skip: _skip,
  );

  test(
    'revoke during a live built-in session',
    () async {
      final conn = RemoteConnection(
        api,
        poll: const Duration(milliseconds: 300),
      );
      await conn.start(info['hostId'] as String);
      final g = conn.grant!;
      final v = EmbeddedRdpViewer.tryCreate(
        canReconnect: () async =>
            !(await api.session(conn.session!.id)).state.terminal,
      )!;
      await v.open(
        ViewerTarget(
          host: '127.0.0.1',
          port: conn.rdp!.port,
          username: g.username,
          password: g.password,
          certPem: g.certPem,
          certSha256: g.certSha256,
          clipboard: g.clipboard,
        ),
      );
      await until('connected', () => v.status == ViewerStatus.connected);
      final t0 = DateTime.now();
      expect(
        await ownerPost('/remote/clients/${info['clientId']}/revoke'),
        200,
      );
      await until(
        'viewer closed by revoke',
        () => v.status == ViewerStatus.closed,
        seconds: 20,
      );
      final dt = DateTime.now().difference(t0);
      expect(v.reconnects, 0, reason: 'no reconnect after a revoke');
      await expectLater(api.hosts(), throwsA(isA<RemoteEngineException>()));
      await v.close();
      log.add(
        'revoke: viewer closed ${dt.inMilliseconds} ms after the owner revoked, no reconnect',
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
    skip: _skip,
  );
}
