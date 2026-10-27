import 'dart:async';
import 'dart:math' as math;

import 'package:flame/game.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../scene/binding/scene_binding.dart';
import '../../scene/catalog/scene_catalog.dart';
import '../../scene/editor/editor_controller.dart';
import '../../scene/editor/placement.dart';
import '../../scene/geometry/iso.dart';
import '../../scene/geometry/scene_layout.dart';
import '../../scene/interaction/scene_interaction.dart';
import '../../scene/model/scene_document.dart';
import '../../scene/render/editor_layer.dart';
import '../../scene/render/scene_game.dart';
import '../../scene/scene_controller.dart';
import '../../state/registry_controller.dart';
import '../../theme/tokens.dart';
import '../registry/entity_details.dart';
import '../registry/error_text.dart';
import 'editor/editor_dialogs.dart';
import 'editor/editor_panels.dart';
import 'scene_overlays.dart';

/// Isometric house: view mode (M03) and build mode (M04 editor).
class HouseView extends StatefulWidget {
  const HouseView({
    super.key,
    required this.scene,
    required this.registry,
    required this.onShowInRegistry,
    this.game,
    this.catalog,
    this.onOpenDiagnostics,
    this.entityPanel,
  });

  final SceneController scene;
  final RegistryController registry;

  /// Switches to «Устройства» and selects the entity.
  final void Function(String entityId) onShowInRegistry;

  /// Injected in tests; created internally otherwise.
  final SceneGame? game;

  /// Editor catalog; the built-in one by default.
  final SceneCatalog? catalog;

  /// Opens Monitoring diagnostics of an entity (null: Monitoring absent).
  final void Function(String entityId)? onOpenDiagnostics;

  /// Extra quick-card panel for a bound entity (Bots); null when none.
  final Widget? Function(String entityId)? entityPanel;

  @override
  State<HouseView> createState() => HouseViewState();
}

/// Pointer-down intent in build mode, decided before the drag starts so a
/// plain click never moves anything.
enum _Press { none, moveObject, moveRoom, resizeRoom }

class HouseViewState extends State<HouseView> implements EditorActions {
  late final SceneGame game = widget.game ?? SceneGame();
  late final SceneInteraction interaction = SceneInteraction(game.view);
  late final EditorController editor = EditorController(
    scene: widget.scene,
    catalog: widget.catalog ?? SceneCatalog.builtin,
    drafts: widget.scene.drafts,
  );
  final _focus = FocusNode(debugLabel: 'house-scene');
  final _surfaceKey = GlobalKey();
  bool _legend = false;
  bool _details = false;
  Offset? _doubleTapAt;
  double _lastScale = 1;
  SceneLayout? _installedLayout;
  Map<String, ObjectPresentation>? _installedPresentations;
  String? _draftCheckedFor;
  DateTime? _registryStamp;

  // Build-mode pointer state.
  Offset? _downAt;
  _Press _press = _Press.none;
  String? _pressObject;
  RoomEdge? _pressEdge;
  bool _dragging = false;

  bool get editing => editor.active;

  @override
  void initState() {
    super.initState();
    game.catalog = editor.catalog;
    widget.scene.addListener(_sync);
    widget.registry.addListener(_onRegistry);
    interaction.addListener(_onInteraction);
    editor.addListener(_onEditor);
    editor.previewTick.addListener(_syncOverlay);
    _sync();
    if (widget.scene.source == SceneSource.none && !widget.scene.loading) {
      unawaited(widget.scene.load());
    }
  }

  @override
  void dispose() {
    widget.scene.removeListener(_sync);
    widget.registry.removeListener(_onRegistry);
    interaction.removeListener(_onInteraction);
    editor.removeListener(_onEditor);
    editor.previewTick.removeListener(_syncOverlay);
    editor.dispose();
    if (widget.game == null) game.disposeResources();
    _focus.dispose();
    super.dispose();
  }

  void _sync() {
    final scene = widget.scene;
    final layout = scene.layout;
    final pres = scene.presentations;
    if (layout != null &&
        (layout != _installedLayout || pres != _installedPresentations)) {
      final reset =
          _installedLayout?.document.sceneId != layout.document.sceneId;
      _installedLayout = layout;
      _installedPresentations = pres;
      interaction.syncWith(layout);
      game.setScene(layout, pres, resetCamera: reset);
    }
    final saved = scene.savedDocument;
    if (saved != null &&
        !scene.loading &&
        !editor.active &&
        _draftCheckedFor != saved.sceneId) {
      _draftCheckedFor = saved.sceneId;
      unawaited(editor.checkForDraft());
    }
    if (mounted) setState(() {});
  }

  void _onRegistry() {
    if (_details && widget.registry.selected == null && mounted) {
      setState(() => _details = false);
    }
    // Registry list reloaded (e.g. a device was renamed): refresh the names
    // shown by bound scene objects.
    final stamp = widget.registry.loadedAt;
    if (stamp != null && stamp != _registryStamp) {
      final first = _registryStamp == null;
      _registryStamp = stamp;
      if (!first && widget.scene.document != null) {
        unawaited(widget.scene.refreshBindings());
      }
    }
  }

  void _onInteraction() {
    game
      ..hoveredId = interaction.hoveredId
      ..selectedId = editing ? _editorSelectedId : interaction.selectedId
      ..wake();
    if (mounted) setState(() {});
  }

  String? get _editorSelectedId =>
      editor.hiddenObjectId == null ? editor.selectedObjectId : null;

  void _onEditor() {
    _syncOverlay();
    if (mounted) setState(() {});
  }

  /// Scene-only update (ghost moved): no widget rebuild.
  void _syncOverlay() {
    game.setEditorOverlay(
      editor.active
          ? EditorOverlay(
              grid: editor.gridVisible,
              ghost: editor.ghost,
              roomGhost: editor.roomGhost,
              selectedRoom: editor.selectedRoom,
              hiddenObjectId: editor.hiddenObjectId,
            )
          : null,
    );
    game.selectedId = editing ? _editorSelectedId : interaction.selectedId;
  }

