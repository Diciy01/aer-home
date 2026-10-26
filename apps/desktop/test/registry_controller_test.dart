import 'package:aer_home_desktop/src/core_api/core_client.dart';
import 'package:aer_home_desktop/src/core_api/registry_models.dart';
import 'package:aer_home_desktop/src/state/connection_controller.dart';
import 'package:aer_home_desktop/src/state/registry_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_registry_api.dart';
import 'fixtures.dart';

void main() {
  late FakeRegistryApi api;
  late ConnectionController connection;
  late RegistryController registry;

  setUp(() async {
    api = FakeRegistryApi();
    api.seed('Основной ПК', 'computer', tags: ['home']);
    api.seed('Сервер', 'server', tags: ['home']);
    api.seed('PICO', 'telegram_bot');
    connection = ConnectionController(clientFor(healthyCore()));
    registry = RegistryController(
      api,
      connection,
      searchDebounce: Duration.zero,
    );
    await connection.refresh();
    await registry.reload();
  });

  tearDown(() {
    registry.dispose();
    connection.dispose();
  });

  test('loads catalog and entities sorted by name', () {
    expect(registry.catalog, isNotNull);
    expect(registry.items.map((e) => e.name), [
      'PICO',
      'Основной ПК',
      'Сервер',
    ]);
    expect(registry.total, 3);
    expect(registry.canEdit, isTrue);
  });

  test('type filter and search narrow the list', () async {
    registry.setTypeFilter('server');
    await pumpEventQueue();
    expect(registry.items.map((e) => e.name), ['Сервер']);

    registry.setTypeFilter(null);
    registry.setSearch('основной');
    await Future<void>.delayed(Duration.zero);
    await pumpEventQueue();
    expect(registry.items.map((e) => e.name), ['Основной ПК']);
  });

  test('failed reload keeps previous items and marks them stale', () async {
    api.failWith = const CoreUnreachable('Connection refused');
    await registry.reload();
    expect(registry.items, hasLength(3));
    expect(registry.error, isA<CoreUnreachable>());
    expect(registry.isStale, isTrue);
  });

  test('create, update, archive and restore keep the list in sync', () async {
    final e = await registry.create(
      const EntityDraft(name: 'Роутер', type: 'server'),
    );
    expect(registry.selected?.id, e.id);
    expect(registry.total, 4);

    final updated = await registry.update(e, {'name': 'Домашний роутер'});
    expect(updated.revision, 2);
    expect(registry.items.any((x) => x.name == 'Домашний роутер'), isTrue);

    await registry.archive(updated);
    expect(
      registry.items.any((x) => x.id == e.id),
      isFalse,
      reason: 'hidden from active list',
    );
    expect(registry.selected?.archived, isTrue);

    registry.setArchivedView(true);
    await pumpEventQueue();
    expect(registry.items.single.id, e.id);
    await registry.restore(registry.items.single);
    expect(registry.items, isEmpty);
  });

  test('stale revision surfaces as conflict', () async {
    final e = registry.items.first;
    await registry.update(e, {'name': 'Новое имя'});
    await expectLater(
      registry.update(e, {'name': 'Ещё одно'}),
      throwsA(
        isA<CoreApiException>().having(
          (x) => x.conflictReason,
          'reason',
          'revision_mismatch',
        ),
      ),
    );
  });

  test('relations are loaded for the selection and updated', () async {
    final bot = registry.items.firstWhere((e) => e.name == 'PICO');
    final server = registry.items.firstWhere((e) => e.name == 'Сервер');
    await registry.select(bot);
    expect(registry.relations, isEmpty);
    await registry.addRelation(bot, 'runs_on', server.id);
    expect(registry.relations.single.peer.name, 'Сервер');
    await registry.deleteRelation(registry.relations.single.relation.id);
    expect(registry.relations, isEmpty);
  });

  test('editing is disabled without Core', () async {
    final offline = ConnectionController(clientFor(deadCore()));
    addTearDown(offline.dispose);
    final r = RegistryController(api, offline);
    addTearDown(r.dispose);
    await offline.refresh();
    await r.reload();
    expect(r.canEdit, isFalse);
  });
}
