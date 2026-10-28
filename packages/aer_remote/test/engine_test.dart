import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aer_remote/aer_remote.dart';
import 'package:test/test.dart';

// TEST DATA: addresses, tickets and grants below are fixtures.

void main() {
  test('fingerprints match the Go format and normalise', () {
    final fp = certFingerprint(utf8.encode('der'));
    expect(fp, hasLength(95));
    expect(':'.allMatches(fp), hasLength(31));
    expect(normalizeFingerprint(fp.toUpperCase()), fp.replaceAll(':', ''));
  });

  test('server address: https only, port 443 by default, nothing built in', () {
    final s = GatewayServer.parse(' home.example.net ', 'ab');
    expect(s.base.host, 'home.example.net');
    expect(s.base.port, 443);
    expect(GatewayServer.parse('203.0.113.5:8443', 'ab').base.port, 8443);
    expect(
      () => GatewayServer.parse('http://home.example.net', 'ab'),
      throwsFormatException,
    );
    expect(() => GatewayServer.parse('https://', 'ab'), throwsFormatException);
  });

  test('a direct-route grant is not a relay grant', () {
    final direct = {
      'sessionId': 's',
      'route': 'direct',
      'tunnel': null,
      'expiresAt': '2026-10-28T10:00:00Z',
    };
    expect(() => RelayGrant.fromJson(direct), throwsFormatException);
    final relay = RelayGrant.fromJson({
      'sessionId': 's',
      'route': 'relay',
      'password': 'p',
      'certSha256': 'aa',
      'clipboard': false,
      'files': null,
      'expiresAt': '2026-10-28T10:00:00Z',
      'tunnel': {
        'path': '/gw/v1/tunnel',
        'tickets': {'rdp': 't1'},
        'ttlSec': 60,
      },
    });
    expect(relay.files, isFalse);
    expect(relay.tickets['rdp'], 't1');
  });

  test('states', () {
    expect(
      RemoteState.parse('awaiting_approval'),
      RemoteState.awaitingApproval,
    );
    expect(RemoteState.parse('nonsense'), RemoteState.failed);
    expect(RemoteState.revoked.terminal, isTrue);
    expect(RemoteState.reconnecting.terminal, isFalse);
  });

  test(
    'local forwarder: one fresh leg per connection, byte counts, errors',
    () async {
      final echo = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      echo.listen((s) => s.listen(s.add, onDone: s.destroy));
      var legs = 0;
      final f = await LocalForwarder.start(() async {
        legs++;
        if (legs == 3) {
          throw const RemoteEngineException(403, 'FORBIDDEN', 'bad ticket');
        }
        return Socket.connect(InternetAddress.loopbackIPv4, echo.port);
      });
      expect(f.address.isLoopback, isTrue);
      for (var i = 0; i < 2; i++) {
        final c = await Socket.connect(InternetAddress.loopbackIPv4, f.port);
        c.add(utf8.encode('кадр'));
        expect(utf8.decode(await c.first), 'кадр');
        c.destroy();
      }
      expect(legs, 2);
      final err = f.errors.first;
      final c = await Socket.connect(InternetAddress.loopbackIPv4, f.port);
      expect(await err, isA<RemoteEngineException>());
      await c.drain<void>().catchError((_) {});
      expect(f.bytesUp, greaterThan(0));
      await f.close();
      await echo.close();
    },
  );

  // End-to-end against the isolated Go stand (core/cmd/aer-remotelab):
  // real Core, Gateway and host agent on loopback with a FAKE RDP service.
  final labBin = Platform.environment['AER_REMOTELAB_BIN'];
  group(
    'lab',
    () {
      late Process lab;
      late Map<String, dynamic> info;
      late GatewayServer server;

      setUpAll(() async {
        lab = await Process.start(labBin!, []);
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
          const Duration(seconds: 10),
          onTimeout: () {
            lab.kill();
            return -1;
          },
        );
      });

      Future<int> owner(String method, String path) async {
        final c = HttpClient();
        final req = await c.openUrl(
          method,
          Uri.parse('${info['coreUrl']}/api/v1$path'),
        );
        req.headers.set('Authorization', 'Bearer ${info['ownerToken']}');
        final res = await req.close();
        await res.drain<void>();
        c.close();
        return res.statusCode;
      }

      test('pin, pairing, session, files, reconnect, revoke', () async {
        expect(await probeFingerprint(server.base), info['fingerprint']);

        final wrong = GatewayClient(GatewayServer(server.base, 'ab' * 32));
        await expectLater(
          wrong.pair(info['pairingCode'] as String),
          throwsA(isA<PinMismatchException>()),
        );
        wrong.close();

        final api = GatewayClient(server);
        await expectLater(
          api.pair('AAAA-BBBB-CCCC'),
          throwsA(
            isA<RemoteEngineException>().having((e) => e.status, 'status', 401),
          ),
        );
        final paired = await api.pair(
          info['pairingCode'] as String,
          deviceName: 'Dart test',
        );
        expect(paired.credential, startsWith('aerc1.'));
        final hosts = await api.hosts();
        expect(hosts.single.canConnect, isTrue);

        final conn = RemoteConnection(
          api,
          poll: const Duration(milliseconds: 200),
        );
        final seen = <RemoteState>[];
        conn.updates.listen((u) => seen.add(u.state));
        await conn.start(info['hostId'] as String);
        expect(conn.grant!.files, isTrue);
        expect(conn.rdp!.address.isLoopback, isTrue);

        // The viewer side: an RDP client would connect here.
        var s = await Socket.connect(
          InternetAddress.loopbackIPv4,
          conn.rdp!.port,
        );
        final lines = s
            .cast<List<int>>()
            .transform(utf8.decoder)
            .transform(const LineSplitter());
        final it = StreamIterator(lines);
        expect(await it.moveNext(), isTrue);
        expect(it.current, 'HOST Домашний ПК (стенд)');
        s.writeln('кадр');
        expect(await it.moveNext(), isTrue);
        expect(it.current, 'кадр');
        await _until(
          () async =>
              (await api.session(conn.session!.id)).state ==
              RemoteState.connected,
        );

        // Files: end-to-end TLS pinned to the host certificate, through the relay.
        final fc = pinnedHttpClient(conn.grant!.certSha256);
        final body = utf8.encode('отчёт');
        final put = await fc.putUrl(
          Uri.https('127.0.0.1:${conn.files!.port}', '/v1/files/report.txt'),
        );
        put.headers
          ..set('Authorization', 'Bearer ${conn.grant!.filesToken}')
          ..set('X-AER-SHA256', _sha(body));
        put.add(body);
        final putRes = await put.close();
        final putBody = await putRes.transform(utf8.decoder).join();
        expect(putRes.statusCode, lessThan(300), reason: putBody);
        expect(
          File('${info['exchangeDir']}/report.txt').readAsStringSync(),
          'отчёт',
        );
        fc.close(force: true);

        // Connection loss → reconnect with a fresh ticket from the engine.
        await it.cancel();
        s.destroy();
        await _until(
          () async =>
              (await api.session(conn.session!.id)).state ==
              RemoteState.reconnecting,
        );
        s = await Socket.connect(InternetAddress.loopbackIPv4, conn.rdp!.port);
        expect(utf8.decode(await s.first).trim(), 'HOST Домашний ПК (стенд)');
        s.destroy();

        // The owner revokes this client: the engine notices and closes up.
        expect(
          await owner('POST', '/remote/clients/${info['clientId']}/revoke'),
          200,
        );
        await _until(() async => seen.contains(RemoteState.revoked));
        await expectLater(
          api.hosts(),
          throwsA(
            isA<RemoteEngineException>().having(
              (e) => e.unauthorized,
              'unauthorized',
              isTrue,
            ),
          ),
        );
        await expectLater(
          Socket.connect(
            InternetAddress.loopbackIPv4,
            conn.rdp!.port,
          ).then((s) => s.first),
          throwsA(anything),
        );
        api.close();
      }, timeout: const Timeout(Duration(minutes: 2)));
    },
    skip: labBin == null
        ? 'set AER_REMOTELAB_BIN to core/bin/aer-remotelab'
        : false,
  );
}

String _sha(List<int> b) {
  // crypto is a dependency of the engine anyway.
  return certFingerprint(b).replaceAll(':', '');
}

Future<void> _until(Future<bool> Function() cond) async {
  for (var i = 0; i < 200; i++) {
    if (await cond()) return;
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  fail('timeout');
}
