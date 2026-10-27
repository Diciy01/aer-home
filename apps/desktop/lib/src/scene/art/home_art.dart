// Geometry notation: W/D/H follow the scene format (width, depth, height).
// ignore_for_file: non_constant_identifier_names

import 'dart:math' as math;
import 'dart:ui';

import 'asset_painters.dart' show ArtContext;
import 'iso_pen.dart';

/// M04 art pass: the reference office set (desk, monitor, chair, lamp,
/// plant, rug) redrawn to one standard, plus the new catalog assets.
/// Still procedural placeholders (art.status = placeholder) — see
/// docs/SCENE_ART_ASSETS.md for the art standard and the sprite brief.
///
/// Standard used here: light from the upper left (top lightest, +y face mid,
/// +x face darkest — done by [IsoPen.box]); warm oak + walnut + sage + cream
/// only; soft rounded reads via edge highlights; no black outlines; small
/// details (handles, seams) one step darker than their surface.

typedef P = ScenePalette;

const _oakTop = Color(0xFFDDB88C);
const _oak = Color(0xFFCFA578);
const _oakDark = Color(0xFFA9805A);
const _brass = Color(0xFFC9A46A);
const _graphite = Color(0xFF55504C);

/// Circle on a local face plane, for knobs, speakers and fans.
List<Offset> _faceCircle(
  IsoPen p,
  String face,
  double a,
  double b,
  double fixed,
  double r, [
  int n = 20,
]) => [
  for (var i = 0; i < n; i++)
    switch (face) {
      'front' => p.p(
        a + r * math.cos(2 * math.pi * i / n),
        fixed,
        b + r * math.sin(2 * math.pi * i / n),
      ),
      _ => p.p(
        fixed,
        a + r * math.cos(2 * math.pi * i / n),
        b + r * math.sin(2 * math.pi * i / n),
      ),
    },
];

void desk(IsoPen p, ArtContext c) {
  const top = 1.38;
  // Side panel leg (left) and drawer pedestal (right).
  p.box(0.06, 0.08, 0, 0.2, p.D - 0.08, top, _oak, top: _oakTop);
  final du = p.W - 1.05;
  p.box(du, 0.1, 0, p.W - 0.06, p.D - 0.06, top, lighten(_oak, 0.04));
  // Modesty panel at the back.
  p.box(0.2, 0.14, 0.55, du, 0.22, top, darken(_oak, 0.08));
  for (final (t0, t1) in [(0.12, 0.5), (0.56, 0.94), (1.0, 1.32)]) {
    p.panel(
      'front',
      du,
      0.1,
      0,
      p.W - 0.06,
      p.D - 0.06,
      top,
      0.06,
      t0,
      0.93,
      t1,
      lighten(_oak, 0.16),
    );
    p.panel(
      'front',
      du,
      0.1,
      0,
      p.W - 0.06,
      p.D - 0.06,
      top,
      0.38,
      t1 - 0.1,
      0.61,
      t1 - 0.06,
      _brass,
    );
  }
  // Top slab with a darker front lip so it reads thick and rounded.
  p.box(0, 0, top, p.W, p.D, 1.5, _oak, top: _oakTop);
  p.panel(
    'front',
    0,
    0,
    top,
    p.W,
    p.D,
    1.5,
    0,
    0,
    p.W,
    0.03,
    darken(_oak, 0.12),
  );
  // Cable grommet and a notebook with a pen.
  p.disc(0.55, 0.35, 1.501, 0.09, _oakDark);
  p.box(0.55, 0.85, 1.5, 1.15, 1.3, 1.53, P.cream, edges: false);
  p.box(
    0.6,
    0.88,
    1.53,
    1.1,
    1.27,
    1.535,
    lighten(P.dustyBlue, 0.25),
    edges: false,
  );
  p.line(p.p(1.2, 0.9, 1.51), p.p(1.3, 1.25, 1.51), P.terracotta, width: 1.4);
}

