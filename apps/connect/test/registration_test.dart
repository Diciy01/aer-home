import 'dart:convert';
import 'dart:io';

import 'package:aer_connect/connect_app.dart';
import 'package:aer_connect/controller.dart';
import 'package:aer_remote/aer_remote.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'connect_test.dart' show MemoryStore, pin;
import 'device_test.dart' show FakeHost, FakeTools, DeviceClient;

final fixture = jsonDecode(
  File('../../packages/aer_remote/test/fixtures/registration.json')
      .readAsStringSync(),
) as Map<String, dynamic>;

class AutoTools extends FakeTools {
  int created = 0;
  @override
  Future<({String privateKey, String publicKey})> keygen() async {
    created++;
    return super.keygen();
  }

  @override
  Future<String> instance(String installId) async => 'INSTANCE-TEST';
}

class FailingStore extends MemoryStore {
  @override
  Future<void> write(String v) async =>
      throw StateError('Secure storage unavailable');
}

class AutoClient extends DeviceClient {
  AutoClient(super.server, this.pendingStore);
  final MemoryStore pendingStore;
  String status = 'pending';
  Object? failure;
  int requests = 0;
  @override
  Future<RegistrationReply> registerInstallation({
    required String deviceName,
    required String boxPub,
    required String instance,
    String proof = '',
  }) async {
    requests++;
    // Storage precedes even the first network call.
    expect(pendingStore.value, isNotNull);
    if (failure != null) throw failure!;
    if (proof.isEmpty) {
      return RegistrationReply(
        'REQUEST-TEST',
        'verifying',
        fixture['challenge'] as Map<String, dynamic>,
      );
    }
    expect(proof, 'CHALLENGE-TEST-ONLY');
    return RegistrationReply(
      'REQUEST-TEST',
      status,
      status == 'approved'
          ? fixture['credentials'] as Map<String, dynamic>
          : null,
    );
  }
}

