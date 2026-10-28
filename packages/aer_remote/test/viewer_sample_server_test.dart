// LIVE check of the built-in viewer core (native/aer_rdp over FreeRDP 3)
// against a REAL RDP server that needs no OS remote-desktop host: the
// FreeRDP sample server (sfreerdp-server, test picture, draws an icon where
// the mouse is), bound to 127.0.0.1 only. Written for M10 (Windows, where
// the built-in RDP host stays off), runs on Linux too.
//
//   AER_RDP_LIB=<aer_rdp.dll|libaer_rdp.so> \
//   AER_RDP_SAMPLE_SERVER=<sfreerdp-server> AER_RDP_SAMPLE_CERT=server.crt \
//   AER_RDP_SAMPLE_KEY=server.key dart test test/viewer_sample_server_test.dart
//
// The server runs in the certificate's directory and needs test_icon.bmp
// there (copy it from FreeRDP's server/Sample).
//
// The sample server has no NLA and no clipboard channel: credentials and
// clipboard transfer are checked against gnome-remote-desktop in
// viewer_lab_test.dart, not here. All data is TEST DATA.
@Tags(['lab'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aer_remote/aer_remote.dart';
import 'package:crypto/crypto.dart';
import 'package:test/test.dart';

final _env = Platform.environment;
final _server = _env['AER_RDP_SAMPLE_SERVER'];
final Object _skip =
    _server == null ||
        _env['AER_RDP_LIB'] == null ||
        _env['AER_RDP_SAMPLE_CERT'] == null ||
        _env['AER_RDP_SAMPLE_KEY'] == null
    ? 'set AER_RDP_LIB, AER_RDP_SAMPLE_SERVER, AER_RDP_SAMPLE_CERT, AER_RDP_SAMPLE_KEY'
    : false;

const _ptrMove = 0x0800; // PTR_FLAGS_MOVE

String _pemSha256(String pem) {
  final b64 = pem
      .split('\n')
      .where((l) => !l.startsWith('-----'))
      .join()
      .trim();
  return sha256.convert(base64.decode(b64)).toString();
}

Future<int> _freePort() async {
  final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final p = s.port;
  await s.close();
  return p;
}

Future<void> _until(String what, bool Function() ok, {int seconds = 15}) async {
  final end = DateTime.now().add(Duration(seconds: seconds));
  while (!ok()) {
    if (DateTime.now().isAfter(end)) fail('timeout: $what');
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

/// First frame, a mouse move the server draws (its icon at x + 10, y), and
/// keyboard input (scancodes, Cyrillic as unicode) that keeps the session up.
Future<void> _pictureMouseKeyboard(RdpSession s, int w, int h) async {
  RdpFrame? first;
  await _until('first frame', () => (first ??= s.takeFrame()) != null);
  expect(first!.width, w);
  expect(first!.height, h);
  expect(first!.bgra.any((b) => b != 0), isTrue, reason: 'test picture drawn');

  int sum(RdpFrame f, int x0, int y0) {
    var t = 0;
    for (var y = y0; y < y0 + 40; y++) {
      for (var x = x0; x < x0 + 40; x++) {
        final i = (y * f.width + x) * 4;
        t += f.bgra[i] + f.bgra[i + 1] + f.bgra[i + 2];
      }
    }
    return t;
  }

  final before = sum(first!, 610, 400);
  var latest = first!;
  for (var i = 0; i < 20; i++) {
    s.mouse(_ptrMove, 600, 400);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    latest = s.takeFrame() ?? latest;
    if (sum(latest, 610, 400) != before) break;
  }
  expect(
    sum(latest, 610, 400),
    isNot(before),
    reason: 'mouse move reached the server and changed the frame',
  );

  for (final sc in [0x1e, 0x30, 0x1c]) {
    s.key(sc, true);
    s.key(sc, false);
  }
  for (final cp in 'Привет'.runes) {
    s.unicode(cp, true);
    s.unicode(cp, false);
  }
  await Future<void>.delayed(const Duration(milliseconds: 500));
  expect(s.state, RdpState.connected, reason: s.error);
}

String _normFp(String fp) => fp.replaceAll(':', '').toLowerCase();

/// Private FreeRDP config dirs aer_rdp made (aer-rdp-*) in the temp dir.
Set<String> _privateDirs() => Directory.systemTemp
    .listSync()
    .whereType<Directory>()
    .map((d) => d.path)
    .where((p) => p.split(Platform.pathSeparator).last.startsWith('aer-rdp-'))
    .toSet();

/// FreeRDP's shared config (known hosts): must stay untouched.
Directory? _sharedFreerdpDir() {
  final base = Platform.isWindows
      ? _env['APPDATA']
      : (_env['XDG_CONFIG_HOME'] ?? '${_env['HOME']}/.config');
  return base == null
      ? null
      : Directory('$base${Platform.pathSeparator}freerdp');
}

void main() {
  Process? server;
  late int port;
  late String pin;
  late RdpNative native;
  final serverLog = StringBuffer();

  setUpAll(() async {
    if (_skip != false) return; // setUpAll runs even when every test skips
    final loaded = RdpNative.load();
    if (loaded == null) {
      fail('Cannot load AER_RDP_LIB and its bundled runtime DLLs');
    }
    native = loaded;
    pin = _pemSha256(File(_env['AER_RDP_SAMPLE_CERT']!).readAsStringSync());
    port = await _freePort();
    server = await Process.start(_server!, [
      '--port=$port',
      '--cert=${_env['AER_RDP_SAMPLE_CERT']}',
      '--key=${_env['AER_RDP_SAMPLE_KEY']}',
    ], workingDirectory: File(_env['AER_RDP_SAMPLE_CERT']!).parent.path);
    server!.stdout.transform(utf8.decoder).listen(serverLog.write);
    server!.stderr.transform(utf8.decoder).listen(serverLog.write);
    final end = DateTime.now().add(const Duration(seconds: 10));
    while (true) {
      try {
        final s = await Socket.connect(InternetAddress.loopbackIPv4, port);
        s.destroy();
        break;
      } on SocketException {
        if (DateTime.now().isAfter(end)) {
          fail('sample server did not listen\n$serverLog');
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
  });

  tearDownAll(() async {
    if (_skip != false) return;
    if (server == null) return;
    server!.kill();
    await server!.exitCode.timeout(
      const Duration(seconds: 5),
      onTimeout: () => -1,
    );
    final log = _env['AER_RDP_SAMPLE_LOG']; // server output, for diagnosis
    if (log != null) File(log).writeAsStringSync(serverLog.toString());
  });

  ViewerTarget target({String? certSha256, bool clipboard = false}) =>
      ViewerTarget(
        host: '127.0.0.1',
        port: port,
        username: 'aer-test',
        password: 'test-only-password',
        certPem: '',
        certSha256: certSha256 ?? pin,
        clipboard: clipboard,
      );

  test('a certificate other than the pinned one is refused', () async {
    final s = RdpSession(native);
    addTearDown(s.dispose);
    expect(s.connect(target(certSha256: 'ab' * 32)), isTrue);
    await _until(
      'failed',
      () => s.state == RdpState.failed || s.state == RdpState.disconnected,
    );
    expect(s.error, contains('does not match the pinned'));
    expect(s.takeFrame(), isNull);
  }, skip: _skip);

  test('no pin, no connection', () {
    final s = RdpSession(native);
    addTearDown(s.dispose);
    expect(s.connect(target(certSha256: '')), isFalse);
    expect(s.state, RdpState.failed);
  }, skip: _skip);

  test('pinned: picture, mouse visible in the frame, keyboard, no clipboard, clean end', () async {
    final shared = _sharedFreerdpDir();
    final sharedBefore = shared != null && shared.existsSync()
        ? shared
              .listSync(recursive: true)
              .map((e) => '${e.path} ${e.statSync().modified}')
              .toSet()
        : null;
    final dirsBefore = _privateDirs();

    final s = RdpSession(native);
    expect(s.connect(target(), width: 1024, height: 768), isTrue);
    await _until(
      'connection settled',
      () => s.state != RdpState.connecting && s.state != RdpState.idle,
    );
    expect(s.state, RdpState.connected, reason: s.error);
    expect(
      _privateDirs().difference(dirsBefore),
      hasLength(1),
      reason: 'one private FreeRDP config dir per connection',
    );

    await _pictureMouseKeyboard(s, 1024, 768);

    // No clipboard right: nothing can be offered to the server.
    expect(s.setClipboard('секрет (тест)'), isFalse);

    s.disconnect();
    await _until('disconnected', () => s.state == RdpState.disconnected);
    s.dispose();
    expect(
      _privateDirs().difference(dirsBefore),
      isEmpty,
      reason: 'private config dir removed',
    );
    if (sharedBefore != null) {
      final after = shared!
          .listSync(recursive: true)
          .map((e) => '${e.path} ${e.statSync().modified}')
          .toSet();
      expect(after, sharedBefore, reason: 'shared FreeRDP config untouched');
    } else {
      expect(
        shared?.existsSync() ?? false,
        isFalse,
        reason: 'no shared FreeRDP config created',
      );
    }
  }, skip: _skip);

  // The same real RDP server behind the own Gateway: core/cmd/aer-remotelab
  test(
    'a late viewer receives the static frame and pin failure stays failed',
    () async {
      final viewer = EmbeddedRdpViewer(native, width: 1024, height: 768);
      try {
        await viewer.open(target());
        await _until(
          'frame before UI subscription',
          () => viewer.lastFrame != null,
        );
        final frame = await viewer.frameData.first.timeout(
          const Duration(seconds: 2),
        );
        expect(frame.width, 1024);
        expect(frame.height, 768);
      } finally {
        await viewer.close();
      }
      final refused = EmbeddedRdpViewer(native);
      try {
        await refused.open(target(certSha256: 'ab' * 32));
        await _until(
          'pin failure reported',
          () =>
              refused.statusName == 'failed' || refused.statusName == 'closed',
        );
        expect(refused.statusName, 'failed');
        expect(refused.lastError, contains('does not match the pinned'));
      } finally {
        await refused.close();
      }
    },
    skip: _skip,
  );

  // with -rdp (in-process Core, Gateway and host agent, all on loopback).
  final labBin = _env['AER_REMOTELAB_BIN'];
  test(
    'through the own Gateway: pairing, pinned relay, picture, mouse, '
    'agent sees the connection, revoke',
    () async {
      final lab = await Process.start(labBin!, [
        '-rdp',
        '127.0.0.1:$port',
        '-rdp-cert',
        _env['AER_RDP_SAMPLE_CERT']!,
        '-rdp-key',
        _env['AER_RDP_SAMPLE_KEY']!,
      ]);
      addTearDown(() async {
        await lab.stdin.close();
        await lab.exitCode.timeout(
          const Duration(seconds: 10),
          onTimeout: () {
            lab.kill();
            return -1;
          },
        );
      });
      final info = jsonDecode(
        await lab.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .first,
      ) as Map<String, dynamic>;
      final api = GatewayClient(
        GatewayServer.parse(
          info['gateway'] as String,
          info['fingerprint'] as String,
        ),
      );
      addTearDown(api.close);
      await api.pair(info['pairingCode'] as String, deviceName: 'M10 test');

      final conn = RemoteConnection(
        api,
        poll: const Duration(milliseconds: 200),
      );
      final seen = <RemoteState>[];
      conn.updates.listen((u) => seen.add(u.state));
      await conn.start(info['hostId'] as String);
      final g = conn.grant!;
      expect(
        _normFp(g.certSha256),
        pin,
        reason: 'the agent pins the real server certificate',
      );

      final s = RdpSession(native);
      addTearDown(s.dispose);
      expect(
        s.connect(
          ViewerTarget(
            host: '127.0.0.1',
            port: conn.rdp!.port,
            username: g.username,
            password: g.password,
            certPem: g.certPem,
            certSha256: g.certSha256,
            clipboard: g.clipboard,
          ),
          width: 1024,
          height: 768,
        ),
        isTrue,
      );
      await _until(
        'connection settled',
        () => s.state != RdpState.connecting && s.state != RdpState.idle,
      );
      expect(s.state, RdpState.connected, reason: s.error);
      await _pictureMouseKeyboard(s, 1024, 768);

      // The host agent counts the real RDP connection (TCP table on
      // Windows/Linux) and reports it to Core.
      Future<RemoteState> state() async =>
          (await api.session(conn.session!.id)).state;
      final end = DateTime.now().add(const Duration(seconds: 15));
      while (await state() != RemoteState.connected) {
        if (DateTime.now().isAfter(end)) fail('agent never saw the connection');
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      s.disconnect();
      await _until('disconnected', () => s.state == RdpState.disconnected);
      final end2 = DateTime.now().add(const Duration(seconds: 15));
      while (await state() != RemoteState.reconnecting) {
        if (DateTime.now().isAfter(end2)) fail('agent never saw the drop');
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }

      // The owner revokes this client: the engine closes up.
      final c = HttpClient();
      final req = await c.postUrl(
        Uri.parse(
          '${info['coreUrl']}/api/v1/remote/clients/${info['clientId']}/revoke',
        ),
      );
      req.headers.set('Authorization', 'Bearer ${info['ownerToken']}');
      expect((await req.close()).statusCode, 200);
      c.close();
      final end3 = DateTime.now().add(const Duration(seconds: 15));
      while (!seen.contains(RemoteState.revoked)) {
        if (DateTime.now().isAfter(end3)) fail('revocation not noticed');
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
    skip: _skip != false
        ? _skip
        : labBin == null
        ? 'set AER_REMOTELAB_BIN to core/bin/aer-remotelab'
        : false,
  );
}
