import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:aer_remote/aer_remote.dart';
import 'package:cryptography/cryptography.dart';
import 'package:test/test.dart';

// AER Connect Anywhere against the isolated Go stand (`aer-remotelab
// -anywhere`): real Core, Gateway with pinned TLS and a host device running
// the real connecthost runtime; its desktop is the stand's FAKE RDP echo.
// TEST DATA: codes, numbers and passwords come from the stand.

void main() {
  final labBin = Platform.environment['AER_REMOTELAB_BIN'];
  group(
    'anywhere lab',
    () {
      late Process lab;
      late Map<String, dynamic> info;
      late GatewayServer server;

      setUpAll(() async {
        lab = await Process.start(labBin!, ['-anywhere']);
        info = jsonDecode(
          await lab.stdout
              .transform(utf8.decoder)
              .transform(const LineSplitter())
              .first,
        ) as Map<String, dynamic>;
        server = GatewayServer.parse(
          info['gateway'] as String,
          info['fingerprint'] as String,
        );
      });
      tearDownAll(() async {
        await lab.stdin.close();
        await lab.exitCode.timeout(
          const Duration(seconds: 15),
          onTimeout: () {
            lab.kill();
            return -1;
          },
        );
      });

      Future<GatewayClient> enrollViewer(String name) async {
        final api = GatewayClient(server);
        final key = await X25519().newKeyPair();
        final pub = base64Url
            .encode((await key.extractPublicKey()).bytes)
            .replaceAll('=', '');
        final r = Random.secure();
        final instance =
            List.generate(32, (_) => r.nextInt(16).toRadixString(16)).join();
        final e = await api.enroll(
          code: info['enrollCode'] as String,
          deviceName: name,
          boxPub: pub,
          instance: instance,
        );
        expect(validDeviceNumber(e.number), isTrue);
        expect(e.clientCredential, startsWith('aerc1.'));
        expect(e.agentToken, startsWith('aer1.'));
        expect((await api.me()).number, e.number);
        return api;
      }

      String password() =>
          File(info['devicePasswordFile'] as String).readAsStringSync();

      test('enroll, wrong password, connect by ID, relay bytes, end', () async {
        final api = await enrollViewer('Ноутбук (стенд)');
        final number = info['deviceNumber'] as String;

        final bad = await api.challenge(formatDeviceNumber(number));
        await expectLater(
          api.connectDevice(await sealPassword(bad, 'неверный')),
          throwsA(
            isA<RemoteEngineException>()
                .having((e) => e.reason, 'reason', 'bad_password')
                .having((e) => e.status, 'status', 403),
          ),
        );
        await expectLater(
          api.challenge('123456780'),
          throwsA(
            isA<RemoteEngineException>().having(
              (e) => e.reason,
              'reason',
              'unknown_device',
            ),
          ),
        );

        final ch = await api.challenge(number);
        expect(ch.name, contains('стенд'));
        final conn = RemoteConnection(
          api,
          poll: const Duration(milliseconds: 200),
        );
        final used = password();
        await conn.startWith(
          () async => api.connectDevice(await sealPassword(ch, used)),
        );
        expect(conn.grant!.tickets.keys, contains('rdp'));
        final s = await Socket.connect(
          InternetAddress.loopbackIPv4,
          conn.rdp!.port,
        );
        final lines = s
            .cast<List<int>>()
            .transform(utf8.decoder)
            .transform(const LineSplitter());
        final it = StreamIterator(lines);
        expect(await it.moveNext(), isTrue);
        expect(it.current, startsWith('HOST '));
        s.write('кириллица ✓\n');
        expect(await it.moveNext(), isTrue);
        expect(it.current, 'кириллица ✓');
        await s.close();
        await it.cancel();
        await conn.end();
        // One-time access: the temporary password changes after the session.
        for (var i = 0; i < 100 && password() == used; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        expect(password(), isNot(used));
        final again = await api.challenge(number);
        await expectLater(
          api.connectDevice(await sealPassword(again, used)),
          throwsA(
            isA<RemoteEngineException>().having(
              (e) => e.reason,
              'reason',
              'bad_password',
            ),
          ),
        );
        api.close();
      });
    },
    skip: labBin == null
        ? 'set AER_REMOTELAB_BIN to core/bin/aer-remotelab -anywhere'
        : false,
  );
}
