import 'dart:convert';

import 'scene_document.dart';

/// A document failed to parse or validate. [issues] maps a JSON path
/// (e.g. `objects[3].position.x`) to a message, like Core's 422 details.
class SceneFormatException implements Exception {
  SceneFormatException(this.issues);
  final Map<String, String> issues;

  @override
  String toString() =>
      'SceneFormatException(${issues.entries.take(5).map((e) => '${e.key}: ${e.value}').join('; ')})';
}

final _uuid = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
);
final _assetId = RegExp(r'^[a-z0-9_]+(/[a-z0-9_.-]+)*$');
const _roomKinds = {
  'office',
  'living',
  'server',
  'network',
  'automation',
  'bedroom',
  'kitchen',
  'custom',
};
const _floors = {'oak', 'oak_warm', 'tile', 'carpet', 'concrete'};
const _walls = {'cream', 'milk', 'sand', 'beige'};
const _eps = 1e-6;

bool isUuid(String s) => _uuid.hasMatch(s);

/// Strict decoder/validator for scene format v1 — mirrors
/// core/internal/modules/scene/document.go so a document accepted by one side
/// is accepted by the other.
class SceneCodec {
  const SceneCodec();

  SceneDocument decodeString(String source) {
    final Object? json;
    try {
      json = jsonDecode(source);
    } on FormatException catch (e) {
      throw SceneFormatException({
        '': 'Документ сцены не является корректным JSON: ${e.message}',
      });
    }
    return decode(json);
  }

