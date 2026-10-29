import 'dart:async';
import 'dart:convert';

import 'package:aer_connect/connect_app.dart';
import 'package:aer_connect/controller.dart';
import 'package:aer_connect/device.dart';
import 'package:aer_remote/aer_remote.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'connect_test.dart' show MemoryStore, pin;

// TEST DATA: numbers, credentials and passwords are fixtures. No desktop
// is captured and no process is started by these tests.

const number = '482913507';

class FakeTools extends HostTools {
  static final privateFixture = base64Url
      .encode(List<int>.generate(32, (i) => i + 1))
      .replaceAll('=', '');
  FakeTools()
    : super(
        hostExe: 'X:/none.exe',
        shadowExe: 'X:/none.exe',
        stateDir: 'X:/state',
      );
  @override
  Future<({String privateKey, String publicKey})> keygen() async =>
      (privateKey: privateFixture, publicKey: 'PUBLIC-FIXTURE');
  @override
  Future<String> instance(String installId) async => 'ab' * 32;
  @override
  Future<bool> autostart() async => false;
}

class FakeHost implements HostRuntime {
  final _u = StreamController<HostView>.broadcast();
  final _r = StreamController<HostReply>.broadcast();
  final sent = <Map<String, Object?>>[];
  Map<String, Object?>? init;
  @override
  Stream<HostView> get updates => _u.stream;
  @override
  Stream<HostReply> get replies => _r.stream;
  void emit(HostView v) => _u.add(v);
  void reply(String type, Map<String, dynamic> d) => _r.add(HostReply(type, d));
  @override
  Future<void> start(Map<String, Object?> init) async => this.init = init;
  @override
  void send(Map<String, Object?> command) {
    sent.add(command);
    if (command['cmd'] == 'setPermanent') {
      final p = command['password'] as String;
      reply(
        'permanent',
        p.length < 10
            ? {'problem': 'Не меньше 10 символов'}
            : {
                'verifier': {'salt': 's', 'hash': 'h', 'iter': 600000},
              },
      );
    }
  }

  @override
  Future<void> stop() async {}
}

class DeviceClient extends GatewayClient {
  DeviceClient(super.server);
  @override
  Future<DeviceTrust> trust() async => const DeviceTrust();
  String? lastNumber;
  @override
  Future<DeviceEnrollment> enroll({
    required String code,
    required String deviceName,
    required String boxPub,
    required String instance,
  }) async {
    if (code.trim() != 'ENROLL-TEST-CODE') {
      throw const RemoteEngineException(
        401,
        'UNAUTHORIZED',
        'x',
        reason: 'bad_code',
      );
    }
    expect(boxPub, 'PUBLIC-FIXTURE');
    credential = 'aerc1.dev.${'1' * 64}';
    return DeviceEnrollment(
      deviceId: 'd1',
      number: number,
      name: deviceName,
      agentToken: 'aer1.agent.${'2' * 64}',
      clientCredential: credential!,
    );
  }

  @override
  Future<List<RemoteHostSummary>> hosts() async => [];

  @override
  Future<ConnectChallenge> challenge(String n) async {
    lastNumber = n;
    if (n == '111111111') {
      throw const RemoteEngineException(
        404,
        'NOT_FOUND',
        'x',
        reason: 'unknown_device',
      );
    }
    // A real X25519 public key (base point) so sealing works offline.
    return ConnectChallenge(
      attemptId: 'attempt-1',
      number: n,
      name: 'Рабочий ПК',
      boxPub: 'CQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
      viewerNumber: number,
    );
  }

  @override
  Future<RemoteSessionInfo> connectDevice(
    SealedPassword sealed, {
    bool? clipboard,
    bool? files,
  }) async {
    expect(sealed.ciphertext, isNot(contains('wrong')));
    throw const RemoteEngineException(
      403,
      'FORBIDDEN',
      'x',
      reason: 'bad_password',
    );
  }
}

typedef Made = ({
  ConnectController c,
  MemoryStore devices,
  List<FakeHost> hosts,
});

