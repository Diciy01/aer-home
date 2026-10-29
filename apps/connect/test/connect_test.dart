import 'dart:convert';

import 'package:aer_connect/connect_app.dart';
import 'package:aer_connect/controller.dart';
import 'package:aer_remote/aer_remote.dart';
import 'package:aer_widgets/aer_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const pin =
    'ab:cd:ef:01:23:45:67:89:ab:cd:ef:01:23:45:67:89:ab:cd:ef:01:23:45:67:89:ab:cd:ef:01:23:45:67:89';

class MemoryStore implements ConnectStore {
  String? value;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String v) async {
    value = v;
  }

  @override
  Future<void> delete() async {
    value = null;
  }
}

class FakeClient extends GatewayClient {
  FakeClient(super.server);
  bool revoked = false;
  @override
  Future<PairResult> pair(String code, {String deviceName = ''}) async {
    if (code != 'TEST-ONLY-CODE') {
      throw const RemoteEngineException(
        401,
        'UNAUTHORIZED',
        'secret must not appear',
      );
    }
    credential = 'aerc1.test.${'0' * 64}';
    return PairResult('test', 'Рабочий ноутбук', credential!);
  }

  @override
  Future<List<RemoteHostSummary>> hosts() async {
    if (revoked) {
      throw const RemoteEngineException(
        401,
        'UNAUTHORIZED',
        'secret must not appear',
      );
    }
    return [
      RemoteHostSummary(
        entityId: 'h1',
        name: 'Домашний ПК',
        canConnect: true,
        reason: 'Готов',
        status: 'online',
        os: 'windows',
        effective: const RemoteCaps(
          desktop: true,
          input: true,
          clipboard: true,
          files: false,
        ),
      ),
    ];
  }
}

ConnectController make(MemoryStore store, List<FakeClient> clients) =>
    ConnectController(
      store: store,
      viewerFactory: (_) =>
          throw UnimplementedError('Widget tests do not capture a desktop'),
      client: (s) {
        final c = FakeClient(s);
        clients.add(c);
        return c;
      },
      probe: (_) async => pin,
    );

void main() {
  test('pair stores only client credential; reload, revoke, forget', () async {
    final store = MemoryStore(), clients = <FakeClient>[];
    final c = make(store, clients);
    await c.pair('home.example.net', pin, ' TEST-ONLY-CODE ');
    final saved = jsonDecode(store.value!) as Map;
    expect(saved['credential'], startsWith('aerc1.'));
    expect(store.value, isNot(contains('TEST-ONLY-CODE')));
    expect(c.hosts.single.entityId, 'h1');
    final again = make(store, clients);
    await again.load();
    expect(again.paired, isTrue);
    expect(again.fingerprint, pin);
    clients.last.revoked = true;
    await again.refresh();
    expect(again.unauthorized, isTrue);
    expect(again.hosts, isEmpty);
    expect(again.error, isNot(contains('secret')));
    await again.forget();
    expect(store.value, isNull);
    await c.shutdown();
    c.dispose();
    again.dispose();
  });

  test('invalid pairing stores nothing and never uses owner token', () async {
    final store = MemoryStore(), clients = <FakeClient>[];
    final c = make(store, clients);
    await expectLater(
      c.pair('home.example.net', pin, 'wrong'),
      throwsA(isA<RemoteEngineException>()),
    );
    expect(store.value, isNull);
    expect(c.paired, isFalse);
    c.dispose();
  });

  testWidgets('AER theme and pin confirmation gate at compact size', (t) async {
    await t.binding.setSurfaceSize(const Size(600, 700));
    addTearDown(() => t.binding.setSurfaceSize(null));
    final c = make(MemoryStore(), []);
    addTearDown(c.dispose);
    await t.pumpWidget(ConnectApp(controller: c));
    expect(
      Theme.of(t.element(find.byType(Scaffold))).scaffoldBackgroundColor,
      AerColors.background,
    );
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/pairing.png'),
    );
    await t.enterText(find.byKey(const Key('gw-address')), 'home.example.net');
    await t.tap(find.byKey(const Key('gw-probe')));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('gw-fingerprint')), findsOneWidget);
    expect(
      t.widget<FilledButton>(find.byKey(const Key('gw-pair'))).onPressed,
      isNull,
    );
    await t.tap(find.byKey(const Key('gw-confirm')));
    await t.pumpAndSettle();
    expect(
      t.widget<FilledButton>(find.byKey(const Key('gw-pair'))).onPressed,
      isNotNull,
    );
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/fingerprint.png'),
    );
    expect(t.takeException(), isNull);
  });

  testWidgets('allowed hosts, error, revoked states; no overflow', (t) async {
    await t.binding.setSurfaceSize(const Size(900, 700));
    addTearDown(() => t.binding.setSurfaceSize(null));
    final clients = <FakeClient>[];
    final c = make(MemoryStore(), clients);
    addTearDown(c.dispose);
    await c.pair('home.example.net', pin, 'TEST-ONLY-CODE');
    await t.pumpWidget(ConnectApp(controller: c));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('gw-host-h1')), findsOneWidget);
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/hosts.png'),
    );
    c.error = 'Сервер недоступен. Проверьте соединение.';
    c.changed();
    await t.pumpAndSettle();
    expect(find.byKey(const Key('connect-error')), findsOneWidget);
    clients.single.revoked = true;
    await c.refresh();
    await t.pumpAndSettle();
    expect(find.text('Доступ отозван владельцем'), findsOneWidget);
    expect(find.byKey(const Key('gw-host-h1')), findsNothing);
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/revoked.png'),
    );
    expect(t.takeException(), isNull);
  });
}
