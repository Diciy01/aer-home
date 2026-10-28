// TEST DOUBLES ONLY: a fake Power API. These tests check the client logic
// and the UI; every power action here is SIMULATED — nothing reaches Core,
// an agent or a real computer.
import 'package:aer_home_desktop/src/app.dart';
import 'package:aer_home_desktop/src/core_api/core_client.dart';
import 'package:aer_home_desktop/src/core_api/power_api.dart';
import 'package:aer_home_desktop/src/features/power/power_view.dart';
import 'package:aer_home_desktop/src/state/app_section.dart';
import 'package:aer_home_desktop/src/state/bots_controller.dart';
import 'package:aer_home_desktop/src/state/connection_controller.dart';
import 'package:aer_home_desktop/src/state/monitoring_controller.dart';
import 'package:aer_home_desktop/src/state/power_controller.dart';
import 'package:aer_home_desktop/src/state/registry_controller.dart';
import 'package:aer_home_desktop/src/state/remote_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../bots/fake_bots_api.dart';
import '../fake_registry_api.dart';
import '../fixtures.dart';
import '../monitoring/fake_monitoring_api.dart';
import '../remote/remote_test.dart' show FakeRemoteApi, FakeLauncher;
import '../scene/scene_fixtures.dart';

final p0 = DateTime.utc(2026, 10, 28, 10);

PowerActionInfo act(
  PowerAction a, {
  bool ok = true,
  String reason = '',
  List<PowerTarget> targets = const [],
}) => PowerActionInfo(
  action: a,
  label: a.label,
  available: ok,
  reason: reason,
  dangerous: const {
    PowerAction.shutdown,
    PowerAction.reboot,
    PowerAction.suspend,
    PowerAction.switchOs,
  }.contains(a),
  targets: targets,
);

PowerDevice onlinePc({bool dryRun = true}) => PowerDevice(
  entityId: 'pc1',
  name: 'Рабочий ПК (тест)',
  type: 'computer',
  state: 'online',
  stateReason: 'Агент питания на связи (Ubuntu)',
  currentOs: 'linux',
  lastContactAt: p0,
  wol: const WoLTarget(mac: '00:00:5e:00:53:aa', broadcast: '192.168.50.255'),
  agents: [
    PowerAgentInfo(
      agentId: 'a1',
      name: 'power ubuntu',
      active: true,
      lastHelloAt: p0,
      os: 'linux',
      dryRun: dryRun,
      secureBoot: 'enabled',
      bitlocker: 'off',
    ),
  ],
  actions: [
    act(PowerAction.wake, ok: false, reason: 'Компьютер уже включён'),
    act(PowerAction.shutdown),
    act(PowerAction.reboot),
    act(
      PowerAction.suspend,
      ok: false,
      reason: 'Система требует пароль (polkit) — удалённо недоступно',
    ),
    act(
      PowerAction.switchOs,
      targets: const [
        PowerTarget(
          os: 'linux',
          label: 'Ubuntu',
          entryId: '',
          available: false,
          reason: 'Уже загружена',
        ),
        PowerTarget(
          os: 'windows',
          label: 'Windows',
          entryId: '0003',
          available: true,
          reason: '',
        ),
      ],
    ),
    act(PowerAction.check),
  ],
);

PowerDevice offlinePc() => PowerDevice(
  entityId: 'pc2',
  name: 'Выключенный ПК (тест)',
  type: 'computer',
  state: 'offline',
  stateReason: 'Не отвечает: выключено, спит или нет сети',
  wol: const WoLTarget(mac: '00:00:5e:00:53:bb'),
  actions: [
    act(PowerAction.wake),
    act(
      PowerAction.shutdown,
      ok: false,
      reason: 'Компьютер не отвечает — команду некому выполнить',
    ),
    act(PowerAction.check),
  ],
);

PowerDevice corePc() => const PowerDevice(
  entityId: 'pc3',
  name: 'Этот ПК (тест)',
  type: 'computer',
  state: 'unknown',
  stateReason: 'Нет данных',
  sameMachine: true,
  sameMachineNote: 'AER Core работает на этом же компьютере: выключенный компьютер не может включить сам себя',
  actions: [],
);

