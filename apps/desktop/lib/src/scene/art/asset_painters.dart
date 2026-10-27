// Geometry notation: W/D/H follow the scene format (width, depth, height).
// ignore_for_file: non_constant_identifier_names

import 'dart:math' as math;
import 'dart:ui';

import '../model/scene_document.dart';
import 'home_art.dart';
import 'iso_pen.dart';

typedef P = ScenePalette;

/// Visual inputs a painter may react to. Painters never fetch data.
class ArtContext {
  const ArtContext({this.status});
  final SceneStatus? status;

  /// LED/indicator colour; neutral when nothing is known.
  Color get led => switch (status) {
    SceneStatus.online => P.sage,
    SceneStatus.warning => P.amber,
    SceneStatus.critical => P.terracotta,
    SceneStatus.loading => P.dustyBlue,
    _ => const Color(0xFFB9AFA6),
  };

  bool get screenOn => switch (status) {
    SceneStatus.online ||
    SceneStatus.warning ||
    SceneStatus.critical ||
    SceneStatus.loading => true,
    _ => false,
  };

  Color get screen => screenOn ? const Color(0xFF6F8FA0) : P.screenOff;
}

typedef AssetPainter = void Function(IsoPen pen, ArtContext ctx);

/// Procedural placeholder art ("cozy/…" refs). Status: placeholder — to be
/// replaced by drawn sprites listed in docs/SCENE_ART_ASSETS.md without
/// changing scene logic (only this registry changes).
final Map<String, AssetPainter> proceduralArt = {
  'cozy/desk': desk,
  'cozy/monitor': monitor,
  'cozy/desk_lamp': deskLampArm,
  'cozy/pc_tower': _pcTower,
  'cozy/office_chair': officeChair,
  'cozy/bookshelf': _bookshelf,
  'cozy/plant': plantFull,
  'cozy/rug': rugPattern,
  'cozy/server_rack': _rack,
  'cozy/shelf': _shelf,
  'cozy/server_box': _serverBox,
  'cozy/network_switch': _switch,
  'cozy/crate': _crate,
  'cozy/tv_stand': _tvStand,
  'cozy/tv': _tv,
  'cozy/tv_stick': _tvStick,
  'cozy/sofa': _sofa,
  'cozy/coffee_table': _coffeeTable,
  'cozy/floor_lamp': _floorLamp,
  'cozy/network_cabinet': _netCabinet,
  'cozy/side_table': _sideTable,
  'cozy/router': _router,
  'cozy/link_panel': _linkPanel,
  'cozy/bot_station': _botStation,
  'cozy/bot': _bot,
  'cozy/terminal': _terminal,
  // M04 catalog additions (home_art.dart).
  'cozy/armchair': armchair,
  'cozy/workstation': workstation,
  'cozy/laptop': laptop,
  'cozy/access_point': accessPoint,
  'cozy/speaker': speaker,
  'cozy/painting': painting,
  'cozy/vase': vase,
};

/// Neutral fallback for unknown art refs: a soft crate with a question mark
/// area, clearly not a finished object.
void missingArt(IsoPen pen, ArtContext ctx) {
  pen.box(0, 0, 0, pen.W, pen.D, pen.H, const Color(0xFFD9D2C8));
  pen.panel(
    'front',
    0,
    0,
    0,
    pen.W,
    pen.D,
    pen.H,
    pen.W * 0.3,
    pen.H * 0.3,
    pen.W * 0.7,
    pen.H * 0.7,
    const Color(0xFFC4BAAE),
  );
}

/// Light pool cast on the floor by lamps (drawn in the floor pass).
const lampLightRadius = {'cozy/floor_lamp': 3.2, 'cozy/desk_lamp': 1.6};

