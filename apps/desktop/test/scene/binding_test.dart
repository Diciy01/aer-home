import 'package:aer_home_desktop/src/scene/binding/scene_binding.dart';
import 'package:aer_home_desktop/src/scene/model/scene_document.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const asset = SceneAsset(
    id: 'cozy/pc_tower',
    label: 'Системный блок',
    footprint: Size2(1, 1),
    height: 1,
    art: AssetArt(
      kind: 'procedural',
      ref: 'cozy/pc_tower',
      status: 'placeholder',
    ),
  );
  const entityId = '44444444-4444-4444-8444-444444444444';
  SceneObject obj({EntityBinding? binding, SceneStatus? demo}) => SceneObject(
    id: '55555555-5555-4555-8555-555555555555',
    roomId: 'r',
    assetId: asset.id,
    label: 'ПК',
    position: const Point3(0, 0, 0),
    entityBinding: binding,
    demoState: demo,
  );
  final at = DateTime.utc(2026, 10, 26);
  EntitySnapshot snap({bool found = true, bool archived = false}) =>
      EntitySnapshot(
        id: entityId,
        found: found,
        name: 'Основной ПК',
        type: 'computer',
        typeLabel: 'Компьютер',
        archived: archived,
        capabilities: const ['power.wake'],
        capabilityLabels: const {'power.wake': 'Wake-on-LAN'},
        fetchedAt: at,
      );
  const bound = EntityBinding(entityId: entityId);

  test('decor has no status at all', () {
    final p = presentObject(obj(), asset, const {}, RegistryLink.live);
    expect(p.status, isNull);
    expect(p.binding, BindingState.unbound);
  });

  test('demo state is shown and marked as test data', () {
    final p = presentObject(
      obj(demo: SceneStatus.online),
      asset,
      const {},
      RegistryLink.live,
    );
    expect(p.status, SceneStatus.online);
    expect(p.isDemo, isTrue);
  });

  test('existing entity: Registry name, unknown state — never online', () {
    final p = presentObject(obj(binding: bound), asset, {
      entityId: snap(),
    }, RegistryLink.live);
    expect(p.title, 'Основной ПК');
    expect(p.subtitle, 'Компьютер');
    expect(p.status, SceneStatus.unknown);
    expect(p.isDemo, isFalse);
    expect(p.stale, isFalse);
  });

  test('missing entity is reported, object stays', () {
    final p = presentObject(obj(binding: bound), asset, {
      entityId: snap(found: false),
    }, RegistryLink.live);
    expect(p.binding, BindingState.missing);
    expect(p.status, SceneStatus.unknown);
    expect(p.title, 'ПК');
  });

  test('archived entity shows archived', () {
    final p = presentObject(obj(binding: bound), asset, {
      entityId: snap(archived: true),
    }, RegistryLink.live);
    expect(p.status, SceneStatus.archived);
    expect(p.binding, BindingState.archived);
  });

  test(
    'without Core: cached snapshot is stale; nothing cached → unavailable',
    () {
      final cached = presentObject(obj(binding: bound), asset, {
        entityId: snap(),
      }, RegistryLink.stale);
      expect(cached.stale, isTrue);
      expect(cached.title, 'Основной ПК');
      final none = presentObject(
        obj(binding: bound),
        asset,
        const {},
        RegistryLink.unavailable,
      );
      expect(none.binding, BindingState.unavailable);
      expect(none.status, SceneStatus.unknown);
    },
  );

  test('loading while Registry answers', () {
    final p = presentObject(
      obj(binding: bound),
      asset,
      const {},
      RegistryLink.loading,
    );
    expect(p.status, SceneStatus.loading);
  });

  test('snapshot JSON round trip', () {
    final s = snap();
    final again = EntitySnapshot.fromJson(s.toJson());
    expect(again.name, s.name);
    expect(again.capabilities, s.capabilities);
    expect(
      again.capabilityLabels['power.wake'],
      'Wake-on-LAN',
      reason: 'labels survive offline',
    );
    expect(again.fetchedAt, s.fetchedAt);
  });
}