void monitor(IsoPen p, ArtContext c) {
  final cu = p.W / 2;
  // Oval foot and a slim neck.
  p.disc(cu, 0.2, 0.0, 0.26, darken(_graphite, 0.05));
  p.box(cu - 0.22, 0.08, 0, cu + 0.22, 0.32, 0.04, _graphite);
  p.box(cu - 0.05, 0.12, 0.04, cu + 0.05, 0.2, 0.42, lighten(_graphite, 0.08));
  // Panel with a thin bezel.
  p.box(0, 0.18, 0.3, p.W, 0.27, p.H, _graphite);
  final on = c.screenOn;
  final screen = on ? const Color(0xFF86A4B2) : const Color(0xFF3F3936);
  p.panel(
    'front',
    0,
    0.18,
    0.3,
    p.W,
    0.27,
    p.H,
    0.04,
    0.05,
    p.W - 0.04,
    p.H - 0.34,
    screen,
  );
  if (on) {
    // A calm desktop: a window and a dock.
    p.panel(
      'front',
      0,
      0.18,
      0.3,
      p.W,
      0.27,
      p.H,
      0.14,
      0.24,
      0.8,
      0.6,
      lighten(screen, 0.35),
    );
    p.panel(
      'front',
      0,
      0.18,
      0.3,
      p.W,
      0.27,
      p.H,
      0.14,
      0.52,
      0.8,
      0.6,
      lighten(screen, 0.15),
    );
    p.panel(
      'front',
      0,
      0.18,
      0.3,
      p.W,
      0.27,
      p.H,
      0.45,
      0.08,
      0.95,
      0.12,
      lighten(screen, 0.25),
    );
  } else {
    // Soft reflection on a dark screen.
    p.panel(
      'front',
      0,
      0.18,
      0.3,
      p.W,
      0.27,
      p.H,
      0.12,
      0.4,
      0.45,
      0.62,
      lighten(screen, 0.08),
    );
  }
  p.glow(p.p(p.W - 0.12, 0.275, 0.33), c.led, radius: 1.3, halo: 3);
}

void officeChair(IsoPen p, ArtContext c) {
  final cu = p.W / 2, cv = p.D / 2;
  const fabric = Color(0xFF8DA78C);
  // Star base: two crossed spokes, five casters.
  p.box(cu - 0.45, cv - 0.04, 0.06, cu + 0.45, cv + 0.04, 0.12, _graphite);
  p.box(cu - 0.04, cv - 0.45, 0.06, cu + 0.04, cv + 0.45, 0.12, _graphite);
  for (var i = 0; i < 5; i++) {
    final a = -math.pi / 2 + i * 2 * math.pi / 5;
    p.disc(
      cu + 0.42 * math.cos(a),
      cv + 0.42 * math.sin(a),
      0.0,
      0.06,
      darken(_graphite, 0.2),
    );
  }
  p.cylinder(cu, cv, 0.05, 0.12, 0.78, lighten(_graphite, 0.1));
  // Seat: base shell + cushion.
  p.box(0.12, 0.14, 0.78, p.W - 0.12, p.D - 0.1, 0.86, _graphite);
  p.box(
    0.14,
    0.16,
    0.86,
    p.W - 0.14,
    p.D - 0.12,
    1.02,
    fabric,
    top: lighten(fabric, 0.14),
  );
  // Backrest with a lumbar cushion, raised on a support.
  p.box(cu - 0.06, 0.06, 0.86, cu + 0.06, 0.16, 1.2, _graphite);
  p.box(
    0.18,
    0.02,
    1.15,
    p.W - 0.18,
    0.2,
    p.H,
    darken(fabric, 0.06),
    top: lighten(fabric, 0.08),
  );
  p.panel(
    'front',
    0.18,
    0.02,
    1.15,
    p.W - 0.18,
    0.2,
    p.H,
    0.08,
    0.12,
    p.W - 0.44,
    0.75,
    lighten(fabric, 0.08),
  );
  // Armrests.
  for (final u in [0.04, p.W - 0.16]) {
    p.box(u + 0.03, 0.42, 0.86, u + 0.09, 0.5, 1.22, _graphite);
    p.box(u, 0.3, 1.22, u + 0.12, p.D - 0.25, 1.3, lighten(_graphite, 0.12));
  }
}

