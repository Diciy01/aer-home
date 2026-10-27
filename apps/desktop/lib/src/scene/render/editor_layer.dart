import 'dart:ui';

import 'package:flame/components.dart';
import 'package:flutter/painting.dart' show TextPainter, TextSpan, TextStyle;

import '../art/iso_pen.dart';
import '../editor/editor_controller.dart';
import '../editor/placement.dart' show metersLabel;
import '../geometry/iso.dart';
import '../model/scene_document.dart';
import 'scene_picture.dart';

/// What the editor wants drawn on top of the static house. Plain data: the
/// renderer never changes the scene, it only shows previews.
class EditorOverlay {
  const EditorOverlay({
    this.grid = false,
    this.ghost,
    this.roomGhost,
    this.selectedRoom,
    this.hiddenObjectId,
  });

  final bool grid;
  final GhostObject? ghost;
  final GhostRoom? roomGhost;
  final SceneRoom? selectedRoom;
  final String? hiddenObjectId;

  /// A preview follows the pointer: frames should come from the texture.
  bool get dragging => ghost != null || roomGhost != null;
}

/// Screen handles of a room's front edges (world pixels at zoom 1).
Map<RoomEdge, Offset> roomHandles(SceneRoom r) {
  final x0 = r.origin.x, y0 = r.origin.y;
  final x1 = x0 + r.size.w, y1 = y0 + r.size.d;
  return {
    RoomEdge.east: Iso.project(x1, (y0 + y1) / 2),
    RoomEdge.south: Iso.project((x0 + x1) / 2, y1),
    RoomEdge.corner: Iso.project(x1, y1),
  };
}

const _okColor = ScenePalette.sageDeep;
const _badColor = ScenePalette.terracotta;
const _accent = ScenePalette.caramel;

List<Offset> _floorQuad(double x0, double y0, double x1, double y1, double z) =>
    [
      Iso.project(x0, y0, z),
      Iso.project(x1, y0, z),
      Iso.project(x1, y1, z),
      Iso.project(x0, y1, z),
    ];

/// World-space editor drawing: grid, room frames, ghosts and occupied cells.
class EditorWorldLayer extends Component {
  EditorWorldLayer(this.overlay, this.rooms, this.zoom);

  final EditorOverlay? Function() overlay;
  final List<SceneRoom> Function() rooms;
  final double Function() zoom;

  final _stroke = Paint()
    ..style = PaintingStyle.stroke
    ..isAntiAlias = true;
  final _fill = Paint()..isAntiAlias = true;

  @override
  void render(Canvas canvas) {
    final o = overlay();
    if (o == null) return;
    final z = zoom();
    if (o.grid) {
      _stroke
        ..color = const Color(0xFF6B4E38).withValues(alpha: 0.24)
        ..strokeWidth = 1 / z;
      for (final r in rooms()) {
        final x0 = r.origin.x, y0 = r.origin.y;
        final x1 = x0 + r.size.w, y1 = y0 + r.size.d;
        for (var x = x0 + 1; x < x1 - 1e-6; x += 1) {
          canvas.drawLine(
            Iso.project(x, y0, 0.004),
            Iso.project(x, y1, 0.004),
            _stroke,
          );
        }
        for (var y = y0 + 1; y < y1 - 1e-6; y += 1) {
          canvas.drawLine(
            Iso.project(x0, y, 0.004),
            Iso.project(x1, y, 0.004),
            _stroke,
          );
        }
      }
    }
    final sel = o.selectedRoom;
    if (sel != null && o.roomGhost == null) {
      _roomFrame(canvas, sel, _accent, z, fill: 0.08);
    }
    final rg = o.roomGhost;
    if (rg != null) {
      _roomFrame(
        canvas,
        rg.room,
        rg.ok ? _okColor : _badColor,
        z,
        fill: 0.22,
        dashed: true,
      );
    }
    final g = o.ghost;
    if (g != null) _ghost(canvas, g, z);
  }

