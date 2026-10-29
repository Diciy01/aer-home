import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:aer_remote/aer_remote.dart';
import 'package:cryptography/cryptography.dart';
import 'package:test/test.dart';

// AER Connect Anywhere with the real RDP stack, SYNTHETIC source only:
// `aer-remotelab -anywhere -shadow aer-shadow.exe` runs a host DEVICE whose
// connecthost runtime drives the native Windows Host on loopback; this test
// is the viewer (FreeRDP FFI). No desktop is captured, no input reaches the
// user session, the system clipboard is not touched.
// TEST DATA: codes, numbers and passwords come from the stand.

Future<void> until(String what, bool Function() cond) async {
  for (var i = 0; i < 200; i++) {
    if (cond()) return;
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  fail('timeout: $what');
}

void main() {
  final env = Platform.environment;
  final labBin = env['AER_REMOTELAB_BIN'], shadow = env['AER_SHADOW_BIN'];
  test(
    'connect by ID to the synthetic Windows host: frames, unicode clipboard, reconnect, repeated sessions',
    () async {
      final lab = await Process.start(labBin!, [
        '-anywhere',
        '-shadow',
        shadow!,
      ]);
      final errs = lab.stderr.drain<void>();
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
      final key = await X25519().newKeyPair();
      final r = Random.secure();
      await api.enroll(
        code: info['enrollCode'] as String,
        deviceName: 'Viewer (стенд)',
        boxPub: base64Url
            .encode((await key.extractPublicKey()).bytes)
            .replaceAll('=', ''),
        instance: List.generate(
          32,
          (_) => r.nextInt(16).toRadixString(16),
        ).join(),
      );
      String password() =>
          File(info['devicePasswordFile'] as String).readAsStringSync();
      try {
        for (var round = 0; round < 3; round++) {
          final used = password();
          final conn = RemoteConnection(
            api,
            poll: const Duration(milliseconds: 100),
          );
          final ch = await api.challenge(info['deviceNumber'] as String);
          await conn.startWith(
            () async => api.connectDevice(await sealPassword(ch, used)),
          );
          final g = conn.grant!;
          final viewer = EmbeddedRdpViewer(
            RdpNative.load()!,
            canReconnect: () async =>
                !(await api.session(conn.session!.id)).state.terminal,
          );
          String? received;
          final sub = viewer.remoteClipboard.listen((s) => received = s);
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
          await until('first synthetic frame', () => viewer.lastFrame != null);
          final text = 'Привет, AER ✓ round $round TEST ONLY';
          expect(viewer.pushClipboard(text), isTrue);
          await until('unicode clipboard echo', () => received == text);
          if (round == 0) {
            conn.rdp!.drop();
            await until(
              'automatic reconnect',
              () => viewer.reconnects > 0 && viewer.statusName == 'connected',
            );
            expect(viewer.pushClipboard('после переподключения'), isTrue);
            await until(
              'clipboard after reconnect',
              () => received == 'после переподключения',
            );
          }
          await sub.cancel();
          await viewer.close().timeout(const Duration(seconds: 10));
          await conn.end();
          // One-time temporary password: a new one after every session.
          for (var i = 0; i < 100 && password() == used; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 100));
          }
          expect(password(), isNot(used));
        }
      } finally {
        api.close();
        await lab.stdin.close();
        await lab.exitCode.timeout(
          const Duration(seconds: 15),
          onTimeout: () {
            lab.kill();
            return -1;
          },
        );
        await errs;
      }
    },
    skip: labBin == null || shadow == null || env['AER_RDP_LIB'] == null
        ? 'set AER_REMOTELAB_BIN, AER_SHADOW_BIN (synthetic) and AER_RDP_LIB'
        : false,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