void _pcTower(IsoPen p, ArtContext c) {
  p.box(0, 0, 0, p.W, p.D, p.H, P.milk);
  p.panel(
    'front',
    0,
    0,
    0,
    p.W,
    p.D,
    p.H,
    0.08,
    0.1,
    p.W - 0.08,
    p.H - 0.1,
    P.warmBeige,
  );
  p.panel(
    'front',
    0,
    0,
    0,
    p.W,
    p.D,
    p.H,
    0.15,
    p.H - 0.3,
    p.W - 0.15,
    p.H - 0.26,
    P.taupe,
  );
  for (var i = 0; i < 5; i++) {
    final t = 0.25 + i * 0.12;
    p.panel(
      'right',
      0,
      0,
      0,
      p.W,
      p.D,
      p.H,
      0.25,
      t,
      p.D - 0.25,
      t + 0.04,
      darken(P.milk, 0.12),
    );
  }
  p.glow(p.p(p.W / 2, p.D + 0.01, p.H - 0.17), c.led, radius: 2, halo: 6);
}

void _bookshelf(IsoPen p, ArtContext c) {
  final wood = P.walnut;
  const t = 0.08;
  p.box(0, 0, 0, p.W, 0.08, p.H, darken(wood, 0.15));
  p.box(0, 0, 0, t, p.D, p.H, wood);
  const books = [
    P.terracotta,
    P.sage,
    P.dustyBlue,
    P.cream,
    P.amber,
    P.lavender,
    P.caramel,
  ];
  final levels = [0.0, 0.9, 1.8, 2.7];
  var seed = 7;
  int next() => seed = (seed * 1103515245 + 12345) & 0x7fffffff;
  for (final z in levels) {
    p.box(t, 0.08, z, p.W - t, p.D, z + t, lighten(wood, 0.1));
    var u = t + 0.06;
    while (u < p.W - t - 0.25) {
      final bw = 0.1 + (next() % 7) / 70.0;
      final bh = 0.5 + (next() % 20) / 80.0;
      if (next() % 9 == 0) {
        u += 0.18;
        continue;
      }
      p.box(
        u,
        0.16,
        z + t,
        u + bw,
        p.D - 0.1,
        z + t + bh,
        books[next() % books.length],
        edges: false,
      );
      u += bw + 0.015;
    }
  }
  p.box(t, 0.08, p.H - t, p.W - t, p.D, p.H, lighten(wood, 0.1));
  p.box(p.W - t, 0, 0, p.W, p.D, p.H, wood);
}

void _rack(IsoPen p, ArtContext c) {
  final body = const Color(0xFF6B5F57);
  p.box(0, 0, 0.08, p.W, p.D, p.H, body, top: lighten(body, 0.1));
  p.box(0.05, 0.05, 0, p.W - 0.05, p.D - 0.05, 0.08, P.charcoal);
  p.panel(
    'front',
    0,
    0,
    0.08,
    p.W,
    p.D,
    p.H,
    0.08,
    0.1,
    p.W - 0.08,
    p.H - 0.25,
    const Color(0xFF4E4440),
  );
  for (var i = 0; i < 7; i++) {
    final t = 0.25 + i * 0.52;
    p.panel(
      'front',
      0,
      0,
      0.08,
      p.W,
      p.D,
      p.H,
      0.18,
      t,
      p.W - 0.18,
      t + 0.36,
      const Color(0xFF5E5450),
    );
    p.panel(
      'front',
      0,
      0,
      0.08,
      p.W,
      p.D,
      p.H,
      0.3,
      t + 0.14,
      p.W - 0.55,
      t + 0.2,
      const Color(0xFF6E625C),
    );
    p.glow(
      p.p(p.W - 0.35, p.D + 0.01, 0.08 + t + 0.18),
      i == 2 ? c.led : lighten(c.led, 0.15),
      radius: 1.6,
      halo: 4,
    );
  }
  for (var i = 0; i < 4; i++) {
    final s = 0.3 + i * 0.32;
    p.panel(
      'right',
      0,
      0,
      0.08,
      p.W,
      p.D,
      p.H,
      s,
      p.H - 0.6,
      s + 0.18,
      p.H - 0.35,
      darken(body, 0.25),
    );
  }
}

void _shelf(IsoPen p, ArtContext c) {
  final wood = P.oak;
  const post = 0.1;
  for (final (u, v) in [(0.0, 0.0), (p.W - post, 0.0)]) {
    p.box(u, v, 0, u + post, v + post, p.H, darken(wood, 0.2));
  }
  for (final z in [0.0, 0.92, 1.92, 2.92]) {
    p.box(0, 0, z, p.W, p.D, z + 0.08, wood, top: lighten(wood, 0.18));
  }
  for (final (u, v) in [(0.0, p.D - post), (p.W - post, p.D - post)]) {
    p.box(u, v, 0, u + post, v + post, p.H, darken(wood, 0.12));
  }
}