  SceneDocument decode(Object? json) {
    final issues = <String, String>{};
    void add(String path, String msg) => issues.putIfAbsent(path, () => msg);
    if (json is! Map<String, dynamic>) {
      throw SceneFormatException({'': 'Ожидается JSON-объект сцены'});
    }
    final version = json['schemaVersion'];
    if (version is! int || version < 1 || version > sceneSchemaVersion) {
      throw SceneFormatException({
        'schemaVersion':
            'Версия схемы $version не поддерживается (клиент понимает 1…$sceneSchemaVersion)',
      });
    }
    // Future: upgrade older versions here, step by step, before parsing.

    final r = _Reader(add);
    r.allowOnly('', json, const {
      'schemaVersion',
      'sceneId',
      'name',
      'demo',
      'projection',
      'assets',
      'rooms',
      'objects',
      'metadata',
    });
    final sceneId = r.str('sceneId', json['sceneId']);
    if (!isUuid(sceneId)) add('sceneId', 'Нужен UUID в нижнем регистре');
    final name = r.str('name', json['name'], min: 1, max: 120);
    final demo = r.boolean('demo', json['demo']);
    final projection = r.str('projection', json['projection']);
    if (projection != sceneProjection) {
      add('projection', 'Поддерживается только $sceneProjection');
    }
    final metadata = r.meta('metadata', json['metadata']);

    final assets = <SceneAsset>[];
    final assetIds = <String>{};
    for (final (i, a) in r.list('assets', json['assets'], max: 500).indexed) {
      final p = 'assets[$i]';
      if (a is! Map<String, dynamic>) {
        add(p, 'Ожидается объект');
        continue;
      }
      r.allowOnly(p, a, const {'id', 'label', 'footprint', 'height', 'art'});
      final id = r.str('$p.id', a['id']);
      if (!_assetId.hasMatch(id) || id.length > 64) {
        add('$p.id', 'Идентификатор ассета: латиница, цифры, _ . - и /');
      } else if (!assetIds.add(id)) {
        add('$p.id', 'Ассет «$id» объявлен дважды');
      }
      final fp = r.obj('$p.footprint', a['footprint'], const {'w', 'd'});
      final art = r.obj('$p.art', a['art'], const {'kind', 'ref', 'status'});
      final kind = r.str('$p.art.kind', art['kind']);
      final status = r.str('$p.art.status', art['status']);
      if (!{'procedural', 'sprite'}.contains(kind)) {
        add('$p.art.kind', 'procedural или sprite');
      }
      if (!{'placeholder', 'final'}.contains(status)) {
        add('$p.art.status', 'placeholder или final');
      }
      assets.add(
        SceneAsset(
          id: id,
          label: r.str('$p.label', a['label'], max: 120),
          footprint: Size2(
            r.num_('$p.footprint.w', fp['w'], 0.05, 50),
            r.num_('$p.footprint.d', fp['d'], 0.05, 50),
          ),
          height: r.num_('$p.height', a['height'], 0.01, 40),
          art: AssetArt(
            kind: kind,
            ref: r.str('$p.art.ref', art['ref'], min: 1, max: 128),
            status: status,
          ),
        ),
      );
    }

    final rooms = <SceneRoom>[];
    final roomList = r.list('rooms', json['rooms'], max: 64);
    if (roomList.isEmpty) add('rooms', 'Нужна хотя бы одна комната');
    for (final (i, m) in roomList.indexed) {
      final p = 'rooms[$i]';
      if (m is! Map<String, dynamic>) {
        add(p, 'Ожидается объект');
        continue;
      }
      r.allowOnly(p, m, const {
        'id',
        'name',
        'kind',
        'origin',
        'size',
        'wallHeight',
        'style',
        'metadata',
      });
      final id = r.str('$p.id', m['id']);
      if (!isUuid(id)) {
        add('$p.id', 'Нужен UUID в нижнем регистре');
      } else if (rooms.any((x) => x.id == id)) {
        add('$p.id', 'Комната с таким id уже есть');
      }
      final kind = r.str('$p.kind', m['kind']);
      if (!_roomKinds.contains(kind)) add('$p.kind', 'Неизвестный вид комнаты');
      final origin = r.obj('$p.origin', m['origin'], const {'x', 'y'});
      final size = r.obj('$p.size', m['size'], const {'w', 'd'});
      final style = r.obj('$p.style', m['style'], const {'floor', 'wall'});
      final floor = r.str('$p.style.floor', style['floor']);
      final wall = r.str('$p.style.wall', style['wall']);
      if (!_floors.contains(floor)) add('$p.style.floor', 'Неизвестный пол');
      if (!_walls.contains(wall)) add('$p.style.wall', 'Неизвестные стены');
      final room = SceneRoom(
        id: id,
        name: r.str('$p.name', m['name'], min: 1, max: 80),
        kind: kind,
        origin: Point2(
          r.num_('$p.origin.x', origin['x'], -500, 500),
          r.num_('$p.origin.y', origin['y'], -500, 500),
        ),
        size: Size2(
          r.num_('$p.size.w', size['w'], 1, 200),
          r.num_('$p.size.d', size['d'], 1, 200),
        ),
        wallHeight: r.num_('$p.wallHeight', m['wallHeight'], 0, 20),
        style: RoomStyle(floor: floor, wall: wall),
        metadata: r.meta('$p.metadata', m['metadata']),
      );
      for (final (j, other) in rooms.indexed) {
        if (_overlap(room, other)) add(p, 'Комната пересекается с rooms[$j]');
      }
      rooms.add(room);
    }
    final roomById = {for (final x in rooms) x.id: x};
    final assetById = {for (final x in assets) x.id: x};

    final objects = <SceneObject>[];
    final objectIds = <String>{};
    for (final (i, m)
        in r.list('objects', json['objects'], max: 2000).indexed) {
      final p = 'objects[$i]';
      if (m is! Map<String, dynamic>) {
        add(p, 'Ожидается объект');
        continue;
      }
      r.allowOnly(p, m, const {
        'id',
        'roomId',
        'assetId',
        'label',
        'position',
        'rotation',
        'scale',
        'layer',
        'entityBinding',
        'visualState',
        'metadata',
      });
      final id = r.str('$p.id', m['id']);
      if (!isUuid(id)) {
        add('$p.id', 'Нужен UUID в нижнем регистре');
      } else if (!objectIds.add(id)) {
        add('$p.id', 'Объект с таким id уже есть');
      }
      final roomId = r.str('$p.roomId', m['roomId']);
      final assetId = r.str('$p.assetId', m['assetId']);
      final room = roomById[roomId];
      final asset = assetById[assetId];
      if (room == null) add('$p.roomId', 'Комната не найдена');
      if (asset == null) add('$p.assetId', 'Ассет не объявлен в assets');
      final rotation = m['rotation'];
      if (rotation is! int || !const {0, 90, 180, 270}.contains(rotation)) {
        add('$p.rotation', 'Поворот: 0, 90, 180 или 270');
      }
      final layerName = r.str('$p.layer', m['layer']);
      final layer = SceneLayer.values
          .where((l) => l.name == layerName)
          .firstOrNull;
      if (layer == null) add('$p.layer', 'Слой: floor, object или wall');
      final pos = r.obj('$p.position', m['position'], const {'x', 'y', 'z'});

      EntityBinding? binding;
      final b = m['entityBinding'];
      if (b != null) {
        final bm = r.obj('$p.entityBinding', b, const {'entityId', 'role'});
        final entityId = r.str('$p.entityBinding.entityId', bm['entityId']);
        if (!isUuid(entityId)) {
          add('$p.entityBinding.entityId', 'Нужен UUID сущности Registry');
        }
        final role = BindingRole.values
            .where((x) => x.name == bm['role'])
            .firstOrNull;
        if (role == null) add('$p.entityBinding.role', 'primary или secondary');
        binding = EntityBinding(
          entityId: entityId,
          role: role ?? BindingRole.primary,
        );
      }
      SceneStatus? demoState;
      final vs = m['visualState'];
      if (vs != null) {
        final vm = r.obj('$p.visualState', vs, const {'demo'});
        demoState = SceneStatus.values
            .where((x) => x.name == vm['demo'])
            .firstOrNull;
        if (demoState == null) {
          add('$p.visualState.demo', 'Неизвестное состояние');
        } else if (!demo) {
          add(
            '$p.visualState',
            'Тестовые состояния допустимы только в демо-сцене',
          );
        } else if (binding != null) {
          add(
            '$p.visualState',
            'У привязанного объекта не может быть тестового состояния',
          );
        }
      }
      final obj = SceneObject(
        id: id,
        roomId: roomId,
        assetId: assetId,
        label: r.str('$p.label', m['label'], max: 120),
        position: Point3(
          r.num_('$p.position.x', pos['x'], 0, 200),
          r.num_('$p.position.y', pos['y'], 0, 200),
          r.num_('$p.position.z', pos['z'], 0, 40),
        ),
        rotation: rotation is int ? rotation : 0,
        scale: r.num_('$p.scale', m['scale'], 0.25, 4),
        layer: layer ?? SceneLayer.object,
        entityBinding: binding,
        demoState: demoState,
        metadata: r.meta('$p.metadata', m['metadata']),
      );
      if (room != null && asset != null) {
        final fp = obj.footprint(asset);
        if (obj.position.x + fp.w > room.size.w + _eps ||
            obj.position.y + fp.d > room.size.d + _eps) {
          add(
            '$p.position',
            'Объект выходит за пределы комнаты «${room.name}»',
          );
        }
      }
      objects.add(obj);
    }

    if (issues.isNotEmpty) throw SceneFormatException(issues);
    return SceneDocument(
      sceneId: sceneId,
      name: name,
      demo: demo,
      assets: assets,
      rooms: rooms,
      objects: objects,
      metadata: metadata,
    );
  }