class FakePowerApi implements PowerApi {
  List<PowerDevice> list = [onlinePc(), offlinePc(), corePc()];
  final executed =
      <({String id, PowerAction a, String token, String target, String key})>[];
  final confirmed = <(PowerAction, String)>[];
  final cancelled = <String>[];
  List<JobState> progression = [
    JobState.sent,
    JobState.waiting,
    JobState.succeeded,
  ];
  PowerPolicy? savedPolicy;
  WoLTarget? savedWoL;
  bool wolEnabled = false;
  var _i = 0;

  PowerJob _job(JobState s, PowerAction a, String entity) => PowerJob(
    id: 'j1',
    entityId: entity,
    deviceName: 'Рабочий ПК (тест)',
    action: a,
    state: s,
    message: s == JobState.succeeded ? 'Новая загрузка подтверждена' : '',
    requestedAt: p0,
    targetOs: a == PowerAction.switchOs ? 'windows' : '',
    fromOs: 'linux',
  );

  PowerAction _last = PowerAction.check;
  String _entity = 'pc1';

  @override
  Future<List<PowerDevice>> devices() async => list;
  @override
  Future<PowerDevice> device(String entityId) async =>
      list.firstWhere((d) => d.entityId == entityId);
  @override
  Future<PowerDevice> setPolicy(String entityId, PowerPolicy p) async {
    savedPolicy = p;
    return list.first;
  }

  @override
  Future<PowerDevice> setWoL(String entityId, WoLTarget t) async {
    if (!RegExp(r'^[0-9a-fA-F:.-]{12,17}$').hasMatch(t.mac)) {
      throw const CoreApiException(
        statusCode: 422,
        code: 'VALIDATION_FAILED',
        message: 'Проверьте данные',
        details: {
          'fields': {'mac': 'MAC-адрес: 6 байт, например 00:11:22:33:44:55'},
        },
      );
    }
    savedWoL = t;
    return list.first;
  }

  @override
  Future<PowerDevice> deleteWoL(String entityId) async => list.first;
  @override
  Future<PowerConfirmation> confirm(
    String entityId,
    PowerAction action, {
    String targetOs = '',
  }) async {
    confirmed.add((action, targetOs));
    return PowerConfirmation(
      token: 'tok-${action.wire}',
      summary: '${action.label} «Рабочий ПК (тест)»',
      risks: const ['Несохранённые данные могут быть потеряны'],
      checks: const [
        PowerCheck('agent', true, 'Агент: pc-test (Ubuntu)'),
        PowerCheck('dry_run', false, 'Агент в режиме проверки (SIMULATED)'),
      ],
      expiresAt: p0.add(const Duration(minutes: 2)),
      targetOs: targetOs,
    );
  }

  @override
  Future<PowerJob> execute(
    String entityId,
    PowerAction action, {
    required String idempotencyKey,
    String confirmationToken = '',
    String targetOs = '',
  }) async {
    executed.add((
      id: entityId,
      a: action,
      token: confirmationToken,
      target: targetOs,
      key: idempotencyKey,
    ));
    _last = action;
    _entity = entityId;
    _i = 0;
    if (action == PowerAction.check) {
      return _job(JobState.succeeded, action, entityId);
    }
    return _job(JobState.queued, action, entityId);
  }

  @override
  Future<List<PowerJob>> jobs({String? entityId, int limit = 50}) async => [
    _job(JobState.simulated, PowerAction.reboot, 'pc1'),
  ];
  @override
  Future<PowerJob> job(String id) async {
    final s =
        progression[_i < progression.length ? _i++ : progression.length - 1];
    return _job(s, _last, _entity);
  }

  @override
  Future<PowerJob> cancel(String id) async {
    cancelled.add(id);
    return _job(JobState.cancelled, _last, _entity);
  }

