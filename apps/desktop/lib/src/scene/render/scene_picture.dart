import 'dart:ui' as ui;
import 'dart:ui';

import '../art/asset_painters.dart';
import '../art/iso_pen.dart';
import '../binding/scene_binding.dart';
import '../catalog/scene_catalog.dart';
import '../geometry/iso.dart';
import '../geometry/scene_layout.dart';
import '../model/scene_document.dart';

/// Records the static part of the scene (everything except hover/selection
/// highlights and status badges) into one vector picture. It is rebuilt only
/// when the document or object states change, never per frame. Materials,
/// lighting presets and finishes come from the [SceneCatalog] (data).
class ScenePictureBuilder {
  const ScenePictureBuilder([this.catalog]);

  final SceneCatalog? catalog;
  SceneCatalog get _cat => catalog ?? SceneCatalog.builtin;

  /// [hiddenObjectId] is left out (the editor draws it as a moving ghost).
  ui.Picture build(
    SceneLayout layout,
    Map<String, ObjectPresentation> presentations, {
    String? hiddenObjectId,
  }) {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    _groundShadow(canvas, layout);
    for (final r in layout.rooms) {
      _floor(canvas, r);
    }
    for (final g in layout.floorObjects) {
      if (g.object.id == hiddenObjectId) continue;
      _object(canvas, g, presentations[g.object.id]);
    }
    for (final g in layout.objects.values) {
      if (g.object.id == hiddenObjectId) continue;
      if (g.object.layer == SceneLayer.object && g.box.minZ < 0.01) {
        _contactShadow(canvas, g);
      }
      final light = lampLightRadius[g.asset.art.ref];
      if (light != null) _lightPool(canvas, g, light);
    }
    for (final item in layout.drawOrder) {
      switch (item) {
        case WallItem(:final wall):
          _wall(canvas, wall, layout.document.room(wall.roomId)!);
        case ObjectItem(:final geometry):
          if (geometry.object.id == hiddenObjectId) continue;
          _object(canvas, geometry, presentations[geometry.object.id]);
      }
    }
    return recorder.endRecording();
  }

