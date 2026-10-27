import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show Offset;

import 'package:flutter/foundation.dart';

import '../../core_api/core_client.dart';
import '../catalog/scene_catalog.dart';
import '../geometry/iso.dart';
import '../geometry/scene_layout.dart';
import '../model/scene_codec.dart';
import '../model/scene_document.dart';
import '../model/scene_edit.dart';
import '../scene_controller.dart';
import 'draft_store.dart';
import 'editor_commands.dart';
import 'placement.dart';

/// What a pointer drag on the scene does right now.
enum EditorTool { select, place, placeRoom, moveObject, moveRoom, resizeRoom }

/// Front edges of a room that can be dragged (they face the viewer).
enum RoomEdge { east, south, corner }

enum SaveResult { saved, conflict, offline, failed, nothing }

/// Semi-transparent preview of an object being placed or moved.
class GhostObject {
  const GhostObject({
    required this.asset,
    required this.box,
    required this.rotation,
    required this.scale,
    required this.object,
    required this.issues,
  });

  final SceneAsset asset;

  /// World box (tiles) where the ghost is drawn.
  final Box3 box;
  final int rotation;
  final double scale;

  /// The candidate in room-local coordinates; null when outside every room.
  final SceneObject? object;
  final List<String> issues;
  bool get ok => object != null && issues.isEmpty;
}

/// Preview of a room being created, moved or resized.
class GhostRoom {
  const GhostRoom(this.room, this.issues);
  final SceneRoom room;
  final List<String> issues;
  bool get ok => issues.isEmpty;
}

/// Settings chosen in «Новая комната».
class RoomTemplate {
  const RoomTemplate({
    required this.name,
    required this.kind,
    required this.size,
    required this.floor,
    required this.wall,
  });
  final String name;
  final String kind;
  final Size2 size;
  final String floor;
  final String wall;
}

/// State of the house editor (build mode). Owns the working copy of the
/// scene, the undo history, tools and their previews, the local draft and
/// saving with conflict detection. Pure model logic: input arrives as world
/// pixel points (zoom 1, see [Iso]); the renderer only draws what this
/// exposes and never edits.
class EditorController extends ChangeNotifier {
  EditorController({
    required this.scene,
    required this.catalog,
    required this.drafts,
    this.edits = const SceneEdits(),
    this.autosaveDelay = const Duration(milliseconds: 800),
  }) : validator = PlacementValidator(catalog);

  final SceneController scene;
  final SceneCatalog catalog;
  final SceneDraftStore drafts;
  final SceneEdits edits;
  final PlacementValidator validator;
  final Duration autosaveDelay;
  final history = EditHistory();
  static const _codec = SceneCodec();

  bool _active = false;
  SceneDocument? _doc;
  SceneDocument? _savedDoc;
  int? _baseRevision;
  bool _disposed = false;

  bool get active => _active;
  SceneDocument? get document => _doc;
  int? get baseRevision => _baseRevision;

  // --- dirty tracking ------------------------------------------------------
  SceneDocument? _dirtyFor;
  bool _dirty = false;
  bool get dirty {
    final d = _doc, s = _savedDoc;
    if (d == null) return false;
    if (identical(d, _dirtyFor)) return _dirty;
    _dirtyFor = d;
    return _dirty =
        s == null || (!identical(d, s) && _codec.encode(d) != _codec.encode(s));
  }

  // --- draft ---------------------------------------------------------------
  SceneDraft? pendingDraft;
  DateTime? draftSavedAt;
  Timer? _autosave;
  String? get draftIssue => drafts.lastIssue;

  /// True when a found draft started from an older Core revision.
  bool get draftOutdated =>
      pendingDraft != null &&
      pendingDraft!.baseRevision != null &&
      scene.revision != null &&
      pendingDraft!.baseRevision != scene.revision;

  // --- selection & tools ---------------------------------------------------
  String? _selectedObject;
  String? _selectedRoom;
  String? get selectedObjectId => _selectedObject;
  String? get selectedRoomId => _selectedRoom;
  SceneObject? get selectedObject =>
      _selectedObject == null ? null : _doc?.object(_selectedObject!);
  SceneRoom? get selectedRoom =>
      _selectedRoom == null ? null : _doc?.room(_selectedRoom!);

  EditorTool _tool = EditorTool.select;
  EditorTool get tool => _tool;
  CatalogAsset? _placing;
  CatalogAsset? get placingAsset => _placing;
  int _placingRotation = 0;
  GhostObject? _ghost;
  GhostRoom? _roomGhost;
  GhostObject? get ghost => _ghost;
  GhostRoom? get roomGhost => _roomGhost;

  /// Object hidden from the static picture while it is being moved.
  String? get hiddenObjectId =>
      _tool == EditorTool.moveObject ? _moving?.id : null;