void _serverBox(IsoPen p, ArtContext c) {
  p.box(0, 0, 0, p.W, p.D, p.H, P.milk);
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
    const Color(0xFF8A7D72),
  );
  for (var i = 0; i < 3; i++) {
    final t = 0.16 + i * 0.2;
    p.panel(
      'front',
      0,
      0,
      0,
      p.W,
      p.D,
      p.H,
      0.16,
      t,
      p.W - 0.3,
      t + 0.12,
      const Color(0xFF9C9086),
    );
  }
  p.glow(p.p(p.W - 0.18, p.D + 0.01, p.H - 0.2), c.led, radius: 2, halo: 6);
}

void _switch(IsoPen p, ArtContext c) {
  const body = Color(0xFF7D8890);
  p.box(0, 0, 0, p.W, p.D, p.H, body);
  for (var i = 0; i < 8; i++) {
    final s = 0.1 + i * 0.15;
    p.panel(
      'front',
      0,
      0,
      0,
      p.W,
      p.D,
      p.H,
      s,
      0.07,
      s + 0.1,
      0.2,
      const Color(0xFF3F4448),
    );
    if (i.isEven) {
      p.glow(p.p(s + 0.05, p.D + 0.01, 0.27), c.led, radius: 1.2, halo: 3);
    }
  }
}

void _crate(IsoPen p, ArtContext c) {
  p.box(0, 0, 0, p.W, p.D, p.H, P.caramel, top: lighten(P.caramel, 0.25));
  for (var t = 0.15; t < p.H - 0.05; t += 0.16) {
    p.panel(
      'front',
      0,
      0,
      0,
      p.W,
      p.D,
      p.H,
      0.03,
      t,
      p.W - 0.03,
      t + 0.035,
      darken(P.caramel, 0.18),
    );
    p.panel(
      'right',
      0,
      0,
      0,
      p.W,
      p.D,
      p.H,
      0.03,
      t,
      p.D - 0.03,
      t + 0.035,
      darken(P.caramel, 0.3),
    );
  }
  p.box(
    0.08,
    0.08,
    p.H,
    p.W - 0.08,
    p.D - 0.08,
    p.H + 0.06,
    P.cream,
    edges: false,
  );
}

void _tvStand(IsoPen p, ArtContext c) {
  final wood = P.oak;
  for (final u in [0.1, p.W - 0.22]) {
    p.box(u, p.D - 0.22, 0, u + 0.12, p.D - 0.1, 0.18, darken(wood, 0.35));
  }
  p.box(0, 0, 0.18, p.W, p.D, p.H, wood, top: lighten(wood, 0.2));
  final third = p.W / 3;
  p.panel(
    'front',
    0,
    0,
    0.18,
    p.W,
    p.D,
    p.H,
    0.06,
    0.08,
    third - 0.03,
    p.H - 0.26,
    lighten(wood, 0.14),
  );
  p.panel(
    'front',
    0,
    0,
    0.18,
    p.W,
    p.D,
    p.H,
    third + 0.03,
    0.08,
    2 * third - 0.03,
    p.H - 0.26,
    darken(wood, 0.3),
  );
  p.panel(
    'front',
    0,
    0,
    0.18,
    p.W,
    p.D,
    p.H,
    2 * third + 0.03,
    0.08,
    p.W - 0.06,
    p.H - 0.26,
    lighten(wood, 0.14),
  );
}

