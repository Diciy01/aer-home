// TEST DOUBLES ONLY: a fake Network API. These tests check the client and
// the UI; no router, TV or Sunshine is contacted.
import 'package:aer_home_desktop/src/app.dart';
import 'package:aer_home_desktop/src/core_api/core_client.dart';
import 'package:aer_home_desktop/src/core_api/monitoring_api.dart';
import 'package:aer_home_desktop/src/core_api/network_api.dart';
import 'package:aer_home_desktop/src/features/classic/classic_view.dart';
import 'package:aer_home_desktop/src/features/network/network_view.dart';
import 'package:aer_home_desktop/src/state/app_section.dart';
import 'package:aer_home_desktop/src/state/bots_controller.dart';
import 'package:aer_home_desktop/src/state/connection_controller.dart';
import 'package:aer_home_desktop/src/state/monitoring_controller.dart';
import 'package:aer_home_desktop/src/state/network_controller.dart';
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
import '../power/power_test.dart' show FakePowerApi;
import '../remote/remote_test.dart' show FakeRemoteApi, FakeLauncher;
import '../scene/scene_fixtures.dart';

final n0 = DateTime.now().toUtc().subtract(const Duration(seconds: 20));

NetDevice dev(
  String id,
  String name,
  String type,
  NetStatus st, {
  String reason = '',
  double? latency,
  bool stale = false,
}) => NetDevice(
  entityId: id,
  name: name,
  type: type,
  status: st,
  reason: reason,
  address: '192.0.2.${id.length}',
  latencyMs: latency,
  lastContactAt: n0,
  lastCheckAt: n0,
  stale: stale,
);

NetworkOverview fullOverview({bool streaming = true}) => NetworkOverview(
  summary: const NetSummary('warning', 'Не отвечают устройства: 1', [
    'Не отвечают устройства: 1',
  ]),
  internet: NetCheck(
    key: 'internet',
    kind: 'internet',
    name: 'Интернет',
    status: NetStatus.up,
    reason: 'Интернет доступен: ответили 2 из 2 целей',
    latencyMs: 12.4,
    lastCheckAt: n0,
    lastOkAt: n0,
    details: const NetDetails(
      targets: [
        NetTarget('198.51.100.1:443', true, 12.4, ''),
        NetTarget('198.51.100.2:443', true, 15, ''),
      ],
    ),
  ),
  routers: [
    NetRouter(
      device: dev('r1', 'Роутер (тест)', 'router', NetStatus.up, latency: 1.2),
      adapter: 'none',
      adapterNote:
          'Только доступность и задержка: API роутера для чтения не настроен',
    ),
    NetRouter(
      device: dev('r2', 'Роутер UPnP (тест)', 'router', NetStatus.up),
      adapter: 'upnp',
      adapterNote: 'UPnP IGD: только чтение состояния WAN',
      wan: NetCheck(
        key: 'router:r2',
        kind: 'router_wan',
        name: 'WAN: Роутер UPnP (тест)',
        status: NetStatus.down,
        reason: 'WAN по данным роутера: Disconnected',
        details: const NetDetails(
          connection: 'Disconnected',
          physicalLink: 'Down',
        ),
      ),
    ),
  ],
  devices: [
    dev(
      'sw',
      'Коммутатор (тест)',
      'network_device',
      NetStatus.down,
      reason: 'Не отвечает на TCP-порты 80, 443',
    ),
  ],
  tvs: [
    dev('tv', 'ТВ (тест)', 'television', NetStatus.error, reason: 'Нет ответа'),
  ],
  sunshine: [
    NetSunshine(
      id: 'pc',
      name: 'Sunshine (тест)',
      webUrl: 'https://127.0.0.1:47990',
      check: NetCheck(
        key: 'sunshine:pc',
        kind: 'sunshine',
        name: 'Sunshine (тест)',
        status: NetStatus.up,
        reason: streaming
            ? 'Sunshine работает, идёт стрим'
            : 'Sunshine работает, стрима нет',
        latencyMs: 2,
        lastOkAt: n0,
        details: NetDetails(
          streaming: streaming,
          version: '0.0-test',
          webReachable: true,
        ),
      ),
      entity: dev('pc', 'ПК (тест)', 'computer', NetStatus.up),
      tv: dev(
        'tv',
        'ТВ (тест)',
        'television',
        NetStatus.error,
        reason: 'Нет ответа',
      ),
    ),
  ],
  incidents: [
    Incident(
      id: 'i1',
      title: 'WAN: Роутер UPnP (тест): недоступно',
      source: 'network',
      severity: MonSeverity.critical,
      status: 'open',
      openedAt: n0,
      updatedAt: n0,
      cause: '',
      related: const [],
      occurrences: 1,
      lastMessage: 'WAN по данным роутера: Disconnected',
      entityId: 'r2',
    ),
  ],
);

