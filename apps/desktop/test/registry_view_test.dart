import 'package:aer_home_desktop/src/app.dart';
import 'package:aer_home_desktop/src/core_api/core_client.dart';
import 'package:aer_home_desktop/src/state/app_section.dart';
import 'package:aer_home_desktop/src/state/connection_controller.dart';
import 'package:aer_home_desktop/src/state/registry_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';

import 'fake_registry_api.dart';
import 'fixtures.dart';
import 'scene/scene_fixtures.dart';

class Harness {
  Harness(this.api, this.connection, this.registry);
  final FakeRegistryApi api;
  final ConnectionController connection;
  final RegistryController registry;
}

Future<Harness> pumpDevices(
  WidgetTester tester, {
  FakeRegistryApi? api,
  MockClient? core,
}) async {
  await tester.binding.setSurfaceSize(const Size(1366, 768));
  final fake = api ?? FakeRegistryApi();
  final connection = ConnectionController(clientFor(core ?? healthyCore()));
  final registry = RegistryController(
    fake,
    connection,
    searchDebounce: const Duration(milliseconds: 10),
  );
  final scene = sceneControllerFor(connection: connection, registry: fake);
  addTearDown(scene.dispose);
  await tester.pumpWidget(
    AerHomeApp(
      connection: connection,
      registry: registry,
      scene: scene,
      section: AppSectionController(AppSection.devices),
    ),
  );
  await tester.runAsync(connection.refresh);
  await tester.pumpAndSettle();
  return Harness(fake, connection, registry);
}

Future<void> finish(WidgetTester tester, Harness h) async {
  h.connection.dispose();
  await tester.pumpWidget(const SizedBox());
  h.registry.dispose();
  await tester.binding.setSurfaceSize(null);
}

FakeRegistryApi seeded() {
  final api = FakeRegistryApi();
  api.seed(
    'Основной ПК',
    'computer',
    tags: ['home', 'dualboot'],
    address: '192.0.2.154',
  );
  api.seed('Сервер', 'server', tags: ['home']);
  api.seed('PICO', 'telegram_bot');
  return api;
}

Finder card(String name) => find.ancestor(
  of: find.text(name),
  matching: find.byWidgetPredicate(
    (w) => w.key is Key && '${w.key}'.contains('entity-'),
  ),
);