  /// One soft shadow under the whole house. Rooms are merged into a single
  /// path (non-zero fill = union) so adjacent rooms leave no seams.
  void _groundShadow(Canvas canvas, SceneLayout layout) {
    final path = Path()..fillType = PathFillType.nonZero;
    final z = -floorThickness - 0.4;
    for (final r in layout.rooms) {
      path.addPolygon([
        Iso.project(r.x0 + 0.6, r.y0 + 0.6, z),
        Iso.project(r.x1 + 0.6, r.y0 + 0.6, z),
        Iso.project(r.x1 + 0.6, r.y1 + 0.6, z),
        Iso.project(r.x0 + 0.6, r.y1 + 0.6, z),
      ], true);
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = const Color(0xFF5B4636).withValues(alpha: 0.16)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 22),
    );
  }

  void _floor(Canvas canvas, RoomGeometry r) {
    final material = _cat.floor(r.room.style.floor);
    final base = material.color;
    final fill = Paint()..isAntiAlias = true;
    final z0 = -floorThickness;
    Offset q(double x, double y, double z) => Iso.project(x, y, z);
    // Slab sides (the "diorama" base) and top.
    canvas.drawPath(
      Path()..addPolygon([
        q(r.x0, r.y1, z0),
        q(r.x1, r.y1, z0),
        q(r.x1, r.y1, 0),
        q(r.x0, r.y1, 0),
      ], true),
      fill..color = darken(ScenePalette.ground, 0.02),
    );
    canvas.drawPath(
      Path()..addPolygon([
        q(r.x1, r.y0, z0),
        q(r.x1, r.y1, z0),
        q(r.x1, r.y1, 0),
        q(r.x1, r.y0, 0),
      ], true),
      fill..color = darken(ScenePalette.ground, 0.16),
    );
    final top = Path()
      ..addPolygon([
        q(r.x0, r.y0, 0),
        q(r.x1, r.y0, 0),
        q(r.x1, r.y1, 0),
        q(r.x0, r.y1, 0),
      ], true);
    canvas.drawPath(top, fill..color = base);

    canvas.save();
    canvas.clipPath(top);
    final seam = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.8;
    switch (material.pattern) {
      case 'planks':
        var i = 0;
        for (var y = r.y0; y < r.y1; y += 0.5, i++) {
          final tint = i.isEven ? lighten(base, 0.05) : darken(base, 0.03);
          canvas.drawPath(
            Path()..addPolygon([
              q(r.x0, y, 0),
              q(r.x1, y, 0),
              q(r.x1, y + 0.5, 0),
              q(r.x0, y + 0.5, 0),
            ], true),
            fill..color = tint,
          );
          final shift = (i * 1.7) % 3.0;
          for (var x = r.x0 + shift; x < r.x1; x += 3.0) {
            canvas.drawLine(
              q(x, y, 0),
              q(x, y + 0.5, 0),
              seam..color = darken(base, 0.18).withValues(alpha: 0.5),
            );
          }
          canvas.drawLine(
            q(r.x0, y, 0),
            q(r.x1, y, 0),
            seam..color = darken(base, 0.12).withValues(alpha: 0.45),
          );
        }
      case 'stone':
        // Large offset slabs with soft tone variation.
        var row = 0;
        for (var y = r.y0; y < r.y1; y += 1.5, row++) {
          final shift = row.isEven ? 0.0 : 1.0;
          var col = 0;
          for (var x = r.x0 - shift; x < r.x1; x += 2, col++) {
            final t = ((row * 7 + col * 3) % 5) / 5;
            canvas.drawPath(
              Path()..addPolygon([
                q(x, y, 0),
                q(x + 2, y, 0),
                q(x + 2, y + 1.5, 0),
                q(x, y + 1.5, 0),
              ], true),
              fill
                ..color = Color.lerp(
                  lighten(base, 0.06),
                  darken(base, 0.05),
                  t,
                )!,
            );
            canvas.drawLine(
              q(x, y, 0),
              q(x, y + 1.5, 0),
              seam..color = darken(base, 0.14).withValues(alpha: 0.55),
            );
          }
          canvas.drawLine(
            q(r.x0, y, 0),
            q(r.x1, y, 0),
            seam..color = darken(base, 0.14).withValues(alpha: 0.55),
          );
        }
      case 'carpet':
        // Soft pile: faint diagonal texture and a border.
        for (var k = r.x0 + r.y0; k < r.x1 + r.y1; k += 0.5) {
          canvas.drawLine(
            q(k - r.y0, r.y0, 0),
            q(r.x0, k - r.x0, 0),
            seam..color = lighten(base, 0.07).withValues(alpha: 0.5),
          );
        }
        canvas.drawPath(
          Path()..addPolygon([
            q(r.x0 + 0.3, r.y0 + 0.3, 0),
            q(r.x1 - 0.3, r.y0 + 0.3, 0),
            q(r.x1 - 0.3, r.y1 - 0.3, 0),
            q(r.x0 + 0.3, r.y1 - 0.3, 0),
          ], true),
          seam
            ..color = darken(base, 0.12)
            ..strokeWidth = 1.2,
        );
      case 'tiles':
        for (var x = r.x0; x <= r.x1; x += 1) {
          canvas.drawLine(
            q(x, r.y0, 0),
            q(x, r.y1, 0),
            seam..color = darken(base, 0.1),
          );
        }
        for (var y = r.y0; y <= r.y1; y += 1) {
          canvas.drawLine(
            q(r.x0, y, 0),
            q(r.x1, y, 0),
            seam..color = darken(base, 0.1),
          );
        }
      default:
        final inner = [
          q(r.x0 + 0.3, r.y0 + 0.3, 0),
          q(r.x1 - 0.3, r.y0 + 0.3, 0),
          q(r.x1 - 0.3, r.y1 - 0.3, 0),
          q(r.x0 + 0.3, r.y1 - 0.3, 0),
        ];
        canvas.drawPath(
          Path()..addPolygon(inner, true),
          seam
            ..color = darken(base, 0.12)
            ..strokeWidth = 1.2,
        );
    }
    // Warm ambient: brighter towards the back walls (window light).
    final b = top.getBounds();
    canvas.drawPath(
      top,
      Paint()
        ..shader = Gradient.linear(
          b.topCenter,
          b.bottomCenter,
          [
            const Color(0xFFFFF4DE).withValues(alpha: 0.28),
            const Color(0x00FFF4DE),
            const Color(0xFF6B4E38).withValues(alpha: 0.06),
          ],
          [0, 0.55, 1],
        ),
    );
    final light = _cat.light(r.room.style.light);
    if (light != null && light.tint.a > 0) {
      canvas.drawPath(top, Paint()..color = light.tint);
    }
    canvas.restore();
    // Front lip highlight.
    canvas.drawLine(
      q(r.x0, r.y1, 0),
      q(r.x1, r.y1, 0),
      Paint()
        ..color = lighten(base, 0.35)
        ..strokeWidth = 1,
    );
    canvas.drawLine(
      q(r.x1, r.y0, 0),
      q(r.x1, r.y1, 0),
      Paint()
        ..color = lighten(base, 0.25)
        ..strokeWidth = 1,
    );
  }

  void _contactShadow(Canvas canvas, ObjectGeometry g) {
    final b = g.box;
    const grow = 0.18;
    final pts = [
      Iso.project(b.minX - grow, b.minY - grow, 0.01),
      Iso.project(b.maxX + grow, b.minY - grow, 0.01),
      Iso.project(b.maxX + grow, b.maxY + grow, 0.01),
      Iso.project(b.minX - grow, b.maxY + grow, 0.01),
    ];
    canvas.drawPath(
      Path()..addPolygon(pts, true),
      Paint()
        ..color = const Color(0xFF4A3426).withValues(alpha: 0.16)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5),
    );
  }

  void _lightPool(Canvas canvas, ObjectGeometry g, double radius) {
    final c = Iso.project(
      (g.box.minX + g.box.maxX) / 2,
      (g.box.minY + g.box.maxY) / 2,
      g.box.minZ + 0.01,
    );
    final rx = radius * Iso.tileWidth / 2 * 1.4, ry = rx / 2;
    final rect = Rect.fromCenter(center: c, width: rx * 2, height: ry * 2);
    // Normal blending only: advanced blend modes (softLight) produced
    // streak artifacts on the GPU backend.
    canvas.drawOval(
      rect,
      Paint()
        ..shader = Gradient.radial(c, rx, [
          const Color(0xFFFFE6B8).withValues(alpha: 0.20),
          const Color(0x00FFE6B8),
        ]),
    );
    canvas.drawOval(
      rect,
      Paint()
        ..shader = Gradient.radial(c, rx * 0.8, [
          const Color(0xFFFFE9C4).withValues(alpha: 0.22),
          const Color(0x00FFE9C4),
        ]),
    );
  }

  void _wall(Canvas canvas, WallSegment w, SceneRoom room) {
    final light = _cat.light(room.style.light);
    var color = _cat.wall(room.style.wall).color;
    if (light != null && light.tint.a > 0) {
      color = Color.alphaBlend(light.tint, color);
    }
    final b = w.box;
    canvas.save();
    final origin = Iso.project(b.minX, b.minY, b.minZ);
    canvas.translate(origin.dx, origin.dy);
    final pen = IsoPen(canvas, W: b.w, D: b.d, H: b.h);
    pen.box(0, 0, 0, b.w, b.d, b.h, color, top: darken(color, 0.22));
    final inner = w.side == WallSide.north ? 'front' : 'right';
    final length = w.side == WallSide.north ? b.w : b.d;
    // Skirting board along the room side.
    pen.panel(
      inner,
      0,
      0,
      0,
      b.w,
      b.d,
      b.h,
      0,
      0,
      length,
      w.tall ? 0.28 : 0.12,
      darken(color, 0.12),
    );
    if (w.tall && w.window && b.h > 2.5) {
      final s0 = 0.25, s1 = length - 0.25;
      pen.panel(
        inner,
        0,
        0,
        0,
        b.w,
        b.d,
        b.h,
        s0 - 0.08,
        1.3,
        s1 + 0.08,
        b.h - 0.62,
        lighten(color, 0.5),
      );
      pen.panel(
        inner,
        0,
        0,
        0,
        b.w,
        b.d,
        b.h,
        s0,
        1.4,
        s1,
        b.h - 0.7,
        const Color(0xFFBFD3DB),
      );
      pen.panel(
        inner,
        0,
        0,
        0,
        b.w,
        b.d,
        b.h,
        s0,
        1.4,
        (s0 + s1) / 2 - 0.03,
        b.h - 0.7,
        const Color(0xFFD3E2E6),
      );
      pen.panel(
        inner,
        0,
        0,
        0,
        b.w,
        b.d,
        b.h,
        (s0 + s1) / 2 - 0.03,
        1.4,
        (s0 + s1) / 2 + 0.03,
        b.h - 0.7,
        lighten(color, 0.4),
      );
      pen.panel(
        inner,
        0,
        0,
        0,
        b.w,
        b.d,
        b.h,
        s0 - 0.12,
        1.22,
        s1 + 0.12,
        1.32,
        darken(color, 0.08),
      );
    }
    canvas.restore();
  }

  void _object(Canvas canvas, ObjectGeometry g, ObjectPresentation? p) {
    final o = g.object;
    paintAssetArt(
      canvas,
      g.asset,
      g.box,
      rotation: o.rotation,
      scale: o.scale,
      status: p?.status,
      muted: p?.status == SceneStatus.archived,
      tint: _cat.finishes[o.metadata['finish']]?.tint,
    );
  }
}