  /// Room whose committed version is replaced by [roomGhost] while dragging.
  String? get hiddenRoomId =>
      _tool == EditorTool.moveRoom || _tool == EditorTool.resizeRoom
      ? _roomDrag?.room.id
      : null;

  bool gridVisible = true;

  /// Bumped when only the preview (ghost) moved. Panels do not depend on it,
  /// so the UI listens here to redraw the scene layer without rebuilding
  /// widgets on every pointer move.
  final previewTick = ValueNotifier<int>(0);

  /// Last user-facing message (invalid placement, refused action).
  String? message;

  bool _saving = false;
  bool get saving => _saving;
  String? lastSaveError;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  // --- mode ----------------------------------------------------------------

  /// Looks for a local draft of the current scene (call after scene load).
  Future<void> checkForDraft() async {
    final current = scene.savedDocument;
    if (current == null || _active) return;
    final d = await drafts.read();
    if (d == null || d.document.sceneId != current.sceneId) {
      pendingDraft = null;
    } else if (_codec.encode(d.document) == _codec.encode(current)) {
      // Identical to what is stored: nothing to restore.
      await drafts.clear();
      pendingDraft = null;
    } else {
      pendingDraft = d;
    }
    _notify();
  }

  /// Enters build mode on the current scene, or on [draft].
  void enter({SceneDraft? draft}) {
    final saved = scene.savedDocument ?? scene.document;
    if (saved == null) return;
    _active = true;
    _savedDoc = saved;
    _doc = draft?.document ?? saved;
    _baseRevision = draft != null ? draft.baseRevision : scene.revision;
    pendingDraft = null;
    history.clear();
    _resetTool();
    _selectedObject = _selectedRoom = null;
    message = null;
    scene.beginEditing();
    if (draft != null) {
      scene.previewDocument(_doc!);
      _scheduleDraft();
    }
    _notify();
  }

  Future<void> restoreDraft() async {
    final d = pendingDraft;
    if (d != null) enter(draft: d);
  }

  Future<void> discardDraft() async {
    pendingDraft = null;
    await drafts.clear();
    _notify();
  }

  /// Leaves build mode. Only allowed without unsaved changes; otherwise the
  /// UI asks first and calls [discardAndExit] or [save].
  bool exit() {
    if (dirty) return false;
    _leave(restoreSaved: false);
    return true;
  }

  Future<void> discardAndExit() async {
    _autosave?.cancel();
    await drafts.clear();
    _leave(restoreSaved: true);
  }

  void _leave({required bool restoreSaved}) {
    _autosave?.cancel();
    _active = false;
    _resetTool();
    _selectedObject = _selectedRoom = null;
    history.clear();
    _doc = _savedDoc = null;
    scene.endEditing(restoreSaved: restoreSaved);
    _notify();
  }

  // --- commands & history ----------------------------------------------------

  /// Applies [c]; on a validation problem nothing changes and [message]
  /// explains why. Returns whether the document changed.
  bool run(EditCommand c, {String? mergeKey}) {
    final before = _doc;
    if (before == null) return false;
    final SceneDocument after;
    try {
      after = c.apply(before, edits);
    } on SceneFormatException catch (e) {
      message = e.issues.values.first;
      _notify();
      return false;
    }
    history.record(c.label, before, after, mergeKey: mergeKey);
    _setDoc(after);
    message = null;
    return true;
  }

  void undo() {
    final d = history.undo();
    if (d != null) _setDoc(d);
  }

  void redo() {
    final d = history.redo();
    if (d != null) _setDoc(d);
  }

  void _setDoc(SceneDocument d) {
    _doc = d;
    if (_selectedObject != null && d.object(_selectedObject!) == null) {
      _selectedObject = null;
    }
    if (_selectedRoom != null && d.room(_selectedRoom!) == null) {
      _selectedRoom = null;
    }
    scene.previewDocument(d);
    _scheduleDraft();
    _notify();
  }

  void _scheduleDraft() {
    _autosave?.cancel();
    _autosave = Timer(autosaveDelay, () => unawaited(flushDraft()));
  }

  /// Writes (or clears) the local draft now.
  Future<void> flushDraft() async {
    _autosave?.cancel();
    final d = _doc;
    if (!_active || d == null) return;
    try {
      if (dirty) {
        final at = DateTime.now();
        await drafts.write(
          SceneDraft(
            document: d,
            baseRevision: _baseRevision,
            savedAt: at,
            changes: history.length,
          ),
        );
        draftSavedAt = at;
      } else {
        await drafts.clear();
        draftSavedAt = null;
      }
    } catch (e) {
      lastSaveError = 'Не удалось записать черновик: $e';
    }
    _notify();
  }

  // --- saving ----------------------------------------------------------------

