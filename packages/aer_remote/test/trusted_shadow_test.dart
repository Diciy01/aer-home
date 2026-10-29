// REAL TLS/Gateway/Host runtime/FreeRDP; SYNTHETIC frames only. No OS input,
// clipboard or desktop capture. Fixture credentials stay in test memory.
import 'dart:convert';
import 'dart:io';

import 'package:aer_remote/aer_remote.dart';
import 'package:cryptography/cryptography.dart';
import 'package:test/test.dart';

void main() {
  final env = Platform.environment;
  test(
    'trusted installation reaches native synthetic Host without a consent callback; revoke stops it',
    () async {
      final lab = await Process.start(env['AER_REMOTELAB_BIN']!, [
        '-anywhere',
        '-shadow',
        env['AER_SHADOW_BIN']!,
      ]);
      final errors = lab.stderr.drain<void>();
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
      final host = GatewayClient(
            server,
            credential: info['deviceClientCredential'] as String,
          ),
          work = GatewayClient(server);
      final key = await X25519().newKeyPair();
      final raw = base64Url
          .encode(await key.extractPrivateKeyBytes())
          .replaceAll('=', '');
      final enrollment = await work.enroll(
        code: info['enrollCode'] as String,
        deviceName: 'Trusted viewer TEST ONLY',
        boxPub: base64Url
            .encode((await key.extractPublicKey()).bytes)
            .replaceAll('=', ''),
        instance: '12' * 32,
      );
      final conn = RemoteConnection(
        work,
        poll: const Duration(milliseconds: 100),
      );
      EmbeddedRdpViewer? viewer;
      Future<void> until(String label, bool Function() condition) async {
        for (var i = 0; i < 200; i++) {
          if (condition()) return;
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        fail('timeout: $label');
      }

      try {
        expect((await host.trust()).enabled, isFalse);
        final peer = await host.trustCandidate(enrollment.number);
        expect(peer.fingerprint, await installationFingerprint(raw));
        await host.grantTrust(peer);
        await host.setUnattended(true);
        final challenge = await work.challenge(info['deviceNumber'] as String);
        final password = await File(info['devicePasswordFile'] as String)
            .readAsString();
        final sealed = await sealPassword(
          challenge,
          password,
          installationKey: raw,
        );
        expect(sealed.identityProof, isNotNull);
        await conn.startWith(() => work.connectDevice(sealed));
        expect(
          await File(info['devicePromptsFile'] as String).readAsString(),
          '0',
        );
        final g = conn.grant!;
        viewer = EmbeddedRdpViewer(
          RdpNative.load()!,
          canReconnect: () async =>
              !(await work.session(conn.session!.id)).state.terminal,
        );
        await viewer.open(
          ViewerTarget(
            host: '127.0.0.1',
            port: conn.rdp!.port,
            username: g.username,
            password: g.password,
            certPem: g.certPem,
            certSha256: g.certSha256,
            clipboard: false,
          ),
        );
        await until('synthetic RDP frame', () => viewer!.lastFrame != null);
        await host.revokeTrust(enrollment.number);
        for (
          var i = 0;
          i < 100 && !(await work.session(conn.session!.id)).state.terminal;
          i++
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        expect(
          (await work.session(conn.session!.id)).state,
          RemoteState.revoked,
        );
        expect(
          await File(info['devicePromptsFile'] as String).readAsString(),
          '0',
        );
        await expectLater(
          work.challenge(info['deviceNumber'] as String),
          throwsA(isA<RemoteEngineException>()),
        );
      } finally {
        await viewer?.close();
        await conn.end();
        host.close();
        work.close();
        await lab.stdin.close();
        await lab.exitCode.timeout(
          const Duration(seconds: 15),
          onTimeout: () {
            lab.kill();
            return -1;
          },
        );
        await errors;
      }
    },
    skip:
        env['AER_REMOTELAB_BIN'] == null ||
        env['AER_SHADOW_BIN'] == null ||
        env['AER_RDP_LIB'] == null,
  );
}