void main() {
  ConnectController make(
    MemoryStore pending,
    MemoryStore devices,
    AutoTools tools,
    List<AutoClient> clients,
    List<FakeHost> hosts,
  ) => ConnectController(
    store: MemoryStore(),
    deviceStore: devices,
    registrationStore: pending,
    preset: const ServerPreset('https://127.0.0.1:18443', pin),
    viewerFactory: (_) => throw UnimplementedError('NO DESKTOP IN TEST'),
    tools: tools,
    hostRuntime: () {
      final h = FakeHost();
      hosts.add(h);
      return h;
    },
    client: (s) {
      final api = AutoClient(s, pending);
      clients.add(api);
      return api;
    },
  );

  test('automatic registration persists identity, waits, then stores credentials and starts Host', () async {
    final pending = MemoryStore(), devices = MemoryStore(), tools = AutoTools();
    final clients = <AutoClient>[], hosts = <FakeHost>[];
    final c = make(pending, devices, tools, clients, hosts);
    await c.load();
    expect(c.registrationStatus, 'pending');
    expect(devices.value, isNull);
    expect(hosts, isEmpty);
    final saved = pending.value;
    await c.shutdown();
    c.dispose();
    // Restart from the pending DPAPI value; the owner has now approved it.
    final approved = ConnectController(
      store: MemoryStore(),
      deviceStore: devices,
      registrationStore: pending,
      preset: const ServerPreset('https://127.0.0.1:18443', pin),
      tools: tools,
      viewerFactory: (_) => throw UnimplementedError(),
      hostRuntime: () {
        final h = FakeHost();
        hosts.add(h);
        return h;
      },
      client: (s) => AutoClient(s, pending)..status = 'approved',
    );
    await approved.load();
    expect(tools.created, 1);
    expect(pending.value, saved);
    expect(approved.device?.number, '482913507');
    expect(devices.value, isNotNull);
    expect(hosts, hasLength(1));
    approved.dispose();
  });

  testWidgets(
    'configured first run has AER cards and no server, pin or enrollment fields',
    (tester) async {
      final c = make(MemoryStore(), MemoryStore(), AutoTools(), [], []);
      await c.load();
      await tester.pumpWidget(ConnectApp(controller: c));
      expect(find.byKey(const Key('automatic-registration')), findsOneWidget);
      expect(find.text('Ждём разрешения владельца сервера'), findsOneWidget);
      expect(find.byKey(const Key('gw-address')), findsNothing);
      expect(find.byKey(const Key('gw-enroll')), findsNothing);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('remote-connect')))
            .onPressed,
        isNull,
      );
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/registration_pending.png'),
      );
      await tester.pumpWidget(const SizedBox.shrink());
      c.dispose();
    },
  );

  for (final state in ['rejected', 'revoked', 'error']) {
    test(
      'registration $state never starts Host or stores credentials',
      () async {
        final pending = MemoryStore(), devices = MemoryStore();
        final hosts = <FakeHost>[];
        final c = ConnectController(
          store: MemoryStore(),
          deviceStore: devices,
          registrationStore: pending,
          preset: const ServerPreset('https://127.0.0.1:18443', pin),
          tools: AutoTools(),
          viewerFactory: (_) => throw UnimplementedError(),
          hostRuntime: () {
            final h = FakeHost();
            hosts.add(h);
            return h;
          },
          client: (s) => AutoClient(s, pending)
            ..status = state
            ..failure = (state == 'error'
                ? const PinMismatchException('', '')
                : null),
        );
        await c.load();
        expect(c.registrationStatus, state);
        expect(devices.value, isNull);
        expect(hosts, isEmpty);
        c.dispose();
      },
    );
  }

  test('server unavailable cannot authorize a device and preserves its pending key', () async {
    final pending = MemoryStore(), devices = MemoryStore();
    final clients = <AutoClient>[], hosts = <FakeHost>[];
    final c = ConnectController(
      store: MemoryStore(),
      deviceStore: devices,
      registrationStore: pending,
      preset: const ServerPreset('https://127.0.0.1:18443', pin),
      tools: AutoTools(),
      viewerFactory: (_) => throw UnimplementedError(),
      hostRuntime: () {
        final h = FakeHost();
        hosts.add(h);
        return h;
      },
      client: (s) {
        final a = AutoClient(s, pending)
          ..failure = const RemoteEngineException(
            503,
            'UNAVAILABLE',
            'Server unavailable',
          );
        clients.add(a);
        return a;
      },
    );
    await c.load();
    expect(c.registrationStatus, 'error');
    expect(pending.value, isNotNull);
    expect(devices.value, isNull);
    expect(hosts, isEmpty);
    c.dispose();
  });

  test(
    'secure storage failure stops before the first network request',
    () async {
      final clients = <AutoClient>[], hosts = <FakeHost>[];
      final c = make(
        FailingStore(),
        MemoryStore(),
        AutoTools(),
        clients,
        hosts,
      );
      await c.load();
      expect(c.registrationStatus, 'error');
      expect(clients, isEmpty);
      expect(hosts, isEmpty);
      c.dispose();
    },
  );

  test(
    'a copied identity or changed server preset is not silently re-enrolled',
    () async {
      final pending = MemoryStore(),
          devices = MemoryStore(),
          tools = AutoTools();
      final first = make(pending, devices, tools, [], []);
      await first.load();
      first.dispose();
      final identity = jsonDecode(pending.value!) as Map<String, dynamic>;
      identity['instance'] = 'ANOTHER-COMPUTER';
      pending.value = jsonEncode(identity);
      final clients = <AutoClient>[], hosts = <FakeHost>[];
      final copied = make(pending, devices, tools, clients, hosts);
      await copied.load();
      expect(copied.registrationStatus, 'error');
      expect(clients, isEmpty);
      expect(hosts, isEmpty);
      copied.dispose();
      identity['instance'] = 'INSTANCE-TEST';
      identity['fingerprint'] = '0' * 64;
      pending.value = jsonEncode(identity);
      final changed = make(pending, devices, tools, clients, hosts);
      await changed.load();
      expect(changed.registrationStatus, 'error');
      expect(clients, isEmpty);
      expect(tools.created, 1);
      changed.dispose();
    },
  );
}