  Future<SaveResult> save() async {
    final d = _doc;
    if (d == null || _saving) return SaveResult.nothing;
    if (!dirty && scene.source == SceneSource.core) return SaveResult.nothing;
    if (!scene.canSave) {
      lastSaveError =
          'Нет связи с Core — изменения остаются в локальном черновике';
      await flushDraft();
      _notify();
      return SaveResult.offline;
    }
    _saving = true;
    lastSaveError = null;
    _notify();
    try {
      await scene.save(baseRevision: _baseRevision);
      _afterStored();
      return SaveResult.saved;
    } on CoreApiException catch (e) {
      if (e.isConflict) {
        lastSaveError = 'Сцену изменили в другом месте (версия в Core новее)';
        await flushDraft();
        return SaveResult.conflict;
      }
      lastSaveError = e.message;
      await flushDraft();
      return SaveResult.failed;
    } catch (e) {
      lastSaveError = 'Не удалось сохранить: $e';
      await flushDraft();
      return SaveResult.failed;
    } finally {
      _saving = false;
      _notify();
    }
  }

  void _afterStored() {
    _savedDoc = scene.savedDocument;
    _doc = scene.document;
    _baseRevision = scene.revision;
    _autosave?.cancel();
    unawaited(drafts.clear());
    draftSavedAt = null;
    _dirtyFor = null;
  }

  /// Conflict: drop local edits and continue from the latest Core version.
  Future<void> reloadLatest() async {
    _autosave?.cancel();
    await drafts.clear();
    history.clear();
    scene.endEditing(restoreSaved: true);
    await scene.load();
    scene.beginEditing();
    _savedDoc = _doc = scene.savedDocument;
    _baseRevision = scene.revision;
    _selectedObject = _selectedRoom = null;
    _resetTool();
    _notify();
  }

  /// Conflict: keep both — store local edits as a new scene.
  Future<SaveResult> saveAsCopy() async {
    if (_doc == null || _saving) return SaveResult.nothing;
    _saving = true;
    _notify();
    try {
      await scene.saveAsCopy(newSceneId: newUuid());
      _afterStored();
      return SaveResult.saved;
    } catch (e) {
      lastSaveError = e is CoreApiException
          ? e.message
          : 'Не удалось сохранить копию: $e';
      return SaveResult.failed;
    } finally {
      _saving = false;
      _notify();
    }
  }

  // --- selection ---------------------------------------------------------------

  void selectObject(String? id) {
    _selectedObject = id;
    if (id != null) _selectedRoom = null;
    _notify();
  }

  void selectRoom(String? id) {
    _selectedRoom = id;
    if (id != null) _selectedObject = null;
    _notify();
  }

  void clearSelection() {
    _selectedObject = _selectedRoom = null;
    _notify();
  }

  void toggleGrid() {
    gridVisible = !gridVisible;
    _notify();
  }

  // --- tools -------------------------------------------------------------------

  SceneObject? _moving;
  Offset _grab = Offset.zero;
  int _moveRotation = 0;
  ({SceneRoom room, Offset start, RoomEdge? edge})? _roomDrag;
  RoomTemplate? _roomTemplate;

  void _resetTool() {
    _tool = EditorTool.select;
    _placing = null;
    _ghost = null;
    _roomGhost = null;
    _moving = null;
    _roomDrag = null;
    _roomTemplate = null;
  }

  /// Esc: cancels the current tool, else clears the selection.
  void cancel() {
    if (_tool != EditorTool.select) {
      _resetTool();
    } else {
      _selectedObject = _selectedRoom = null;
    }
    message = null;
    _notify();
  }

  void startPlacing(String assetId) {
    final a = catalog.asset(assetId);
    if (a == null || _doc == null) return;
    _resetTool();
    _tool = EditorTool.place;
    _placing = a;
    _placingRotation = 0;
    _selectedObject = _selectedRoom = null;
    message = null;
    _notify();
  }

  /// Moves the placement preview to the cursor ([world] pixels at zoom 1).
  void hover(Offset world, {bool fine = false}) {
    switch (_tool) {
      case EditorTool.place:
        final a = _placing!;
        _ghost = _ghostAt(
          world,
          _doc!.asset(a.id) ?? a.toSceneAsset(),
          a,
          rotation: _placingRotation,
          scale: 1,
          id: '',
          fine: fine,
        );
      case EditorTool.moveObject:
        final o = _moving!;
        final a = _doc!.asset(o.assetId)!;
        _ghost = _ghostAt(
          world + _grab,
          a,
          catalog.placementOf(a),
          rotation: _moveRotation,
          scale: o.scale,
          id: o.id,
          fine: fine,
          base: o,
        );
      case EditorTool.placeRoom:
        _roomGhost = _roomAt(world);
      case EditorTool.moveRoom || EditorTool.resizeRoom:
        _roomGhost = _roomDragAt(world);
      case EditorTool.select:
        return;
    }
    if (!_disposed) previewTick.value++;
  }