void _tv(IsoPen p, ArtContext c) {
  for (final u in [0.5, p.W - 0.8]) {
    p.box(u, 0.0, 0, u + 0.3, p.D, 0.06, P.charcoal);
  }
  p.box(0, 0.08, 0.1, p.W, 0.22, p.H, const Color(0xFF453D39));
  if (c.screenOn) {
    final rect = [
      p.p(0.08, 0.225, 0.18),
      p.p(p.W - 0.08, 0.225, 0.18),
      p.p(p.W - 0.08, 0.225, p.H - 0.08),
      p.p(0.08, 0.225, p.H - 0.08),
    ];
    final path = Path()..addPolygon(rect, true);
    final b = path.getBounds();
    p.canvas.drawPath(
      path,
      Paint()
        ..shader = Gradient.linear(b.topLeft, b.bottomRight, [
          P.dustyBlue,
          P.sage,
          P.amber,
        ]),
    );
  } else {
    p.panel(
      'front',
      0,
      0.08,
      0.1,
      p.W,
      0.22,
      p.H,
      0.08,
      0.08,
      p.W - 0.08,
      p.H - 0.18,
      P.screenOff,
    );
    p.panel(
      'front',
      0,
      0.08,
      0.1,
      p.W,
      0.22,
      p.H,
      0.25,
      p.H - 0.6,
      1.2,
      p.H - 0.45,
      const Color(0xFF4A433F),
    );
  }
}

void _tvStick(IsoPen p, ArtContext c) {
  p.box(0, 0, 0, p.W, p.D, p.H, P.charcoal);
  p.glow(p.p(p.W - 0.08, p.D + 0.01, p.H * 0.6), c.led, radius: 1.3, halo: 3);
}

void _sofa(IsoPen p, ArtContext c) {
  const fabric = Color(0xFFB99272);
  for (final u in [0.15, p.W - 0.3]) {
    for (final v in [0.15, p.D - 0.3]) {
      p.box(u, v, 0, u + 0.15, v + 0.15, 0.18, P.walnut);
    }
  }
  p.box(0, 0, 0.18, p.W, p.D, 0.72, fabric);
  p.box(
    0.4,
    0.45,
    0.72,
    p.W / 2 - 0.02,
    p.D - 0.1,
    0.95,
    lighten(fabric, 0.12),
  );
  p.box(
    p.W / 2 + 0.02,
    0.45,
    0.72,
    p.W - 0.4,
    p.D - 0.1,
    0.95,
    lighten(fabric, 0.12),
  );
  p.box(0, 0, 0.72, p.W, 0.45, p.H, darken(fabric, 0.05));
  p.box(0, 0.45, 0.72, 0.4, p.D, 1.15, fabric);
  p.box(p.W - 0.4, 0.45, 0.72, p.W, p.D, 1.15, fabric);
  p.sphere(0.75, 0.75, 1.2, 0.22, P.terracotta);
  p.sphere(p.W - 0.8, 0.75, 1.2, 0.22, P.sage);
}

void _coffeeTable(IsoPen p, ArtContext c) {
  final wood = P.walnut;
  for (final (u, v) in [
    (0.1, 0.1),
    (p.W - 0.22, 0.1),
    (0.1, p.D - 0.22),
    (p.W - 0.22, p.D - 0.22),
  ]) {
    p.box(u, v, 0, u + 0.12, v + 0.12, 0.68, darken(wood, 0.1));
  }
  p.box(0.12, 0.12, 0.2, p.W - 0.12, p.D - 0.12, 0.26, lighten(wood, 0.1));
  p.box(
    0,
    0,
    0.68,
    p.W,
    p.D,
    p.H,
    lighten(wood, 0.15),
    top: lighten(wood, 0.32),
  );
  p.cylinder(0.55, 0.55, 0.1, p.H, p.H + 0.2, P.cream);
  p.box(p.W - 1.0, 0.35, p.H, p.W - 0.35, 0.8, p.H + 0.08, P.dustyBlue);
}

void _floorLamp(IsoPen p, ArtContext c) {
  final cu = p.W / 2, cv = p.D / 2;
  p.cylinder(cu, cv, 0.3, 0, 0.08, P.charcoal);
  p.box(
    cu - 0.04,
    cv - 0.04,
    0.08,
    cu + 0.04,
    cv + 0.04,
    2.5,
    darken(P.caramel, 0.2),
  );
  p.glow(p.p(cu, cv, 2.5), const Color(0xFFFFD9A0), radius: 4, halo: 22);
  p.cylinder(
    cu,
    cv,
    0.38,
    2.4,
    3.1,
    const Color(0xFFF5E2C2),
    top: const Color(0xFFFFF3DD),
  );
}

