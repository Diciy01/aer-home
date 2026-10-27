// TEST DOUBLES ONLY: fake Remote API and a fake RDP launcher. These tests
// check the client logic, not the RDP transport (verified on the live lab).
import 'dart:async';
import 'dart:io';

import 'package:aer_home_desktop/src/app.dart';
import 'package:aer_home_desktop/src/core_api/monitoring_api.dart';
import 'package:aer_home_desktop/src/core_api/remote_api.dart';
import 'package:aer_home_desktop/src/features/remote/remote_view.dart';
import 'package:aer_home_desktop/src/remote/files_client.dart';
import 'package:aer_home_desktop/src/remote/rdp_launcher.dart';
import 'package:aer_home_desktop/src/state/app_section.dart';
import 'package:aer_home_desktop/src/state/bots_controller.dart';
import 'package:aer_home_desktop/src/state/connection_controller.dart';
import 'package:aer_home_desktop/src/state/monitoring_controller.dart';
import 'package:aer_home_desktop/src/state/registry_controller.dart';
import 'package:aer_home_desktop/src/state/remote_controller.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../bots/fake_bots_api.dart';
import '../fake_registry_api.dart';
import '../fixtures.dart';
import '../monitoring/fake_monitoring_api.dart';
import '../scene/scene_fixtures.dart';

final r0 = DateTime.utc(2026, 10, 27, 10);

RemoteHost fakeHost(
  String id,
  String name, {
  bool ready = true,
  String reason = '',
  bool files = true,
  String approval = 'auto',
}) => RemoteHost(
  entityId: id,
  name: name,
  type: 'computer',
  policy: RemotePolicy(files: files),
  effective: RemoteCaps(
    desktop: true,
    input: true,
    clipboard: true,
    files: files,
  ),
  canConnect: ready,
  reason: reason,
  status: ready ? MonStatus.online : MonStatus.offline,
  declared: const ['remote.desktop'],
  agent: RemoteHostAgent(
    os: 'linux',
    backend: 'gnome-rdp',
    address: '192.0.2.10',
    port: 3389,
    caps: const RemoteCaps(desktop: true, clipboard: true, files: true),
    approval: approval,
    ready: true,
    reason: '',
  ),
  agentActive: ready,
  lastHelloAt: r0,
);

class FakeRemoteApi implements RemoteApi {
  final hostsList = [
    fakeHost('h1', 'Рабочий ПК (тест)'),
    fakeHost(
      'h2',
      'Выключенный ПК (тест)',
      ready: false,
      reason: 'Агент удалённого доступа не на связи — компьютер выключен или агент не запущен',
    ),
  ];
  final states = <RemoteState>[
    RemoteState.pending,
    RemoteState.awaitingApproval,
    RemoteState.connecting,
  ];
  RemoteState after = RemoteState.connected;
  String failReason = '';
  final created = <(String, String, bool, bool)>[];
  final ended = <String>[];
  final revoked = <String>[];
  RemotePolicy? savedPolicy;
  int grants = 0;
  var _i = 0;

  RemoteSession _s(RemoteState st) => RemoteSession(
    id: 's1',
    entityId: 'h1',
    state: st,
    createdAt: r0,
    expiresAt: r0.add(const Duration(hours: 1)),
    hostName: 'Рабочий ПК (тест)',
    sourceName: 'тест',
    reason: failReason,
    allowed: const RemoteCaps(desktop: true, clipboard: true, files: true),
  );

  @override
  Future<List<RemoteHost>> hosts() async => hostsList;
  @override
  Future<RemoteHost> setPolicy(String entityId, RemotePolicy p) async {
    savedPolicy = p;
    return hostsList.first;
  }

  @override
  Future<List<RemoteSession>> sessions({
    String? entityId,
    int limit = 50,
  }) async => [_s(RemoteState.disconnected)];
  @override
  Future<RemoteSession> session(String id) async {
    if (revoked.contains(id)) return _s(RemoteState.revoked);
    if (_i < states.length) return _s(states[_i++]);
    return _s(after);
  }

  @override
  Future<RemoteSession> create(
    String entityId, {
    required String sourceName,
    required String idempotencyKey,
    bool clipboard = true,
    bool files = true,
  }) async {
    created.add((entityId, idempotencyKey, clipboard, files));
    return _s(states[_i++]);
  }

  @override
  Future<RemoteGrant> grant(String id) async {
    grants++;
    return RemoteGrant(
      sessionId: id,
      host: '192.0.2.10',
      port: 3389,
      username: 'aer',
      password: 'TESTpassword1234567890abcdefgh',
      certPem: '-----BEGIN CERTIFICATE-----\nTEST\n-----END CERTIFICATE-----\n',
      certSha256: 'aa:bb',
      clipboard: true,
      expiresAt: r0.add(const Duration(hours: 1)),
    );
  }

  @override
  Future<RemoteSession> end(String id) async {
    ended.add(id);
    return _s(RemoteState.disconnected);
  }