  /// Rotates the preview (placing/moving) or the selected object by 90°.
  void rotate() {
    if (_tool == EditorTool.place) {
      _placingRotation = (_placingRotation + 90) % 360;
      _ghost = null;
      _notify();
    } else if (_tool == EditorTool.moveObject) {
      _moveRotation = (_moveRotation + 90) % 360;
      _notify();
    } else if (selectedObject != null) {
      rotateObject(selectedObject!.id);
    }
  }

  /// Confirms placement of a new object; returns its id.
  String? confirmPlacement({bool keepPlacing = false}) {
    final g = _ghost, a = _placing;
    if (_tool != EditorTool.place || g == null || a == null) return null;
    if (!g.ok) {
      message = g.issues.isEmpty ? 'Наведите на комнату' : g.issues.first;
      _notify();
      return null;
    }
    final id = newUuid();
    final o = SceneObject(
      id: id,
      roomId: g.object!.roomId,
      assetId: a.id,
      position: g.object!.position,
      rotation: g.rotation,
      layer: a.layer,
    );
    if (!run(AddObject(o, _doc!.asset(a.id) ?? a.toSceneAsset()))) return null;
    if (!keepPlacing) {
      _resetTool();
      _selectedObject = id;
    } else {
      _ghost = null;
    }
    _notify();
    return id;
  }

  /// Starts dragging [objectId]; [world] is where the pointer went down.
  void beginMove(String objectId, Offset world) {
    final d = _doc;
    final o = d?.object(objectId);
    final a = o == null ? null : d!.asset(o.assetId);
    final r = o == null ? null : d!.room(o.roomId);
    if (o == null || a == null || r == null) return;
    final b = SceneLayout.boxOf(o, a, r);
    final anchor = Iso.project(
      (b.minX + b.maxX) / 2,
      (b.minY + b.maxY) / 2,
      b.minZ,
    );
    _resetTool();
    _tool = EditorTool.moveObject;
    _moving = o;
    _moveRotation = o.rotation;
    _grab = anchor - world;
    _selectedObject = objectId;
    _ghost = GhostObject(
      asset: a,
      box: b,
      rotation: o.rotation,
      scale: o.scale,
      object: o,
      issues: const [],
    );
    _notify();
  }

  /// Ends an object drag: one history step for the whole drag.
  bool endMove() {
    final o = _moving, g = _ghost;
    if (_tool != EditorTool.moveObject || o == null) return false;
    _resetTool();
    _selectedObject = o.id;
    if (g == null || !g.ok) {
      message = g == null || g.issues.isEmpty
          ? 'Предмет можно поставить только в комнату'
          : g.issues.first;
      _notify();
      return false;
    }
    final c = g.object!;
    if (c.roomId == o.roomId &&
        _samePoint(c.position, o.position) &&
        c.rotation == o.rotation) {
      _notify();
      return false;
    }
    return run(
      UpdateObject(
        o.id,
        label: 'Перемещение «${_title(o)}»',
        roomId: c.roomId,
        position: c.position,
        rotation: c.rotation,
      ),
    );
  }

  void startRoomPlacement(RoomTemplate t) {
    if (_doc == null) return;
    _resetTool();
    _tool = EditorTool.placeRoom;
    _roomTemplate = t;
    _selectedObject = _selectedRoom = null;
    message = null;
    _notify();
  }

  /// Confirms a new room at the preview; returns its id.
  String? confirmRoomPlacement() {
    final g = _roomGhost;
    if (_tool != EditorTool.placeRoom || g == null) return null;
    if (!g.ok) {
      message = g.issues.first;
      _notify();
      return null;
    }
    if (!run(AddRoom(g.room))) return null;
    _resetTool();
    _selectedRoom = g.room.id;
    _notify();
    return g.room.id;
  }

  void beginRoomMove(String roomId, Offset world) =>
      _beginRoomDrag(roomId, world, null);

  void beginRoomResize(String roomId, RoomEdge edge, Offset world) =>
      _beginRoomDrag(roomId, world, edge);

  void _beginRoomDrag(String roomId, Offset world, RoomEdge? edge) {
    final r = _doc?.room(roomId);
    if (r == null) return;
    _resetTool();
    _tool = edge == null ? EditorTool.moveRoom : EditorTool.resizeRoom;
    _roomDrag = (room: r, start: world, edge: edge);
    _selectedRoom = roomId;
    _selectedObject = null;
    _roomGhost = GhostRoom(r, const []);
    _notify();
  }

