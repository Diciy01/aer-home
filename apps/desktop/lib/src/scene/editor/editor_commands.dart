import 'dart:math' as math;

import '../model/scene_codec.dart';
import '../model/scene_document.dart';
import '../model/scene_edit.dart';

final _random = math.Random.secure();

/// Random UUID v4 in lower case (scene ids are UUIDs, see SCENE_FORMAT.md).
String newUuid() {
  final b = List<int>.generate(16, (_) => _random.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  final h = [for (final x in b) x.toRadixString(16).padLeft(2, '0')].join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-'
      '${h.substring(16, 20)}-${h.substring(20)}';
}

/// One editor action. [apply] is a pure function of the document (built on
/// [SceneEdits], so the result is validated) and never mutates its input;
/// ids for new rooms/objects are fixed when the command is created, so
/// applying the same command twice gives the same document.
sealed class EditCommand {
  const EditCommand();

  /// Human label for the history («Перемещение: Монитор»).
  String get label;

  SceneDocument apply(SceneDocument doc, SceneEdits edits);
}

class AddRoom extends EditCommand {
  const AddRoom(this.room);
  final SceneRoom room;

  @override
  String get label => 'Новая комната «${room.name}»';

  @override
  SceneDocument apply(SceneDocument doc, SceneEdits edits) =>
      edits.addRoom(doc, room);
}

/// Rename, move, resize, restyle or change the kind of a room. Objects keep
/// their room-local positions, so moving a room carries its furniture along.
class UpdateRoom extends EditCommand {
  const UpdateRoom(
    this.roomId, {
    required this.label,
    this.name,
    this.kind,
    this.origin,
    this.size,
    this.style,
  });

  final String roomId;
  @override
  final String label;
  final String? name;
  final String? kind;
  final Point2? origin;
  final Size2? size;
  final RoomStyle? style;

  @override
  SceneDocument apply(SceneDocument doc, SceneEdits edits) => edits.updateRoom(
    doc,
    roomId,
    (r) => r.copyWith(
      name: name,
      kind: kind,
      origin: origin,
      size: size,
      style: style,
    ),
  );
}

class RemoveRoom extends EditCommand {
  const RemoveRoom(this.roomId, this.name);
  final String roomId;
  final String name;

  @override
  String get label => 'Удаление комнаты «$name»';

  @override
  SceneDocument apply(SceneDocument doc, SceneEdits edits) =>
      edits.removeRoom(doc, roomId);
}

/// Copies a room with all its objects to [origin]. Registry bindings are
/// copied too (several visual objects may show one entity).
class DuplicateRoom extends EditCommand {
  DuplicateRoom(
    SceneDocument doc,
    this.roomId, {
    required this.origin,
    String? newRoomId,
  }) : newRoomId = newRoomId ?? newUuid(),
       objectIds = {for (final o in doc.objectsIn(roomId)) o.id: newUuid()},
       name = doc.room(roomId)?.name ?? '';

  final String roomId;
  final String newRoomId;
  final Point2 origin;
  final Map<String, String> objectIds;
  final String name;

  @override
  String get label => 'Копия комнаты «$name»';

  @override
  SceneDocument apply(SceneDocument doc, SceneEdits edits) {
    final src = doc.room(roomId);
    if (src == null) {
      throw SceneFormatException({'roomId': 'Комната не найдена'});
    }
    final copy = src.copyWith(
      id: newRoomId,
      name: _copyName(src.name),
      origin: origin,
    );
    return edits.addRoomWithObjects(doc, copy, [
      for (final o in doc.objectsIn(roomId))
        o.copyWith(id: objectIds[o.id], roomId: newRoomId),
    ]);
  }
}

String _copyName(String name) {
  final n = '$name (копия)';
  return n.runes.length > 80 ? String.fromCharCodes(n.runes.take(80)) : n;
}

/// Places a new object; declares its asset in the document if needed.
class AddObject extends EditCommand {
  const AddObject(this.object, this.asset, {this.title});
  final SceneObject object;
  final SceneAsset asset;
  final String? title;

  @override
  String get label => 'Новый предмет «${title ?? asset.label}»';

  @override
  SceneDocument apply(SceneDocument doc, SceneEdits edits) =>
      edits.addObject(edits.declareAsset(doc, asset), object);
}

/// Moves, rotates, scales, renames or restyles one object.
class UpdateObject extends EditCommand {
  const UpdateObject(
    this.objectId, {
    required this.label,
    this.roomId,
    this.position,
    this.rotation,
    this.scale,
    this.title,
    this.metadata,
  });

  final String objectId;
  @override
  final String label;
  final String? roomId;
  final Point3? position;
  final int? rotation;
  final double? scale;

  /// New object label (shown when the object is not bound).
  final String? title;
  final Map<String, String>? metadata;

  @override
  SceneDocument apply(SceneDocument doc, SceneEdits edits) =>
      edits.updateObject(
        doc,
        objectId,
        (o) => o.copyWith(
          roomId: roomId,
          position: position,
          rotation: rotation,
          scale: scale,
          label: title,
          metadata: metadata,
        ),
      );
}

class RemoveObject extends EditCommand {
  const RemoveObject(this.objectId, this.title);
  final String objectId;
  final String title;

  @override
  String get label => 'Удаление «$title»';

  @override
  SceneDocument apply(SceneDocument doc, SceneEdits edits) =>
      edits.removeObject(doc, objectId);
}

class DuplicateObject extends EditCommand {
  DuplicateObject(this.objectId, this.title, this.position, {String? newId})
    : newId = newId ?? newUuid();
  final String objectId;
  final String title;
  final Point3 position;
  final String newId;

  @override
  String get label => 'Копия «$title»';

  @override
  SceneDocument apply(SceneDocument doc, SceneEdits edits) {
    final src = doc.object(objectId);
    if (src == null) {
      throw SceneFormatException({'objectId': 'Объект не найден'});
    }
    return edits.addObject(doc, src.copyWith(id: newId, position: position));
  }
}

class BindEntity extends EditCommand {
  const BindEntity(this.objectId, this.entityId, this.entityName);
  final String objectId;
  final String entityId;
  final String entityName;

  @override
  String get label => 'Привязка к «$entityName»';

  @override
  SceneDocument apply(SceneDocument doc, SceneEdits edits) =>
      edits.bindEntity(doc, objectId, entityId);
}

class UnbindEntity extends EditCommand {
  const UnbindEntity(this.objectId, this.title);
  final String objectId;
  final String title;

  @override
  String get label => 'Отвязка «$title»';

  @override
  SceneDocument apply(SceneDocument doc, SceneEdits edits) =>
      edits.unbindEntity(doc, objectId);
}

/// One history step: the documents before and after a command.
class HistoryEntry {
  HistoryEntry(this.label, this.before, this.after, this.mergeKey, this.at);
  final String label;
  final SceneDocument before;
  SceneDocument after;
  final String? mergeKey;
  DateTime at;
}

/// Undo/redo over immutable documents. Undo restores the exact document a
/// command started from, so any number of undo/redo cycles cannot corrupt
/// the model. Rapid edits with the same merge key (slider drags, repeated
/// nudges) collapse into one step.
class EditHistory {
  EditHistory({
    this.limit = 200,
    this.mergeWindow = const Duration(seconds: 2),
  });

  final int limit;
  final Duration mergeWindow;
  final _undo = <HistoryEntry>[];
  final _redo = <HistoryEntry>[];

  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;
  String? get undoLabel => _undo.lastOrNull?.label;
  String? get redoLabel => _redo.lastOrNull?.label;
  int get length => _undo.length;

  List<String> get labels => [for (final e in _undo) e.label];

  void record(
    String label,
    SceneDocument before,
    SceneDocument after, {
    String? mergeKey,
    DateTime? now,
  }) {
    final t = now ?? DateTime.now();
    _redo.clear();
    final last = _undo.lastOrNull;
    if (mergeKey != null &&
        last != null &&
        last.mergeKey == mergeKey &&
        t.difference(last.at) <= mergeWindow) {
      last
        ..after = after
        ..at = t;
      return;
    }
    _undo.add(HistoryEntry(label, before, after, mergeKey, t));
    if (_undo.length > limit) _undo.removeAt(0);
  }

  /// Returns the document to show after undo, or null if nothing to undo.
  SceneDocument? undo() {
    if (_undo.isEmpty) return null;
    final e = _undo.removeLast();
    _redo.add(e);
    return e.before;
  }

  SceneDocument? redo() {
    if (_redo.isEmpty) return null;
    final e = _redo.removeLast();
    _undo.add(e);
    return e.after;
  }

  void clear() {
    _undo.clear();
    _redo.clear();
  }
}