  void _moved() {
    game.userMovedCamera = true;
    game.wake();
  }

  ObjectPresentation? _pres(ObjectGeometry? g) =>
      g == null ? null : widget.scene.presentation(g.object.id);

  /// Registry cards need a live Core (offline the card cannot be loaded).
  bool _canOpen(ObjectPresentation? p) =>
      widget.registry.canEdit &&
      p != null &&
      (p.binding == BindingState.resolved ||
          p.binding == BindingState.archived);

  Future<void> _openDetails(ObjectGeometry g) async {
    final p = _pres(g);
    final id = g.object.entityBinding?.entityId;
    if (!_canOpen(p) || id == null) {
      interaction.select(g.object.id);
      return;
    }
    final messenger = ScaffoldMessenger.of(context);
    try {
      await widget.registry.selectById(id);
      if (mounted) setState(() => _details = true);
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(describeError(e))));
    }
  }

  Offset _world(Offset local) => game.view.screenToWorld(local);

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  // --- Build mode: entering, leaving, saving --------------------------------

  Future<void> _enterEditor() async {
    if (widget.scene.document == null) return;
    interaction.select(null);
    widget.registry.clearSelection();
    setState(() => _details = false);
    if (editor.pendingDraft != null) {
      final restore = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Найден несохранённый черновик'),
          content: const Text(
            'Продолжить с того места, где вы остановились? Если начать заново, черновик будет удалён.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Начать заново'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Восстановить'),
            ),
          ],
        ),
      );
      if (restore == null) return;
      if (restore) {
        await editor.restoreDraft();
      } else {
        await editor.discardDraft();
        editor.enter();
      }
    } else {
      editor.enter();
    }
    _focus.requestFocus();
  }

  @override
  Future<void> exit() async {
    if (!editor.dirty) {
      editor.exit();
      return;
    }
    final choice = await askUnsaved(context, canSave: widget.scene.canSave);
    switch (choice) {
      case UnsavedChoice.save:
        if (await _saveFlow()) editor.exit();
      case UnsavedChoice.discard:
        await editor.discardAndExit();
      case UnsavedChoice.keepEditing:
        break;
    }
  }

  @override
  Future<void> save() async => _saveFlow();

  Future<bool> _saveFlow() async {
    final r = await editor.save();
    if (!mounted) return false;
    switch (r) {
      case SaveResult.saved:
        _snack('Планировка сохранена · версия ${widget.scene.revision}');
        return true;
      case SaveResult.nothing:
        return !editor.dirty;
      case SaveResult.offline || SaveResult.failed:
        _snack(editor.lastSaveError ?? 'Не удалось сохранить');
        return false;
      case SaveResult.conflict:
        final c = await askConflict(context);
        if (!mounted) return false;
        switch (c) {
          case ConflictChoice.reload:
            await editor.reloadLatest();
            _snack('Загружена актуальная версия из Core');
            return true;
          case ConflictChoice.saveCopy:
            final s = await editor.saveAsCopy();
            if (s == SaveResult.saved) {
              _snack('Ваши изменения сохранены отдельной копией дома');
              return true;
            }
            _snack(editor.lastSaveError ?? 'Не удалось сохранить копию');
            return false;
          case ConflictChoice.keepEditing:
            return false;
        }
    }
  }

  // --- EditorActions -----------------------------------------------------------

  @override
  void focusObject(String id) {
    final g = widget.scene.layout?.objects[id];
    if (g == null) return;
    game.view.focusRect(g.screenBounds.inflate(160));
    _moved();
  }

  @override
  void focusRoom(String id) {
    final r = widget.scene.layout?.roomGeometry(id);
    if (r == null) return;
    game.view.focusRect(r.focusBounds);
    _moved();
  }

  @override
  Future<void> bindObject(String id) async {
    final o = editor.document?.object(id);
    if (o == null) return;
    if (!widget.registry.canEdit) {
      _snack('Нужна связь с Core: список устройств хранится в Registry');
      return;
    }
    final e = await pickDeviceForBinding(
      context,
      api: widget.registry.api,
      objectTitle: editor.titleOf(o),
      currentEntityId: o.entityBinding?.entityId,
      typeLabel: (t) => widget.registry.catalog?.typeLabel(t) ?? t,
    );
    if (e == null || !mounted) return;
    if (editor.bindObject(id, e.id, e.name)) {
      _snack('«${editor.titleOf(o)}» привязан к «${e.name}»');
    }
  }

  @override
  Future<void> deleteObject(String id) async {
    final o = editor.document?.object(id);
    if (o == null) return;
    final title = editor.titleOf(o);
    final ok = await confirmDelete(
      context,
      title: 'Удалить «$title»?',
      body: o.entityBinding != null
          ? 'Предмет исчезнет из сцены. Устройство в Registry не удаляется — пропадёт только его изображение в доме. '
                'Отменить можно через Ctrl+Z.'
          : 'Предмет исчезнет из сцены. Отменить можно через Ctrl+Z.',
    );
    if (ok) editor.deleteObject(id);
  }

  @override
  Future<void> deleteRoom(String id) async {
    final doc = editor.document;
    final r = doc?.room(id);
    if (doc == null || r == null) return;
    final objects = doc.objectsIn(id).toList();
    final bound = objects.where((o) => o.entityBinding != null).length;
    final n = objects.length;
    final ok = await confirmDelete(
      context,
      title: 'Удалить комнату «${r.name}»?',
      body: n == 0
          ? 'Комната пустая. Отменить можно через Ctrl+Z.'
          : 'Вместе с комнатой будут удалены $n ${plural(n, 'предмет', 'предмета', 'предметов')}'
                '${bound > 0 ? ' (привязанных к Registry: $bound — сами устройства в Registry останутся)' : ''}. '
                'Отменить можно через Ctrl+Z.',
      action: n == 0
          ? 'Удалить'
          : 'Удалить комнату и $n ${plural(n, 'предмет', 'предмета', 'предметов')}',
    );
    if (ok) editor.deleteRoom(id);
  }

  @override
  Future<void> newRoom() async {
    final t = await askNewRoom(context, editor.catalog);
    if (t == null || !mounted || editor.document == null) return;
    editor.startRoomPlacement(t);
    final o = editor.suggestRoomOrigin(t.size);
    final center = Iso.project(o.x + t.size.w / 2, o.y + t.size.d / 2);
    editor.hover(center);
    final layout = widget.scene.layout;
    final ghost = Iso.screenBounds(
      Box3(o.x, o.y, 0, o.x + t.size.w, o.y + t.size.d, 2),
    );
    game.view.focusRect(
      layout == null ? ghost : layout.bounds.expandToInclude(ghost),
    );
    _moved();
    _focus.requestFocus();
  }

  Future<void> _duplicateSelected() async {
    if (editor.selectedObjectId case final id?) {
      editor.duplicateObject(id);
    } else if (editor.selectedRoomId case final id?) {
      editor.duplicateRoom(id);
    }
  }

  Future<void> _deleteSelected() async {
    if (editor.selectedObjectId case final id?) {
      await deleteObject(id);
    } else if (editor.selectedRoomId case final id?) {
      await deleteRoom(id);
    }
  }

  // --- Keyboard ------------------------------------------------------------------

  /// True while a text field has focus: shortcuts must not steal typing.
  bool get _typing {
    final ctx = FocusManager.instance.primaryFocus?.context;
    return ctx != null &&
        ctx.findAncestorStateOfType<EditableTextState>() != null;
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (_typing) return KeyEventResult.ignored;
    final keys = HardwareKeyboard.instance;
    final ctrl = keys.isControlPressed || keys.isMetaPressed;
    final shift = keys.isShiftPressed;
    final k = e.logicalKey;
    final repeat = e is KeyRepeatEvent;
    if (editing) {
      final handled = _editorKey(k, ctrl: ctrl, shift: shift, repeat: repeat);
      if (handled) return KeyEventResult.handled;
    }
    if (repeat) return KeyEventResult.ignored;
    switch (k) {
      case LogicalKeyboardKey.escape:
        interaction.select(null);
        widget.registry.clearSelection();
      case LogicalKeyboardKey.equal || LogicalKeyboardKey.numpadAdd:
        game.view.zoomAt(_center, 1.25);
        _moved();
      case LogicalKeyboardKey.minus || LogicalKeyboardKey.numpadSubtract:
        game.view.zoomAt(_center, 0.8);
        _moved();
      case LogicalKeyboardKey.digit0 || LogicalKeyboardKey.numpad0:
        game.view.reset(animate: true);
        game.userMovedCamera = false;
        game.wake();
      default:
        return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  bool _editorKey(
    LogicalKeyboardKey k, {
    required bool ctrl,
    required bool shift,
    required bool repeat,
  }) {
    if (ctrl) {
      if (k == LogicalKeyboardKey.keyZ) {
        shift ? editor.redo() : editor.undo();
      } else if (k == LogicalKeyboardKey.keyY) {
        editor.redo();
      } else if (k == LogicalKeyboardKey.keyS && !repeat) {
        unawaited(save());
      } else if (k == LogicalKeyboardKey.keyD && !repeat) {
        unawaited(_duplicateSelected());
      } else {
        return false;
      }
      return true;
    }
    final step = shift ? EditorLimits.fineSnap : EditorLimits.snap;
    final obj = editor.selectedObjectId, room = editor.selectedRoomId;
    void nudge(double dx, double dy) {
      if (obj != null) {
        editor.nudgeObject(obj, dx * step, dy * step);
      } else if (room != null) {
        final r = editor.selectedRoom!;
        editor.moveRoom(room, r.origin.copyWithDelta(dx, dy));
      }
    }

    switch (k) {
      case LogicalKeyboardKey.escape:
        editor.cancel();
      case LogicalKeyboardKey.delete || LogicalKeyboardKey.backspace:
        if (repeat) return true;
        unawaited(_deleteSelected());
      case LogicalKeyboardKey.keyR:
        if (repeat) return true;
        editor.rotate();
      case LogicalKeyboardKey.keyG:
        if (repeat) return true;
        editor.toggleGrid();
      case LogicalKeyboardKey.keyF:
        if (obj != null) focusObject(obj);
        if (room != null) focusRoom(room);
      case LogicalKeyboardKey.enter || LogicalKeyboardKey.numpadEnter:
        if (editor.tool == EditorTool.placeRoom) {
          editor.confirmRoomPlacement();
        } else if (editor.tool == EditorTool.place) {
          editor.confirmPlacement();
        } else {
          return false;
        }
      case LogicalKeyboardKey.arrowUp:
        nudge(0, -1);
      case LogicalKeyboardKey.arrowDown:
        nudge(0, 1);
      case LogicalKeyboardKey.arrowLeft:
        nudge(-1, 0);
      case LogicalKeyboardKey.arrowRight:
        nudge(1, 0);
      default:
        return false;
    }
    return true;
  }

  // --- Build-mode pointer handling ----------------------------------------------

  ObjectGeometry? _pickEditable(Offset local) =>
      widget.scene.layout?.hitTestEditable(_world(local));

  SceneRoom? _roomAtLocal(Offset local) {
    final doc = editor.document;
    if (doc == null) return null;
    final (x, y) = Iso.unproject(_world(local));
    return doc.rooms
        .where(
          (r) =>
              x >= r.origin.x &&
              x < r.origin.x + r.size.w &&
              y >= r.origin.y &&
              y < r.origin.y + r.size.d,
        )
        .firstOrNull;
  }

  RoomEdge? _handleAt(Offset local) {
    final r = editor.selectedRoom;
    if (r == null) return null;
    for (final MapEntry(:key, :value) in roomHandles(r).entries) {
      if ((game.view.worldToScreen(value) - local).distance <= 12) return key;
    }
    return null;
  }

  void _editorPointerDown(PointerDownEvent e) {
    _downAt = e.localPosition;
    _press = _Press.none;
    _pressObject = null;
    _pressEdge = null;
    if (e.buttons != kPrimaryMouseButton || editor.tool != EditorTool.select) {
      return;
    }
    final edge = _handleAt(e.localPosition);
    if (edge != null) {
      _press = _Press.resizeRoom;
      _pressEdge = edge;
      return;
    }
    final g = _pickEditable(e.localPosition);
    // Only an already selected object can be dragged: the first click
    // selects, so selecting never moves anything by accident.
    if (g != null) {
      if (g.object.id == editor.selectedObjectId) {
        _press = _Press.moveObject;
        _pressObject = g.object.id;
      }
      return;
    }
    final room = _roomAtLocal(e.localPosition);
    if (room != null && room.id == editor.selectedRoomId) {
      _press = _Press.moveRoom;
    }
  }

  bool get _fine => HardwareKeyboard.instance.isAltPressed;

  void _editorTapUp(TapUpDetails d) {
    final at = d.localPosition;
    switch (editor.tool) {
      case EditorTool.place:
        editor.hover(_world(at), fine: _fine);
        editor.confirmPlacement(
          keepPlacing: HardwareKeyboard.instance.isShiftPressed,
        );
      case EditorTool.placeRoom:
        editor.hover(_world(at));
        editor.confirmRoomPlacement();
      case EditorTool.select:
        final g = _pickEditable(at);
        if (g != null) {
          editor.selectObject(g.object.id);
        } else if (_roomAtLocal(at) case final r?) {
          editor.selectRoom(r.id);
        } else {
          editor.clearSelection();
        }
      default:
        break;
    }
    _focus.requestFocus();
  }

  void _editorScaleStart(ScaleStartDetails d) {
    _lastScale = 1;
    final down = _downAt;
    if (d.pointerCount != 1 || down == null) return;
    switch (_press) {
      case _Press.moveObject:
        editor.beginMove(_pressObject!, _world(down));
        _dragging = true;
      case _Press.moveRoom:
        editor.beginRoomMove(editor.selectedRoomId!, _world(down));
        _dragging = true;
      case _Press.resizeRoom:
        editor.beginRoomResize(
          editor.selectedRoomId!,
          _pressEdge!,
          _world(down),
        );
        _dragging = true;
      case _Press.none:
        break;
    }
  }

  void _editorScaleUpdate(ScaleUpdateDetails d) {
    if (_dragging) {
      editor.hover(_world(d.localFocalPoint), fine: _fine);
      return;
    }
    _viewScaleUpdate(d);
  }

  void _editorScaleEnd(ScaleEndDetails d) {
    if (!_dragging) return;
    _dragging = false;
    if (editor.tool == EditorTool.moveObject) {
      editor.endMove();
    } else {
      editor.endRoomDrag();
    }
  }

  void _viewScaleUpdate(ScaleUpdateDetails d) {
    if (d.pointerCount > 1 || d.scale != 1) {
      game.view.zoomAt(d.localFocalPoint, d.scale / _lastScale);
      _lastScale = d.scale;
    }
    game.view.panBy(d.focalPointDelta);
    _moved();
  }

  Future<void> _contextMenu(Offset local, Offset global) async {
    if (editing) return _editorContextMenu(local, global);
    final g = interaction.pick(local);
    if (g == null) return;
    interaction.select(g.object.id);
    final p = _pres(g);
    final bound = g.object.entityBinding != null;
    final choice = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        global.dx,
        global.dy,
        global.dx,
        global.dy,
      ),
      items: [
        PopupMenuItem(
          value: 'open',
          enabled: _canOpen(p),
          child: const Text('Открыть'),
        ),
        const PopupMenuItem(value: 'info', child: Text('Информация')),
        PopupMenuItem(
          value: 'find',
          enabled: bound,
          child: const Text('Найти в Registry'),
        ),
        const PopupMenuItem(value: 'props', child: Text('Свойства')),
      ],
    );
    if (!mounted) return;
    switch (choice) {
      case 'open':
        await _openDetails(g);
      case 'info':
        interaction.select(g.object.id);
      case 'find':
        widget.onShowInRegistry(g.object.entityBinding!.entityId);
      case 'props':
        await showObjectProperties(context, g, p);
    }
  }

  PopupMenuItem<String> _item(
    String v,
    IconData icon,
    String label, {
    String? hint,
    bool enabled = true,
  }) => PopupMenuItem(
    value: v,
    enabled: enabled,
    height: 40,
    child: Row(
      children: [
        Icon(
          icon,
          size: 18,
          color: enabled ? AerColors.ink : AerColors.inkMuted,
        ),
        const SizedBox(width: 10),
        Expanded(child: Text(label)),
        if (hint != null)
          Text(
            hint,
            style: Theme.of(context).textTheme.labelSmall
                ?.copyWith(color: AerColors.inkMuted),
          ),
      ],
    ),
  );

  Future<void> _editorContextMenu(Offset local, Offset global) async {
    if (editor.tool != EditorTool.select) {
      editor.cancel();
      return;
    }
    final pos = RelativeRect.fromLTRB(
      global.dx,
      global.dy,
      global.dx,
      global.dy,
    );
    final g = _pickEditable(local);
    if (g != null) {
      final id = g.object.id;
      editor.selectObject(id);
      final bound = g.object.entityBinding != null;
      final choice = await showMenu<String>(
        context: context,
        position: pos,
        items: [
          _item('rotate', Icons.rotate_right_rounded, 'Повернуть', hint: 'R'),
          _item('dup', Icons.copy_rounded, 'Дублировать', hint: 'Ctrl+D'),
          _item(
            'bind',
            Icons.link_rounded,
            bound ? 'Сменить устройство…' : 'Привязать устройство…',
            enabled: widget.registry.canEdit,
          ),
          if (bound) _item('unbind', Icons.link_off_rounded, 'Отвязать'),
          _item(
            'focus',
            Icons.center_focus_strong_outlined,
            'Показать',
            hint: 'F',
          ),
          const PopupMenuDivider(),
          _item('delete', Icons.delete_outline_rounded, 'Удалить', hint: 'Del'),
        ],
      );
      if (!mounted) return;
      switch (choice) {
        case 'rotate':
          editor.rotateObject(id);
        case 'dup':
          editor.duplicateObject(id);
        case 'bind':
          await bindObject(id);
        case 'unbind':
          editor.unbindObject(id);
        case 'focus':
          focusObject(id);
        case 'delete':
          await deleteObject(id);
      }
      return;
    }
    final r = _roomAtLocal(local);
    if (r == null) return;
    editor.selectRoom(r.id);
    final choice = await showMenu<String>(
      context: context,
      position: pos,
      items: [
        _item('dup', Icons.copy_rounded, 'Дублировать комнату', hint: 'Ctrl+D'),
        _item(
          'focus',
          Icons.center_focus_strong_outlined,
          'Показать',
          hint: 'F',
        ),
        const PopupMenuDivider(),
        _item(
          'delete',
          Icons.delete_outline_rounded,
          'Удалить комнату',
          hint: 'Del',
        ),
      ],
    );
    if (!mounted) return;
    switch (choice) {
      case 'dup':
        editor.duplicateRoom(r.id);
      case 'focus':
        focusRoom(r.id);
      case 'delete':
        await deleteRoom(r.id);
    }
  }

  MouseCursor get _cursor {
    if (!editing) {
      return interaction.hoveredId != null
          ? SystemMouseCursors.click
          : SystemMouseCursors.grab;
    }
    return switch (editor.tool) {
      EditorTool.place || EditorTool.placeRoom => SystemMouseCursors.precise,
      EditorTool.moveObject ||
      EditorTool.moveRoom => SystemMouseCursors.grabbing,
      EditorTool.resizeRoom => SystemMouseCursors.resizeUpLeftDownRight,
      EditorTool.select =>
        interaction.hoveredId != null &&
                interaction.hoveredId == editor.selectedObjectId
            ? SystemMouseCursors.move
            : interaction.hoveredId != null
            ? SystemMouseCursors.click
            : SystemMouseCursors.basic,
    };
  }

  // --- Build ------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final scene = widget.scene;
    game.reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final layout = scene.layout;
    if (layout == null) {
      return Center(
        child: scene.loading || scene.error == null
            ? const CircularProgressIndicator()
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(describeError(scene.error!)),
                  const SizedBox(height: AerSpacing.m),
                  OutlinedButton(
                    onPressed: scene.load,
                    child: const Text('Повторить'),
                  ),
                ],
              ),
      );
    }
    return Focus(
      onKeyEvent: _onKey,
      child: LayoutBuilder(
        builder: (context, box) => editing
            ? _editorLayout(context, layout, box.biggest)
            : _viewLayout(context, layout),
      ),
    );
  }

  Widget _viewLayout(BuildContext context, SceneLayout layout) {
    final scene = widget.scene;
    // Expand: overlay children may be non-positioned when hidden, and the
    // section gets loose constraints from the IndexedStack.
    return Stack(
      fit: StackFit.expand,
      children: [
        _sceneSlot(layout, EdgeInsets.zero),
        Positioned(
          left: AerSpacing.m,
          top: AerSpacing.m,
          right: 300,
          child: _SourceBar(scene: scene),
        ),
        Positioned(
          right: 84,
          top: AerSpacing.m,
          child: FilledButton.icon(
            key: const Key('house-edit'),
            onPressed: scene.document == null ? null : _enterEditor,
            icon: const Icon(Icons.handyman_outlined, size: 18),
            label: const Text('Редактировать дом'),
          ),
        ),
        Positioned(
          right: AerSpacing.m,
          top: AerSpacing.m,
          child: _cameraControls(),
        ),
        if (_legend)
          Positioned(
            right: AerSpacing.m,
            top: 210,
            child: SceneLegend(onClose: () => setState(() => _legend = false)),
          ),
        if (editor.pendingDraft != null)
          Positioned(
            top: 64,
            left: AerSpacing.m,
            right: 84,
            child: Align(
              alignment: Alignment.topLeft,
              child: _draftBanner(context),
            ),
          ),
        Positioned(
          left: AerSpacing.m,
          right: AerSpacing.m,
          bottom: AerSpacing.m,
          child: _RoomBar(
            layout: layout,
            onRoom: (r) {
              game.view.focusRect(r.focusBounds);
              game.userMovedCamera = true;
              game.wake();
            },
            onAll: () {
              game.view.reset(animate: true);
              game.userMovedCamera = false;
              game.wake();
            },
          ),
        ),
        _hoverOverlay(),
        if (interaction.selected case final g?)
          if (_pres(g) case final p?)
            Positioned(
              left: AerSpacing.m,
              bottom: 76,
              width: 340,
              child: QuickCard(
                geometry: g,
                presentation: p,
                capabilityLabel: (c) =>
                    widget.registry.catalog?.capabilityLabel(c) ??
                    p.snapshot?.capabilityLabels[c] ??
                    c,
                onClose: () => interaction.select(null),
                onOpen: _canOpen(p) ? () => _openDetails(g) : null,
                onProperties: () => showObjectProperties(context, g, p),
                onDiagnostics:
                    widget.onOpenDiagnostics == null ||
                        g.object.entityBinding == null
                    ? null
                    : () => widget.onOpenDiagnostics!(
                        g.object.entityBinding!.entityId,
                      ),
                extra: g.object.entityBinding == null
                    ? null
                    : widget.entityPanel?.call(
                        g.object.entityBinding!.entityId,
                      ),
              ),
            ),
        if (_details &&
            widget.registry.selected != null &&
            widget.registry.catalog != null)
          Positioned(
            right: 0,
            top: 0,
            bottom: 0,
            width: 400,
            child: Material(
              elevation: 8,
              color: AerColors.surface,
              child: EntityDetails(registry: widget.registry),
            ),
          ),
      ],
    );
  }

  Widget _draftBanner(BuildContext context) {
    final d = editor.pendingDraft!;
    final text = Theme.of(context).textTheme;
    final at = d.savedAt.toLocal();
    final time =
        '${at.day.toString().padLeft(2, '0')}.${at.month.toString().padLeft(2, '0')} '
        '${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}';
    return Material(
      key: const Key('draft-banner'),
      color: AerColors.surface,
      elevation: 3,
      shadowColor: AerColors.ink.withValues(alpha: 0.2),
      borderRadius: BorderRadius.circular(AerRadii.medium),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
        child: Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: AerSpacing.s,
          runSpacing: AerSpacing.xs,
          children: [
            const Icon(Icons.edit_note_rounded, color: AerColors.amber),
            Text(
              'Найден несохранённый черновик от $time'
              '${d.changes > 0 ? ' · ${d.changes} ${plural(d.changes, 'изменение', 'изменения', 'изменений')}' : ''}',
              style: text.bodyMedium,
            ),
            if (editor.draftOutdated)
              Text(
                'версия в Core с тех пор изменилась',
                style: text.bodySmall?.copyWith(color: AerColors.amber),
              ),
            FilledButton.tonal(
              key: const Key('draft-restore'),
              onPressed: () async {
                await editor.restoreDraft();
                _focus.requestFocus();
              },
              child: const Text('Восстановить'),
            ),
            TextButton(
              key: const Key('draft-discard'),
              onPressed: editor.discardDraft,
              child: const Text('Удалить черновик'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _cameraControls() => _CameraControls(
    onZoomIn: () {
      game.view.zoomAt(_center, 1.25);
      _moved();
    },
    onZoomOut: () {
      game.view.zoomAt(_center, 0.8);
      _moved();
    },
    onReset: () {
      game.view.reset(animate: true);
      game.userMovedCamera = false;
      game.wake();
    },
    legendOpen: _legend,
    onLegend: editing ? null : () => setState(() => _legend = !_legend),
  );

  Widget _editorLayout(BuildContext context, SceneLayout layout, Size size) {
    final wide = size.width >= 1250;
    final left = wide ? 300.0 : 264.0;
    final right = wide ? 316.0 : 280.0;
    const gap = AerSpacing.s;
    const top = 52.0 + gap * 2;
    const bottom = 36.0 + gap * 2;
    return Stack(
      fit: StackFit.expand,
      children: [
        _sceneSlot(
          layout,
          EdgeInsets.fromLTRB(left + gap * 2, top, right + gap * 2, bottom),
        ),
        Positioned(
          left: gap,
          right: gap,
          top: gap,
          child: EditorTopBar(
            editor: editor,
            scene: widget.scene,
            actions: this,
          ),
        ),
        Positioned(
          left: gap,
          top: top,
          bottom: bottom,
          width: left,
          child: EditorSidePanel(
            editor: editor,
            scene: widget.scene,
            actions: this,
          ),
        ),
        Positioned(
          right: gap,
          top: top,
          bottom: bottom,
          width: right,
          child: editor.selectedObject != null || editor.selectedRoom != null
              ? EditorInspector(
                  editor: editor,
                  scene: widget.scene,
                  actions: this,
                  canBind: widget.registry.canEdit,
                )
              : _HistoryPanel(editor: editor),
        ),
        Positioned(
          right: right + gap * 3,
          top: top + gap,
          child: _cameraControls(),
        ),
        Positioned(
          left: gap,
          right: gap,
          bottom: gap,
          child: ValueListenableBuilder<int>(
            valueListenable: game.viewChanged,
            builder: (context, _, _) => EditorStatusBar(
              editor: editor,
              zoom: game.view.zoom,
              onToggleGrid: editor.toggleGrid,
            ),
          ),
        ),
        Positioned(
          left: left + gap * 2,
          right: right + gap * 2,
          top: top,
          bottom: bottom,
          child: IgnorePointer(child: _hoverOverlay()),
        ),
      ],
    );
  }

  bool _dropping = false;

  /// The scene keeps the same keyed slot in both modes, so switching modes
  /// never remounts the GameWidget (a remount detaches the Flame game).
  Widget _sceneSlot(SceneLayout layout, EdgeInsets insets) => Positioned(
    key: const ValueKey('scene-slot'),
    left: insets.left,
    top: insets.top,
    right: insets.right,
    bottom: insets.bottom,
    child: ClipRRect(
      borderRadius: BorderRadius.circular(editing ? AerRadii.medium : 0),
      child: DragTarget<String>(
        onWillAcceptWithDetails: (_) => editing,
        onMove: (d) => _catalogDrag(d.data, d.offset),
        onLeave: (_) {
          if (editor.tool == EditorTool.place && !_dropping) {
            editor.cancel();
          }
        },
        onAcceptWithDetails: (d) {
          _dropping = true;
          _catalogDrag(d.data, d.offset);
          editor.confirmPlacement();
          _dropping = false;
          _focus.requestFocus();
        },
        builder: (context, _, _) => _sceneSurface(layout.document.name, layout),
      ),
    ),
  );

  void _catalogDrag(String assetId, Offset global) {
    final box = _surfaceKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    if (editor.tool != EditorTool.place || editor.placingAsset?.id != assetId) {
      editor.startPlacing(assetId);
    }
    editor.hover(_world(box.globalToLocal(global)), fine: _fine);
  }

  Offset get _center =>
      Offset(game.view.viewport.width / 2, game.view.viewport.height / 2);

  Widget _sceneSurface(String name, SceneLayout layout) {
    return Semantics(
      label:
          'Изометрический дом «$name»: ${layout.rooms.length} комнат, ${layout.objects.length} объектов. '
          'Список устройств доступен в разделе «Устройства».',
      child: Focus(
        focusNode: _focus,
        child: Listener(
          onPointerDown: (e) {
            _focus.requestFocus();
            if (editing) _editorPointerDown(e);
          },
          onPointerSignal: (e) {
            if (e is PointerScrollEvent) {
              game.view.zoomAt(
                e.localPosition,
                math.pow(1.0018, -e.scrollDelta.dy).toDouble(),
              );
              _moved();
            }
          },
          child: MouseRegion(
            cursor: _cursor,
            onHover: (e) {
              if (editing &&
                  (editor.tool == EditorTool.place ||
                      editor.tool == EditorTool.placeRoom)) {
                editor.hover(_world(e.localPosition), fine: _fine);
                interaction.hover(null);
              } else {
                interaction.hover(e.localPosition);
              }
            },
            onExit: (_) => interaction.hover(null),
            child: GestureDetector(
              key: const Key('scene-surface'),
              behavior: HitTestBehavior.opaque,
              onTapUp: editing
                  ? _editorTapUp
                  : (d) => interaction.tap(d.localPosition),
              onDoubleTapDown: editing
                  ? null
                  : (d) => _doubleTapAt = d.localPosition,
              onDoubleTap: editing
                  ? null
                  : () {
                      final at = _doubleTapAt;
                      final g = at == null ? null : interaction.pick(at);
                      if (g != null) unawaited(_openDetails(g));
                    },
              onSecondaryTapUp: (d) =>
                  _contextMenu(d.localPosition, d.globalPosition),
              onScaleStart: editing ? _editorScaleStart : (_) => _lastScale = 1,
              onScaleUpdate: editing ? _editorScaleUpdate : _viewScaleUpdate,
              onScaleEnd: editing ? _editorScaleEnd : null,
              child: KeyedSubtree(
                key: _surfaceKey,
                child: GameWidget(game: game),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _hoverOverlay() {
    return ValueListenableBuilder<int>(
      valueListenable: game.viewChanged,
      builder: (context, _, _) {
        final g = interaction.hovered;
        final p = _pres(g);
        if (g == null ||
            p == null ||
            _dragging ||
            g.object.id ==
                (editing ? editor.selectedObjectId : interaction.selectedId)) {
          return const SizedBox.shrink();
        }
        final at = game.view.worldToScreen(g.topAnchor);
        return Stack(
          children: [
            Positioned(
              left: at.dx - 90,
              top: at.dy - 74,
              width: 180,
              child: IgnorePointer(
                child: Center(child: HoverLabel(presentation: p)),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Right column in build mode when nothing is selected: tips and history.
class _HistoryPanel extends StatelessWidget {
  const _HistoryPanel({required this.editor});
  final EditorController editor;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final labels = editor.history.labels.reversed.take(12).toList();
    return Container(
      key: const Key('editor-history-panel'),
      decoration: BoxDecoration(
        color: AerColors.surface.withValues(alpha: 0.97),
        borderRadius: BorderRadius.circular(AerRadii.medium),
        border: Border.all(color: AerColors.border),
      ),
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 10),
      child: ListView(
        children: [
          Text('Как обустроить дом', style: text.titleSmall),
          const SizedBox(height: AerSpacing.s),
          for (final (icon, tip) in const [
            (
              Icons.touch_app_outlined,
              'Клик — выбрать предмет или комнату, свойства появятся здесь.',
            ),
            (
              Icons.open_with_rounded,
              'Выбранный предмет можно перетащить мышью; обычный клик его не сдвинет.',
            ),
            (
              Icons.chair_outlined,
              'Предметы из каталога ставятся кликом или перетаскиванием.',
            ),
            (
              Icons.rotate_right_rounded,
              'R — повернуть, Ctrl+D — копия, Del — удалить.',
            ),
            (
              Icons.undo_rounded,
              'Ctrl+Z / Ctrl+Shift+Z — отменить и повторить.',
            ),
          ])
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(icon, size: 18, color: AerColors.accent),
                  const SizedBox(width: 8),
                  Expanded(child: Text(tip, style: text.bodySmall)),
                ],
              ),
            ),
          const Divider(height: 24),
          Text('История', style: text.titleSmall),
          const SizedBox(height: AerSpacing.xs),
          if (labels.isEmpty)
            Text(
              'Изменений пока нет',
              style: text.bodySmall?.copyWith(color: AerColors.inkMuted),
            )
          else
            for (final (i, l) in labels.indexed)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  children: [
                    Icon(
                      i == 0
                          ? Icons.radio_button_checked_rounded
                          : Icons.circle_outlined,
                      size: 12,
                      color: i == 0 ? AerColors.accent : AerColors.border,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        l,
                        style: text.bodySmall,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
        ],
      ),
    );
  }
}

extension on Point2 {
  Point2 copyWithDelta(double dx, double dy) => Point2(x + dx, y + dy);
}

class _SourceBar extends StatelessWidget {
  const _SourceBar({required this.scene});
  final SceneController scene;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final hasDemoStates =
        scene.document?.objects.any((o) => o.demoState != null) ?? false;
    final link = scene.registryLink;
    final bound = scene.document?.boundEntityIds.isNotEmpty ?? false;
    return Align(
      alignment: Alignment.topLeft,
      child: Wrap(
        spacing: AerSpacing.s,
        runSpacing: AerSpacing.s,
        crossAxisAlignment: WrapCrossAlignment.center,
        children:
            [
                  _Pill(
                    icon: switch (scene.source) {
                      SceneSource.core => Icons.cloud_done_outlined,
                      SceneSource.cache => Icons.history_rounded,
                      _ => Icons.draw_outlined,
                    },
                    text: sourceText(
                      scene.source.name,
                      revision: scene.revision,
                      at: scene.cachedAt,
                    ),
                    tone: scene.source == SceneSource.cache
                        ? AerColors.amber
                        : AerColors.inkMuted,
                  ),
                  if (scene.source == SceneSource.bundled)
                    FilledButton.tonalIcon(
                      key: const Key('scene-save'),
                      onPressed: scene.canSave
                          ? () async {
                              final messenger = ScaffoldMessenger.of(context);
                              try {
                                await scene.save();
                                messenger.showSnackBar(
                                  const SnackBar(
                                    content: Text(
                                      'Планировка сохранена в Core',
                                    ),
                                  ),
                                );
                              } catch (e) {
                                messenger.showSnackBar(
                                  SnackBar(content: Text(describeError(e))),
                                );
                              }
                            }
                          : null,
                      icon: const Icon(Icons.save_outlined, size: 16),
                      label: const Text('Сохранить в Core'),
                    ),
                  if (hasDemoStates)
                    const _Pill(
                      icon: Icons.science_outlined,
                      text: 'Состояния — тестовые',
                      tone: AerColors.lavender,
                    ),
                  if (bound && link != RegistryLink.live)
                    _Pill(
                      icon: Icons.link_off_rounded,
                      text: link == RegistryLink.loading
                          ? 'Registry: загрузка'
                          : 'Registry: данные устарели',
                      tone: AerColors.amber,
                    ),
                  if (scene.cacheIssue != null)
                    Tooltip(
                      message: scene.cacheIssue!,
                      child: const _Pill(
                        icon: Icons.warning_amber_rounded,
                        text: 'Кэш сцены был повреждён',
                        tone: AerColors.terracotta,
                      ),
                    ),
                  if (scene.saving)
                    const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                ]
                .map(
                  (w) =>
                      DefaultTextStyle.merge(style: text.labelMedium, child: w),
                )
                .toList(),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.icon, required this.text, required this.tone});
  final IconData icon;
  final String text;
  final Color tone;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    decoration: BoxDecoration(
      color: AerColors.surface.withValues(alpha: 0.92),
      borderRadius: BorderRadius.circular(AerRadii.large),
      border: Border.all(color: AerColors.border),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: tone),
        const SizedBox(width: 6),
        Flexible(child: Text(text, overflow: TextOverflow.ellipsis)),
      ],
    ),
  );
}

class _CameraControls extends StatelessWidget {
  const _CameraControls({
    required this.onZoomIn,
    required this.onZoomOut,
    required this.onReset,
    this.onLegend,
    required this.legendOpen,
  });

  final VoidCallback onZoomIn, onZoomOut, onReset;

  /// Null hides the legend button (build mode).
  final VoidCallback? onLegend;
  final bool legendOpen;

  @override
  Widget build(BuildContext context) {
    Widget btn(
      String key,
      IconData icon,
      String tip,
      VoidCallback onTap, {
      bool active = false,
    }) => IconButton(
      key: Key(key),
      tooltip: tip,
      onPressed: onTap,
      isSelected: active,
      icon: Icon(icon, size: 20),
    );
    return Material(
      color: AerColors.surface.withValues(alpha: 0.94),
      borderRadius: BorderRadius.circular(AerRadii.medium),
      elevation: 2,
      shadowColor: AerColors.ink.withValues(alpha: 0.2),
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            btn('scene-zoom-in', Icons.add_rounded, 'Приблизить (+)', onZoomIn),
            btn(
              'scene-zoom-out',
              Icons.remove_rounded,
              'Отдалить (−)',
              onZoomOut,
            ),
            btn(
              'scene-reset',
              Icons.center_focus_strong_outlined,
              'Весь дом (0)',
              onReset,
            ),
            if (onLegend case final legend?)
              btn(
                'scene-legend-toggle',
                Icons.info_outline_rounded,
                'Обозначения',
                legend,
                active: legendOpen,
              ),
          ],
        ),
      ),
    );
  }
}

class _RoomBar extends StatelessWidget {
  const _RoomBar({
    required this.layout,
    required this.onRoom,
    required this.onAll,
  });
  final SceneLayout layout;
  final ValueChanged<RoomGeometry> onRoom;
  final VoidCallback onAll;

  @override
  Widget build(BuildContext context) {
    final rooms = [...layout.rooms]
      ..sort(
        (a, b) => layout.document.rooms
            .indexOf(a.room)
            .compareTo(layout.document.rooms.indexOf(b.room)),
      );
    return Center(
      child: Material(
        color: AerColors.surface.withValues(alpha: 0.94),
        borderRadius: BorderRadius.circular(AerRadii.large),
        elevation: 2,
        shadowColor: AerColors.ink.withValues(alpha: 0.2),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.all(6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _RoomChip(
                key: const Key('room-all'),
                icon: Icons.home_outlined,
                label: 'Весь дом',
                onTap: onAll,
              ),
              for (final r in rooms)
                _RoomChip(
                  key: Key('room-${r.room.kind}'),
                  icon: roomIcon(r.room.kind),
                  label: r.room.name,
                  onTap: () => onRoom(r),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RoomChip extends StatelessWidget {
  const _RoomChip({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
  });
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 2),
    child: TextButton.icon(
      onPressed: onTap,
      style: TextButton.styleFrom(
        foregroundColor: AerColors.ink,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AerRadii.medium),
        ),
      ),
      icon: Icon(icon, size: 18, color: AerColors.accent),
      label: Text(label),
    ),
  );
}