  bool endRoomDrag() {
    final drag = _roomDrag, g = _roomGhost;
    final moving = _tool == EditorTool.moveRoom;
    if (drag == null ||
        (_tool != EditorTool.moveRoom && _tool != EditorTool.resizeRoom)) {
      return false;
    }
    _resetTool();
    _selectedRoom = drag.room.id;
    if (g == null) return false;
    if (!g.ok) {
      message = g.issues.first;
      _notify();
      return false;
    }
    final r = drag.room, n = g.room;
    if (n.origin.x == r.origin.x &&
        n.origin.y == r.origin.y &&
        n.size.w == r.size.w &&
        n.size.d == r.size.d) {
      _notify();
      return false;
    }
    return run(
      moving
          ? UpdateRoom(
              r.id,
              label: 'Перенос комнаты «${r.name}»',
              origin: n.origin,
            )
          : UpdateRoom(r.id, label: 'Размер комнаты «${r.name}»', size: n.size),
    );
  }

  // --- previews ------------------------------------------------------------------

  GhostObject _ghostAt(
    Offset world,
    SceneAsset asset,
    CatalogAsset spec, {
    required int rotation,
    required double scale,
    required String id,
    required bool fine,
    SceneObject? base,
  }) {
    final d = _doc!;
    final step = fine ? EditorLimits.fineSnap : EditorLimits.snap;
    final h = asset.height * scale;
    Size2 fpFor(int rot) {
      final w = asset.footprint.w * scale, dd = asset.footprint.d * scale;
      return rot == 90 || rot == 270 ? Size2(dd, w) : Size2(w, dd);
    }

    SceneObject candidate(SceneRoom r, Point3 p, int rot) => SceneObject(
      id: id.isEmpty ? '00000000-0000-4000-8000-000000000000' : id,
      roomId: r.id,
      assetId: asset.id,
      label: base?.label ?? '',
      position: p,
      rotation: rot,
      scale: scale,
      layer: spec.layer,
      entityBinding: base?.entityBinding,
      metadata: base?.metadata ?? const {},
    );

    GhostObject build(
      SceneRoom? r,
      double wx,
      double wy,
      double z,
      int rot, [
      String? extra,
    ]) {
      final fp = fpFor(rot);
      if (r == null) {
        return GhostObject(
          asset: asset,
          box: Box3(
            wx - fp.w / 2,
            wy - fp.d / 2,
            z,
            wx + fp.w / 2,
            wy + fp.d / 2,
            z + h,
          ),
          rotation: rot,
          scale: scale,
          object: null,
          issues: const ['Наведите на комнату'],
        );
      }
      final p = Point3(
        _round(wx - r.origin.x),
        _round(wy - r.origin.y),
        _round(z),
      );
      final o = candidate(r, p, rot);
      final check = validator.checkObject(d, o, asset: asset);
      return GhostObject(
        asset: asset,
        box: SceneLayout.boxOf(o, asset, r),
        rotation: rot,
        scale: scale,
        object: o,
        issues: [?extra, ...check.issues],
      );
    }

    double snapIn(double v, double lo, double hi) =>
        (hi < lo) ? lo : clampDouble((v / step).round() * step, lo, hi);

    if (spec.placement == Placement.wall) {
      final hit = _wallHit(d, world);
      if (hit == null) {
        final (x, y) = Iso.unproject(world);
        return build(null, x, y, spec.wallZ, rotation);
      }
      final (r, side, along, z) = hit;
      final rot = side == WallSide.north ? 0 : 90;
      final fp = fpFor(rot);
      final zz = snapIn(z - h / 2, 0, r.wallHeight - h);
      if (side == WallSide.north) {
        final lx = snapIn(along - fp.w / 2, 0, r.size.w - fp.w);
        return build(r, r.origin.x + lx, r.origin.y, zz, rot);
      }
      final ly = snapIn(along - fp.d / 2, 0, r.size.d - fp.d);
      return build(r, r.origin.x, r.origin.y + ly, zz, rot);
    }

    final fp = fpFor(rotation);
    var z = 0.0;
    var (x, y) = Iso.unproject(world);
    SceneRoom? room;
    if (spec.placement == Placement.surface) {
      ({double z, String supportId})? best;
      SceneRoom? bestRoom;
      for (final r in d.rooms) {
        final s = validator.surfaceAt(
          d,
          r,
          x,
          y,
          excludeId: base?.id,
          itemHeight: h,
          cursorWorld: world,
        );
        if (s != null && (best == null || s.z > best.z)) {
          best = s;
          bestRoom = r;
        }
      }
      if (best != null) {
        z = best.z;
        (x, y) = Iso.unproject(world, z: z);
        room = bestRoom;
      }
    }
    room ??= d.rooms
        .where(
          (r) =>
              x >= r.origin.x &&
              x < r.origin.x + r.size.w &&
              y >= r.origin.y &&
              y < r.origin.y + r.size.d,
        )
        .firstOrNull;
    if (room == null) return build(null, x, y, z, rotation);
    final lx = snapIn(x - room.origin.x - fp.w / 2, 0, room.size.w - fp.w);
    final ly = snapIn(y - room.origin.y - fp.d / 2, 0, room.size.d - fp.d);
    return build(
      room,
      room.origin.x + lx,
      room.origin.y + ly,
      z,
      rotation,
      fp.w > room.size.w || fp.d > room.size.d
          ? 'Предмет больше комнаты'
          : null,
    );
  }