void _netCabinet(IsoPen p, ArtContext c) {
  const body = Color(0xFFB8AEA4);
  p.box(0, 0, 0, p.W, p.D, p.H, body);
  p.panel(
    'front',
    0,
    0,
    0,
    p.W,
    p.D,
    p.H,
    0.1,
    0.12,
    p.W - 0.1,
    p.H - 0.12,
    const Color(0xFF5A514C),
  );
  for (var i = 0; i < 5; i++) {
    final t = 0.4 + i * 0.48;
    p.panel(
      'front',
      0,
      0,
      0,
      p.W,
      p.D,
      p.H,
      0.22,
      t,
      p.W - 0.22,
      t + 0.22,
      const Color(0xFF746A63),
    );
    for (var k = 0; k < 4; k++) {
      p.glow(
        p.p(0.4 + k * 0.32, p.D + 0.012, t + 0.11),
        k == 0 ? c.led : lighten(c.led, 0.2),
        radius: 1.3,
        halo: 3,
      );
    }
  }
  p.panel(
    'front',
    0,
    0,
    0,
    p.W,
    p.D,
    p.H,
    p.W - 0.28,
    p.H / 2 - 0.2,
    p.W - 0.2,
    p.H / 2 + 0.2,
    P.cream,
  );
}

void _sideTable(IsoPen p, ArtContext c) {
  final wood = P.oak;
  for (final (u, v) in [
    (0.08, 0.08),
    (p.W - 0.2, 0.08),
    (0.08, p.D - 0.2),
    (p.W - 0.2, p.D - 0.2),
  ]) {
    p.box(u, v, 0, u + 0.12, v + 0.12, 1.0, darken(wood, 0.2));
  }
  p.box(0.04, 0.04, 1.0, p.W - 0.04, p.D - 0.04, 1.2, lighten(wood, 0.06));
  p.panel(
    'front',
    0.04,
    0.04,
    1.0,
    p.W - 0.04,
    p.D - 0.04,
    1.2,
    p.W / 2 - 0.25,
    0.06,
    p.W / 2 + 0.2,
    0.12,
    darken(wood, 0.3),
  );
  p.box(0, 0, 1.2, p.W, p.D, p.H, wood, top: lighten(wood, 0.22));
}

void _router(IsoPen p, ArtContext c) {
  for (final u in [0.15, 0.4, 0.6, 0.85]) {
    final lean = (u - p.W / 2) * 0.15;
    p.line(
      p.p(u, 0.12, 0.25),
      p.p(u + lean, 0.08, p.H),
      P.charcoal,
      width: 2.4,
    );
  }
  p.box(0, 0, 0, p.W, p.D, 0.28, P.milk, top: lighten(P.milk, 0.5));
  for (var i = 0; i < 4; i++) {
    p.glow(
      p.p(0.2 + i * 0.18, p.D + 0.01, 0.15),
      i == 0 ? c.led : lighten(c.led, 0.2),
      radius: 1.3,
      halo: 3.5,
    );
  }
}

void _linkPanel(IsoPen p, ArtContext c) {
  p.box(0, 0, 0, p.W, p.D, p.H, P.milk);
  p.panel(
    'front',
    0,
    0,
    0,
    p.W,
    p.D,
    p.H,
    0.06,
    0.06,
    p.W - 0.06,
    p.H - 0.06,
    P.warmBeige,
  );
  for (var i = 0; i < 6; i++) {
    final s = 0.2 + i * 0.3;
    p.glow(
      p.p(s, p.D + 0.01, 0.62),
      i < 2 ? c.led : lighten(c.led, 0.15),
      radius: 2.2,
      halo: 5,
    );
    p.panel(
      'front',
      0,
      0,
      0,
      p.W,
      p.D,
      p.H,
      s - 0.09,
      0.22,
      s + 0.09,
      0.28,
      P.taupe,
    );
  }
}