/// Paints an asset's art with its min corner at [box]'s projected min corner.
/// Shared by the static picture and the editor's placement ghost.
void paintAssetArt(
  Canvas canvas,
  SceneAsset asset,
  Box3 box, {
  required int rotation,
  required double scale,
  SceneStatus? status,
  bool muted = false,
  Color? tint,
  double opacity = 1,
}) {
  final paint = proceduralArt[asset.art.ref] ?? missingArt;
  final origin = Iso.project(box.minX, box.minY, box.minZ);
  canvas.save();
  canvas.translate(origin.dx, origin.dy);
  final tinted = tint != null && tint.a > 0;
  final layered = muted || tinted || opacity < 1;
  if (layered) {
    // Archived objects stay visible but muted; finishes tint the art only.
    canvas.saveLayer(
      null,
      Paint()
        ..colorFilter = muted ? const ColorFilter.matrix(_mute) : null
        ..color = Color.fromRGBO(255, 255, 255, opacity),
    );
  }
  paint(
    IsoPen(
      canvas,
      W: asset.footprint.w,
      D: asset.footprint.d,
      H: asset.height,
      rotation: rotation,
      scale: scale,
    ),
    ArtContext(status: status),
  );
  if (tinted) {
    canvas.drawPaint(
      Paint()
        ..color = tint
        ..blendMode = BlendMode.srcATop,
    );
  }
  if (layered) canvas.restore();
  canvas.restore();
}

/// Desaturate to ~35% and fade slightly.
const _mute = <double>[
  0.55, 0.38, 0.07, 0, 0, //
  0.18, 0.75, 0.07, 0, 0,
  0.18, 0.38, 0.44, 0, 0,
  0, 0, 0, 0.8, 0,
];