  /// Back wall (north or west, outer only) under the cursor: room, side,
  /// position along the wall and height, solved on the wall plane.
  (SceneRoom, WallSide, double, double)? _wallHit(
    SceneDocument d,
    Offset world,
  ) {
    bool outside(double x, double y) => !d.rooms.any(
      (r) =>
          x >= r.origin.x &&
          x < r.origin.x + r.size.w &&
          y >= r.origin.y &&
          y < r.origin.y + r.size.d,
    );
    (SceneRoom, WallSide, double, double)? best;
    var bestDepth = double.negativeInfinity;
    for (final r in d.rooms) {
      final x0 = r.origin.x, y0 = r.origin.y;
      // North wall: plane y = y0.
      final xn = world.dx / (Iso.tileWidth / 2) + y0;
      final zn = ((xn + y0) * Iso.tileHeight / 2 - world.dy) / Iso.zStep;
      if (xn >= x0 &&
          xn <= x0 + r.size.w &&
          zn >= 0 &&
          zn <= r.wallHeight &&
          outside(xn, y0 - 0.05)) {
        final depth = xn + y0;
        if (depth > bestDepth) {
          bestDepth = depth;
          best = (r, WallSide.north, xn - x0, zn);
        }
      }
      // West wall: plane x = x0.
      final yw = x0 - world.dx / (Iso.tileWidth / 2);
      final zw = ((x0 + yw) * Iso.tileHeight / 2 - world.dy) / Iso.zStep;
      if (yw >= y0 &&
          yw <= y0 + r.size.d &&
          zw >= 0 &&
          zw <= r.wallHeight &&
          outside(x0 - 0.05, yw)) {
        final depth = x0 + yw;
        if (depth > bestDepth) {
          bestDepth = depth;
          best = (r, WallSide.west, yw - y0, zw);
        }
      }
    }
    return best;
  }

  GhostRoom? _roomAt(Offset world) {
    final t = _roomTemplate;
    final d = _doc;
    if (t == null || d == null) return null;
    final (x, y) = Iso.unproject(world);
    final room = SceneRoom(
      id: _roomGhost?.room.id ?? newUuid(),
      name: t.name,
      kind: t.kind,
      origin: Point2(
        (x - t.size.w / 2).roundToDouble(),
        (y - t.size.d / 2).roundToDouble(),
      ),
      size: t.size,
      wallHeight: d.rooms.firstOrNull?.wallHeight ?? 5,
      style: RoomStyle(floor: t.floor, wall: t.wall),
    );
    return GhostRoom(room, validator.checkRoom(d, room));
  }

  GhostRoom? _roomDragAt(Offset world) {
    final drag = _roomDrag;
    final d = _doc;
    if (drag == null || d == null) return null;
    final r = drag.room;
    final (sx, sy) = Iso.unproject(drag.start);
    final (x, y) = Iso.unproject(world);
    final SceneRoom n;
    if (drag.edge == null) {
      n = r.copyWith(
        origin: Point2(
          r.origin.x + (x - sx).roundToDouble(),
          r.origin.y + (y - sy).roundToDouble(),
        ),
      );
    } else {
      final e = drag.edge!;
      final w = e == RoomEdge.south
          ? r.size.w
          : math.max(
              EditorLimits.minRoomSide,
              (x - r.origin.x).roundToDouble(),
            );
      final dd = e == RoomEdge.east
          ? r.size.d
          : math.max(
              EditorLimits.minRoomSide,
              (y - r.origin.y).roundToDouble(),
            );
      n = r.copyWith(
        size: Size2(
          math.min(w, EditorLimits.maxRoomSide),
          math.min(dd, EditorLimits.maxRoomSide),
        ),
      );
    }
    return GhostRoom(n, validator.checkRoom(d, n));
  }

  // --- object operations -----------------------------------------------------------

  String _title(SceneObject o) {
    final p = scene.presentation(o.id);
    if (p != null && p.title.isNotEmpty) return p.title;
    if (o.label.isNotEmpty) return o.label;
    return _doc?.asset(o.assetId)?.label ?? o.assetId;
  }

  String titleOf(SceneObject o) => _title(o);

