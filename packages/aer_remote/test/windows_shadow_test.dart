// REAL RDP/TLS/codecs/agent/Gateway, SYNTHETIC pixels and clipboard only.
// Never captures a desktop, touches the Windows clipboard or calls SendInput.
@Tags(['lab'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aer_remote/aer_remote.dart';
import 'package:test/test.dart';

Future<void> until(String label, bool Function() condition) async {
  final end = DateTime.now().add(const Duration(seconds: 20));
  while (!condition()) {
    if (DateTime.now().isAfter(end)) fail('timeout: $label');
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

void main() {
  final env = Platform.environment;
  final labBin = env['AER_REMOTELAB_BIN'], shadow = env['AER_SHADOW_BIN'];
  test(
    'embedded viewer clipboard and asynchronous disposal through relay',
    () async {
      final lab = await Process.start(labBin!, ['-shadow', shadow!]);
      final stderr = lab.stderr.drain<void>();
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
      final conn = RemoteConnection(
        api,
        poll: const Duration(milliseconds: 100),
      );
      EmbeddedRdpViewer? viewer;
      StreamSubscription<String>? clipboard;
      try {
        await api.pair(info['pairingCode'] as String);
        await conn.start(info['hostId'] as String);
        final g = conn.grant!;
        viewer = EmbeddedRdpViewer(
          RdpNative.load()!,
          canReconnect: () async =>
              !(await api.session(conn.session!.id)).state.terminal,
        );
        String? received;
        clipboard = viewer.remoteClipboard.listen((s) {
          received = s;
        });
        await viewer.open(
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
        expect(viewer.pushClipboard('AER Connect TEST ONLY'), isTrue);
        await until(
          'embedded clipboard echo',
          () => received == 'AER Connect TEST ONLY',
        );
        expect(viewer.lastFrame, isNotNull);
        conn.rdp!.drop();
        await until(
          'automatic reconnect after transport loss',
          () => viewer!.reconnects > 0 && viewer.statusName == 'connected',
        );
        expect(viewer.pushClipboard('AER reconnect TEST ONLY'), isTrue);
        await until(
          'clipboard after automatic reconnect',
          () => received == 'AER reconnect TEST ONLY',
        );
        await clipboard.cancel();
        clipboard = null;
        conn.rdp!.drop();
        await viewer.close().timeout(const Duration(seconds: 10));
        viewer = null;
      } finally {
        await clipboard?.cancel();
        await viewer?.close();
        await conn.end();
        api.close();
        await lab.stdin.close();
        await lab.exitCode.timeout(
          const Duration(seconds: 12),
          onTimeout: () {
            lab.kill();
            return -1;
          },
        );
        await stderr;
      }
    },
    skip: labBin == null || shadow == null || env['AER_RDP_LIB'] == null
        ? 'set synthetic lab and native viewer paths'
        : false,
    timeout: const Timeout(Duration(minutes: 1)),
  );
  test(
    'synthetic host enforces denied input, clipboard and file channels',
    () async {
      final lab = await Process.start(labBin!, [
        '-shadow',
        shadow!,
        '-shadow-view-only',
        '-no-clipboard',
        '-no-files',
      ]);
      final errors = lab.stderr.drain<void>();
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
      final conn = RemoteConnection(
        api,
        poll: const Duration(milliseconds: 100),
      );
      RdpSession? s;
      try {
        await api.pair(info['pairingCode'] as String);
        await conn.start(info['hostId'] as String);
        final g = conn.grant!;
        expect(g.clipboard, isFalse);
        expect(g.files, isFalse);
        expect(conn.files, isNull);
        expect(conn.session!.allowed.input, isFalse);
        await expectLater(
          api.ticket(conn.session!.id, 'files'),
          throwsA(isA<RemoteEngineException>()),
        );
        s = RdpSession(RdpNative.load()!);
        // Deliberately request clipboard despite the grant, to test the host boundary.
        expect(
          s.connect(
            ViewerTarget(
              host: '127.0.0.1',
              port: conn.rdp!.port,
              username: g.username,
              password: g.password,
              certPem: g.certPem,
              certSha256: g.certSha256,
              clipboard: true,
            ),
          ),
          isTrue,
        );
        RdpFrame? frame;
        await until('view-only pixels', () {
          frame = s!.takeFrame() ?? frame;
          return frame != null && frame!.bgra[2] == 0x90;
        });
        final initial = frame!.bgra[0];
        s.mouse(0x0800, 170, 180);
        s.key(0x1e, true);
        s.key(0x1e, false);
        s.setClipboard('DENIED TEST ONLY');
        for (var i = 0; i < 20; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
          frame = s.takeFrame() ?? frame;
        }
        expect(
          frame!.bgra[0],
          initial,
          reason: 'synthetic input counter must not change',
        );
        expect(s.takeRemoteClipboard(), isNull);
      } finally {
        await s?.disposeAsync();
        await conn.end();
        api.close();
        await lab.stdin.close();
        await lab.exitCode.timeout(
          const Duration(seconds: 12),
          onTimeout: () {
            lab.kill();
            return -1;
          },
        );
        await errors;
      }
    },
    skip: labBin == null || shadow == null || env['AER_RDP_LIB'] == null
        ? 'set synthetic lab and viewer paths'
        : false,
    timeout: const Timeout(Duration(minutes: 1)),
  );
  test(
    'managed Windows synthetic host: auth, frames, input, clipboard, files, reconnect, revoke',
    () async {
      final lab = await Process.start(labBin!, ['-shadow', shadow!]);
      final stderr = lab.stderr.transform(utf8.decoder).join();
      addTearDown(() async {
        await lab.stdin.close();
        await lab.exitCode.timeout(
          const Duration(seconds: 12),
          onTimeout: () {
            lab.kill();
            return -1;
          },
        );
        final errors = await stderr;
        expect(errors, isNot(contains('aerc1.')));
        expect(errors, isNot(contains('aer1.')));
      });
      final info = jsonDecode(
        await lab.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .first,
      ) as Map<String, dynamic>;
      final server = GatewayServer.parse(
        info['gateway'] as String,
        info['fingerprint'] as String,
      );
      final api = GatewayClient(server);
      addTearDown(api.close);
      await api.pair(info['pairingCode'] as String);
      final conn = RemoteConnection(
        api,
        poll: const Duration(milliseconds: 100),
      );
      addTearDown(conn.end);
      await conn.start(info['hostId'] as String);
      final grant = conn.grant!;
      final native = RdpNative.load()!;
      ViewerTarget target({String? password, String? pin, bool? clipboard}) =>
          ViewerTarget(
            host: '127.0.0.1',
            port: conn.rdp!.port,
            username: grant.username,
            password: password ?? grant.password,
            certPem: grant.certPem,
            certSha256: pin ?? grant.certSha256,
            clipboard: clipboard ?? grant.clipboard,
          );
      for (final wrongPin in [true, false]) {
        final rejected = RdpSession(native);
        try {
          expect(
            rejected.connect(
              target(
                pin: wrongPin ? 'ab' * 32 : null,
                password: wrongPin ? null : 'wrong-test-password',
              ),
            ),
            isTrue,
          );
          await until(
            'reject pin/password',
            () =>
                rejected.state == RdpState.failed ||
                rejected.state == RdpState.disconnected,
          );
          final blank = rejected.takeFrame();
          if (blank != null) {
            expect(
              [for (var i = 2; i < 4002; i += 4) blank.bgra[i]]
                  .every((b) => b == 0x90),
              isFalse,
              reason: 'No synthetic desktop pattern before session authentication (local GDI/lobby is allowed)',
            );
          }
        } finally {
          rejected.dispose();
        }
        await Future<void>.delayed(const Duration(milliseconds: 400));
      }
      var s = RdpSession(native);
      addTearDown(() => s.dispose());
      expect(s.connect(target()), isTrue);
      expect(s.setClipboard('Привет AER — TEST ONLY'), isTrue);
      await until(
        'connected: ${s.error}',
        () => s.state != RdpState.connecting,
      );
      expect(s.state, RdpState.connected, reason: s.error);
      RdpFrame? frame;
      await until('synthetic pixels', () {
        frame = s.takeFrame() ?? frame;
        return frame != null && frame!.bgra[2] == 0x90;
      });
      expect(frame!.width, 640);
      expect(frame!.height, 480);
      final firstByte = frame!.bgra[0];
      s.mouse(0x0800, 120, 120);
      await until('mouse changed synthetic frame', () {
        frame = s.takeFrame() ?? frame;
        return frame!.bgra[0] != firstByte;
      });
      final afterMouse = frame!.bgra[0];
      s.key(0x1e, true);
      s.key(0x1e, false);
      s.unicode(0x41f, true);
      s.unicode(0x41f, false);
      await until('key changed synthetic frame', () {
        frame = s.takeFrame() ?? frame;
        return frame!.bgra[0] != afterMouse;
      });
      String? copied;
      await until('text clipboard roundtrip', () {
        copied = s.takeRemoteClipboard() ?? copied;
        return copied == 'Привет AER — TEST ONLY';
      });
      final dir = await Directory.systemTemp.createTemp('aer-shadow-files-');
      addTearDown(() => dir.delete(recursive: true));
      final files = RemoteFilesClient(
        baseUrl: 'https://127.0.0.1:${conn.files!.port}',
        token: grant.filesToken!,
        certSha256: grant.certSha256,
      );
      addTearDown(files.close);
      final source = File('${dir.path}/source.txt');
      await source.writeAsString('synthetic host transfer');
      await files.upload(source, 'transfer.txt');
      expect(
        await (await files.download('transfer.txt', dir)).readAsString(),
        'synthetic host transfer',
      );
      s.disconnect();
      s.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 700));
      s = RdpSession(native);
      expect(s.connect(target(clipboard: false)), isTrue);
      await until('reconnect', () => s.state != RdpState.connecting);
      expect(s.state, RdpState.connected, reason: s.error);
      expect(s.setClipboard('must not leave client'), isFalse);
      final owner = HttpClient();
      try {
        final req = await owner.postUrl(
          Uri.parse(
            '${info['coreUrl']}/api/v1/remote/clients/${info['clientId']}/revoke',
          ),
        );
        req.headers.set('Authorization', 'Bearer ${info['ownerToken']}');
        final res = await req.close();
        expect(res.statusCode, 200);
        await res.drain<void>();
      } finally {
        owner.close(force: true);
      }
      await until(
        'revocation drops real RDP',
        () => s.state == RdpState.disconnected || s.state == RdpState.failed,
      );
      await expectLater(files.list(), throwsA(anything));
    },
    skip: labBin == null || shadow == null || env['AER_RDP_LIB'] == null
        ? 'set loopback lab, synthetic shadow and native viewer paths'
        : false,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
