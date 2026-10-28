// TEST DOUBLES ONLY: a fake Gateway client and in-memory/temporary stores.
// The real path (Core + Gateway + agent + FreeRDP) is checked live in
// integration_test/remote_gateway_live_test.dart.
import 'dart:io';

import 'package:aer_home_desktop/src/core_api/remote_api.dart';
import 'package:aer_home_desktop/src/features/remote/gateway_views.dart';
import 'package:aer_home_desktop/src/remote/gateway_profile.dart';
import 'package:aer_home_desktop/src/state/connection_controller.dart';
import 'package:aer_home_desktop/src/state/gateway_remote_controller.dart';
import 'package:aer_home_desktop/src/state/remote_controller.dart';
import 'package:aer_remote/aer_remote.dart' as engine;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';

import '../fixtures.dart';
import 'remote_test.dart' hide main;

const fp =
    'ab:cd:ef:01:23:45:67:89:ab:cd:ef:01:23:45:67:89:ab:cd:ef:01:23:45:67:89:ab:cd:ef:01:23:45:67:89';

class MemoryProfiles extends GatewayProfileStore {
  MemoryProfiles() : super(File('/nonexistent/aer-test-profile.json'));
  GatewayProfile? p;
  @override
  Future<GatewayProfile?> read() async => p;
  @override
  Future<void> write(GatewayProfile v) async => p = v;
  @override
  Future<void> delete() async => p = null;
}

class MemoryStore implements CredentialStore {
  String? value;
  @override
  String get description => 'память теста';
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String credential) async => value = credential;
  @override
  Future<void> delete() async => value = null;
}

/// Answers like the Gateway would; nothing goes to the network.
class FakeGatewayClient extends engine.GatewayClient {
  FakeGatewayClient(super.server);
  Object? pairError;
  Object? hostsError;
  final paired = <String>[];

  @override
  Future<engine.PairResult> pair(String code, {String deviceName = ''}) async {
    if (pairError != null) throw pairError!;
    paired.add(code);
    credential = 'aerc1.client-1.${'0' * 64}';
    return engine.PairResult('client-1', 'Ноутбук (тест)', credential!);
  }