void deskLampArm(IsoPen p, ArtContext c) {
  final cu = p.W / 2, cv = p.D / 2;
  p.cylinder(cu, cv, 0.19, 0, 0.05, P.sageDeep, top: lighten(P.sageDeep, 0.2));
  p.box(
    cu - 0.025,
    cv - 0.025,
    0.05,
    cu + 0.025,
    cv + 0.025,
    0.7,
    darken(P.sage, 0.25),
  );
  p.disc(cu, cv, 0.7, 0.04, _brass);
  // Arm forward to the shade.
  p.box(
    cu - 0.02,
    cv - 0.02,
    0.68,
    cu + 0.02,
    cv + 0.18,
    0.72,
    darken(P.sage, 0.25),
  );
  p.cylinder(
    cu,
    cv + 0.12,
    0.17,
    0.78,
    1.05,
    P.cream,
    top: lighten(P.cream, 0.35),
  );
  p.glow(
    p.p(cu, cv + 0.12, 0.77),
    const Color(0xFFFFD79A),
    radius: 3,
    halo: 14,
  );
}

void plantFull(IsoPen p, ArtContext c) {
  final cu = p.W / 2, cv = p.D / 2;
  // Ceramic pot with a darker band and a rim.
  p.cylinder(cu, cv, 0.3, 0, 0.5, const Color(0xFFE9DCC7));
  p.cylinder(cu, cv, 0.305, 0.12, 0.2, P.terracotta);
  p.cylinder(cu, cv, 0.33, 0.5, 0.58, lighten(const Color(0xFFE9DCC7), 0.1));
  p.disc(cu, cv, 0.581, 0.28, darken(P.walnut, 0.35));
  p.line(
    p.p(cu, cv, 0.58),
    p.p(cu - 0.05, cv, 1.1),
    darken(P.sageDeep, 0.3),
    width: 1.6,
  );
  // Foliage: back to front, darker to lighter.
  final leaves = [
    (-0.16, -0.12, 1.0, 0.27, darken(P.sageDeep, 0.1)),
    (0.18, -0.06, 1.1, 0.25, P.sageDeep),
    (-0.08, 0.14, 1.22, 0.27, P.sage),
    (0.14, 0.12, 1.42, 0.24, lighten(P.sage, 0.06)),
    (-0.06, -0.02, 1.62, 0.22, lighten(P.sage, 0.14)),
    (0.06, 0.04, 1.8, 0.16, lighten(P.sage, 0.22)),
  ];
  for (final (du, dv, h, r, col) in leaves) {
    p.sphere(cu + du, cv + dv, h, r, col);
  }
}

void rugPattern(IsoPen p, ArtContext c) {
  const base = Color(0xFFE2CDAE);
  p.box(0, 0, 0, p.W, p.D, p.H, base, top: lighten(base, 0.12), edges: false);
  List<Offset> rect(double i) => [
    p.p(i, i, p.H),
    p.p(p.W - i, i, p.H),
    p.p(p.W - i, p.D - i, p.H),
    p.p(i, p.D - i, p.H),
  ];
  p.poly(rect(0.18), lighten(P.caramel, 0.3));
  p.poly(rect(0.3), lighten(base, 0.2));
  p.poly(rect(0.55), lighten(P.sage, 0.38));
  p.poly(rect(0.68), lighten(base, 0.24));
  // Diamonds along the centre line.
  final cv = p.D / 2;
  for (var u = 1.0; u < p.W - 0.8; u += 0.7) {
    p.poly([
      p.p(u, cv - 0.32, p.H),
      p.p(u + 0.28, cv, p.H),
      p.p(u, cv + 0.32, p.H),
      p.p(u - 0.28, cv, p.H),
    ], lighten(P.terracotta, 0.35));
  }
  // Fringe on the short sides.
  for (var v = 0.1; v < p.D - 0.05; v += 0.16) {
    p.line(p.p(-0.08, v, 0.02), p.p(0, v, 0.02), lighten(base, 0.1), width: 1);
    p.line(
      p.p(p.W, v, 0.02),
      p.p(p.W + 0.08, v, 0.02),
      lighten(base, 0.1),
      width: 1,
    );
  }
}

