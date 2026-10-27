import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;

import '../../../scene/binding/scene_binding.dart';
import '../../../scene/catalog/scene_catalog.dart';
import '../../../scene/editor/editor_controller.dart';
import '../../../scene/editor/placement.dart';
import '../../../scene/model/scene_document.dart';
import '../../../scene/scene_controller.dart';
import '../../../theme/tokens.dart';
import '../scene_overlays.dart';
import 'asset_preview.dart';
import 'editor_dialogs.dart';

/// Actions the panels ask the house view to perform (dialogs, camera).
abstract interface class EditorActions {
  void focusObject(String id);
  void focusRoom(String id);
  Future<void> bindObject(String id);
  Future<void> deleteObject(String id);
  Future<void> deleteRoom(String id);
  Future<void> newRoom();
  Future<void> save();
  Future<void> exit();
}

IconData categoryIcon(String icon) => switch (icon) {
  'chair' => Icons.chair_outlined,
  'computer' => Icons.computer_outlined,
  'dns' => Icons.dns_outlined,
  'router' => Icons.router_outlined,
  'tv' => Icons.tv_outlined,
  'bot' => Icons.smart_toy_outlined,
  'plant' => Icons.local_florist_outlined,
  _ => Icons.category_outlined,
};

String placementLabel(Placement p) => switch (p) {
  Placement.floor => 'На полу',
  Placement.surface => 'На полу или на поверхности',
  Placement.wall => 'На стене',
  Placement.overlay => 'Покрытие пола (под мебелью)',
};

BoxDecoration _panelDecoration() => BoxDecoration(
  color: AerColors.surface.withValues(alpha: 0.97),
  borderRadius: BorderRadius.circular(AerRadii.medium),
  border: Border.all(color: AerColors.border),
  // A small, cheap shadow: panels are recomposited on every scene frame.
  boxShadow: [
    BoxShadow(
      color: AerColors.ink.withValues(alpha: 0.08),
      blurRadius: 4,
      offset: const Offset(0, 2),
    ),
  ],
);

// --- Top bar ---------------------------------------------------------------------

class EditorTopBar extends StatelessWidget {
  const EditorTopBar({
    super.key,
    required this.editor,
    required this.scene,
    required this.actions,
  });

  final EditorController editor;
  final SceneController scene;
  final EditorActions actions;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final name = editor.document?.name ?? scene.document?.name ?? '';
    final h = editor.history;
    return Container(
      key: const Key('editor-top-bar'),
      height: 52,
      padding: const EdgeInsets.symmetric(horizontal: AerSpacing.s),
      decoration: _panelDecoration(),
      child: Row(
        children: [
          const SizedBox(width: AerSpacing.xs),
          const Icon(
            Icons.construction_rounded,
            color: AerColors.accent,
            size: 20,
          ),
          const SizedBox(width: AerSpacing.s),
          Flexible(
            child: Text(
              name,
              style: text.titleSmall,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: AerSpacing.m),
          SegmentedButton<bool>(
            key: const Key('editor-mode-switch'),
            showSelectedIcon: false,
            style: const ButtonStyle(visualDensity: VisualDensity.compact),
            segments: const [
              ButtonSegment(
                value: false,
                icon: Icon(Icons.visibility_outlined, size: 16),
                label: Text('Просмотр'),
              ),
              ButtonSegment(
                value: true,
                icon: Icon(Icons.handyman_outlined, size: 16),
                label: Text('Строительство'),
              ),
            ],
            selected: const {true},
            onSelectionChanged: (s) {
              if (!s.first) actions.exit();
            },
          ),
          const Spacer(),
          IconButton(
            key: const Key('editor-undo'),
            tooltip: h.canUndo
                ? 'Отменить: ${h.undoLabel} (Ctrl+Z)'
                : 'Нечего отменять',
            onPressed: h.canUndo ? editor.undo : null,
            icon: const Icon(Icons.undo_rounded),
          ),
          IconButton(
            key: const Key('editor-redo'),
            tooltip: h.canRedo
                ? 'Повторить: ${h.redoLabel} (Ctrl+Shift+Z)'
                : 'Нечего повторять',
            onPressed: h.canRedo ? editor.redo : null,
            icon: const Icon(Icons.redo_rounded),
          ),
          const SizedBox(width: AerSpacing.xs),
          FilledButton.icon(
            key: const Key('editor-save'),
            onPressed:
                editor.saving ||
                    !(editor.dirty || scene.source == SceneSource.bundled)
                ? null
                : actions.save,
            icon: editor.saving
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: AerColors.surface,
                    ),
                  )
                : const Icon(Icons.save_outlined, size: 18),
            label: const Text('Сохранить'),
          ),
          const SizedBox(width: AerSpacing.xs),
          TextButton.icon(
            key: const Key('editor-exit'),
            onPressed: actions.exit,
            icon: const Icon(Icons.logout_rounded, size: 18),
            label: const Text('Выйти'),
          ),
        ],
      ),
    );
  }
}

