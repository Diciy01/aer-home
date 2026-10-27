import 'dart:convert';

import 'package:aer_home_desktop/src/app.dart';
import 'package:aer_home_desktop/src/core_api/bots_api.dart';
import 'package:aer_home_desktop/src/core_api/monitoring_api.dart';
import 'package:aer_home_desktop/src/features/bots/bot_details.dart';
import 'package:aer_home_desktop/src/features/bots/bot_scene_panel.dart';
import 'package:aer_home_desktop/src/state/app_section.dart';
import 'package:aer_home_desktop/src/state/bots_controller.dart';
import 'package:aer_home_desktop/src/state/connection_controller.dart';
import 'package:aer_home_desktop/src/state/monitoring_controller.dart';
import 'package:aer_home_desktop/src/state/registry_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../fake_registry_api.dart';
import '../fixtures.dart';
import '../monitoring/fake_monitoring_api.dart';
import '../scene/scene_fixtures.dart';
import 'fake_bots_api.dart';

void main() {
  group('BotsController', () {
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
      'loads, filters on the client, marks stale data, reloads archive',
      () async {
        final api = FakeBotsApi();
        final c = BotsController(api, conn, autoPoll: false);
        addTearDown(c.dispose);
        await c.start();
        expect(c.all, hasLength(3));
        expect(c.adapters, hasLength(3));
        expect(c.botFor('bot-2')!.controllerId, 'testproc');
        expect(
          c.botFor('nope'),
          isNull,
          reason: 'non-bot entities get no bot panel',
        );

        c.filter = c.filter.copyWith(status: () => MonStatus.degraded);
        expect(c.visible.map((b) => b.entityId), ['bot-2']);
        c.filter = const BotFilter(query: 'тест дом');
        expect(c.visible.map((b) => b.entityId), [
          'bot-1',
        ], reason: 'all words must match');
        c.filter = const BotFilter(runtime: 'n8n');
        expect(c.visible.single.name, 'n8n (тест)');

        up = false;
        await conn.refresh();
        expect(c.isStale, isTrue);
        expect(c.all, hasLength(3), reason: 'last known list kept');

        up = true;
        await conn.refresh();
        c.filter = const BotFilter(archived: true);
        await c.refresh();
        await c.refresh(); // the queued re-run after an in-flight refresh
        expect(api.lastArchived, 'true');
        expect(c.all, isEmpty);
      },
    );
  });

  test(
    'HttpBotsApi sends Idempotency-Key and parses contract payloads',
    () async {
      final seen = <http.Request>[];
      final botJson = {
        'entityId': 'e1',
        'runtime': 'python',
        'category': '',
        'controllerId': 'p',
        'n8nInstanceId': '',
        'n8nWorkflowIds': [],
        'telegramTokenId': '',
        'container': '',
        'heartbeatIntervalSec': 15,
        'heartbeatTimeoutSec': 60,
        'logSource': 'controller',
        'notes': '',
        'revision': 2,
        'createdAt': '2026-10-27T10:00:00Z',
        'updatedAt': '2026-10-27T10:00:00Z',
        'name': 'Тест',
        'type': 'process',
        'description': '',
        'tags': ['a'],
        'archived': false,
        'entityRevision': 1,
        'host': null,
        'status': 'online',
        'statusReason': 'ok',
        'lastContactAt': null,
        'openIncidents': 0,
        'heartbeat': {
          'credentials': 0,
          'active': false,
          'lastSeenAt': null,
          'intervalSec': 15,
          'timeoutSec': 60,
          'library': '',
        },
        'version': '',
        'startedAt': null,
        'uptimeSec': null,
        'lastError': '',
        'lastErrorAt': null,
        'lastSuccessAt': null,
        'apiOk': null,
        'cpuPercent': 1.5,
        'memBytes': null,
        'runtimeState': {
          'adapter': 'process',
          'state': 'stopped',
          'since': null,
          'reason': 'нет',
        },
        'lastJobOk': null,
        'lastJobFailed': null,
        'jobs': {'success24h': 1, 'failed24h': 0, 'running': 0},
        'dependencies': [],
        'crashes': [],
        'restarts': [],
        'integration': null,
        'actions': [
          {
            'id': 'stop',
            'label': 'Остановить',
            'available': true,
            'reason': '',
            'confirm': true,
            'risk': 'r',
          },
        ],
      };
      final api = HttpBotsApi(
        clientFor(
          MockClient((r) async {
            seen.add(r);
            if (r.url.path.endsWith('/actions/stop')) {
              return jsonResponse(
                envelope({
                  'id': 'x',
                  'entityId': 'e1',
                  'action': 'stop',
                  'jobId': '',
                  'adapter': 'process:p',
                  'status': 'succeeded',
                  'message': 'ok',
                  'idempotencyKey': r.headers['Idempotency-Key'],
                  'requestedAt': '2026-10-27T10:00:00Z',
                  'finishedAt': '2026-10-27T10:00:01Z',
                  'replayed': false,
                }),
              );
            }
            if (r.method == 'POST' && r.url.path == '/api/v1/bots') {
              return jsonResponse(
                envelope({'bot': botJson, 'heartbeatToken': 'aer1.x'}),
                201,
              );
            }
            return jsonResponse(envelope(botJson));
          }),
        ),
      );
      final d = await api.get('e1');
      expect(d.bot.runtimeState!.state, 'stopped');
      expect(d.bot.cpuPercent, 1.5);
      expect(d.bot.success24h, 1);
      expect(d.action('stop')!.available, isTrue);
      final rec = await api.execute(
        'e1',
        'stop',
        idempotencyKey: 'key-123456',
        confirmationToken: 'tok',
      );
      expect(rec.status, 'succeeded');
      expect(seen.last.headers['Idempotency-Key'], 'key-123456');
      expect(jsonDecode(seen.last.body), {'confirmationToken': 'tok'});
      final (_, token) = await api.create(
        BotDraft(name: 'Тест', type: 'process'),
      );
      expect(token, 'aer1.x');
      final body = jsonDecode(seen.last.body) as Map<String, dynamic>;
      expect(body['name'], 'Тест');
      expect(body.containsKey('entityId'), isFalse);
      expect(newIdempotencyKey(), isNot(newIdempotencyKey()));
    },
  );

  group('Bots UI', () {
    Future<(FakeBotsApi, BotsController)> pump(
      WidgetTester tester, {
      Size size = const Size(1366, 768),
    }) async {
      await tester.binding.setSurfaceSize(size);
      final conn = ConnectionController(clientFor(healthyCore()));
      await tester.runAsync(conn.refresh);
      final mon = MonitoringController(
        FakeMonitoringApi(),
        conn,
        cache: MemoryMonitoringCache(),
        autoPoll: false,
      );
      final api = FakeBotsApi();
      final bots = BotsController(api, conn, autoPoll: false);
      final regApi = FakeRegistryApi();
      final registry = RegistryController(regApi, conn);
      final scene = sceneControllerFor(connection: conn, registry: regApi);
      await tester.pumpWidget(
        AerHomeApp(
          connection: conn,
          registry: registry,
          scene: scene,
          section: AppSectionController(AppSection.bots),
          monitoring: mon,
          bots: bots,
        ),
      );
      await tester.pumpAndSettle();
      addTearDown(() async {
        conn.dispose();
        await tester.pumpWidget(const SizedBox());
        mon.dispose();
        bots.dispose();
        registry.dispose();
        scene.dispose();
        await tester.binding.setSurfaceSize(null);
      });
      return (api, bots);
    }

    for (final size in const [Size(1366, 768), Size(1920, 1080)]) {
      testWidgets(
        'list, search, filters and every bot tab fit ${size.width.toInt()}',
        (tester) async {
          await pump(tester, size: size);
          expect(find.text('Боты'), findsWidgets);
          for (final id in ['bot-1', 'bot-2', 'bot-3']) {
            expect(find.byKey(Key('bot-$id')), findsOneWidget);
          }
          expect(find.text('только мониторинг'), findsNWidgets(2));
          expect(
            find.textContaining('Ошибка: тестовая ошибка API'),
            findsOneWidget,
          );

          await tester.enterText(find.byKey(const Key('bots-search')), 'отчёт');
          await tester.pumpAndSettle();
          expect(find.byKey(const Key('bot-bot-1')), findsNothing);
          expect(find.byKey(const Key('bot-bot-2')), findsOneWidget);
          await tester.enterText(find.byKey(const Key('bots-search')), '');
          await tester.tap(find.byKey(const Key('bots-filter-offline')));
          await tester.pumpAndSettle();
          expect(find.byKey(const Key('bot-bot-3')), findsOneWidget);
          expect(find.byKey(const Key('bot-bot-1')), findsNothing);
          await tester.tap(find.byKey(const Key('bots-filter-offline')));
          await tester.pumpAndSettle();

          await tester.tap(find.byKey(const Key('bot-bot-3')));
          await tester.pumpAndSettle();
          expect(find.byKey(const Key('bot-details')), findsOneWidget);
          for (final tab in BotTab.values) {
            await tester.tap(find.byKey(Key('bot-tab-${tab.name}')));
            await tester.pumpAndSettle();
          }
          expect(find.textContaining('Сервис n8n не отвечает'), findsOneWidget);
          expect(tester.takeException(), isNull);
        },
      );
    }

    testWidgets(
      'monitoring-only bot: management buttons disabled with the reason',
      (tester) async {
        final (api, _) = await pump(tester);
        await tester.tap(find.byKey(const Key('bot-bot-1')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('bot-tab-control')));
        await tester.pumpAndSettle();
        for (final a in ['start', 'stop', 'restart']) {
          final b = tester.widget<ButtonStyleButton>(
            find.byKey(Key('bot-action-$a')),
          );
          expect(b.onPressed, isNull, reason: '$a must be unavailable');
        }
        expect(find.textContaining('Только мониторинг'), findsWidgets);
        expect(api.confirms, isEmpty);
      },
    );

    testWidgets(
      'restart asks Core for a confirmation; cancel runs nothing, confirm runs once',
      (tester) async {
        final (api, _) = await pump(tester);
        await tester.tap(find.byKey(const Key('bot-bot-2')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('bot-tab-control')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('bot-action-restart')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('bot-confirm')), findsOneWidget);
        expect(find.text('Бот будет недоступен (тест)'), findsOneWidget);
        await tester.tap(find.text('Отмена'));
        await tester.pumpAndSettle();
        expect(api.executed, isEmpty, reason: 'cancel must not run anything');

        await tester.tap(find.byKey(const Key('bot-action-restart')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('bot-confirm-ok')));
        await tester.pumpAndSettle();
        expect(api.executed, hasLength(1));
        final (id, action, key, token) = api.executed.single;
        expect((id, action, token), ('bot-2', 'restart', 'confirm-restart'));
        expect(key, startsWith('ui-'));
        expect(find.textContaining('Готово: Выполнено (тест)'), findsOneWidget);

        // Read-only check runs without a confirmation dialog.
        await tester.tap(find.byKey(const Key('bot-action-check')));
        await tester.pumpAndSettle();
        expect(api.executed.last.$2, 'check');
        expect(api.executed.last.$4, isNull);
        expect(api.confirms, ['bot-2/restart/', 'bot-2/restart/']);
      },
    );

    testWidgets('n8n job retry needs a confirmation', (tester) async {
      final (api, _) = await pump(tester);
      await tester.tap(find.byKey(const Key('bot-bot-3')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('bot-tab-jobs')));
      await tester.pumpAndSettle();
      expect(find.text('Рассылка (тест)'), findsOneWidget);
      await tester.tap(find.byKey(const Key('job-retry-j2')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('bot-confirm-ok')));
      await tester.pumpAndSettle();
      expect(api.confirms.single, 'bot-3/job.retry/j2');
      expect(api.executed.single.$2, 'job.retry');
    });

    testWidgets(
      'wizard: four steps, busy controller disabled, token shown once',
      (tester) async {
        final (api, _) = await pump(tester);
        await tester.tap(find.byKey(const Key('bots-add')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('bot-wizard-next')));
        await tester.pumpAndSettle();
        expect(find.text('Укажите название'), findsOneWidget);
        await tester.tap(find.byKey(const Key('bot-type-process')));
        await tester.enterText(
          find.byKey(const Key('bot-wizard-name')),
          'Новый бот (тест)',
        );
        await tester.enterText(
          find.byKey(const Key('bot-wizard-category')),
          'работа',
        );
        await tester.tap(find.byKey(const Key('bot-wizard-next')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('bot-wizard-next')));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const Key('bot-wizard-interval')),
          '40',
        );
        await tester.tap(find.byKey(const Key('bot-wizard-next')));
        await tester.pumpAndSettle();
        expect(
          find.text('Тайм-аут должен быть не меньше двух интервалов'),
          findsOneWidget,
        );
        await tester.enterText(
          find.byKey(const Key('bot-wizard-interval')),
          '20',
        );
        await tester.tap(find.byKey(const Key('bot-wizard-next')));
        await tester.pumpAndSettle();

        final busy = tester.widget<RadioListTile<String>>(
          find.byKey(const Key('bot-ctl-testproc')),
        );
        expect(
          busy.enabled,
          isFalse,
          reason: 'a controller used by another bot is not offered',
        );
        await tester.tap(find.byKey(const Key('bot-ctl-spare')));
        await tester.pumpAndSettle();
        expect(find.textContaining('управление: spare'), findsOneWidget);
        await tester.tap(find.byKey(const Key('bot-wizard-save')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('bot-token')), findsOneWidget);
        expect(find.text('aer1.test-token-not-a-secret'), findsOneWidget);
        await tester.tap(find.text('Готово'));
        await tester.pumpAndSettle();
        final j = api.created.single;
        expect(j['name'], 'Новый бот (тест)');
        expect(j['type'], 'process');
        expect(j['controllerId'], 'spare');
        expect(j['heartbeatIntervalSec'], 20);
        expect(j['createCredential'], isTrue);
        expect(
          find.byKey(const Key('bot-details')),
          findsOneWidget,
          reason: 'opens the new bot',
        );
      },
    );

    testWidgets('edit keeps the revision for optimistic locking', (
      tester,
    ) async {
      final (api, _) = await pump(tester);
      await tester.tap(find.byKey(const Key('bot-bot-2')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('bot-tab-integration')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('bot-edit')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('bot-wizard-category')),
        'отчёты',
      );
      for (var i = 0; i < 3; i++) {
        await tester.tap(find.byKey(const Key('bot-wizard-next')));
        await tester.pumpAndSettle();
      }
      await tester.tap(find.byKey(const Key('bot-wizard-save')));
      await tester.pumpAndSettle();
      expect(api.patched.single['revision'], 1);
      expect(api.patched.single['category'], 'отчёты');
      expect(api.patched.single['controllerId'], 'testproc');
    });
  });

  testWidgets('house panel: bot state, errors link and confirmed controls', (
    tester,
  ) async {
    final conn = ConnectionController(clientFor(healthyCore()));
    await tester.runAsync(conn.refresh);
    final api = FakeBotsApi();
    final bots = BotsController(api, conn, autoPoll: false);
    await tester.runAsync(bots.start);
    BotTab? opened;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 340,
            child: BotScenePanel(
              bots: bots,
              bot: bots.botFor('bot-2')!,
              onOpen: (t) => opened = t,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('scene-bot-error')), findsOneWidget);
    await tester.tap(find.byKey(const Key('scene-bot-errors')));
    expect(opened, BotTab.errors);
    await tester.tap(find.byKey(const Key('bot-action-stop')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('bot-confirm-ok')));
    await tester.pumpAndSettle();
    expect(api.executed.single.$2, 'stop');
    addTearDown(() {
      bots.dispose();
      conn.dispose();
    });
  });
}