  /// Validates a document built in code (e.g. after an edit operation).
  void validate(SceneDocument doc) => decode(jsonDecode(encode(doc)));

  String encode(SceneDocument doc) => jsonEncode(doc.toJson());
}

bool _overlap(SceneRoom a, SceneRoom b) =>
    a.origin.x < b.origin.x + b.size.w - _eps &&
    b.origin.x < a.origin.x + a.size.w - _eps &&
    a.origin.y < b.origin.y + b.size.d - _eps &&
    b.origin.y < a.origin.y + a.size.d - _eps;

/// Typed accessors that record issues instead of throwing.
class _Reader {
  _Reader(this.add);
  final void Function(String, String) add;

  void allowOnly(String p, Map<String, dynamic> m, Set<String> keys) {
    for (final k in m.keys) {
      if (!keys.contains(k)) {
        add(p.isEmpty ? k : '$p.$k', 'Поле не предусмотрено схемой v1');
      }
    }
    for (final k in keys) {
      if (!m.containsKey(k)) add(p.isEmpty ? k : '$p.$k', 'Обязательное поле');
    }
  }

  String str(String p, Object? v, {int min = 0, int max = 1 << 20}) {
    if (v is! String) {
      add(p, 'Ожидается строка');
      return '';
    }
    final n = v.runes.length;
    if (n < min || n > max) {
      add(p, min > 0 && n == 0 ? 'Обязательное поле' : 'Длина от $min до $max');
    }
    return v;
  }

  bool boolean(String p, Object? v) {
    if (v is! bool) add(p, 'Ожидается true/false');
    return v == true;
  }

  // ignore: non_constant_identifier_names
  double num_(String p, Object? v, double lo, double hi) {
    if (v is! num || v.isNaN || v.isInfinite) {
      add(p, 'Ожидается число');
      return lo;
    }
    if (v < lo - _eps || v > hi + _eps) {
      add(p, 'Значение должно быть в диапазоне $lo…$hi');
    }
    return v.toDouble();
  }

  List<Object?> list(String p, Object? v, {required int max}) {
    if (v is! List) {
      add(p, 'Ожидается массив');
      return const [];
    }
    if (v.length > max) add(p, 'Не больше $max элементов');
    return v;
  }

  Map<String, dynamic> obj(String p, Object? v, Set<String> keys) {
    if (v is! Map<String, dynamic>) {
      add(p, 'Ожидается объект');
      return const {};
    }
    allowOnly(p, v, keys);
    return v;
  }

  Map<String, String> meta(String p, Object? v) {
    if (v is! Map<String, dynamic>) {
      add(p, 'Ожидается объект');
      return const {};
    }
    if (v.length > 16) add(p, 'Не больше 16 записей');
    final out = <String, String>{};
    for (final e in v.entries) {
      if (e.value is! String ||
          e.key.isEmpty ||
          e.key.length > 64 ||
          (e.value as String).length > 512) {
        add('$p.${e.key}', 'Ключ до 64 символов, строковое значение до 512');
      } else {
        out[e.key] = e.value as String;
      }
    }
    return out;
  }
}