void armchair(IsoPen p, ArtContext c) {
  const fabric = Color(0xFFC9A27E);
  for (final (u, v) in [
    (0.12, 0.12),
    (p.W - 0.24, 0.12),
    (0.12, p.D - 0.24),
    (p.W - 0.24, p.D - 0.24),
  ]) {
    p.box(u, v, 0, u + 0.12, v + 0.12, 0.2, P.walnut);
  }
  p.box(0, 0, 0.2, p.W, p.D, 0.7, fabric);
  p.box(0.3, 0.42, 0.7, p.W - 0.3, p.D - 0.06, 0.92, lighten(fabric, 0.14));
  p.box(0, 0, 0.7, p.W, 0.42, p.H, darken(fabric, 0.05));
  p.box(0, 0.42, 0.7, 0.3, p.D, 1.12, fabric);
  p.box(p.W - 0.3, 0.42, 0.7, p.W, p.D, 1.12, fabric);
  p.sphere(p.W / 2, 0.55, 1.15, 0.24, P.sage);
}

void workstation(IsoPen p, ArtContext c) {
  p.box(0.04, 0.04, 0, p.W - 0.04, p.D - 0.04, 0.08, darken(_graphite, 0.2));
  p.box(0, 0, 0.08, p.W, p.D, p.H, _graphite, top: lighten(_graphite, 0.12));
  // Front mesh: fine horizontal slits.
  for (var t = 0.2; t < p.H - 0.4; t += 0.08) {
    p.panel(
      'front',
      0,
      0,
      0.08,
      p.W,
      p.D,
      p.H,
      0.1,
      t,
      p.W - 0.1,
      t + 0.03,
      darken(_graphite, 0.25),
    );
  }
  // Tinted side window with a soft status strip.
  p.panel(
    'right',
    0,
    0,
    0.08,
    p.W,
    p.D,
    p.H,
    0.12,
    0.25,
    p.D - 0.12,
    p.H - 0.35,
    const Color(0xFF6E6863),
  );
  p.panel(
    'right',
    0,
    0,
    0.08,
    p.W,
    p.D,
    p.H,
    0.12,
    p.H - 0.45,
    p.D - 0.12,
    p.H - 0.4,
    c.led.withValues(alpha: 0.9),
  );
  p.glow(p.p(p.W / 2, p.D + 0.01, p.H - 0.12), c.led, radius: 2, halo: 6);
}

void laptop(IsoPen p, ArtContext c) {
  const shell = Color(0xFFD9D4CE);
  p.box(0, 0.05, 0, p.W, p.D, 0.04, shell, top: lighten(shell, 0.2));
  p.box(
    0.1,
    0.12,
    0.04,
    p.W - 0.1,
    p.D * 0.62,
    0.045,
    darken(shell, 0.18),
    edges: false,
  );
  p.box(
    0.3,
    p.D * 0.7,
    0.04,
    p.W - 0.3,
    p.D - 0.06,
    0.045,
    darken(shell, 0.1),
    edges: false,
  );
  // Lid, standing at the back.
  p.box(0, 0, 0.04, p.W, 0.05, p.H, shell);
  p.panel(
    'front',
    0,
    0,
    0.04,
    p.W,
    0.05,
    p.H,
    0.05,
    0.05,
    p.W - 0.05,
    p.H - 0.09,
    c.screenOn ? const Color(0xFF86A4B2) : const Color(0xFF3F3936),
  );
}