  @override
  Future<RemoteSession> revoke(String id) async {
    revoked.add(id);
    return _s(RemoteState.revoked);
  }

  @override
  Future<({String status, String reason})> apps(String entityId) async =>
      (status: 'unsupported', reason: 'весь рабочий стол');
}

class FakeLauncher implements RdpLauncher {
  FakeLauncher({this.available = true});
  @override
  final bool available;
  final launched = <RemoteGrant>[];
  final exits = <Completer<int>>[];
  @override
  String get clientName => 'Remmina';
  @override
  Future<RdpClientHandle> launch(RemoteGrant g) async {
    launched.add(g);
    final c = Completer<int>();
    exits.add(c);
    return _FakeHandle(c);
  }
}

class _FakeHandle implements RdpClientHandle {
  _FakeHandle(this.c);
  final Completer<int> c;
  bool stopped = false;
  @override
  Future<int> get exitCode => c.future;
  @override
  void stop() {
    stopped = true;
    if (!c.isCompleted) c.complete(0);
  }
}

void main() {
  group('RemoteController', () {
    var up = true;
    late ConnectionController conn;
    setUp(() async {
      up = true;
      conn = ConnectionController(
        clientFor(
          MockClient((r) async {
            if (!up) throw http.ClientException('refused', r.url);
            return healthyHandler(r);
          }),
        ),
      );
      await conn.refresh();
    });
    tearDown(() => conn.dispose());

    RemoteController make(FakeRemoteApi api, FakeLauncher l) =>
        RemoteController(
          api,
          conn,
          launcher: l,
          autoPoll: false,
          step: Duration.zero,
          probe: (_, _) async => const Duration(milliseconds: 1),
        );

    test(
      'connect: request → host approval → one-time grant → external client',
      () async {
        final api = FakeRemoteApi();
        final l = FakeLauncher();
        final c = make(api, l);
        addTearDown(c.dispose);
        await c.start();
        await c.connect(api.hostsList.first, files: false);
        expect(
          api.created.single.$4,
          isFalse,
          reason: 'files switched off by the user',
        );
        expect(
          api.created.single.$2,
          startsWith('ui-'),
          reason: 'idempotency key per attempt',
        );
        expect(api.grants, 1);
        expect(l.launched.single.password, 'TESTpassword1234567890abcdefgh');
        expect(c.active!.phase, RemotePhase.running);
        expect(c.active!.message, contains('Remmina'));

        await c.revoke('s1');
        expect(c.active!.phase, RemotePhase.ended);
        expect(c.active!.files, isNull);
        expect(c.active!.live, isFalse);
      },
    );

    test(
      'client window closed → reconnect with the same session; end ends it',
      () async {
        final api = FakeRemoteApi();
        final l = FakeLauncher();
        final c = make(api, l);
        addTearDown(c.dispose);
        await c.start();
        await c.connect(api.hostsList.first);
        l.exits.first.complete(0);
        await Future<void>.delayed(Duration.zero);
        expect(c.active!.phase, RemotePhase.clientClosed);
        await c.reconnect();
        expect(l.launched, hasLength(2));
        expect(api.grants, 1, reason: 'no second grant: it is one-time');
        await c.end();
        expect(api.ended, ['s1']);
        expect(c.active!.phase, RemotePhase.ended);
      },
    );

    test(
      'denied on the host: failure with the reason, nothing launched',
      () async {
        final api = FakeRemoteApi()
          ..states.replaceRange(1, 3, [RemoteState.failed])
          ..failReason = 'Отклонено на компьютере';
        final l = FakeLauncher();
        final c = make(api, l);
        addTearDown(c.dispose);
        await c.connect(api.hostsList.first);
        expect(c.active!.phase, RemotePhase.failed);
        expect(c.active!.message, 'Отклонено на компьютере');
        expect(l.launched, isEmpty);
      },
    );

    test('no RDP client installed: no session is requested', () async {
      final api = FakeRemoteApi();
      final c = make(api, FakeLauncher(available: false));
      addTearDown(c.dispose);
      await c.connect(api.hostsList.first);
      expect(c.active!.phase, RemotePhase.failed);
      expect(c.active!.message, contains('не установлен'));
      expect(api.created, isEmpty);
    });

    test('Core lost: last known data marked stale', () async {
      final api = FakeRemoteApi();
      final c = make(api, FakeLauncher());
      addTearDown(c.dispose);
      await c.start();
      up = false;
      await conn.refresh();
      expect(c.isStale, isTrue);
      expect(c.hosts, hasLength(2));
      expect(c.canAct, isFalse);
      up = true;
      await conn.refresh();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(c.isStale, isFalse, reason: 'refreshed on reconnect');
    });
  });

  test(
    'Remmina launcher pins the host certificate and builds the URI',
    () async {
      final dir = Directory.systemTemp.createTempSync('aer-pin-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final l = RemminaLauncher(
        command: ['remmina', '-c'],
        freerdpDir: dir.path,
      );
      final g = RemoteGrant(
        sessionId: 's',
        host: '192.0.2.10',
        port: 33891,
        username: 'aer',
        password: 'Abc123',
        certPem: 'PEM',
        certSha256: '',
        clipboard: true,
        expiresAt: r0,
      );
      expect(
        l.pinFile(g).path,
        '${dir.path}/server/192.0.2.10.33891_33891.pem',
      );
      expect(l.uri(g).toString(), 'rdp://aer:Abc123@192.0.2.10:33891');
    },
  );

  test('file channel pins the certificate by SHA-256', () {
    final der = [1, 2, 3, 4];
    final fp = sha256
        .convert(der)
        .bytes
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join(':');
    expect(RemoteFilesClient.fingerprint(der), fp);
  });

  group('Remote UI', () {
    Future<(FakeRemoteApi, FakeLauncher, RemoteController)> pump(
      WidgetTester tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1366, 768));
      final conn = ConnectionController(clientFor(healthyCore()));
      await tester.runAsync(conn.refresh);
      final mon = MonitoringController(
        FakeMonitoringApi(),
        conn,
        cache: MemoryMonitoringCache(),
        autoPoll: false,
      );
      final bots = BotsController(FakeBotsApi(), conn, autoPoll: false);
      final api = FakeRemoteApi();
      final l = FakeLauncher();
      final remote = RemoteController(
        api,
        conn,
        launcher: l,
        autoPoll: false,
        step: Duration.zero,
        probe: (_, _) async => const Duration(microseconds: 1500),
      );
      final regApi = FakeRegistryApi();
      final registry = RegistryController(regApi, conn);
      final scene = sceneControllerFor(connection: conn, registry: regApi);
      await tester.pumpWidget(
        AerHomeApp(
          connection: conn,
          registry: registry,
          scene: scene,
          section: AppSectionController(AppSection.remote),
          monitoring: mon,
          bots: bots,
          remote: remote,
        ),
      );
      await tester.pumpAndSettle();
      addTearDown(() async {
        conn.dispose();
        await tester.pumpWidget(const SizedBox());
        mon.dispose();
        bots.dispose();
        remote.dispose();
        registry.dispose();
        scene.dispose();
        await tester.binding.setSurfaceSize(null);
      });
      return (api, l, remote);
    }

    testWidgets('hosts: ready one connectable, offline one explains why', (
      tester,
    ) async {
      final (api, l, remote) = await pump(tester);
      final ok = tester.widget<ButtonStyleButton>(
        find.byKey(const Key('remote-connect-h1')),
      );
      final off = tester.widget<ButtonStyleButton>(
        find.byKey(const Key('remote-connect-h2')),
      );
      expect(ok.onPressed, isNotNull);
      expect(
        off.onPressed,
        isNull,
        reason: 'an offline computer is not offered',
      );
      expect(find.textContaining('компьютер выключен'), findsOneWidget);

      await tester.tap(find.byKey(const Key('remote-connect-h1')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('remote-connect-dialog')), findsOneWidget);
      expect(find.textContaining('внешний клиент RDP'), findsOneWidget);
      await tester.tap(find.byKey(const Key('remote-connect-go')));
      await tester.pumpAndSettle();
      expect(l.launched, hasLength(1));
      expect(find.byKey(const Key('remote-active')), findsOneWidget);
      expect(find.textContaining('в окне Remmina'), findsOneWidget);
      expect(find.textContaining('Core видео не передаёт'), findsOneWidget);

      await tester.tap(find.byKey(const Key('remote-end')));
      await tester.pumpAndSettle();
      expect(api.ended, ['s1']);
      await tester.tap(find.byKey(const Key('remote-tab-history')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('remote-history')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('policy dialog saves files permission', (tester) async {
      final (api, _, _) = await pump(tester);
      await tester.tap(find.byKey(const Key('remote-policy-h1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('policy-files')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('policy-save')));
      await tester.pumpAndSettle();
      expect(api.savedPolicy!.files, isFalse);
    });
  });

  testWidgets('house panel offers «Подключиться» only for a ready host', (
    tester,
  ) async {
    final conn = ConnectionController(clientFor(healthyCore()));
    await tester.runAsync(conn.refresh);
    final remote = RemoteController(
      FakeRemoteApi(),
      conn,
      launcher: FakeLauncher(),
      autoPoll: false,
    );
    var opened = 0;
    final api = FakeRemoteApi();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              RemoteScenePanel(
                remote: remote,
                host: api.hostsList[0],
                onOpen: () => opened++,
              ),
              RemoteScenePanel(
                remote: remote,
                host: api.hostsList[1],
                onOpen: () => opened++,
              ),
            ],
          ),
        ),
      ),
    );
    expect(find.byKey(const Key('scene-remote-connect')), findsOneWidget);
    expect(find.byKey(const Key('scene-remote-open')), findsNWidgets(2));
    await tester.tap(find.byKey(const Key('scene-remote-open')).last);
    expect(opened, 1);
    addTearDown(() {
      remote.dispose();
      conn.dispose();
    });
  });
}