void main() {
  testWidgets('shows entities from Core as cards', (tester) async {
    final h = await pumpDevices(tester, api: seeded());

    expect(find.text('Устройства и сервисы'), findsOneWidget);
    expect(find.text('всего: 3'), findsOneWidget);
    expect(find.text('Основной ПК'), findsOneWidget);
    expect(find.text('192.0.2.154'), findsOneWidget);
    expect(find.text('dualboot'), findsOneWidget);
    expect(find.text('Telegram-бот'), findsOneWidget);
    expect(find.text('без адреса'), findsNWidgets(2));
    await finish(tester, h);
  });

  testWidgets('empty registry invites to add, no demo data is invented', (
    tester,
  ) async {
    final h = await pumpDevices(tester);
    expect(find.text('Пока ничего не добавлено'), findsOneWidget);
    expect(find.text('Добавить первый объект'), findsOneWidget);
    expect(h.api.entities, isEmpty);
    await finish(tester, h);
  });

  testWidgets('without Core the screen explains why and blocks adding', (
    tester,
  ) async {
    final api = seeded()
      ..failWith = const CoreUnreachable('Connection refused');
    final h = await pumpDevices(tester, api: api, core: deadCore());

    expect(find.text('Список устройств недоступен'), findsOneWidget);
    expect(find.textContaining('AER Core не отвечает'), findsOneWidget);
    final add = tester.widget<ButtonStyleButton>(
      find.byKey(const Key('action-add')),
    );
    expect(add.onPressed, isNull);
    await finish(tester, h);
  });

  testWidgets('cached list stays visible as stale when Core drops', (
    tester,
  ) async {
    final h = await pumpDevices(tester, api: seeded());
    h.api.failWith = const CoreUnreachable('Connection refused');
    await tester.runAsync(h.registry.reload);
    await tester.pump();

    expect(find.text('Основной ПК'), findsOneWidget);
    expect(find.textContaining('Изменения заблокированы'), findsOneWidget);
    await finish(tester, h);
  });

  testWidgets('search filters the list', (tester) async {
    final h = await pumpDevices(tester, api: seeded());
    await tester.enterText(find.byKey(const Key('registry-search')), 'pico');
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pumpAndSettle();

    expect(find.text('PICO'), findsOneWidget);
    expect(find.text('Основной ПК'), findsNothing);
    expect(find.text('всего: 1'), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('registry-search')),
      'нет такого',
    );
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pumpAndSettle();
    expect(find.text('Ничего не найдено'), findsOneWidget);
    await finish(tester, h);
  });

  testWidgets('type filter narrows the list', (tester) async {
    final h = await pumpDevices(tester, api: seeded());
    await tester.tap(find.byKey(const Key('registry-type-filter')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Сервер').last);
    await tester.pumpAndSettle();

    expect(find.text('всего: 1'), findsOneWidget);
    expect(find.text('Основной ПК'), findsNothing);
    await finish(tester, h);
  });

  testWidgets('wizard adds an object in three steps', (tester) async {
    final h = await pumpDevices(tester);
    await tester.tap(find.byKey(const Key('action-add')));
    await tester.pumpAndSettle();

    // Step 1: what.
    expect(find.text('Что добавляем?'), findsOneWidget);
    await tester.tap(find.byKey(const Key('type-telegram_bot')));
    await tester.pumpAndSettle();

    // Step 2: bot has no address field; only the name is required.
    expect(find.byKey(const Key('field-address')), findsNothing);
    await tester.tap(find.text('Далее'));
    await tester.pumpAndSettle();
    expect(find.text('Укажите название'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('field-name')), 'PICO');
    await tester.tap(find.text('Расширенные настройки'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('field-tags')),
      'Bots, telegram',
    );
    await tester.tap(find.text('Далее'));
    await tester.pumpAndSettle();

    // Step 3: summary, defaults explained, then save.
    expect(find.text('Подтверждение'), findsOneWidget);
    expect(find.text('bots, telegram'), findsOneWidget);
    expect(find.text('Heartbeat'), findsOneWidget);
    await tester.tap(find.byKey(const Key('wizard-save')));
    await tester.pumpAndSettle();

    expect(find.text('Добавить объект'), findsNothing);
    final saved = h.api.entities.values.single;
    expect(saved.name, 'PICO');
    expect(saved.tags, ['bots', 'telegram']);
    expect(saved.capabilities, ['monitoring.heartbeat']);
    expect(find.text('«PICO» добавлен'), findsOneWidget);
    expect(find.byKey(const Key('entity-details')), findsOneWidget);
    await finish(tester, h);
  });

  testWidgets(
    'wizard requires an address where the type needs one and shows server errors',
    (tester) async {
      final h = await pumpDevices(tester);
      await tester.tap(find.byKey(const Key('action-add')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('type-website')));
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(const Key('field-name')), 'Мой сайт');
      await tester.tap(find.text('Далее'));
      await tester.pumpAndSettle();
      expect(find.text('Для этого типа нужен адрес'), findsOneWidget);

      // Passes local checks but Core rejects it: the wizard returns to step 2.
      await tester.enterText(
        find.byKey(const Key('field-address')),
        'https://user@example.org',
      );
      await tester.tap(find.text('Далее'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('wizard-save')));
      await tester.pumpAndSettle();

      expect(find.text('Основные сведения'), findsOneWidget);
      expect(
        find.text('Не указывайте логин и пароль в адресе'),
        findsOneWidget,
      );
      expect(h.api.entities, isEmpty);
      await finish(tester, h);
    },
  );

  testWidgets('details show capabilities and relations; edit saves changes', (
    tester,
  ) async {
    final api = seeded();
    final h = await pumpDevices(tester, api: api);
    await tester.tap(find.text('Основной ПК'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('entity-details')), findsOneWidget);
    expect(find.text('Перезагрузка'), findsOneWidget); // capability label
    expect(find.text('Связей нет'), findsOneWidget);
    expect(find.textContaining('не отслеживается'), findsOneWidget);

    await tester.tap(find.byKey(const Key('action-edit')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('field-name')), 'Главный ПК');
    await tester.tap(find.byKey(const Key('edit-save')));
    await tester.pumpAndSettle();

    expect(find.text('Главный ПК'), findsWidgets);
    final e = api.entities.values.firstWhere((x) => x.type == 'computer');
    expect(e.name, 'Главный ПК');
    expect(e.revision, 2);
    await finish(tester, h);
  });

  testWidgets('edit conflict offers to reload the latest version', (
    tester,
  ) async {
    final api = seeded();
    final h = await pumpDevices(tester, api: api);
    await tester.tap(find.text('Сервер').first);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('action-edit')));
    await tester.pumpAndSettle();

    // Someone else edits the same object meanwhile.
    final id = api.entities.values.firstWhere((x) => x.name == 'Сервер').id;
    await api.update(id, 1, {'description': 'изменено в другом окне'});

    await tester.enterText(find.byKey(const Key('field-name')), 'Мой сервер');
    await tester.tap(find.byKey(const Key('edit-save')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Объект изменился'), findsOneWidget);

    await tester.tap(find.text('Обновить данные'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('field-name')), 'Мой сервер');
    await tester.tap(find.byKey(const Key('edit-save')));
    await tester.pumpAndSettle();
    expect(api.entities[id]!.name, 'Мой сервер');
    expect(api.entities[id]!.description, 'изменено в другом окне');
    await finish(tester, h);
  });

  testWidgets(
    'archive asks for confirmation, then restore from the archive view',
    (tester) async {
      final api = seeded();
      final h = await pumpDevices(tester, api: api);
      await tester.tap(find.text('PICO'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('action-archive')));
      await tester.pumpAndSettle();
      expect(find.text('Архивировать «PICO»?'), findsOneWidget);
      await tester.tap(find.byKey(const Key('confirm-archive')));
      await tester.pumpAndSettle();

      expect(find.text('всего: 2'), findsOneWidget);
      expect(find.textContaining('В архиве с'), findsOneWidget);

      await tester.tap(find.text('Архив'));
      await tester.pumpAndSettle();
      expect(find.text('в архиве: 1'), findsOneWidget);
      await tester.tap(find.text('PICO'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('action-restore')));
      await tester.pumpAndSettle();

      expect(api.entities.values.where((e) => e.archived), isEmpty);
      expect(find.text('Архив пуст'), findsOneWidget);
      await finish(tester, h);
    },
  );

  testWidgets(
    'relation can be added via picker and a cycle error is explained',
    (tester) async {
      final api = seeded();
      final h = await pumpDevices(tester, api: api);
      await tester.tap(find.text('PICO'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('action-add-relation')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('relation-pick')));
      await tester.pumpAndSettle();
      await tester.tap(
        find
            .descendant(
              of: find.byType(ListTile),
              matching: find.text('Сервер'),
            )
            .first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('relation-save')));
      await tester.pumpAndSettle();

      expect(find.text('работает на → Сервер'), findsOneWidget);

      // Reverse edge would close a cycle: Core says so, the dialog shows it.
      await tester.tap(find.text('Сервер').first);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('action-add-relation')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('relation-pick')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(ListTile),
          matching: find.text('PICO'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('relation-save')));
      await tester.pumpAndSettle();
      expect(find.textContaining('циклическую зависимость'), findsOneWidget);
      await finish(tester, h);
    },
  );

  testWidgets('capabilities can be changed', (tester) async {
    final api = seeded();
    final h = await pumpDevices(tester, api: api);
    await tester.tap(find.text('Основной ПК'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('action-capabilities')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('cap-power.wake')));
    await tester.tap(find.byKey(const Key('cap-power.reboot')));
    await tester.tap(find.byKey(const Key('caps-save')));
    await tester.pumpAndSettle();

    final pc = api.entities.values.firstWhere((e) => e.type == 'computer');
    expect(pc.capabilities, ['network.ping', 'power.wake']);
    expect(find.text('Wake-on-LAN'), findsOneWidget);
    await finish(tester, h);
  });
}