  @override
  Future<PowerNet> interfaces() async => (
    interfaces: const [
      PowerInterface(
        name: 'eth0',
        mac: '00:00:5e:00:53:01',
        addresses: ['192.168.50.2/24'],
        broadcasts: ['192.168.50.255'],
        up: true,
      ),
      PowerInterface(
        name: 'lo',
        addresses: ['127.0.0.1/8'],
        up: true,
        loopback: true,
      ),
    ],
    wolEnabled: wolEnabled,
    defaultPort: 9,
  );
}

void main() {
  group('PowerController', () {
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

    test('run: confirmation token + fresh Idempotency-Key, job followed to the end', () async {
      final api = FakePowerApi();
      final c = PowerController(
        api,
        conn,
        autoPoll: false,
        step: Duration.zero,
      );
      addTearDown(c.dispose);
      await c.start();
      expect(c.devices, hasLength(3));
      final conf = await c.prepare('pc1', PowerAction.reboot);
      final j = await c.run('pc1', PowerAction.reboot, confirmation: conf);
      expect(j.state, JobState.queued);
      final e = api.executed.single;
      expect(e.token, 'tok-reboot');
      expect(e.key, startsWith('ui-'));
      for (var i = 0; i < 10 && !c.followed('pc1')!.state.terminal; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(c.followed('pc1')!.state, JobState.succeeded);
      // A second run gets a new key: no accidental replay.
      await c.run('pc1', PowerAction.reboot, confirmation: conf);
      expect(api.executed[1].key, isNot(api.executed[0].key));
    });

    test('check needs no confirmation; Core away marks data stale', () async {
      final api = FakePowerApi();
      final c = PowerController(
        api,
        conn,
        autoPoll: false,
        step: Duration.zero,
      );
      addTearDown(c.dispose);
      await c.start();
      await c.check('pc1');
      expect(api.executed.single.token, isEmpty);
      expect(c.canAct, isTrue);
      up = false;
      await conn.refresh();
      expect(c.isStale, isTrue);
      expect(c.canAct, isFalse, reason: 'no commands without Core');
      expect(c.devices, hasLength(3), reason: 'last known data stays visible');
    });
  });

  group('Power UI', () {
    Future<(FakePowerApi, PowerController, AppSectionController)> pump(
      WidgetTester tester, {
      FakePowerApi? api,
      AppSection at = AppSection.power,
    }) async {
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      final conn = ConnectionController(clientFor(healthyCore()));
      await tester.runAsync(conn.refresh);
      final mon = MonitoringController(
        FakeMonitoringApi(),
        conn,
        cache: MemoryMonitoringCache(),
        autoPoll: false,
      );
      final bots = BotsController(FakeBotsApi(), conn, autoPoll: false);
      final remote = RemoteController(
        FakeRemoteApi(),
        conn,
        launcher: FakeLauncher(),
        autoPoll: false,
      );
      final a = api ?? FakePowerApi();
      final power = PowerController(
        a,
        conn,
        autoPoll: false,
        step: Duration.zero,
      );
      final regApi = FakeRegistryApi();
      final registry = RegistryController(regApi, conn);
      final scene = sceneControllerFor(connection: conn, registry: regApi);
      final section = AppSectionController(at);
      await tester.pumpWidget(
        AerHomeApp(
          connection: conn,
          registry: registry,
          scene: scene,
          section: section,
          monitoring: mon,
          bots: bots,
          remote: remote,
          power: power,
        ),
      );
      await tester.pumpAndSettle();
      addTearDown(() async {
        conn.dispose();
        await tester.pumpWidget(const SizedBox());
        mon.dispose();
        bots.dispose();
        remote.dispose();
        power.dispose();
        registry.dispose();
        scene.dispose();
        await tester.binding.setSurfaceSize(null);
      });
      return (a, power, section);
    }

    ButtonStyleButton button(WidgetTester t, String key) =>
        t.widget<ButtonStyleButton>(find.byKey(Key(key)));

    testWidgets(
      'cards: real state, unavailable actions disabled with the reason',
      (tester) async {
        await pump(tester);
        expect(find.text('Питание'), findsWidgets);
        expect(find.byKey(const Key('power-state-pc1')), findsOneWidget);
        expect(find.text('Включён'), findsOneWidget);
        expect(find.text('Не отвечает'), findsOneWidget);
        expect(button(tester, 'power-wake-pc1').onPressed, isNull);
        expect(button(tester, 'power-suspend-pc1').onPressed, isNull);
        expect(button(tester, 'power-shutdown-pc1').onPressed, isNotNull);
        expect(button(tester, 'power-wake-pc2').onPressed, isNotNull);
        expect(button(tester, 'power-shutdown-pc2').onPressed, isNull);
        final tip = tester.widget<Tooltip>(
          find.ancestor(
            of: find.byKey(const Key('power-suspend-pc1')),
            matching: find.byType(Tooltip),
          ),
        );
        expect(tip.message, contains('polkit'));
        expect(find.byKey(const Key('power-dry-run')), findsOneWidget);
        expect(find.byKey(const Key('power-same-machine')), findsOneWidget);
        expect(
          find.textContaining('не может включить сам себя'),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('shutdown: plan, risks, second confirmation, then the job', (
      tester,
    ) async {
      final (api, _, _) = await pump(tester);
      await tester.tap(find.byKey(const Key('power-shutdown-pc1')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('power-confirm-dialog')), findsOneWidget);
      expect(find.textContaining('Несохранённые данные'), findsOneWidget);
      expect(find.textContaining('SIMULATED'), findsWidgets);
      expect(
        button(tester, 'power-confirm-go').onPressed,
        isNull,
        reason: 'dangerous: needs the explicit acknowledgement',
      );
      await tester.tap(find.byKey(const Key('power-confirm-ack')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('power-confirm-go')));
      await tester.pumpAndSettle();
      expect(api.executed.single.a, PowerAction.shutdown);
      expect(api.executed.single.token, 'tok-shutdown');
      expect(find.byKey(const Key('power-job-pc1')), findsOneWidget);
      expect(find.textContaining('Выполнено'), findsWidgets);
    });

    testWidgets('cancel offered while queued; dialog cancel sends nothing', (
      tester,
    ) async {
      final api = FakePowerApi()..progression = [JobState.queued];
      final (_, power, _) = await pump(tester, api: api);
      await tester.tap(find.byKey(const Key('power-reboot-pc1')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Отмена'));
      await tester.pumpAndSettle();
      expect(api.executed, isEmpty);

      await tester.tap(find.byKey(const Key('power-reboot-pc1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('power-confirm-ack')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('power-confirm-go')));
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const Key('power-job-cancel-pc1')), findsOneWidget);
      await tester.tap(find.byKey(const Key('power-job-cancel-pc1')));
      api.progression = [JobState.cancelled];
      await tester.pumpAndSettle();
      expect(api.cancelled, ['j1']);
      expect(power.followed('pc1')!.state, JobState.cancelled);
    });

    testWidgets(
      'switch OS: current OS not offered, Windows chosen and confirmed',
      (tester) async {
        final (api, _, _) = await pump(tester);
        await tester.tap(find.byKey(const Key('power-switch_os-pc1')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('power-target-dialog')), findsOneWidget);
        final linux = tester.widget<ListTile>(
          find.byKey(const Key('power-target-linux')),
        );
        expect(linux.enabled, isFalse);
        expect(find.text('Уже загружена'), findsOneWidget);
        expect(
          find.textContaining('порядок загрузки, GRUB и rEFInd не меняются'),
          findsOneWidget,
        );
        await tester.tap(find.byKey(const Key('power-target-windows')));
        await tester.pumpAndSettle();
        expect(api.confirmed.single, (PowerAction.switchOs, 'windows'));
        await tester.tap(find.byKey(const Key('power-confirm-ack')));
        await tester.pump();
        await tester.tap(find.byKey(const Key('power-confirm-go')));
        await tester.pumpAndSettle();
        expect(api.executed.single.target, 'windows');
      },
    );

    testWidgets(
      'Wake-on-LAN dialog: disabled sending explained, validation shown',
      (tester) async {
        final (api, _, _) = await pump(tester);
        await tester.tap(find.byKey(const Key('power-wol-pc1')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('power-wol-disabled')), findsOneWidget);
        await tester.enterText(find.byKey(const Key('power-wol-mac')), 'nope');
        await tester.tap(find.byKey(const Key('power-wol-save')));
        await tester.pumpAndSettle();
        expect(find.textContaining('6 байт'), findsOneWidget);
        await tester.enterText(
          find.byKey(const Key('power-wol-mac')),
          '00:00:5e:00:53:aa',
        );
        await tester.tap(find.byKey(const Key('power-wol-iface')));
        await tester.pumpAndSettle();
        await tester.tap(find.textContaining('eth0').last);
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('power-wol-save')));
        await tester.pumpAndSettle();
        expect(api.savedWoL!.interface, 'eth0');
        expect(api.savedWoL!.broadcast, '192.168.50.255');
        expect(find.byKey(const Key('power-wol-dialog')), findsNothing);
      },
    );

    testWidgets('policy: OS switch is opt-in', (tester) async {
      final (api, _, _) = await pump(tester);
      await tester.tap(find.byKey(const Key('power-policy-pc1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('power-policy-switchOs')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('power-policy-save')));
      await tester.pumpAndSettle();
      expect(api.savedPolicy!.switchOs, isTrue);
      expect(api.savedPolicy!.allowWithBitLocker, isFalse);
    });

    testWidgets('history tab and job audit', (tester) async {
      await pump(tester);
      await tester.tap(find.byKey(const Key('power-tab-history')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('power-history')), findsOneWidget);
      expect(find.textContaining('SIMULATED'), findsOneWidget);
    });

    testWidgets('«Удалённый доступ» opens the Remote section', (tester) async {
      final (_, _, section) = await pump(tester);
      await tester.tap(find.byKey(const Key('power-remote-pc1')));
      await tester.pumpAndSettle();
      expect(section.value, AppSection.remote);
    });
  });

  testWidgets('house panel offers only available actions and opens sections', (
    tester,
  ) async {
    final conn = ConnectionController(clientFor(healthyCore()));
    await tester.runAsync(conn.refresh);
    final api = FakePowerApi();
    final power = PowerController(
      api,
      conn,
      autoPoll: false,
      step: Duration.zero,
    );
    await tester.runAsync(power.refresh);
    var opened = 0, remote = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              PowerScenePanel(
                power: power,
                device: onlinePc(),
                onOpen: () => opened++,
                onOpenRemote: () => remote++,
              ),
              PowerScenePanel(
                power: power,
                device: corePc(),
                onOpen: () => opened++,
              ),
            ],
          ),
        ),
      ),
    );
    expect(find.byKey(const Key('scene-power-shutdown')), findsOneWidget);
    expect(find.byKey(const Key('scene-power-reboot')), findsOneWidget);
    expect(find.byKey(const Key('scene-power-switch_os')), findsOneWidget);
    expect(find.byKey(const Key('scene-power-wake')), findsNothing);
    expect(find.byKey(const Key('scene-power-suspend')), findsNothing);
    expect(find.byKey(const Key('scene-power-remote')), findsOneWidget);
    expect(find.textContaining('включить его по сети нельзя'), findsOneWidget);
    await tester.tap(find.byKey(const Key('scene-power-open')).first);
    await tester.tap(find.byKey(const Key('scene-power-remote')));
    expect((opened, remote), (1, 1));
    // Starting from the house shows progress in the panel.
    await tester.tap(find.byKey(const Key('scene-power-reboot')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('power-confirm-ack')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('power-confirm-go')));
    await tester.pumpAndSettle();
    expect(api.executed.single.a, PowerAction.reboot);
    addTearDown(() {
      power.dispose();
      conn.dispose();
    });
  });
}