Made make({MemoryStore? devices}) {
  final store = devices ?? MemoryStore(), hosts = <FakeHost>[];
  final c = ConnectController(
    store: MemoryStore(),
    deviceStore: store,
    viewerFactory: (_) => throw UnimplementedError('no desktop in tests'),
    client: DeviceClient.new,
    probe: (_) async => pin,
    tools: FakeTools(),
    hostRuntime: () {
      final h = FakeHost();
      hosts.add(h);
      return h;
    },
  );
  return (c: c, devices: store, hosts: hosts);
}

const online = HostView(
  link: HostLink.online,
  tempPassword: 'k7m2x9qp',
  allowIncoming: true,
);

/// Sealing runs real (pure Dart) crypto: let it finish outside fake time.
Future<void> settle(WidgetTester t) async {
  await t.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 300)),
  );
  await t.pumpAndSettle();
}

void main() {
  test(
    'enroll keeps secrets in the device store only; reload, permanent, forget',
    () async {
      final m = make();
      await expectLater(
        m.c.enroll('home.example.net', pin, 'nope', 'Домашний ПК'),
        throwsA(isA<RemoteEngineException>()),
      );
      expect(m.devices.value, isNull);
      await m.c.enroll(
        'home.example.net',
        pin,
        ' ENROLL-TEST-CODE ',
        'Домашний ПК',
      );
      final saved = jsonDecode(m.devices.value!) as Map<String, dynamic>;
      expect(saved['number'], number);
      expect(saved['boxKey'], FakeTools.privateFixture);
      expect(saved['permanent'], isNull);
      expect(m.devices.value, isNot(contains('ENROLL-TEST-CODE')));
      expect(m.hosts.single.init!['number'], number);
      expect(m.hosts.single.init!['shadowSource'], 'desktop');

      m.hosts.single.emit(online);
      await Future<void>.delayed(Duration.zero);
      expect(m.c.host.tempPassword, 'k7m2x9qp');
      expect(
        m.devices.value,
        isNot(contains('k7m2x9qp')),
        reason: 'temporary password is never stored',
      );

      expect(await m.c.setPermanent('short'), contains('10'));
      expect(await m.c.setPermanent('Дом-2026-надёжный'), isNull);
      expect(m.devices.value, isNot(contains('Дом-2026-надёжный')));
      expect((jsonDecode(m.devices.value!) as Map)['permanent'], isNotNull);

      final again = make(devices: m.devices);
      await again.c.load();
      expect(again.c.device!.number, number);
      expect((again.hosts.single.init!['permanent'] as Map)['iter'], 600000);
      await again.c.setIncoming(false);
      expect(again.hosts.single.sent.last, {
        'cmd': 'allowIncoming',
        'value': false,
      });
      again.c.stopIncoming();
      expect(again.hosts.single.sent.last, {'cmd': 'stopSession'});

      again.hosts.single.emit(const HostView(link: HostLink.revoked));
      await Future<void>.delayed(Duration.zero);
      expect(again.c.deviceRevoked, isTrue);
      await again.c.forgetDevice();
      expect(m.devices.value, isNull);
      m.c.dispose();
      again.c.dispose();
    },
  );

  test('connect by ID: validation, unknown device, wrong password', () async {
    final m = make();
    await m.c.enroll('home.example.net', pin, 'ENROLL-TEST-CODE', 'ПК');
    await m.c.connectById('12345', 'x');
    expect(m.c.error, contains('9 цифр'));
    await m.c.connectById('111 111 111', 'x');
    expect(m.c.error, contains('не найден'));
    await m.c.connectById('222 333 444', 'wrongpass');
    expect(m.c.error, 'Неверный пароль.');
    expect(m.c.live, isFalse);
    expect(m.c.busy, isFalse);
    m.c.dispose();
  });

  Future<Made> pumpDevice(WidgetTester t, Size size) async {
    await t.binding.setSurfaceSize(size);
    addTearDown(() => t.binding.setSurfaceSize(null));
    final m = make();
    addTearDown(m.c.dispose);
    await m.c.enroll(
      'home.example.net',
      pin,
      'ENROLL-TEST-CODE',
      'Домашний ПК',
    );
    await t.pumpWidget(ConnectApp(controller: m.c));
    m.hosts.single.emit(online);
    await t.pumpAndSettle();
    return m;
  }

  testWidgets('this computer online and connect form', (t) async {
    final m = await pumpDevice(t, const Size(1000, 900));
    expect(find.text('482 913 507'), findsOneWidget);
    expect(find.text('k7m2x9qp'), findsOneWidget);
    expect(find.text('В сети'), findsOneWidget);
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/device-online.png'),
    );
    await t.tap(find.byKey(const Key('host-rotate')));
    expect(m.hosts.single.sent.last, {'cmd': 'rotate'});
    expect(t.takeException(), isNull);
  });

  testWidgets('offline, wrong password and unknown device messages', (t) async {
    final m = await pumpDevice(t, const Size(1000, 900));
    m.hosts.single.emit(
      const HostView(
        link: HostLink.reconnecting,
        error: 'Нет связи с сервером',
        tempPassword: 'k7m2x9qp',
        allowIncoming: true,
      ),
    );
    await t.enterText(find.byKey(const Key('remote-id')), '222 333 444');
    await t.enterText(find.byKey(const Key('remote-password')), 'wrongpass');
    await t.tap(find.byKey(const Key('remote-connect')));
    await settle(t);
    expect(find.text('Неверный пароль.'), findsOneWidget);
    expect(find.text('Переподключение'), findsOneWidget);
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/device-bad-password.png'),
    );
    expect(
      t
          .widget<TextField>(find.byKey(const Key('remote-password')))
          .controller!
          .text,
      isEmpty,
      reason: 'a refused password is never resent',
    );
    await t.enterText(find.byKey(const Key('remote-id')), '111 111 111');
    await t.enterText(find.byKey(const Key('remote-password')), 'anything');
    await t.tap(find.byKey(const Key('remote-connect')));
    await settle(t);
    expect(find.textContaining('с таким ID не найден'), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  testWidgets('waiting for approval on the other computer', (t) async {
    final m = await pumpDevice(t, const Size(1000, 900));
    m.c
      ..hostName = 'Рабочий ПК · 222 333 444'
      ..state = RemoteState.awaitingApproval
      ..message = 'Ждём подтверждения на удалённом компьютере…'
      ..busy = true
      ..connection = RemoteConnection(m.c.api!)
      ..changed();
    await t.pump();
    expect(
      find.text(
        'Рабочий ПК · 222 333 444: Ждём подтверждения на удалённом компьютере',
      ),
      findsOneWidget,
    );
    expect(find.byKey(const Key('gw-end')), findsOneWidget);
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/device-waiting.png'),
    );
    m.c
      ..busy = false
      ..connection = null
      ..hostName = ''
      ..changed();
    await t.pump();
  });

  testWidgets('incoming session indicator and Stop at compact size', (t) async {
    final m = await pumpDevice(t, const Size(600, 1300));
    m.hosts.single.emit(
      HostView(
        link: HostLink.online,
        tempPassword: 'k7m2x9qp',
        allowIncoming: true,
        session: IncomingSession(
          's1',
          'Ноутбук (ID 222 333 444)',
          'connected',
          DateTime(2026, 10, 29, 14, 5),
        ),
      ),
    );
    await t.pumpAndSettle();
    expect(find.text('Удалённое управление'), findsOneWidget);
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/device-incoming.png'),
    );
    await t.tap(find.byKey(const Key('host-stop')));
    expect(m.hosts.single.sent.last, {'cmd': 'stopSession'});
    expect(t.takeException(), isNull);
  });

  testWidgets('revoked registration', (t) async {
    final m = await pumpDevice(t, const Size(1000, 900));
    m.hosts.single.emit(
      const HostView(link: HostLink.revoked, error: 'Устройство отозвано'),
    );
    await t.pumpAndSettle();
    expect(find.byKey(const Key('device-revoked')), findsOneWidget);
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/device-revoked.png'),
    );
  });
}
