// Geometry notation: W/D/H follow the scene format (width, depth, height).
// ignore_for_file: non_constant_identifier_names

import 'dart:math' as math;
import 'dart:ui';

import '../geometry/iso.dart';

/// Cozy Beige scene palette (docs/DESIGN_TOKENS.md, extended for the house).
abstract final class ScenePalette {
  static const cream = Color(0xFFF4E9D8);
  static const milk = Color(0xFFFBF6EE);
  static const warmBeige = Color(0xFFE6D3B8);
  static const sand = Color(0xFFD7BF9C);
  static const taupe = Color(0xFF9A8878);
  static const caramel = Color(0xFFB27C52);
  static const oak = Color(0xFFCFA578);
  static const walnut = Color(0xFF8E6A4E);
  static const sage = Color(0xFF8DA78C);
  static const sageDeep = Color(0xFF6F8C70);
  static const dustyBlue = Color(0xFF8FA8B6);
  static const amber = Color(0xFFD9A55B);
  static const terracotta = Color(0xFFC57A64);
  static const lavender = Color(0xFFB2A6C6);
  static const charcoal = Color(0xFF4D4541);
  static const screenOff = Color(0xFF3B3532);
  static const ground = Color(0xFFB79D7E);
}

Color lighten(Color c, double t) => Color.lerp(c, const Color(0xFFFFFFFF), t)!;
Color darken(Color c, double t) => Color.lerp(c, const Color(0xFF2A211C), t)!;

/// Draws an object in its own local frame and maps it onto the scene with a
/// quarter-turn rotation and uniform scale.
///
/// Local frame: u ∈ [0, W] (width), v ∈ [0, D] (depth, front face at v = D),
/// h ∈ [0, H] (up). The picture origin is the projected min corner of the
/// object's world box, so the same recording can be replayed anywhere.
class IsoPen {
  IsoPen(
    this.canvas, {
    required this.W,
    required this.D,
    required this.H,
    this.rotation = 0,
    this.scale = 1,
  });

  final Canvas canvas;
  final double W, D, H;
  final int rotation;
  final double scale;

  final _fill = Paint()..isAntiAlias = true;
  final _stroke = Paint()
    ..isAntiAlias = true
    ..style = PaintingStyle.stroke
    ..strokeJoin = StrokeJoin.round;

  /// Local (u, v) → world offset inside the rotated footprint.
  (double, double) _rot(double u, double v) {
    u *= scale;
    v *= scale;
    final w = W * scale, d = D * scale;
    return switch (rotation) {
      90 => (v, w - u),
      180 => (w - u, d - v),
      270 => (d - v, u),
      _ => (u, v),
    };
  }

  /// Rotates a local direction.
  (double, double) _dir(double du, double dv) => switch (rotation) {
    90 => (dv, -du),
    180 => (-du, -dv),
    270 => (-dv, du),
    _ => (du, dv),
  };

  Offset p(double u, double v, double h) {
    final (x, y) = _rot(u, v);
    return Iso.project(x, y, h * scale);
  }

  /// A local face with outward normal (nu, nv) is visible when it faces +x or +y.
  bool faceVisible(double nu, double nv) {
    final (x, y) = _dir(nu, nv);
    return x > 0.5 || y > 0.5;
  }

  void poly(
    List<Offset> pts,
    Color color, {
    double outline = 0,
    Color? outlineColor,
  }) {
    final path = Path()..addPolygon(pts, true);
    canvas.drawPath(
      path,
      _fill
        ..color = color
        ..shader = null,
    );
    if (outline > 0) {
      canvas.drawPath(
        path,
        _stroke
          ..color = outlineColor ?? darken(color, 0.35).withValues(alpha: 0.45)
          ..strokeWidth = outline,
      );
    }
  }

  void line(Offset a, Offset b, Color color, {double width = 1}) =>
      canvas.drawLine(
        a,
        b,
        _stroke
          ..color = color
          ..strokeWidth = width
          ..strokeCap = StrokeCap.round,
      );

  /// A shaded box in local coordinates. Light comes from the upper left:
  /// top lightest, +y face mid, +x face darkest. A soft highlight runs along
  /// the visible top edges so volumes read as gently rounded, not hard cubes.
  void box(
    double u0,
    double v0,
    double h0,
    double u1,
    double v1,
    double h1,
    Color base, {
    Color? top,
    bool edges = true,
  }) {
    final (ax, ay) = _rot(u0, v0);
    final (bx, by) = _rot(u1, v1);
    final x0 = math.min(ax, bx), x1 = math.max(ax, bx);
    final y0 = math.min(ay, by), y1 = math.max(ay, by);
    final z0 = h0 * scale, z1 = h1 * scale;
    Offset q(double x, double y, double z) => Iso.project(x, y, z);
    final topC = top ?? lighten(base, 0.12);
    final leftC = base;
    final rightC = darken(base, 0.16);
    poly([q(x0, y1, z0), q(x1, y1, z0), q(x1, y1, z1), q(x0, y1, z1)], leftC);
    poly([q(x1, y0, z0), q(x1, y1, z0), q(x1, y1, z1), q(x1, y0, z1)], rightC);
    poly([q(x0, y0, z1), q(x1, y0, z1), q(x1, y1, z1), q(x0, y1, z1)], topC);
    if (edges && (z1 - z0) > 0.02) {
      final hl = lighten(topC, 0.35).withValues(alpha: 0.9);
      line(q(x0, y1, z1), q(x1, y1, z1), hl, width: 0.9);
      line(q(x1, y1, z1), q(x1, y0, z1), hl, width: 0.9);
      final shade = darken(base, 0.45).withValues(alpha: 0.28);
      line(
        q(x1, y1, z0),
        q(x1, y1, z1),
        lighten(base, 0.18).withValues(alpha: 0.6),
        width: 0.7,
      );
      line(q(x0, y1, z0), q(x1, y1, z0), shade, width: 0.7);
      line(q(x1, y0, z0), q(x1, y1, z0), shade, width: 0.7);
    }
  }