  @override
  Future<List<engine.RemoteHostSummary>> hosts() async {
    if (hostsError != null) throw hostsError!;
    return [
      engine.RemoteHostSummary.fromJson({
        'entityId': 'h1',
        'name': 'Домашний ПК (тест)',
        'canConnect': true,
        'reason': 'Готов',
        'status': 'online',
        'effective': {
          'desktop': true,
          'input': true,
          'clipboard': true,
          'files': false,
        },
      }),
    ];
  }
}

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('aer-gw-test-'));
  tearDown(() => dir.deleteSync(recursive: true));

  GatewayRemoteController make(
    MemoryStore secrets,
    List<FakeGatewayClient> made, {
    String probed = fp,
  }) => GatewayRemoteController(
    profiles: GatewayProfileStore(File('${dir.path}/remote-gateway.json')),
    credentials: secrets,
    launcher: FakeLauncher(),
    client: (s) {
      final c = FakeGatewayClient(s);
      made.add(c);
      return c;
    },
    probe: (_) async => probed,
  );

  test(
    'pair: credential to the secret store only, profile without secrets',
    () async {
      final secrets = MemoryStore(), made = <FakeGatewayClient>[];
      final g = make(secrets, made);
      addTearDown(g.dispose);
      expect(await g.probe('home.example.net'), fp);
      await g.pair('home.example.net', fp, ' ABCD-EFGH-JKLM ');
      expect(made.single.paired, ['ABCD-EFGH-JKLM']);
      expect(
        made.single.server.fingerprint,
        fp,
        reason: 'the confirmed pin is used',
      );
      expect(secrets.value, startsWith('aerc1.'));
      final profile = File('${dir.path}/remote-gateway.json')
          .readAsStringSync();
      expect(profile, isNot(contains('aerc1')));
      expect(profile, isNot(contains('ABCD')));
      expect(g.phase, GatewayPhase.ready);
      expect(g.hosts.single.name, 'Домашний ПК (тест)');

      // A new controller restores from the stores (no network for load()).
      final again = make(secrets, made);
      addTearDown(again.dispose);
      await again.load();
      expect(again.phase, GatewayPhase.ready);
      expect(made.last.credential, secrets.value);
      expect(again.profile!.clientName, 'Ноутбук (тест)');
    },
  );

  test('pairing refused: nothing stored, clear message', () async {
    final secrets = MemoryStore();
    final g = GatewayRemoteController(
      profiles: GatewayProfileStore(File('${dir.path}/p.json')),
      credentials: secrets,
      launcher: FakeLauncher(),
      client: (s) => FakeGatewayClient(s)
        ..pairError = const engine.RemoteEngineException(
          401,
          'UNAUTHORIZED',
          'x',
        ),
      probe: (_) async => fp,
    );
    addTearDown(g.dispose);
    await expectLater(
      g.pair('h', fp, 'bad'),
      throwsA(isA<engine.RemoteEngineException>()),
    );
    expect(secrets.value, isNull);
    expect(File('${dir.path}/p.json').existsSync(), isFalse);
    expect(g.error, contains('сопряжение'));
    expect(g.phase, GatewayPhase.notPaired);
  });

  test(
    'revoked credential: the controller asks for a new pairing; forget clears',
    () async {
      final secrets = MemoryStore(), made = <FakeGatewayClient>[];
      final g = make(secrets, made);
      addTearDown(g.dispose);
      await g.pair('h', fp, 'c');
      made.last.hostsError = const engine.RemoteEngineException(
        401,
        'UNAUTHORIZED',
        'x',
      );
      await g.refreshHosts();
      expect(g.phase, GatewayPhase.unauthorized);
      expect(g.hosts, isEmpty);
      await g.forget();
      expect(secrets.value, isNull);
      expect(File('${dir.path}/remote-gateway.json').existsSync(), isFalse);
      expect(g.phase, GatewayPhase.notPaired);
    },
  );

  test('error messages are clear and never echo secrets', () {
    final d = GatewayRemoteController.describe;
    expect(
      d(const engine.PinMismatchException('a', 'b')),
      contains('не совпадает'),
    );
    expect(
      d(const engine.RemoteEngineException(429, 'UNAVAILABLE', '')),
      contains('Слишком много'),
    );
    expect(d(const SocketException('x')), contains('недоступен'));
    expect(
      d(const engine.RemoteEngineException(409, 'CONFLICT', 'Уже идёт сеанс')),
      'Уже идёт сеанс',
    );
    expect(d(Exception('aerc1.secret')), isNot(contains('aerc1')));
  });

  group('UI', () {
    late ConnectionController conn;
    setUp(() async {
      conn = ConnectionController(
        clientFor(MockClient((r) async => healthyHandler(r))),
      );
      await conn.refresh();
    });
    tearDown(() => conn.dispose());

    testWidgets(
      'clients: create with hosts and rights → one-time code; revoke',
      (tester) async {
        final api = FakeRemoteApi()
          ..gw = RemoteGatewayInfo(
            fp,
            '0.1.0',
            DateTime.utc(2026, 10, 28),
            true,
          );
        final r = RemoteController(
          api,
          conn,
          launcher: FakeLauncher(),
          autoPoll: false,
        );
        addTearDown(r.dispose);
        await tester.runAsync(r.start);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ListenableBuilder(
                listenable: r,
                builder: (_, _) => RemoteClientsTab(r: r),
              ),
            ),
          ),
        );
        expect(
          find.byKey(const Key('remote-gateway-fingerprint')),
          findsOneWidget,
        );
        await tester.tap(find.byKey(const Key('remote-client-new')));
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<FilledButton>(find.byKey(const Key('remote-client-save')))
              .onPressed,
          isNull,
          reason: 'name and at least one computer are required',
        );
        await tester.enterText(
          find.byKey(const Key('remote-client-name')),
          'Рабочий ноутбук (тест)',
        );
        await tester.tap(find.byKey(const Key('remote-client-host-h1')));
        await tester.tap(find.byKey(const Key('remote-client-files')));
        await tester.pump();
        await tester.tap(find.byKey(const Key('remote-client-save')));
        await tester.pumpAndSettle();
        expect(find.text('TEST-CODE-0'), findsOneWidget);
        final c = api.clientList.single;
        expect(c.hosts, ['h1']);
        expect((c.clipboard, c.files), (true, true));
        await tester.tap(find.byKey(const Key('remote-pairing-done')));
        await tester.pumpAndSettle();
        expect(
          find.text('TEST-CODE-0'),
          findsNothing,
          reason: 'the code is shown once',
        );
        expect(find.text('Ждёт сопряжения'), findsOneWidget);

        await tester.tap(find.byKey(Key('remote-client-revoke-${c.id}')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('remote-client-revoke-confirm')));
        await tester.pumpAndSettle();
        expect(api.clientList.single.revoked, isTrue);
        expect(find.textContaining('Отозван'), findsOneWidget);
        expect(find.byKey(Key('remote-client-revoke-${c.id}')), findsNothing);
      },
    );

    testWidgets(
      'gateway: fingerprint shown, mismatch warned, pairing only after confirmation',
      (tester) async {
        final api = FakeRemoteApi()
          ..gw = RemoteGatewayInfo(
            fp.replaceFirst('ab', '00'),
            '0.1.0',
            DateTime.utc(2026, 10, 28),
            true,
          );
        final r = RemoteController(
          api,
          conn,
          launcher: FakeLauncher(),
          autoPoll: false,
        );
        addTearDown(r.dispose);
        await tester.runAsync(r.start);
        final g = GatewayRemoteController(
          profiles: MemoryProfiles(),
          credentials: MemoryStore(),
          launcher: FakeLauncher(),
          client: FakeGatewayClient.new,
          probe: (_) async => fp,
        );
        addTearDown(g.dispose);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: GatewayTab(r: r, g: g),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const Key('gw-address')),
          'home.example.net',
        );
        await tester.tap(find.byKey(const Key('gw-probe')));
        await tester.pumpAndSettle();
        expect(find.text(fp), findsOneWidget);
        expect(find.textContaining('НЕ совпадает'), findsOneWidget);
        expect(
          tester
              .widget<FilledButton>(find.byKey(const Key('gw-pair')))
              .onPressed,
          isNull,
        );
        await tester.tap(find.byKey(const Key('gw-confirm')));
        await tester.pump();
        await tester.enterText(
          find.byKey(const Key('gw-code')),
          'ABCD-EFGH-JKLM',
        );
        await tester.tap(find.byKey(const Key('gw-pair')));
        await tester.pumpAndSettle();
        expect(g.phase, GatewayPhase.ready);
        expect(find.byKey(const Key('gw-profile')), findsOneWidget);
        expect(find.byKey(const Key('gw-connect-h1')), findsOneWidget);
      },
    );
  });
}
