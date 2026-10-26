import 'dart:async';
import 'dart:math' as math;

import 'package:flame/game.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../scene/binding/scene_binding.dart';
import '../../scene/geometry/scene_layout.dart';
import '../../scene/interaction/scene_interaction.dart';
import '../../scene/render/scene_game.dart';
import '../../scene/scene_controller.dart';
import '../../state/registry_controller.dart';
import '../../theme/tokens.dart';
import '../registry/entity_details.dart';
import '../registry/error_text.dart';
import 'scene_overlays.dart';

/// Isometric house mode: Flame scene + Flutter overlays.
class HouseView extends StatefulWidget {
  const HouseView({
    super.key,
    required this.scene,
    required this.registry,
    required this.onShowInRegistry,
    this.game,
  });

  final SceneController scene;
  final RegistryController registry;

  /// Switches to «Устройства» and selects the entity.
  final void Function(String entityId) onShowInRegistry;

  /// Injected in tests; created internally otherwise.
  final SceneGame? game;

  @override
  State<HouseView> createState() => HouseViewState();
}

class HouseViewState extends State<HouseView> {
  late final SceneGame game = widget.game ?? SceneGame();
  late final SceneInteraction interaction = SceneInteraction(game.view);
  final _focus = FocusNode(debugLabel: 'house-scene');
  bool _legend = false;
  bool _details = false;
  Offset? _doubleTapAt;
  double _lastScale = 1;
  SceneLayout? _installedLayout;
  Map<String, ObjectPresentation>? _installedPresentations;

  @override
  void initState() {
    super.initState();
    widget.scene.addListener(_sync);
    widget.registry.addListener(_onRegistry);
    interaction.addListener(_onInteraction);
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
    _focus.dispose();
    super.dispose();
  }

  void _sync() {
    final layout = widget.scene.layout;
    final pres = widget.scene.presentations;
    if (layout != null &&
        (layout != _installedLayout || pres != _installedPresentations)) {
      final reset =
          _installedLayout?.document.sceneId != layout.document.sceneId;
      _installedLayout = layout;
      _installedPresentations = pres;
      interaction.syncWith(layout);
      game.setScene(layout, pres, resetCamera: reset);
    }
    if (mounted) setState(() {});
  }

  void _onRegistry() {
    if (_details && widget.registry.selected == null && mounted) {
      setState(() => _details = false);
    }
  }

  void _onInteraction() {
    game
      ..hoveredId = interaction.hoveredId
      ..selectedId = interaction.selectedId
      ..wake();
    if (mounted) setState(() {});
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

  Future<void> _contextMenu(Offset local, Offset global) async {
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

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    final center = Offset(
      game.view.viewport.width / 2,
      game.view.viewport.height / 2,
    );
    switch (e.logicalKey) {
      case LogicalKeyboardKey.escape:
        interaction.select(null);
        widget.registry.clearSelection();
      case LogicalKeyboardKey.equal || LogicalKeyboardKey.numpadAdd:
        game.view.zoomAt(center, 1.25);
        _moved();
      case LogicalKeyboardKey.minus || LogicalKeyboardKey.numpadSubtract:
        game.view.zoomAt(center, 0.8);
        _moved();
      case LogicalKeyboardKey.digit0:
        game.view.reset(animate: true);
        game.wake();
      default:
        return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

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
    final doc = layout.document;
    // Expand: overlay children may be non-positioned when hidden, and the
    // section gets loose constraints from the IndexedStack.
    return Stack(
      fit: StackFit.expand,
      children: [
        Positioned.fill(child: _sceneSurface(doc.name, layout)),
        Positioned(
          left: AerSpacing.m,
          top: AerSpacing.m,
          right: 220,
          child: _SourceBar(scene: scene),
        ),
        Positioned(
          right: AerSpacing.m,
          top: AerSpacing.m,
          child: _CameraControls(
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
            onLegend: () => setState(() => _legend = !_legend),
          ),
        ),
        if (_legend)
          Positioned(
            right: AerSpacing.m,
            top: 210,
            child: SceneLegend(onClose: () => setState(() => _legend = false)),
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

  Offset get _center =>
      Offset(game.view.viewport.width / 2, game.view.viewport.height / 2);

  Widget _sceneSurface(String name, SceneLayout layout) {
    return Semantics(
      label:
          'Изометрический дом «$name»: ${layout.rooms.length} комнат, ${layout.objects.length} объектов. '
          'Список устройств доступен в разделе «Устройства».',
      child: Focus(
        focusNode: _focus,
        onKeyEvent: _onKey,
        child: Listener(
          onPointerDown: (_) => _focus.requestFocus(),
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
            cursor: interaction.hoveredId != null
                ? SystemMouseCursors.click
                : SystemMouseCursors.grab,
            onHover: (e) => interaction.hover(e.localPosition),
            onExit: (_) => interaction.hover(null),
            child: GestureDetector(
              key: const Key('scene-surface'),
              behavior: HitTestBehavior.opaque,
              onTapUp: (d) => interaction.tap(d.localPosition),
              onDoubleTapDown: (d) => _doubleTapAt = d.localPosition,
              onDoubleTap: () {
                final at = _doubleTapAt;
                final g = at == null ? null : interaction.pick(at);
                if (g != null) unawaited(_openDetails(g));
              },
              onSecondaryTapUp: (d) =>
                  _contextMenu(d.localPosition, d.globalPosition),
              onScaleStart: (_) => _lastScale = 1,
              onScaleUpdate: (d) {
                if (d.pointerCount > 1 || d.scale != 1) {
                  game.view.zoomAt(d.localFocalPoint, d.scale / _lastScale);
                  _lastScale = d.scale;
                }
                game.view.panBy(d.focalPointDelta);
                _moved();
              },
              child: GameWidget(game: game),
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
        if (g == null || p == null || g.object.id == interaction.selectedId) {
          return const SizedBox.shrink();
        }
        final at = game.view.worldToScreen(g.topAnchor);
        return Positioned(
          left: at.dx - 90,
          top: at.dy - 74,
          width: 180,
          child: IgnorePointer(
            child: Center(child: HoverLabel(presentation: p)),
          ),
        );
      },
    );
  }
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
    required this.onLegend,
    required this.legendOpen,
  });

  final VoidCallback onZoomIn, onZoomOut, onReset, onLegend;
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
            btn(
              'scene-legend-toggle',
              Icons.info_outline_rounded,
              'Обозначения',
              onLegend,
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
