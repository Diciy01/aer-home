import 'scene_codec.dart';
import 'scene_document.dart';

/// Pure scene edit operations (used by the M04 editor commands). Each returns
/// a new validated document (or throws [SceneFormatException]) and never
/// mutates its input, so undo/redo is "keep the previous document".
class SceneEdits {
  const SceneEdits([this._codec = const SceneCodec()]);
  final SceneCodec _codec;

  SceneDocument _checked(SceneDocument doc) {
    _codec.validate(doc);
    return doc;
  }

  SceneDocument addRoom(SceneDocument doc, SceneRoom room) =>
      _checked(doc.copyWith(rooms: [...doc.rooms, room]));

  /// Removes a room together with the objects placed in it.
  SceneDocument removeRoom(SceneDocument doc, String roomId) => _checked(
    doc.copyWith(
      rooms: [
        for (final r in doc.rooms)
          if (r.id != roomId) r,
      ],
      objects: [
        for (final o in doc.objects)
          if (o.roomId != roomId) o,
      ],
    ),
  );

  /// Adds a room together with its objects in one validated step.
  SceneDocument addRoomWithObjects(
    SceneDocument doc,
    SceneRoom room,
    List<SceneObject> objects,
  ) => _checked(
    doc.copyWith(
      rooms: [...doc.rooms, room],
      objects: [...doc.objects, ...objects],
    ),
  );

  /// Generic room change (rename, move, resize, style, kind).
  SceneDocument updateRoom(
    SceneDocument doc,
    String roomId,
    SceneRoom Function(SceneRoom) fn,
  ) => _replaceRoom(doc, roomId, fn);

  /// Declares [asset] if the document does not have it yet. An existing
  /// declaration is kept as is (documents are self-contained).
  SceneDocument declareAsset(SceneDocument doc, SceneAsset asset) =>
      doc.asset(asset.id) != null
      ? doc
      : doc.copyWith(assets: [...doc.assets, asset]);

  /// Generic object change (move, rotate, scale, label, metadata).
  SceneDocument updateObject(
    SceneDocument doc,
    String objectId,
    SceneObject Function(SceneObject) fn,
  ) => _replaceObject(doc, objectId, fn);

  SceneDocument resizeRoom(SceneDocument doc, String roomId, Size2 size) =>
      _replaceRoom(doc, roomId, (r) => r.copyWith(size: size));

  SceneDocument moveRoom(SceneDocument doc, String roomId, Point2 origin) =>
      _replaceRoom(doc, roomId, (r) => r.copyWith(origin: origin));

  SceneDocument addObject(SceneDocument doc, SceneObject object) =>
      _checked(doc.copyWith(objects: [...doc.objects, object]));

  SceneDocument removeObject(SceneDocument doc, String objectId) => _checked(
    doc.copyWith(
      objects: [
        for (final o in doc.objects)
          if (o.id != objectId) o,
      ],
    ),
  );

  SceneDocument moveObject(
    SceneDocument doc,
    String objectId,
    Point3 position, {
    String? roomId,
  }) => _replaceObject(
    doc,
    objectId,
    (o) => o.copyWith(position: position, roomId: roomId),
  );

  SceneDocument rotateObject(
    SceneDocument doc,
    String objectId,
    int rotation,
  ) => _replaceObject(doc, objectId, (o) => o.copyWith(rotation: rotation));

  SceneDocument scaleObject(SceneDocument doc, String objectId, double scale) =>
      _replaceObject(doc, objectId, (o) => o.copyWith(scale: scale));

  SceneDocument setLayer(
    SceneDocument doc,
    String objectId,
    SceneLayer layer,
  ) => _replaceObject(doc, objectId, (o) => o.copyWith(layer: layer));

  /// Binds to a Registry entity UUID; a demo state is dropped because a bound
  /// object shows only real (or unknown) state.
  SceneDocument bindEntity(
    SceneDocument doc,
    String objectId,
    String entityId, {
    BindingRole role = BindingRole.primary,
  }) => _replaceObject(
    doc,
    objectId,
    (o) => o.copyWith(
      entityBinding: () => EntityBinding(entityId: entityId, role: role),
      demoState: () => null,
    ),
  );

  SceneDocument unbindEntity(SceneDocument doc, String objectId) =>
      _replaceObject(
        doc,
        objectId,
        (o) => o.copyWith(entityBinding: () => null),
      );

  SceneDocument _replaceRoom(
    SceneDocument doc,
    String id,
    SceneRoom Function(SceneRoom) fn,
  ) {
    if (doc.room(id) == null) {
      throw SceneFormatException({'roomId': 'Комната $id не найдена'});
    }
    return _checked(
      doc.copyWith(rooms: [for (final r in doc.rooms) r.id == id ? fn(r) : r]),
    );
  }

  SceneDocument _replaceObject(
    SceneDocument doc,
    String id,
    SceneObject Function(SceneObject) fn,
  ) {
    if (doc.object(id) == null) {
      throw SceneFormatException({'objectId': 'Объект $id не найден'});
    }
    return _checked(
      doc.copyWith(
        objects: [for (final o in doc.objects) o.id == id ? fn(o) : o],
      ),
    );
  }
}