  /// Rotates by 90° around the footprint centre, kept inside the room.
  bool rotateObject(String id) {
    final d = _doc!;
    final o = d.object(id);
    final a = o == null ? null : d.asset(o.assetId);
    final r = o == null ? null : d.room(o.roomId);
    if (o == null || a == null || r == null) return false;
    final spec = catalog.placementOf(a);
    if (spec.placement == Placement.wall) {
      message = 'Предмет на стене поворачивается вместе со стеной — перенесите его на другую стену';
      _notify();
      return false;
    }
    final rot = (o.rotation + 90) % 360;
    final fp = o.footprint(a);
    final nfp = o.copyWith(rotation: rot).footprint(a);
    final cx = o.position.x + fp.w / 2, cy = o.position.y + fp.d / 2;
    final p = Point3(
      _round(clampDouble(cx - nfp.w / 2, 0, math.max(0, r.size.w - nfp.w))),
      _round(clampDouble(cy - nfp.d / 2, 0, math.max(0, r.size.d - nfp.d))),
      o.position.z,
    );
    return _guarded(
      o.copyWith(rotation: rot, position: p),
      UpdateObject(
        id,
        label: 'Поворот «${_title(o)}»',
        rotation: rot,
        position: p,
      ),
    );
  }

  bool scaleObject(String id, double scale) {
    final o = _doc!.object(id);
    if (o == null) return false;
    final s = _round(
      clampDouble(scale, EditorLimits.minScale, EditorLimits.maxScale),
    );
    return _guarded(
      o.copyWith(scale: s),
      UpdateObject(id, label: 'Масштаб «${_title(o)}»', scale: s),
      mergeKey: 'scale:$id',
    );
  }

  /// Moves by a grid step (arrow keys / inspector arrows).
  bool nudgeObject(String id, double dx, double dy) {
    final o = _doc!.object(id);
    if (o == null) return false;
    final p = Point3(
      _round(o.position.x + dx),
      _round(o.position.y + dy),
      o.position.z,
    );
    return _guarded(
      o.copyWith(position: p),
      UpdateObject(id, label: 'Перемещение «${_title(o)}»', position: p),
      mergeKey: 'nudge:$id',
    );
  }

  /// Exact position from the inspector's advanced section.
  bool setObjectPosition(String id, Point3 p) {
    final o = _doc!.object(id);
    if (o == null) return false;
    final q = Point3(_round(p.x), _round(p.y), _round(p.z));
    return _guarded(
      o.copyWith(position: q),
      UpdateObject(id, label: 'Положение «${_title(o)}»', position: q),
    );
  }

  bool renameObject(String id, String label) {
    final o = _doc!.object(id);
    final t = label.trim();
    if (o == null || t == o.label) return false;
    if (t.runes.length > 120) {
      message = 'Название не длиннее 120 символов';
      _notify();
      return false;
    }
    return run(
      UpdateObject(id, label: 'Название «$t»', title: t),
      mergeKey: 'rename:$id',
    );
  }

  /// Visual finish (metadata `finish`, see the catalog).
  bool setFinish(String id, String? finish) {
    final o = _doc!.object(id);
    if (o == null) return false;
    final m = {...o.metadata}..remove('finish');
    if (finish != null && finish != 'natural') m['finish'] = finish;
    return run(
      UpdateObject(id, label: 'Оформление «${_title(o)}»', metadata: m),
    );
  }

  /// Copies the selected object next to the original (first free spot).
  String? duplicateObject(String id) {
    final d = _doc!;
    final o = d.object(id);
    final a = o == null ? null : d.asset(o.assetId);
    if (o == null || a == null) return null;
    final fp = o.footprint(a);
    final p = o.position;
    final tries = [
      Point3(p.x + fp.w + 0.5, p.y, p.z),
      Point3(p.x, p.y + fp.d + 0.5, p.z),
      Point3(p.x - fp.w - 0.5, p.y, p.z),
      Point3(p.x, p.y - fp.d - 0.5, p.z),
      Point3(p.x + 1, p.y + 1, p.z),
    ];
    for (final t in tries) {
      final q = Point3(_round(t.x), _round(t.y), t.z);
      final copy = o.copyWith(
        id: '00000000-0000-4000-8000-000000000001',
        position: q,
      );
      if (validator.checkObject(d, copy).ok) {
        final c = DuplicateObject(id, _title(o), q);
        if (run(c)) {
          _selectedObject = c.newId;
          _notify();
          return c.newId;
        }
      }
    }
    message = 'Рядом нет свободного места для копии';
    _notify();
    return null;
  }

  bool deleteObject(String id) {
    final o = _doc!.object(id);
    if (o == null) return false;
    return run(RemoveObject(id, _title(o)));
  }

  bool bindObject(String id, String entityId, String entityName) {
    final o = _doc!.object(id);
    if (o == null) return false;
    return run(BindEntity(id, entityId, entityName));
  }

  bool unbindObject(String id) {
    final o = _doc!.object(id);
    if (o == null || o.entityBinding == null) return false;
    return run(UnbindEntity(id, _title(o)));
  }