void _botStation(IsoPen p, ArtContext c) {
  final wood = P.oak;
  for (final u in [0.08, p.W - 0.2]) {
    p.box(u, 0.1, 0, u + 0.12, p.D - 0.1, 0.92, darken(wood, 0.25));
  }
  p.box(0, 0, 0.92, p.W, p.D, 1.02, wood, top: lighten(wood, 0.2));
  p.box(0.4, 0.15, 1.02, p.W - 0.4, 0.3, 1.5, P.charcoal);
  final rows = [0.08, 0.17, 0.26, 0.35];
  p.panel(
    'front',
    0.4,
    0.15,
    1.02,
    p.W - 0.4,
    0.3,
    1.5,
    0.05,
    0.05,
    p.W - 0.85,
    0.43,
    const Color(0xFF55615F),
  );
  for (final (i, t) in rows.indexed) {
    p.panel(
      'front',
      0.4,
      0.15,
      1.02,
      p.W - 0.4,
      0.3,
      1.5,
      0.12,
      t + 0.02,
      0.3 + (i * 37 % 5) * 0.12,
      t + 0.05,
      i.isEven ? P.sage : P.amber,
    );
  }
  p.box(0.6, 0.6, 1.02, p.W - 0.6, 0.95, 1.06, P.cream, edges: false);
}

void _bot(IsoPen p, ArtContext c) {
  final cu = p.W / 2, cv = p.D / 2;
  const shell = Color(0xFFF1E6D6);
  p.disc(cu, cv, 0.02, 0.3, darken(P.taupe, 0.2));
  p.cylinder(cu, cv, 0.26, 0.05, 0.62, shell);
  p.box(cu - 0.36, cv - 0.05, 0.3, cu - 0.26, cv + 0.05, 0.55, P.taupe);
  p.box(cu + 0.26, cv - 0.05, 0.3, cu + 0.36, cv + 0.05, 0.55, P.taupe);
  p.sphere(cu, cv, 0.88, 0.3, shell);
  // Face: a rounded visor on the head, turned between the bot's front and the
  // camera so characters stay readable from the fixed isometric view.
  final head = p.p(cu, cv, 0.88);
  final front = p.p(cu, cv + 1, 0.88) - head;
  final dir = Offset.lerp(front / front.distance, const Offset(0, 1), 0.55)!;
  final r = 0.3 * p.scale * 64 * 0.56;
  final visorCenter = head + dir / dir.distance * r * 0.38;
  final visor = RRect.fromRectAndRadius(
    Rect.fromCenter(center: visorCenter, width: r * 1.25, height: r * 0.62),
    Radius.circular(r * 0.31),
  );
  p.canvas.drawRRect(visor, Paint()..color = const Color(0xFF4A4542));
  final eye =
      c.status == SceneStatus.offline || c.status == SceneStatus.archived
      ? const Color(0xFF8A817A)
      : lighten(c.led, 0.25);
  p.glow(
    visorCenter.translate(-r * 0.28, 0),
    eye,
    radius: r * 0.13,
    halo: r * 0.25,
  );
  p.glow(
    visorCenter.translate(r * 0.28, 0),
    eye,
    radius: r * 0.13,
    halo: r * 0.25,
  );
  p.line(p.p(cu, cv, 1.15), p.p(cu, cv, 1.27), P.taupe, width: 1.5);
  p.glow(p.p(cu, cv, 1.29), c.led, radius: 2.4, halo: 6);
}

void _terminal(IsoPen p, ArtContext c) {
  final cu = p.W / 2;
  p.box(0.1, 0.1, 0, p.W - 0.1, p.D - 0.1, 0.1, P.charcoal);
  p.box(cu - 0.12, 0.35, 0.1, cu + 0.12, 0.6, 1.35, P.taupe);
  p.box(0.05, 0.2, 1.35, p.W - 0.05, 0.7, p.H, P.milk);
  p.panel(
    'front',
    0.05,
    0.2,
    1.35,
    p.W - 0.05,
    0.7,
    p.H,
    0.08,
    0.1,
    p.W - 0.18,
    p.H - 1.45,
    c.screen,
  );
  if (c.screenOn) {
    for (var i = 0; i < 3; i++) {
      p.panel(
        'front',
        0.05,
        0.2,
        1.35,
        p.W - 0.05,
        0.7,
        p.H,
        0.16,
        0.2 + i * 0.13,
        0.4 + i * 0.12,
        0.25 + i * 0.13,
        P.cream,
      );
    }
  }
  p.box(0.2, 0.6, 1.25, p.W - 0.2, p.D - 0.05, 1.32, P.cream);
}

/// Deterministic tiny variation for repeated decor.
double jitter(int seed) => (math.sin(seed * 12.9898) * 43758.5453) % 1;