void accessPoint(IsoPen p, ArtContext c) {
  // Flat rounded plate on the wall with a soft status ring.
  p.box(
    0.05,
    0,
    0.05,
    p.W - 0.05,
    p.D,
    p.H - 0.05,
    P.milk,
    top: lighten(P.milk, 0.2),
  );
  p.panel(
    'front',
    0.05,
    0,
    0.05,
    p.W - 0.05,
    p.D,
    p.H - 0.05,
    0.05,
    0.05,
    p.W - 0.15,
    p.H - 0.15,
    lighten(P.milk, 0.3),
  );
  if (p.faceVisible(0, 1)) {
    p.poly(
      _faceCircle(p, 'front', p.W / 2, p.H / 2, p.D + 0.006, 0.12),
      c.led.withValues(alpha: 0.85),
    );
    p.poly(
      _faceCircle(p, 'front', p.W / 2, p.H / 2, p.D + 0.008, 0.07),
      lighten(P.milk, 0.3),
    );
  }
}

void speaker(IsoPen p, ArtContext c) {
  p.box(0, 0, 0, p.W, p.D, p.H, P.walnut, top: lighten(P.walnut, 0.18));
  p.panel(
    'front',
    0,
    0,
    0,
    p.W,
    p.D,
    p.H,
    0.05,
    0.05,
    p.W - 0.05,
    p.H - 0.05,
    const Color(0xFF6E625A),
  );
  if (p.faceVisible(0, 1)) {
    final f = p.D + 0.006;
    p.poly(_faceCircle(p, 'front', p.W / 2, 0.32, f, 0.17), _graphite);
    p.poly(
      _faceCircle(p, 'front', p.W / 2, 0.32, f + 0.002, 0.07),
      lighten(_graphite, 0.15),
    );
    p.poly(_faceCircle(p, 'front', p.W / 2, 0.74, f, 0.08), _graphite);
  }
  p.glow(p.p(p.W / 2, p.D + 0.01, p.H - 0.1), c.led, radius: 1.3, halo: 3);
}

void painting(IsoPen p, ArtContext c) {
  p.box(0, 0, 0, p.W, p.D, p.H, P.walnut, top: lighten(P.walnut, 0.2));
  // Canvas: sky, sun, two hills.
  p.panel(
    'front',
    0,
    0,
    0,
    p.W,
    p.D,
    p.H,
    0.08,
    0.08,
    p.W - 0.08,
    p.H - 0.08,
    const Color(0xFFE7EEEC),
  );
  if (!p.faceVisible(0, 1)) return;
  final f = p.D + 0.006;
  p.poly(
    _faceCircle(p, 'front', p.W * 0.68, p.H * 0.68, f, 0.13),
    lighten(P.amber, 0.25),
  );
  p.poly([
    p.p(0.08, f, 0.08),
    p.p(p.W - 0.08, f, 0.08),
    p.p(p.W - 0.08, f, 0.42),
    p.p(p.W * 0.62, f, 0.62),
    p.p(p.W * 0.3, f, 0.38),
    p.p(0.08, f, 0.5),
  ], P.sage);
  p.poly([
    p.p(0.08, f, 0.08),
    p.p(p.W - 0.08, f, 0.08),
    p.p(p.W - 0.08, f, 0.22),
    p.p(p.W * 0.4, f, 0.34),
    p.p(0.08, f, 0.2),
  ], P.sageDeep);
}

void vase(IsoPen p, ArtContext c) {
  final cu = p.W / 2, cv = p.D / 2;
  p.cylinder(cu, cv, 0.13, 0, 0.36, lighten(P.sage, 0.2));
  p.cylinder(cu, cv, 0.08, 0.36, 0.42, lighten(P.sage, 0.3));
  for (final (du, h) in [(-0.06, 0.66), (0.05, 0.7), (0.0, 0.62)]) {
    p.line(
      p.p(cu, cv, 0.4),
      p.p(cu + du, cv, h),
      darken(P.caramel, 0.1),
      width: 1.1,
    );
    p.sphere(cu + du, cv, h, 0.04, lighten(P.amber, 0.2));
  }
}
