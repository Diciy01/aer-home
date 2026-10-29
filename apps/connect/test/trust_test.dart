import 'package:aer_connect/connect_app.dart';
import 'package:aer_connect/controller.dart';
import 'package:aer_remote/aer_remote.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'connect_test.dart' show MemoryStore, pin;
import 'device_test.dart' show DeviceClient, FakeHost, FakeTools;

// Stateful TEST server, no sockets/processes/desktop/OS clipboard.
class TrustServer {
  DeviceTrust state = const DeviceTrust();
  bool unavailable = false;
  int changes = 0;
  static final candidate = TrustedDevice(
    number: '753951456',
    name: 'Рабочий ПК (тест)',
    fingerprint: 'ab' * 32,
  );
  void check() {
    if (unavailable) {
      throw const RemoteEngineException(
        503,
        'UNAVAILABLE',
        'Сервер недоступен',
      );
    }
  }
}

class TrustClient extends DeviceClient {
  TrustClient(super.server, this.backend);
  final TrustServer backend;
  @override
  Future<DeviceTrust> trust() async {
    backend.check();
    return backend.state;
  }

  @override
  Future<DeviceTrust> setUnattended(bool enabled) async {
    backend.check();
    backend.changes++;
    return backend.state = DeviceTrust(
      enabled: enabled,
      devices: backend.state.devices,
    );
  }

  @override
  Future<TrustedDevice> trustCandidate(String number) async {
    backend.check();
    if (normalizeDeviceNumber(number) != TrustServer.candidate.number) {
      throw const RemoteEngineException(404, 'NOT_FOUND', 'Не найдено');
    }
    return TrustServer.candidate;
  }

  @override
  Future<DeviceTrust> grantTrust(TrustedDevice peer) async {
    backend.check();
    backend.changes++;
    return backend.state = DeviceTrust(
      enabled: backend.state.enabled,
      devices: [peer],
    );
  }

  @override
  Future<DeviceTrust> revokeTrust(String number) async {
    backend.check();
    backend.changes++;
    return backend.state = DeviceTrust(
      enabled: backend.state.enabled,
      devices: [
        TrustedDevice(
          number: TrustServer.candidate.number,
          name: TrustServer.candidate.name,
          fingerprint: TrustServer.candidate.fingerprint,
          revoked: true,
        ),
      ],
    );
  }
}

ConnectController controller(TrustServer server, MemoryStore devices) =>
    ConnectController(
      store: MemoryStore(),
      deviceStore: devices,
      tools: FakeTools(),
      client: (s) => TrustClient(s, server),
      hostRuntime: FakeHost.new,
      viewerFactory: (_) =>
          throw UnimplementedError('No viewer in UI trust tests'),
    );