// --- Left panel: catalog / rooms / objects --------------------------------------------

class EditorSidePanel extends StatefulWidget {
  const EditorSidePanel({
    super.key,
    required this.editor,
    required this.scene,
    required this.actions,
  });

  final EditorController editor;
  final SceneController scene;
  final EditorActions actions;

  @override
  State<EditorSidePanel> createState() => _EditorSidePanelState();
}

class _EditorSidePanelState extends State<EditorSidePanel> {
  int _tab = 0;
  String _query = '';
  String? _category;
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('editor-side-panel'),
      decoration: _panelDecoration(),
      clipBehavior: Clip.antiAlias,
      // ListTiles paint on the nearest Material: keep one inside the panel.
      child: Material(
        type: MaterialType.transparency,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
              child: _Tabs(
                labels: const ['Каталог', 'Комнаты', 'Объекты'],
                selected: _tab,
                onSelected: (i) => setState(() => _tab = i),
              ),
            ),
            Expanded(
              child: switch (_tab) {
                0 => _catalog(context),
                1 => _rooms(context),
                _ => _objects(context),
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _catalog(BuildContext context) {
    final cat = widget.editor.catalog;
    final text = Theme.of(context).textTheme;
    final items = cat.search(query: _query, category: _category).toList();
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 4, 8, 6),
          child: TextField(
            key: const Key('catalog-search'),
            controller: _search,
            decoration: InputDecoration(
              isDense: true,
              prefixIcon: const Icon(Icons.search_rounded, size: 20),
              hintText: 'Найти предмет',
              suffixIcon: _query.isEmpty
                  ? null
                  : IconButton(
                      tooltip: 'Очистить',
                      icon: const Icon(Icons.close_rounded, size: 18),
                      onPressed: () => setState(() {
                        _search.clear();
                        _query = '';
                      }),
                    ),
            ),
            onChanged: (v) => setState(() => _query = v),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Wrap(
            spacing: 4,
            runSpacing: 4,
            children: [
              ChoiceChip(
                key: const Key('catalog-cat-all'),
                label: const Text('Все'),
                showCheckmark: false,
                visualDensity: VisualDensity.compact,
                selected: _category == null,
                onSelected: (_) => setState(() => _category = null),
              ),
              for (final c in cat.categories)
                ChoiceChip(
                  key: Key('catalog-cat-${c.id}'),
                  showCheckmark: false,
                  avatar: Icon(categoryIcon(c.icon), size: 16),
                  label: Text(c.label),
                  visualDensity: VisualDensity.compact,
                  selected: _category == c.id,
                  onSelected: (_) => setState(
                    () => _category = _category == c.id ? null : c.id,
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 4),
        Expanded(
          child: items.isEmpty
              ? Center(
                  child: Text(
                    'Ничего не нашлось',
                    style: text.bodyMedium?.copyWith(color: AerColors.inkMuted),
                  ),
                )
              : GridView.builder(
                  padding: const EdgeInsets.all(8),
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 150,
                    mainAxisExtent: 132,
                    crossAxisSpacing: 6,
                    mainAxisSpacing: 6,
                  ),
                  itemCount: items.length,
                  itemBuilder: (context, i) => _CatalogTile(
                    asset: items[i],
                    active: widget.editor.placingAsset?.id == items[i].id,
                    onPick: () => widget.editor.startPlacing(items[i].id),
                  ),
                ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
          child: Text(
            'Нажмите на предмет или перетащите его в комнату. Графика — временная (placeholder).',
            style: text.labelSmall?.copyWith(color: AerColors.inkMuted),
          ),
        ),
      ],
    );
  }

  Widget _rooms(BuildContext context) {
    final e = widget.editor;
    final doc = e.document;
    final text = Theme.of(context).textTheme;
    if (doc == null) return const SizedBox.shrink();
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(8),
          child: SizedBox(
            width: double.infinity,
            child: FilledButton.tonalIcon(
              key: const Key('editor-new-room'),
              onPressed: widget.actions.newRoom,
              icon: const Icon(Icons.add_home_outlined, size: 18),
              label: const Text('Новая комната'),
            ),
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            children: [
              for (final r in doc.rooms)
                ListTile(
                  key: Key('editor-room-${r.id}'),
                  dense: true,
                  selected: e.selectedRoomId == r.id,
                  selectedTileColor: AerColors.accentSoft.withValues(
                    alpha: 0.4,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(AerRadii.small),
                  ),
                  leading: Icon(roomIcon(r.kind), color: AerColors.accent),
                  title: Text(
                    r.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    '${metersLabel(r.size.w)} × ${metersLabel(r.size.d)} · '
                    '${e.objectsIn(r.id)} ${plural(e.objectsIn(r.id), 'предмет', 'предмета', 'предметов')}',
                    style: text.labelSmall,
                  ),
                  onTap: () {
                    e.selectRoom(r.id);
                    widget.actions.focusRoom(r.id);
                  },
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _objects(BuildContext context) {
    final e = widget.editor;
    final doc = e.document;
    final text = Theme.of(context).textTheme;
    if (doc == null) return const SizedBox.shrink();
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      children: [
        for (final r in doc.rooms) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 10, 10, 2),
            child: Text(
              r.name.toUpperCase(),
              style: text.labelSmall?.copyWith(
                letterSpacing: 0.8,
                color: AerColors.inkMuted,
              ),
            ),
          ),
          for (final o in doc.objectsIn(r.id))
            ListTile(
              key: Key('editor-object-${o.id}'),
              dense: true,
              visualDensity: VisualDensity.compact,
              selected: e.selectedObjectId == o.id,
              selectedTileColor: AerColors.accentSoft.withValues(alpha: 0.4),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(AerRadii.small),
              ),
              leading: Icon(
                categoryIcon(
                  e.catalog.categories
                          .where(
                            (c) => c.id == e.catalog.asset(o.assetId)?.category,
                          )
                          .firstOrNull
                          ?.icon ??
                      '',
                ),
                size: 18,
                color: AerColors.accent,
              ),
              title: Text(
                e.titleOf(o),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: o.entityBinding == null
                  ? null
                  : const Tooltip(
                      message: 'Привязан к Registry',
                      child: Icon(
                        Icons.link_rounded,
                        size: 16,
                        color: AerColors.sage,
                      ),
                    ),
              onTap: () {
                e.selectObject(o.id);
                widget.actions.focusObject(o.id);
              },
            ),
        ],
      ],
    );
  }
}

/// Compact text tabs (fit a 260 px panel without wrapping).
class _Tabs extends StatelessWidget {
  const _Tabs({
    required this.labels,
    required this.selected,
    required this.onSelected,
  });
  final List<String> labels;
  final int selected;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: AerColors.surfaceMuted,
        borderRadius: BorderRadius.circular(AerRadii.small),
      ),
      child: Row(
        children: [
          for (final (i, l) in labels.indexed)
            Expanded(
              child: GestureDetector(
                key: Key('editor-tab-$i'),
                onTap: () => onSelected(i),
                child: AnimatedContainer(
                  duration: AerMotion.short,
                  padding: const EdgeInsets.symmetric(vertical: 7),
                  decoration: BoxDecoration(
                    color: i == selected
                        ? AerColors.surface
                        : const Color(0x00000000),
                    borderRadius: BorderRadius.circular(AerRadii.small - 3),
                    boxShadow: i == selected
                        ? [
                            BoxShadow(
                              color: AerColors.ink.withValues(alpha: 0.08),
                              blurRadius: 4,
                              offset: const Offset(0, 1),
                            ),
                          ]
                        : null,
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    l,
                    maxLines: 1,
                    style: text.labelLarge?.copyWith(
                      color: i == selected ? AerColors.ink : AerColors.inkMuted,
                      fontWeight: i == selected
                          ? FontWeight.w600
                          : FontWeight.w500,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _CatalogTile extends StatelessWidget {
  const _CatalogTile({
    required this.asset,
    required this.onPick,
    required this.active,
  });
  final CatalogAsset asset;
  final VoidCallback onPick;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scene = asset.toSceneAsset();
    final tile = Material(
      color: active
          ? AerColors.accentSoft.withValues(alpha: 0.55)
          : AerColors.background,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AerRadii.small),
        side: BorderSide(color: active ? AerColors.accent : AerColors.border),
      ),
      child: InkWell(
        key: Key('catalog-item-${asset.id}'),
        borderRadius: BorderRadius.circular(AerRadii.small),
        onTap: onPick,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(6, 6, 6, 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Center(
                  child: AssetPreview(asset: scene, size: const Size(110, 66)),
                ),
              ),
              Text(
                asset.label,
                style: text.labelMedium,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '${metersLabel(asset.footprint.w)} × ${metersLabel(asset.footprint.d)}',
                      style: text.labelSmall?.copyWith(
                        color: AerColors.inkMuted,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (asset.bindable)
                    const Tooltip(
                      message: 'Можно привязать к устройству Registry',
                      child: Icon(
                        Icons.link_rounded,
                        size: 14,
                        color: AerColors.sage,
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    return Draggable<String>(
      data: asset.id,
      // Horizontal drags leave the panel towards the scene; vertical ones
      // keep scrolling the catalog.
      affinity: Axis.horizontal,
      dragAnchorStrategy: pointerDragAnchorStrategy,
      feedback: Opacity(
        opacity: 0.85,
        child: AssetPreview(asset: scene, size: const Size(90, 60)),
      ),
      child: Tooltip(
        message: '${asset.group} · ${placementLabel(asset.placement)}',
        waitDuration: const Duration(milliseconds: 600),
        child: tile,
      ),
    );
  }
}

// --- Right panel: inspector ------------------------------------------------------------

class EditorInspector extends StatelessWidget {
  const EditorInspector({
    super.key,
    required this.editor,
    required this.scene,
    required this.actions,
    required this.canBind,
  });

  final EditorController editor;
  final SceneController scene;
  final EditorActions actions;
  final bool canBind;

  @override
  Widget build(BuildContext context) {
    final o = editor.selectedObject;
    final r = editor.selectedRoom;
    return Container(
      key: const Key('editor-inspector'),
      decoration: _panelDecoration(),
      clipBehavior: Clip.antiAlias,
      child: Material(
        type: MaterialType.transparency,
        child: o != null
            ? _ObjectInspector(
                key: ValueKey('obj-${o.id}'),
                editor: editor,
                scene: scene,
                actions: actions,
                object: o,
                canBind: canBind,
              )
            : r != null
            ? _RoomInspector(
                key: ValueKey('room-${r.id}'),
                editor: editor,
                actions: actions,
                room: r,
              )
            : const SizedBox.shrink(),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section(this.title, this.child);
  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: AerSpacing.m),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title.toUpperCase(),
          style: Theme.of(context).textTheme.labelSmall
              ?.copyWith(letterSpacing: 0.9, color: AerColors.inkMuted),
        ),
        const SizedBox(height: 6),
        child,
      ],
    ),
  );
}

/// Text field that commits on Enter or focus loss (one history step).
class _CommitField extends StatefulWidget {
  const _CommitField({
    super.key,
    required this.value,
    required this.hint,
    required this.onCommit,
    this.maxLength = 120,
  });
  final String value;
  final String hint;
  final ValueChanged<String> onCommit;
  final int maxLength;

  @override
  State<_CommitField> createState() => _CommitFieldState();
}

class _CommitFieldState extends State<_CommitField> {
  late final _c = TextEditingController(text: widget.value);
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!_focus.hasFocus) widget.onCommit(_c.text);
    });
  }

  @override
  void didUpdateWidget(_CommitField old) {
    super.didUpdateWidget(old);
    if (!_focus.hasFocus && widget.value != _c.text) _c.text = widget.value;
  }

  @override
  void dispose() {
    _c.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TextField(
    controller: _c,
    focusNode: _focus,
    maxLength: widget.maxLength,
    decoration: InputDecoration(
      isDense: true,
      hintText: widget.hint,
      counterText: '',
    ),
    onSubmitted: widget.onCommit,
  );
}

class _ArrowPad extends StatelessWidget {
  const _ArrowPad({required this.onMove, required this.keyPrefix});
  final void Function(double dx, double dy) onMove;
  final String keyPrefix;

  @override
  Widget build(BuildContext context) {
    // Arrows follow the screen: ↗ is −y, ↘ is +x, ↙ is +y, ↖ is −x.
    Widget b(String k, IconData i, String tip, double dx, double dy) =>
        IconButton(
          key: Key('$keyPrefix-$k'),
          tooltip: tip,
          visualDensity: VisualDensity.compact,
          onPressed: () => onMove(dx, dy),
          icon: Icon(i, size: 18),
        );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        b('nw', Icons.north_west_rounded, 'Влево-вверх', -1, 0),
        b('ne', Icons.north_east_rounded, 'Вправо-вверх', 0, -1),
        b('sw', Icons.south_west_rounded, 'Влево-вниз', 0, 1),
        b('se', Icons.south_east_rounded, 'Вправо-вниз', 1, 0),
      ],
    );
  }
}

class _ObjectInspector extends StatelessWidget {
  const _ObjectInspector({
    super.key,
    required this.editor,
    required this.scene,
    required this.actions,
    required this.object,
    required this.canBind,
  });

  final EditorController editor;
  final SceneController scene;
  final EditorActions actions;
  final SceneObject object;
  final bool canBind;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final doc = editor.document!;
    final o = object;
    final asset = doc.asset(o.assetId)!;
    final spec = editor.catalog.placementOf(asset);
    final room = doc.room(o.roomId)!;
    final p = scene.presentation(o.id);
    final category = editor.catalog.categories
        .where((c) => c.id == spec.category)
        .firstOrNull;
    final check = editor.validator.checkObject(doc, o);
    final support = switch (check.support) {
      OnTop(:final objectId) || OnShelf(:final objectId) => () {
        final s = doc.object(objectId);
        final on = check.support is OnShelf ? 'на полке' : 'на';
        return s == null ? '' : '$on «${editor.titleOf(s)}»';
      }(),
      OnWall() => 'на стене',
      _ => 'на полу',
    };
    final fp = o.footprint(asset);
    return ListView(
      scrollCacheExtent: ScrollCacheExtent.pixels(2000),
      key: const Key('inspector-scroll'),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              decoration: BoxDecoration(
                color: AerColors.background,
                borderRadius: BorderRadius.circular(AerRadii.small),
              ),
              child: AssetPreview(
                asset: asset,
                size: const Size(72, 60),
                rotation: o.rotation,
              ),
            ),
            const SizedBox(width: AerSpacing.s),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    p?.title ?? editor.titleOf(o),
                    style: text.titleMedium,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    [
                      ?category?.label,
                      if (spec.group.isNotEmpty) spec.group,
                    ].join(' · '),
                    style: text.bodySmall?.copyWith(color: AerColors.inkMuted),
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: 'Снять выделение (Esc)',
              visualDensity: VisualDensity.compact,
              onPressed: editor.clearSelection,
              icon: const Icon(Icons.close_rounded, size: 18),
            ),
          ],
        ),
        _Section(
          o.entityBinding == null ? 'Название' : 'Подпись в доме',
          _CommitField(
            key: const Key('inspector-object-name'),
            value: o.label,
            hint: asset.label,
            onCommit: (v) => editor.renameObject(o.id, v),
          ),
        ),
        _Section('Устройство', _binding(context, p)),
        _Section(
          'Положение',
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('${room.name} · $support', style: text.bodyMedium),
              const SizedBox(height: 4),
              Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 8,
                runSpacing: 4,
                children: [
                  _ArrowPad(
                    keyPrefix: 'nudge',
                    onMove: (dx, dy) => editor.nudgeObject(
                      o.id,
                      dx * EditorLimits.snap,
                      dy * EditorLimits.snap,
                    ),
                  ),
                  Tooltip(
                    message: 'Повернуть на 90° (R)',
                    child: OutlinedButton.icon(
                      key: const Key('inspector-rotate'),
                      style: OutlinedButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                      ),
                      onPressed: () => editor.rotateObject(o.id),
                      icon: const Icon(Icons.rotate_right_rounded, size: 18),
                      label: Text('${o.rotation}°'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        _Section(
          'Размер',
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Slider(
                      key: const Key('inspector-scale'),
                      value: o.scale.clamp(
                        EditorLimits.minScale,
                        EditorLimits.maxScale,
                      ),
                      min: EditorLimits.minScale,
                      max: EditorLimits.maxScale,
                      divisions: 30,
                      label:
                          '×${o.scale.toStringAsFixed(2).replaceAll('.', ',')}',
                      onChanged: (v) => editor.scaleObject(o.id, v),
                    ),
                  ),
                  Text(
                    '×${o.scale.toStringAsFixed(2).replaceAll('.', ',')}',
                    style: text.labelMedium,
                  ),
                ],
              ),
              Text(
                'Занимает ${metersLabel(fp.w)} × ${metersLabel(fp.d)}, высота ${metersLabel(asset.height * o.scale)}',
                style: text.bodySmall?.copyWith(color: AerColors.inkMuted),
              ),
            ],
          ),
        ),
        _Section(
          'Оформление',
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final f in editor.catalog.finishes.values)
                ChoiceChip(
                  key: Key('finish-${f.id}'),
                  visualDensity: VisualDensity.compact,
                  avatar: CircleAvatar(
                    backgroundColor: f.tint.a == 0
                        ? AerColors.surface
                        : Color.alphaBlend(f.tint, const Color(0xFFD9B58C)),
                    radius: 7,
                  ),
                  label: Text(f.label),
                  selected: (o.metadata['finish'] ?? 'natural') == f.id,
                  onSelected: (_) => editor.setFinish(o.id, f.id),
                ),
            ],
          ),
        ),
        if (!check.ok)
          Padding(
            padding: const EdgeInsets.only(top: AerSpacing.m),
            child: Row(
              children: [
                const Icon(
                  Icons.warning_amber_rounded,
                  size: 18,
                  color: AerColors.terracotta,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    check.issues.first,
                    style: text.bodySmall?.copyWith(
                      color: AerColors.terracotta,
                    ),
                  ),
                ),
              ],
            ),
          ),
        const SizedBox(height: AerSpacing.m),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                key: const Key('inspector-duplicate'),
                onPressed: () => editor.duplicateObject(o.id),
                icon: const Icon(Icons.copy_rounded, size: 18),
                label: const Text('Копия'),
              ),
            ),
            const SizedBox(width: AerSpacing.s),
            Expanded(
              child: OutlinedButton.icon(
                key: const Key('inspector-delete'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AerColors.terracotta,
                ),
                onPressed: () => actions.deleteObject(o.id),
                icon: const Icon(Icons.delete_outline_rounded, size: 18),
                label: const Text('Удалить'),
              ),
            ),
          ],
        ),
        Theme(
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            key: const Key('inspector-advanced'),
            tilePadding: EdgeInsets.zero,
            title: Text('Дополнительно', style: text.labelLarge),
            children: [
              _kv(context, 'Тип размещения', placementLabel(spec.placement)),
              _kv(
                context,
                'Позиция, клетки',
                'x ${_n(o.position.x)} · y ${_n(o.position.y)} · z ${_n(o.position.z)}',
              ),
              _kv(
                context,
                'Графика',
                asset.art.isPlaceholder
                    ? 'временная (placeholder)'
                    : 'финальная',
              ),
              _kv(context, 'ID', o.id),
            ],
          ),
        ),
      ],
    );
  }

  Widget _binding(BuildContext context, ObjectPresentation? p) {
    final text = Theme.of(context).textTheme;
    final o = object;
    final bound = o.entityBinding != null;
    final bindTip = canBind
        ? ''
        : 'Нужна связь с Core: список устройств хранится в Registry';
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AerColors.background,
        borderRadius: BorderRadius.circular(AerRadii.small),
        border: Border.all(color: AerColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (bound && p != null) ...[
            Row(
              children: [
                if (p.status case final s?)
                  StatusDot(s, size: 18, stale: p.stale),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    p.title,
                    style: text.bodyMedium,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              p.note,
              style: text.bodySmall?.copyWith(color: AerColors.inkMuted),
            ),
          ] else
            Text(
              editor.catalog.asset(o.assetId)?.bindable ?? false
                  ? 'Не привязан. Привяжите устройство из Registry, чтобы видеть его название и состояние.'
                  : 'Декор — привязка не обязательна.',
              style: text.bodySmall?.copyWith(color: AerColors.inkMuted),
            ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              Tooltip(
                message: bindTip,
                child: FilledButton.tonalIcon(
                  key: const Key('inspector-bind'),
                  style: FilledButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                  onPressed: canBind ? () => actions.bindObject(o.id) : null,
                  icon: const Icon(Icons.link_rounded, size: 18),
                  label: Text(bound ? 'Сменить' : 'Привязать устройство'),
                ),
              ),
              if (bound)
                OutlinedButton.icon(
                  key: const Key('inspector-unbind'),
                  style: OutlinedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                  onPressed: () => editor.unbindObject(o.id),
                  icon: const Icon(Icons.link_off_rounded, size: 18),
                  label: const Text('Отвязать'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

String _n(double v) =>
    (v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2))
        .replaceAll('.', ',');

Widget _kv(BuildContext context, String k, String v) {
  final text = Theme.of(context).textTheme;
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 118,
          child: Text(
            k,
            style: text.bodySmall?.copyWith(color: AerColors.inkMuted),
          ),
        ),
        Expanded(child: SelectableText(v, style: text.bodySmall)),
      ],
    ),
  );
}

class _RoomInspector extends StatelessWidget {
  const _RoomInspector({
    super.key,
    required this.editor,
    required this.actions,
    required this.room,
  });
  final EditorController editor;
  final EditorActions actions;
  final SceneRoom room;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final r = room;
    final c = editor.catalog;
    final n = editor.objectsIn(r.id);
    return ListView(
      scrollCacheExtent: ScrollCacheExtent.pixels(2000),
      key: const Key('inspector-scroll'),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      children: [
        Row(
          children: [
            Icon(roomIcon(r.kind), color: AerColors.accent),
            const SizedBox(width: AerSpacing.s),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    r.name,
                    style: text.titleMedium,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    '$n ${plural(n, 'предмет', 'предмета', 'предметов')}',
                    style: text.bodySmall?.copyWith(color: AerColors.inkMuted),
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: 'Снять выделение (Esc)',
              visualDensity: VisualDensity.compact,
              onPressed: editor.clearSelection,
              icon: const Icon(Icons.close_rounded, size: 18),
            ),
          ],
        ),
        _Section(
          'Название',
          _CommitField(
            key: const Key('inspector-room-name'),
            value: r.name,
            hint: 'Название комнаты',
            maxLength: 80,
            onCommit: (v) => editor.renameRoom(r.id, v),
          ),
        ),
        _Section(
          'Назначение',
          DropdownButtonFormField<String>(
            key: const Key('inspector-room-kind'),
            initialValue: r.kind,
            isExpanded: true,
            decoration: const InputDecoration(isDense: true),
            items: [
              for (final k in c.roomKinds)
                DropdownMenuItem(value: k.id, child: Text(k.label)),
            ],
            onChanged: (v) {
              if (v != null) editor.setRoomKind(r.id, v);
            },
          ),
        ),
        _Section(
          'Размер',
          Column(
            children: [
              SizeStepper(
                key: const Key('room-width'),
                label: 'Ширина',
                tiles: r.size.w,
                onChanged: (v) => editor.resizeRoom(r.id, Size2(v, r.size.d)),
              ),
              const SizedBox(height: 6),
              SizeStepper(
                key: const Key('room-depth'),
                label: 'Длина',
                tiles: r.size.d,
                onChanged: (v) => editor.resizeRoom(r.id, Size2(r.size.w, v)),
              ),
              const SizedBox(height: 4),
              Text(
                'Или потяните за кружки на краях комнаты.',
                style: text.bodySmall?.copyWith(color: AerColors.inkMuted),
              ),
            ],
          ),
        ),
        _Section(
          'Положение',
          Row(
            children: [
              _ArrowPad(
                keyPrefix: 'room-move',
                onMove: (dx, dy) => editor.moveRoom(
                  r.id,
                  Point2(r.origin.x + dx, r.origin.y + dy),
                ),
              ),
            ],
          ),
        ),
        _Section(
          'Пол · ${c.floor(r.style.floor).label}',
          MaterialSwatches(
            keyPrefix: 'floor',
            options: [
              for (final f in c.floors.values) (f.id, f.label, f.color),
            ],
            selected: r.style.floor,
            onSelected: (v) =>
                editor.styleRoom(r.id, r.style.copyWith(floor: v)),
          ),
        ),
        _Section(
          'Стены · ${c.wall(r.style.wall).label}',
          MaterialSwatches(
            keyPrefix: 'wall',
            options: [for (final w in c.walls.values) (w.id, w.label, w.color)],
            selected: r.style.wall,
            onSelected: (v) =>
                editor.styleRoom(r.id, r.style.copyWith(wall: v)),
          ),
        ),
        _Section(
          'Освещение',
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final l in c.lights.values)
                ChoiceChip(
                  key: Key('light-${l.id}'),
                  visualDensity: VisualDensity.compact,
                  label: Text(l.label),
                  selected: (r.style.light ?? 'day') == l.id,
                  onSelected: (_) => editor.styleRoom(
                    r.id,
                    r.style.copyWith(light: () => l.id == 'day' ? null : l.id),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: AerSpacing.m),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                key: const Key('room-duplicate'),
                onPressed: () => editor.duplicateRoom(r.id),
                icon: const Icon(Icons.copy_rounded, size: 18),
                label: const Text('Копия'),
              ),
            ),
            const SizedBox(width: AerSpacing.s),
            Expanded(
              child: OutlinedButton.icon(
                key: const Key('room-delete'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AerColors.terracotta,
                ),
                onPressed: () => actions.deleteRoom(r.id),
                icon: const Icon(Icons.delete_outline_rounded, size: 18),
                label: const Text('Удалить'),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

// --- Bottom status bar ----------------------------------------------------------------

class EditorStatusBar extends StatelessWidget {
  const EditorStatusBar({
    super.key,
    required this.editor,
    required this.zoom,
    required this.onToggleGrid,
  });
  final EditorController editor;
  final double zoom;
  final VoidCallback onToggleGrid;

  String _hint() => switch (editor.tool) {
    EditorTool.place => 'Клик — поставить · Shift+клик — ещё один · R — повернуть · Alt — точнее · Esc — отмена',
    EditorTool.placeRoom =>
      'Клик — поставить комнату · Enter — в предложенное место · Esc — отмена',
    EditorTool.moveObject =>
      'Отпустите, чтобы поставить · R — повернуть · Esc — отмена',
    EditorTool.moveRoom ||
    EditorTool.resizeRoom => 'Отпустите, чтобы применить · Esc — отмена',
    EditorTool.select =>
      editor.selectedObjectId != null
          ? 'Перетащите выделенный предмет · R — повернуть · Ctrl+D — копия · Del — удалить · F — к предмету'
          : editor.selectedRoomId != null
          ? 'Перетащите комнату или кружки на её краях · Del — удалить'
          : 'Клик — выбрать предмет или комнату · колесо — масштаб · 0 — весь дом · G — сетка',
  };

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final msg = editor.message;
    final String save;
    if (editor.saving) {
      save = 'Сохранение…';
    } else if (editor.lastSaveError != null && editor.dirty) {
      save = editor.lastSaveError!;
    } else if (editor.dirty) {
      final at = editor.draftSavedAt;
      save = at == null
          ? 'Есть несохранённые изменения'
          : 'Не сохранено · черновик ${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}';
    } else {
      save = 'Все изменения сохранены';
    }
    return Container(
      key: const Key('editor-status-bar'),
      height: 36,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: _panelDecoration(),
      child: Row(
        children: [
          Expanded(
            child: Text(
              msg ?? _hint(),
              key: const Key('editor-hint'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: text.bodySmall?.copyWith(
                color: msg != null ? AerColors.terracotta : AerColors.inkMuted,
              ),
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            key: const Key('editor-grid'),
            tooltip: editor.gridVisible
                ? 'Скрыть сетку (G)'
                : 'Показать сетку (G)',
            visualDensity: VisualDensity.compact,
            isSelected: editor.gridVisible,
            onPressed: onToggleGrid,
            icon: const Icon(Icons.grid_4x4_rounded, size: 18),
          ),
          Text('${(zoom * 100).round()} %', style: text.labelMedium),
          const SizedBox(width: 12),
          Icon(
            editor.dirty ? Icons.circle : Icons.check_circle_outline_rounded,
            size: 12,
            color: editor.dirty ? AerColors.amber : AerColors.sage,
          ),
          const SizedBox(width: 6),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 280),
            child: Text(
              save,
              key: const Key('editor-save-state'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: text.labelMedium,
            ),
          ),
        ],
      ),
    );
  }
}