  bool _guarded(SceneObject candidate, EditCommand c, {String? mergeKey}) {
    final check = validator.checkObject(_doc!, candidate);
    if (!check.ok) {
      message = check.issues.first;
      _notify();
      return false;
    }
    return run(c, mergeKey: mergeKey);
  }

  // --- room operations --------------------------------------------------------------

  int objectsIn(String roomId) => _doc?.objectsIn(roomId).length ?? 0;

  bool renameRoom(String id, String name) {
    final r = _doc!.room(id);
    final t = name.trim();
    if (r == null || t == r.name) return false;
    if (t.isEmpty || t.runes.length > 80) {
      message = 'Название комнаты: от 1 до 80 символов';
      _notify();
      return false;
    }
    return run(
      UpdateRoom(id, label: 'Название комнаты «$t»', name: t),
      mergeKey: 'rename-room:$id',
    );
  }

  bool setRoomKind(String id, String kind) {
    final r = _doc!.room(id);
    if (r == null || r.kind == kind) return false;
    return run(UpdateRoom(id, label: 'Вид комнаты «${r.name}»', kind: kind));
  }

  bool resizeRoom(String id, Size2 size) {
    final r = _doc!.room(id);
    if (r == null) return false;
    return _roomGuarded(
      r.copyWith(size: size),
      UpdateRoom(id, label: 'Размер комнаты «${r.name}»', size: size),
      mergeKey: 'room-size:$id',
    );
  }

  bool moveRoom(String id, Point2 origin) {
    final r = _doc!.room(id);
    if (r == null) return false;
    return _roomGuarded(
      r.copyWith(origin: origin),
      UpdateRoom(id, label: 'Перенос комнаты «${r.name}»', origin: origin),
      mergeKey: 'room-move:$id',
    );
  }

  bool styleRoom(String id, RoomStyle style) {
    final r = _doc!.room(id);
    if (r == null || r.style == style) return false;
    return run(
      UpdateRoom(id, label: 'Оформление комнаты «${r.name}»', style: style),
    );
  }

  /// Copies a room (with its furniture) next to the original.
  String? duplicateRoom(String id) {
    final d = _doc!;
    final r = d.room(id);
    if (r == null) return null;
    final o = r.origin, s = r.size;
    for (final t in [
      Point2(o.x + s.w, o.y),
      Point2(o.x, o.y + s.d),
      Point2(o.x - s.w, o.y),
      Point2(o.x, o.y - s.d),
      Point2(o.x + s.w, o.y + s.d),
    ]) {
      if (validator
          .checkRoom(
            d,
            r.copyWith(id: '00000000-0000-4000-8000-000000000002', origin: t),
          )
          .isEmpty) {
        final c = DuplicateRoom(d, id, origin: t);
        if (run(c)) {
          _selectedRoom = c.newRoomId;
          _notify();
          return c.newRoomId;
        }
      }
    }
    message = 'Рядом нет места для копии комнаты';
    _notify();
    return null;
  }

  bool deleteRoom(String id) {
    final d = _doc!;
    final r = d.room(id);
    if (r == null) return false;
    if (d.rooms.length <= 1) {
      message = 'В доме должна остаться хотя бы одна комната';
      _notify();
      return false;
    }
    return run(RemoveRoom(id, r.name));
  }

  bool _roomGuarded(SceneRoom candidate, EditCommand c, {String? mergeKey}) {
    final issues = validator.checkRoom(_doc!, candidate);
    if (issues.isNotEmpty) {
      message = issues.first;
      _notify();
      return false;
    }
    return run(c, mergeKey: mergeKey);
  }

  /// A free spot for a new room of [size]: right of or below the house.
  Point2 suggestRoomOrigin(Size2 size) {
    final d = _doc!;
    var maxX = 0.0;
    for (final r in d.rooms) {
      maxX = math.max(maxX, r.origin.x + r.size.w);
    }
    final minY = d.rooms.map((r) => r.origin.y).fold<double>(0, math.min);
    for (var y = minY; y < minY + 60; y += 1) {
      final c = SceneRoom(
        id: '00000000-0000-4000-8000-000000000003',
        name: 'x',
        kind: 'custom',
        origin: Point2(maxX, y),
        size: size,
        wallHeight: 5,
        style: const RoomStyle(floor: 'oak', wall: 'milk'),
      );
      if (validator.checkRoom(d, c).isEmpty) return c.origin;
    }
    return Point2(maxX, minY);
  }

  @override
  void dispose() {
    _disposed = true;
    _autosave?.cancel();
    previewTick.dispose();
    super.dispose();
  }
}

double _round(double v) => (v * 1000).roundToDouble() / 1000;

bool _samePoint(Point3 a, Point3 b) =>
    (a.x - b.x).abs() < 1e-9 &&
    (a.y - b.y).abs() < 1e-9 &&
    (a.z - b.z).abs() < 1e-9;