void main() {
  test(
    'trust reloads from its server authority and errors never imply enabled',
    () async {
      final server = TrustServer(), saved = MemoryStore();
      final first = controller(server, saved);
      await first.enroll(
        'home.example.net',
        pin,
        'ENROLL-TEST-CODE',
        'Домашний ПК',
      );
      expect(first.trust!.enabled, isFalse);
      await first.grantTrust(TrustServer.candidate);
      await first.setUnattended(true);
      await first.shutdown();
      first.dispose();
      final second = controller(server, saved);
      await second.load();
      expect(second.trust!.enabled, isTrue);
      expect(second.trust!.devices.single.number, TrustServer.candidate.number);
      server.unavailable = true;
      await second.refreshTrust();
      expect(second.trust, isNull);
      expect(second.trustError, isNotEmpty);
      await expectLater(
        second.setUnattended(true),
        throwsA(isA<RemoteEngineException>()),
      );
      await second.shutdown();
      second.dispose();
    },
  );

  Future<ConnectController> pump(WidgetTester t, TrustServer server) async {
    await t.binding.setSurfaceSize(const Size(1100, 1400));
    addTearDown(() => t.binding.setSurfaceSize(null));
    final c = controller(server, MemoryStore());
    addTearDown(c.dispose);
    await c.enroll('home.example.net', pin, 'ENROLL-TEST-CODE', 'Домашний ПК');
    await t.pumpWidget(ConnectApp(controller: c));
    await t.pumpAndSettle();
    await t.ensureVisible(find.byKey(const Key('host-trust')));
    await t.tap(find.byKey(const Key('host-trust')));
    await t.pumpAndSettle();
    return c;
  }

  Future<void> tap(WidgetTester t, Finder f) async {
    await t.ensureVisible(f);
    await t.tap(f);
    await t.pumpAndSettle();
  }

  testWidgets(
    'unattended defaults off; owner warning and installation fingerprint confirmation required',
    (t) async {
      final server = TrustServer();
      final c = await pump(t, server);
      expect(
        t
            .widget<SwitchListTile>(find.byKey(const Key('host-unattended')))
            .value,
        isFalse,
      );
      await tap(t, find.byKey(const Key('host-unattended')));
      expect(
        find.text('Постоянный доступ доверенным устройствам'),
        findsOneWidget,
      );
      await tap(t, find.text('Отмена').last);
      expect(server.changes, 0);
      await tap(t, find.byKey(const Key('host-unattended')));
      await tap(t, find.byKey(const Key('trust-enable-confirm')));
      expect(c.trust!.enabled, isTrue);
      await tap(t, find.byKey(const Key('trust-add')));
      await t.enterText(find.byKey(const Key('trust-number')), '753 951 456');
      await tap(t, find.byKey(const Key('trust-lookup')));
      expect(find.text(TrustServer.candidate.fingerprint), findsOneWidget);
      expect(
        t.widget<FilledButton>(find.byKey(const Key('trust-grant'))).onPressed,
        isNull,
      );
      await tap(t, find.byKey(const Key('trust-key-confirm')));
      await tap(t, find.byKey(const Key('trust-grant')));
      expect(c.trust!.devices.single.number, TrustServer.candidate.number);
      expect(find.text('Доверено · без подтверждения'), findsOneWidget);
      expect(t.takeException(), isNull);
    },
  );
  testWidgets(
    'revoke and disable use existing AER controls and retain revoked status',
    (t) async {
      final server = TrustServer()
        ..state = DeviceTrust(enabled: true, devices: [TrustServer.candidate]);
      final c = await pump(t, server);
      await tap(
        t,
        find.byKey(Key('trust-revoke-${TrustServer.candidate.number}')),
      );
      await tap(t, find.widgetWithText(FilledButton, 'Отозвать доступ'));
      expect(c.trust!.devices.single.revoked, isTrue);
      expect(find.text('Доступ отозван'), findsOneWidget);
      await tap(t, find.byKey(const Key('trust-disable')));
      expect(c.trust!.enabled, isFalse);
      expect(c.trust!.devices.single.revoked, isTrue);
      expect(t.takeException(), isNull);
    },
  );
  testWidgets(
    'unavailable policy disables unattended switch instead of trusting stale data',
    (t) async {
      final server = TrustServer()..unavailable = true;
      await pump(t, server);
      final toggle = t.widget<SwitchListTile>(
        find.byKey(const Key('host-unattended')),
      );
      expect(toggle.value, isFalse);
      expect(toggle.onChanged, isNull);
      expect(
        find.textContaining('Параметры доверия недоступны'),
        findsOneWidget,
      );
    },
  );
  testWidgets('trusted device list fits a compact AER window', (t) async {
    final server = TrustServer()
      ..state = DeviceTrust(enabled: true, devices: [TrustServer.candidate]);
    await pump(t, server);
    await t.binding.setSurfaceSize(const Size(520, 1100));
    await t.pumpAndSettle();
    await t.ensureVisible(
      find.byKey(Key('trust-revoke-${TrustServer.candidate.number}')),
    );
    await t.pumpAndSettle();
    expect(find.text('Доверено · без подтверждения'), findsOneWidget);
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/device-trusted.png'),
    );
    expect(t.takeException(), isNull);
  });
}