  void _roomFrame(
    Canvas canvas,
    SceneRoom r,
    Color c,
    double z, {
    double fill = 0.1,
    bool dashed = false,
  }) {
    final x0 = r.origin.x, y0 = r.origin.y;
    final pts = _floorQuad(x0, y0, x0 + r.size.w, y0 + r.size.d, 0.01);
    final path = Path()..addPolygon(pts, true);
    canvas.drawPath(path, _fill..color = c.withValues(alpha: fill));
    canvas.drawPath(
      path,
      _stroke
        ..color = c
        ..strokeWidth = (dashed ? 2.5 : 2) / z,
    );
    if (r.wallHeight > 0 && dashed) {
      // Outline of the wall volume so the new size reads in 3D.
      final h = r.wallHeight * 0.35;
      for (final p in [(x0, y0), (x0 + r.size.w, y0), (x0, y0 + r.size.d)]) {
        canvas.drawLine(
          Iso.project(p.$1, p.$2, 0),
          Iso.project(p.$1, p.$2, h),
          _stroke..strokeWidth = 1.2 / z,
        );
      }
    }
  }

  void _ghost(Canvas canvas, GhostObject g, double z) {
    final b = g.box;
    final c = g.ok ? _okColor : _badColor;
    // Occupied cells: every grid cell the footprint touches, then the exact footprint.
    final base = b.minZ + 0.01;
    for (var x = b.minX.floorToDouble(); x < b.maxX - 1e-6; x += 1) {
      for (var y = b.minY.floorToDouble(); y < b.maxY - 1e-6; y += 1) {
        canvas.drawPath(
          Path()..addPolygon(_floorQuad(x, y, x + 1, y + 1, base), true),
          _fill..color = c.withValues(alpha: 0.10),
        );
      }
    }
    final fp = Path()
      ..addPolygon(_floorQuad(b.minX, b.minY, b.maxX, b.maxY, base), true);
    canvas.drawPath(fp, _fill..color = c.withValues(alpha: 0.28));
    canvas.drawPath(
      fp,
      _stroke
        ..color = c
        ..strokeWidth = 2 / z,
    );
    paintAssetArt(
      canvas,
      g.asset,
      b,
      rotation: g.rotation,
      scale: g.scale,
      opacity: 0.62,
      tint: g.ok ? null : _badColor.withValues(alpha: 0.45),
    );
  }
}

/// Screen-space editor marks: room size labels and resize handles.
class EditorHudLayer extends Component {
  EditorHudLayer(this.overlay, this.toScreen);

  final EditorOverlay? Function() overlay;
  final Offset Function(Offset world) toScreen;

  final _fill = Paint()..isAntiAlias = true;
  final _stroke = Paint()
    ..style = PaintingStyle.stroke
    ..isAntiAlias = true
    ..strokeWidth = 2;
  final _labels = <String, TextPainter>{};

  TextPainter _text(String s, Color c) => _labels.putIfAbsent(
    '$s|${c.toARGB32()}',
    () => TextPainter(
      text: TextSpan(
        text: s,
        style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: c),
      ),
      textDirection: TextDirection.ltr,
    )..layout(),
  );

  @override
  void render(Canvas canvas) {
    final o = overlay();
    if (o == null) return;
    final rg = o.roomGhost;
    final room = rg?.room ?? o.selectedRoom;
    if (room == null) return;
    final ok = rg?.ok ?? true;
    final x0 = room.origin.x, y0 = room.origin.y;
    final x1 = x0 + room.size.w, y1 = y0 + room.size.d;
    _pill(
      canvas,
      toScreen(Iso.project((x0 + x1) / 2, y1)) + const Offset(-26, 16),
      metersLabel(room.size.w),
      ok,
    );
    _pill(
      canvas,
      toScreen(Iso.project(x1, (y0 + y1) / 2)) + const Offset(26, 16),
      metersLabel(room.size.d),
      ok,
    );
    if (rg == null) {
      for (final p in roomHandles(room).values) {
        final s = toScreen(p);
        canvas.drawCircle(s, 8, _fill..color = const Color(0xFFFFFBF4));
        canvas.drawCircle(s, 8, _stroke..color = _accent);
        canvas.drawCircle(s, 3.2, _fill..color = _accent);
      }
    }
  }

  void _pill(Canvas canvas, Offset at, String s, bool ok) {
    final tp = _text(s, ok ? const Color(0xFF40352E) : const Color(0xFFFFFBF4));
    final r = Rect.fromCenter(
      center: at,
      width: tp.width + 16,
      height: tp.height + 8,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(r, const Radius.circular(9)),
      _fill..color = ok ? const Color(0xF2FFFBF4) : _badColor,
    );
    tp.paint(canvas, r.topLeft + const Offset(8, 4));
  }
}