NetworkOverview emptyOverview() => const NetworkOverview(
  summary: NetSummary('unconfigured', 'Сеть не настроена', []),
  internet: NetCheck(
    key: 'internet',
    kind: 'internet',
    name: 'Интернет',
    status: NetStatus.unconfigured,
    reason: 'Не настроено: укажите цели network.internet.targets',
  ),
);

class FakeNetworkApi implements NetworkApi {
  FakeNetworkApi([NetworkOverview? o]) : o = o ?? fullOverview();
  NetworkOverview o;
  int checks = 0;
  bool tooSoon = false;

  @override
  Future<NetworkOverview> overview() async => o;

  @override
  Future<NetworkOverview> checkNow() async {
    checks++;
    if (tooSoon) {
      throw const CoreApiException(
        statusCode: 409,
        code: 'CONFLICT',
        message: 'Проверка уже выполнялась несколько секунд назад',
      );
    }
    return o;
  }
}

void main() {
  group('NetworkController', () {
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

    test('lookups, too-soon check, stale without Core', () async {
      final api = FakeNetworkApi();
      final c = NetworkController(api, conn, autoPoll: false);
      addTearDown(c.dispose);
      await c.start();
      expect(c.deviceFor('r1')!.latencyMs, 1.2);
      expect(c.routerFor('r2')!.wan!.status, NetStatus.down);
      expect(c.sunshineFor('tv').single.id, 'pc', reason: 'TV links Sunshine');
      expect(c.deviceFor('pc')!.type, 'computer');
      expect(await c.checkNow(), isNull);
      api.tooSoon = true;
      expect(await c.checkNow(), contains('несколько секунд'));
      up = false;
      await conn.refresh();
      expect(c.isStale, isTrue);
      expect(c.canAct, isFalse);
      expect(c.overview, isNotNull, reason: 'last data stays visible');
    });
  });

  group('Network UI', () {
    Future<(FakeNetworkApi, AppSectionController, List<Uri>)> pump(
      WidgetTester tester, {
      Size size = const Size(1366, 768),
      FakeNetworkApi? api,
      AppSection at = AppSection.network,
    }) async {
      await tester.binding.setSurfaceSize(size);
      final conn = ConnectionController(clientFor(healthyCore()));
      await tester.runAsync(conn.refresh);
      final monApi = FakeMonitoringApi()
        ..netLogs = [
          LogEntry(
            id: 1000,
            at: DateTime.utc(2026, 10, 28, 10),
            source: 'net.sunshine',
            level: 'warning',
            message: 'Sunshine (тест): Sunshine не отвечает: тайм-аут',
            correlationId: '',
          ),
        ];
      final mon = MonitoringController(
        monApi,
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
      final power = PowerController(FakePowerApi(), conn, autoPoll: false);
      final a = api ?? FakeNetworkApi();
      final network = NetworkController(a, conn, autoPoll: false);
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
          network: network,
        ),
      );
      await tester.runAsync(network.start);
      await tester.pumpAndSettle();
      addTearDown(() async {
        conn.dispose();
        await tester.pumpWidget(const SizedBox());
        mon.dispose();
        bots.dispose();
        remote.dispose();
        power.dispose();
        network.dispose();
        registry.dispose();
        scene.dispose();
        await tester.binding.setSurfaceSize(null);
      });
      return (a, section, <Uri>[]);
    }

    for (final size in const [Size(1366, 768), Size(1920, 1080)]) {
      testWidgets(
        'overview at ${size.width.toInt()}×${size.height.toInt()}: states, no overflow',
        (tester) async {
          await pump(tester, size: size);
          expect(tester.takeException(), isNull);
          expect(find.text('Сеть и ТВ'), findsWidgets);
          expect(find.byKey(const Key('net-summary')), findsOneWidget);
          expect(find.byKey(const Key('net-internet')), findsOneWidget);
          expect(find.byKey(const Key('net-router-r1')), findsOneWidget);
          expect(
            find.byKey(const Key('net-router-note-r1')),
            findsOneWidget,
            reason: 'no API: says only reachability is checked',
          );
          expect(find.text('WAN по данным роутера (UPnP)'), findsOneWidget);
          await tester.scrollUntilVisible(
            find.byKey(const Key('net-sunshine-pc')),
            300,
            scrollable: find.byType(Scrollable).last,
          );
          expect(
            find.byKey(const Key('net-sunshine-stream-pc')),
            findsOneWidget,
          );
          expect(find.textContaining('отдельное устройство'), findsOneWidget);
          for (final s in NetStatus.values.where(
            (s) => s != NetStatus.unconfigured && s != NetStatus.unknown,
          )) {
            expect(find.text(s.label), findsWidgets, reason: s.label);
          }
          expect(tester.takeException(), isNull);
        },
      );
    }

    testWidgets('navigation: device card, diagnostics, journal, Sunshine UI', (
      tester,
    ) async {
      final (_, section, _) = await pump(tester);
      final opened = <Uri>[];
      // Replace the opener through a fresh view to record calls.
      await tester.scrollUntilVisible(
        find.byKey(const Key('net-device-sw')),
        300,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.tap(find.byKey(const Key('net-device-sw')));
      await tester.pumpAndSettle();
      expect(section.value, AppSection.devices);
      section.value = AppSection.network;
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byKey(const Key('net-open-journal')),
        300,
        scrollable: find.byType(Scrollable).last,
      );
      expect(find.byKey(const Key('net-incidents')), findsOneWidget);
      await tester.tap(find.byKey(const Key('net-open-journal')));
      await tester.pumpAndSettle();
      expect(section.value, AppSection.monitoring);
      expect(opened, isEmpty);
    });

    testWidgets('journal tab shows net.* checks only', (tester) async {
      await pump(tester);
      await tester.tap(find.byKey(const Key('net-tab-journal')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('net-journal')), findsOneWidget);
      expect(find.textContaining('Sunshine не отвечает'), findsOneWidget);
      expect(find.textContaining('строка журнала'), findsNothing);
    });

    testWidgets('nothing configured: explains what to set up', (tester) async {
      await pump(tester, api: FakeNetworkApi(emptyOverview()));
      expect(find.byKey(const Key('net-setup-hint')), findsOneWidget);
      expect(find.text('Роутер не добавлен'), findsOneWidget);
      expect(find.text('Sunshine не настроен'), findsOneWidget);
      expect(find.text('Не настроен'), findsWidgets);
      expect(tester.takeException(), isNull);
    });

    testWidgets('check now: too soon shows the reason', (tester) async {
      final api = FakeNetworkApi()..tooSoon = true;
      await pump(tester, api: api);
      await tester.tap(find.byKey(const Key('net-check-now')));
      await tester.pumpAndSettle();
      expect(api.checks, 1);
      expect(find.textContaining('несколько секунд'), findsOneWidget);
    });

    testWidgets(
      'classic «Обзор» shows the network card and opens the section',
      (tester) async {
        final (_, section, _) = await pump(tester, at: AppSection.overview);
        expect(find.byKey(const Key('classic-network')), findsOneWidget);
        expect(find.byType(ClassicView), findsOneWidget);
        await tester.tap(find.text('Открыть'));
        await tester.pumpAndSettle();
        expect(section.value, AppSection.network);
      },
    );
  });

  testWidgets('Sunshine card opens only its configured web UI', (tester) async {
    final opened = <Uri>[];
    final o = fullOverview(streaming: false);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 430,
            child: SunshineCard(
              sunshine: o.sunshine.single,
              links: NetworkLinks(
                opener: (u) async {
                  opened.add(u);
                  return true;
                },
              ),
            ),
          ),
        ),
      ),
    );
    expect(find.text('Сейчас стрима нет'), findsOneWidget);
    await tester.tap(find.byKey(const Key('net-sunshine-open-pc')));
    await tester.pump();
    expect(opened.single.toString(), 'https://127.0.0.1:47990');
  });

  testWidgets('house panel: device, router WAN and Sunshine kept separate', (
    tester,
  ) async {
    final conn = ConnectionController(clientFor(healthyCore()));
    await tester.runAsync(conn.refresh);
    final n = NetworkController(FakeNetworkApi(), conn, autoPoll: false);
    await tester.runAsync(n.start);
    var opened = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              NetworkScenePanel(
                network: n,
                entityId: 'tv',
                onOpen: () => opened++,
              ),
              NetworkScenePanel(
                network: n,
                entityId: 'r2',
                onOpen: () => opened++,
              ),
            ],
          ),
        ),
      ),
    );
    expect(find.text('В сети'), findsNWidgets(2));
    expect(find.text('Sunshine (тест)'), findsOneWidget);
    expect(find.text('WAN (UPnP)'), findsOneWidget);
    expect(find.text('Ошибка проверки'), findsOneWidget, reason: 'TV itself');
    await tester.tap(find.byKey(const Key('scene-net-open')).first);
    expect(opened, 1);
    addTearDown(() {
      n.dispose();
      conn.dispose();
    });
  });
}
