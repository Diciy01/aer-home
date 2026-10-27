import 'dart:io';

import 'package:aer_home_desktop/src/app.dart';
import 'package:aer_home_desktop/src/core_api/monitoring_api.dart';
import 'package:aer_home_desktop/src/scene/binding/scene_binding.dart';
import 'package:aer_home_desktop/src/scene/model/scene_document.dart';
import 'package:aer_home_desktop/src/state/app_section.dart';
import 'package:aer_home_desktop/src/state/connection_controller.dart';
import 'package:aer_home_desktop/src/state/monitoring_controller.dart';
import 'package:aer_home_desktop/src/state/registry_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../fake_registry_api.dart';
import '../fixtures.dart';
import '../scene/scene_fixtures.dart';
import 'fake_monitoring_api.dart';

void main() {
  group('MonitoringController', () {
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

    test(
      'live data, stale after Core loss, refresh on reconnect, cache',
      () async {
        final api = FakeMonitoringApi();
        final dir = Directory.systemTemp.createTempSync('aer-mon-');
        addTearDown(() => dir.deleteSync(recursive: true));
        final cache = MonitoringCache(
          File('${dir.path}/monitoring-cache.json'),
        );
        final c = MonitoringController(
          api,
          conn,
          cache: cache,
          interval: const Duration(hours: 1),
        );
        addTearDown(c.dispose);
        await c.start();
        expect(c.freshness, MonFreshness.live);
        expect(c.states, hasLength(3));
        expect(c.stateFor(api.devices[1].entityId)!.status, MonStatus.degraded);
        for (var i = 0; i < 100 && !File(cache.file.path).existsSync(); i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        expect(
          File(cache.file.path).existsSync(),
          isTrue,
          reason: 'snapshot written atomically',
        );

        up = false;
        await conn.refresh();
        expect(
          c.isStale,
          isTrue,
          reason: 'Core lost → last known data marked stale',
        );
        expect(c.states, hasLength(3), reason: 'last known state kept');

        final before = api.overviewCalls;
        up = true;
        await conn.refresh();
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(api.overviewCalls, greaterThan(before));
        expect(c.freshness, MonFreshness.live);

        // Restart without Core: the cached snapshot is shown as stale.
        up = false;
        await conn.refresh();
        final c2 = MonitoringController(
          api,
          conn,
          cache: cache,
          interval: const Duration(hours: 1),
        );
        addTearDown(c2.dispose);
        await c2.start();
        expect(c2.isStale, isTrue);
        expect(c2.states, hasLength(3));
        expect(c2.updatedAt, isNotNull);
      },
    );

    test('poll error keeps data but marks it stale', () async {
      final api = FakeMonitoringApi();
      final c = MonitoringController(
        api,
        conn,
        cache: MemoryMonitoringCache(),
        interval: const Duration(hours: 1),
      );
      addTearDown(c.dispose);
      await c.start();
      api.failWith = http.ClientException('reset');
      await c.refresh();
      expect(c.isStale, isTrue);
      expect(c.error, isNotNull);
      expect(c.overview, isNotNull);
    });

    test('scene live status mapping never invents health', () async {
      final api = FakeMonitoringApi();
      final c = MonitoringController(
        api,
        conn,
        cache: MemoryMonitoringCache(),
        interval: const Duration(hours: 1),
      );
      addTearDown(c.dispose);
      expect(
        liveStatusOf(c, api.devices[0].entityId),
        isNull,
        reason: 'no data yet → null',
      );
      await c.start();
      expect(
        liveStatusOf(c, api.devices[0].entityId)!.status,
        SceneStatus.online,
      );
      expect(
        liveStatusOf(c, api.devices[1].entityId)!.status,
        SceneStatus.warning,
      );
      expect(
        liveStatusOf(c, api.devices[2].entityId)!.status,
        SceneStatus.offline,
      );
      api.devices = [
        device(
          'x',
          'X',
          'server',
          MonStatus.degraded,
          worst: MonSeverity.critical,
        ),
      ];
      await c.refresh();
      expect(liveStatusOf(c, 'x')!.status, SceneStatus.critical);
      up = false;
      await conn.refresh();
      expect(liveStatusOf(c, 'x')!.stale, isTrue);
    });
  });

  test('presentObject uses Monitoring state for resolved bindings only', () {
    final doc = exampleScene();
    final o = doc.objects.firstWhere((x) => x.assetId == 'cozy/pc_tower');
    final bound = o.copyWith(
      entityBinding: () =>
          const EntityBinding(entityId: '11111111-1111-4111-8111-111111111111'),
      demoState: () => null,
    );
    final snap = {
      '11111111-1111-4111-8111-111111111111': EntitySnapshot(
        id: '11111111-1111-4111-8111-111111111111',
        found: true,
        name: 'Сервер',
        fetchedAt: DateTime(2026),
      ),
    };
    const live = LiveStatus(
      status: SceneStatus.online,
      note: 'Данные от агента',
      lastContactAt: null,
      openIncidents: 0,
    );
    final p = presentObject(
      bound,
      doc.asset(o.assetId),
      snap,
      RegistryLink.live,
      live,
    );
    expect(p.status, SceneStatus.online);
    expect(p.note, 'Данные от агента');
    final none = presentObject(
      bound,
      doc.asset(o.assetId),
      snap,
      RegistryLink.live,
    );
    expect(
      none.status,
      SceneStatus.unknown,
      reason: 'no monitoring data → unknown, never online',
    );
    final stale = presentObject(
      bound,
      doc.asset(o.assetId),
      snap,
      RegistryLink.live,
      const LiveStatus(status: SceneStatus.online, note: 'x', stale: true),
    );
    expect(stale.stale, isTrue);
  });

  group('Monitoring UI', () {
    Future<(FakeMonitoringApi, MonitoringController, ConnectionController)>
    pump(WidgetTester tester, Size size, {bool online = true}) async {
      await tester.binding.setSurfaceSize(size);
      final conn = ConnectionController(
        clientFor(online ? healthyCore() : deadCore()),
      );
      await tester.runAsync(conn.refresh);
      final api = FakeMonitoringApi();
      final mon = MonitoringController(
        api,
        conn,
        cache: MemoryMonitoringCache(),
        interval: const Duration(hours: 1),
        autoPoll: false,
      );
      final regApi = FakeRegistryApi();
      final registry = RegistryController(regApi, conn);
      final scene = sceneControllerFor(connection: conn, registry: regApi);
      await tester.pumpWidget(
        AerHomeApp(
          connection: conn,
          registry: registry,
          scene: scene,
          section: AppSectionController(AppSection.monitoring),
          monitoring: mon,
        ),
      );
      await tester.pumpAndSettle();
      addTearDown(() async {
        conn.dispose();
        await tester.pumpWidget(const SizedBox());
        mon.dispose();
        registry.dispose();
        scene.dispose();
        await tester.binding.setSurfaceSize(null);
      });
      return (api, mon, conn);
    }

    for (final size in const [Size(1366, 768), Size(1920, 1080)]) {
      testWidgets('all tabs fit ${size.width.toInt()}×${size.height.toInt()}', (
        tester,
      ) async {
        await pump(tester, size);
        expect(find.byKey(const Key('mon-tile-devices')), findsOneWidget);
        expect(
          find.text('Сокет не найден (тест)'),
          findsOneWidget,
          reason: 'integration problem explained',
        );
        for (final tab in [
          'devices',
          'incidents',
          'logs',
          'agents',
          'overview',
        ]) {
          await tester.tap(find.byKey(Key('mon-tab-$tab')));
          await tester.pumpAndSettle();
        }
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets(
      'devices → diagnostics with chart gaps; unsupported metric is not 0',
      (tester) async {
        final (api, _, _) = await pump(tester, const Size(1366, 768));
        await tester.tap(find.byKey(const Key('mon-tab-devices')));
        await tester.pumpAndSettle();
        expect(
          find.byKey(Key('device-${api.devices[0].entityId}')),
          findsOneWidget,
        );
        expect(find.textContaining('CPU 12'), findsOneWidget);
        await tester.tap(find.byKey(Key('device-${api.devices[0].entityId}')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('diagnostics')), findsOneWidget);
        await tester.tap(find.text('Метрики'));
        await tester.pumpAndSettle();
        expect(
          find.textContaining('не поддерживается: Нет датчика'),
          findsOneWidget,
        );
        await tester.tap(find.text('Графики'));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('metric-chart')), findsOneWidget);
        await tester.tap(find.byKey(const Key('diagnostics-close')));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('incidents: filters and acknowledge', (tester) async {
      final (api, _, _) = await pump(tester, const Size(1366, 768));
      await tester.tap(find.byKey(const Key('mon-tab-incidents')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('incident-inc-1')), findsOneWidget);
      expect(
        find.byKey(const Key('incident-inc-2')),
        findsNothing,
        reason: 'resolved hidden in «Активные»',
      );
      await tester.tap(find.byKey(const Key('ack-inc-1')));
      await tester.pumpAndSettle();
      expect(api.acked, ['inc-1']);
      expect(find.byKey(const Key('ack-inc-1')), findsNothing);
      await tester.tap(find.byKey(const Key('inc-filter-resolved')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('incident-inc-2')), findsOneWidget);
    });

    testWidgets('logs: search, level filter, pagination, details with links', (
      tester,
    ) async {
      await pump(tester, const Size(1920, 1080));
      await tester.tap(find.byKey(const Key('mon-tab-logs')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('log-50')), findsOneWidget);
      await tester.dragUntilVisible(
        find.byKey(const Key('logs-more')),
        find.byType(ListView).last,
        const Offset(0, -400),
      );
      await tester.tap(find.byKey(const Key('logs-more')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('log-30')),
        findsOneWidget,
        reason: 'second page appended',
      );
      await tester.enterText(find.byKey(const Key('logs-search')), 'журнала 7');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('log-7')), findsOneWidget);
      expect(find.byKey(const Key('log-50')), findsNothing);
      await tester.enterText(find.byKey(const Key('logs-search')), '');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('log-50')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('log-details')), findsOneWidget);
      expect(find.byKey(const Key('log-open-incident')), findsOneWidget);
      expect(find.byKey(const Key('log-open-device')), findsOneWidget);
    });

    testWidgets('notifications bell: unread and read all', (tester) async {
      final (api, _, _) = await pump(tester, const Size(1366, 768));
      expect(find.text('2'), findsWidgets);
      await tester.tap(find.byKey(const Key('notifications-bell')));
      await tester.pumpAndSettle();
      expect(find.text('Бот перестал отвечать (тест)'), findsOneWidget);
      await tester.tap(find.byKey(const Key('notifications-read-all')));
      await tester.pumpAndSettle();
      expect(api.readAll, isTrue);
    });

    testWidgets('Core unavailable without cache: explained, no zeros', (
      tester,
    ) async {
      await pump(tester, const Size(1366, 768), online: false);
      expect(find.textContaining('Нет связи с Core'), findsWidgets);
      expect(find.byKey(const Key('mon-tile-devices')), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });
}