  /// A rectangle on a face of the local box [u0..u1]×[v0..v1]×[h0..h1].
  /// [face] is one of 'front' (v=v1), 'back' (v=v0), 'right' (u=u1),
  /// 'left' (u=u0). (s, t) are offsets along the face from its lower-left
  /// as seen from outside; drawn only if the face is visible.
  void panel(
    String face,
    double u0,
    double v0,
    double h0,
    double u1,
    double v1,
    double h1,
    double s0,
    double t0,
    double s1,
    double t1,
    Color color, {
    double inset = 0.004,
  }) {
    late List<Offset> pts;
    switch (face) {
      case 'front':
        if (!faceVisible(0, 1)) return;
        final v = v1 + inset;
        pts = [
          p(u0 + s0, v, h0 + t0),
          p(u0 + s1, v, h0 + t0),
          p(u0 + s1, v, h0 + t1),
          p(u0 + s0, v, h0 + t1),
        ];
      case 'back':
        if (!faceVisible(0, -1)) return;
        final v = v0 - inset;
        pts = [
          p(u1 - s0, v, h0 + t0),
          p(u1 - s1, v, h0 + t0),
          p(u1 - s1, v, h0 + t1),
          p(u1 - s0, v, h0 + t1),
        ];
      case 'right':
        if (!faceVisible(1, 0)) return;
        final u = u1 + inset;
        pts = [
          p(u, v1 - s0, h0 + t0),
          p(u, v1 - s1, h0 + t0),
          p(u, v1 - s1, h0 + t1),
          p(u, v1 - s0, h0 + t1),
        ];
      default:
        if (!faceVisible(-1, 0)) return;
        final u = u0 - inset;
        pts = [
          p(u, v0 + s0, h0 + t0),
          p(u, v0 + s1, h0 + t0),
          p(u, v0 + s1, h0 + t1),
          p(u, v0 + s0, h0 + t1),
        ];
    }
    poly(pts, color);
  }

  List<Offset> _ellipse(
    double cu,
    double cv,
    double h,
    double r, [
    int n = 28,
  ]) => [
    for (var i = 0; i < n; i++)
      p(
        cu + r * math.cos(2 * math.pi * i / n),
        cv + r * math.sin(2 * math.pi * i / n),
        h,
      ),
  ];

  void disc(double cu, double cv, double h, double r, Color color) =>
      poly(_ellipse(cu, cv, h, r), color);

  /// Upright cylinder with side shading and a lighter top.
  void cylinder(
    double cu,
    double cv,
    double r,
    double h0,
    double h1,
    Color base, {
    Color? top,
  }) {
    final bottom = _ellipse(cu, cv, h0, r), upper = _ellipse(cu, cv, h1, r);
    final hull = convexHull([...bottom, ...upper]);
    final rect = Path()..addPolygon(hull, true);
    final b = rect.getBounds();
    canvas.drawPath(
      rect,
      _fill
        ..shader = Gradient.linear(
          b.centerLeft,
          b.centerRight,
          [lighten(base, 0.08), base, darken(base, 0.22)],
          [0, 0.45, 1],
        ),
    );
    _fill.shader = null;
    poly(upper, top ?? lighten(base, 0.14));
  }

  /// Soft sphere (foliage, robot heads) with a warm highlight.
  void sphere(double cu, double cv, double h, double r, Color base) {
    final c = p(cu, cv, h);
    final radius = r * scale * Iso.tileWidth * 0.56;
    final rect = Rect.fromCircle(center: c, radius: radius);
    canvas.drawCircle(
      c,
      radius,
      _fill
        ..shader = Gradient.radial(
          c.translate(-radius * 0.35, -radius * 0.4),
          radius * 1.4,
          [lighten(base, 0.28), base, darken(base, 0.25)],
          [0, 0.55, 1],
        ),
    );
    _fill.shader = null;
    canvas.drawOval(
      rect.deflate(radius * 0.02),
      _stroke
        ..color = darken(base, 0.4).withValues(alpha: 0.25)
        ..strokeWidth = 0.6,
    );
  }

  /// Small glowing dot (LEDs, lamps).
  void glow(Offset at, Color color, {double radius = 2.2, double halo = 6}) {
    canvas.drawCircle(
      at,
      halo,
      _fill
        ..color = color.withValues(alpha: 0.18)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
    );
    _fill.maskFilter = null;
    canvas.drawCircle(at, radius, _fill..color = color);
  }
}
