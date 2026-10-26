import 'dart:ui';

import 'package:aer_home_desktop/src/scene/camera/scene_camera.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  SceneCamera cam() => SceneCamera()
    ..configure(
      bounds: const Rect.fromLTWH(-800, -100, 1600, 900),
      viewportSize: const Size(1366, 768),
    )
    ..reset();

  test('screen ↔ world are inverse', () {
    final c = cam()..zoomAt(const Offset(300, 200), 1.7);
    for (final p in [
      Offset.zero,
      const Offset(100, 50),
      const Offset(1300, 760),
    ]) {
      final back = c.worldToScreen(c.screenToWorld(p));
      expect(back.dx, closeTo(p.dx, 1e-9));
      expect(back.dy, closeTo(p.dy, 1e-9));
    }
  });

  test('reset fits the whole scene', () {
    final c = cam();
    final tl = c.worldToScreen(c.sceneBounds.topLeft),
        br = c.worldToScreen(c.sceneBounds.bottomRight);
    expect(tl.dx >= 0 && tl.dy >= 0, isTrue);
    expect(br.dx <= 1366 && br.dy <= 768, isTrue);
  });

  test('zoom at cursor keeps the point under the cursor', () {
    final c = cam();
    const cursor = Offset(400, 300);
    final before = c.screenToWorld(cursor);
    c.zoomAt(cursor, 1.5);
    final after = c.screenToWorld(cursor);
    expect((after - before).distance, lessThan(1e-6));
  });

  test('zoom is clamped to min/max', () {
    final c = cam();
    for (var i = 0; i < 50; i++) {
      c.zoomAt(const Offset(10, 10), 2);
    }
    expect(c.zoom, c.maxZoom);
    for (var i = 0; i < 50; i++) {
      c.zoomAt(const Offset(10, 10), 0.5);
    }
    expect(c.zoom, closeTo(c.minZoom, 1e-9));
  });

  test('panning cannot lose the scene', () {
    final c = cam();
    c.panBy(const Offset(100000, -100000));
    expect(
      c.sceneBounds.contains(c.center) ||
          c.sceneBounds.inflate(1).contains(c.center),
      isTrue,
    );
    expect(
      c.screenToWorld(Offset(c.viewport.width / 2, c.viewport.height / 2)),
      c.center,
    );
  });

  test('focus flight animates to the room and stops', () {
    final c = cam();
    const room = Rect.fromLTWH(100, 100, 300, 200);
    c.focusRect(room);
    expect(c.isAnimating, isTrue);
    var steps = 0;
    while (c.tick(1 / 60)) {
      steps++;
    }
    expect(steps, inInclusiveRange(20, 40));
    expect((c.center - room.center).distance, lessThan(1e-6));
    expect(c.zoom, greaterThan(1));
  });

  test('resize keeps the camera valid', () {
    final c = cam()..configure(viewportSize: const Size(3840, 2160));
    expect(c.zoom, inInclusiveRange(c.minZoom, c.maxZoom));
    c.configure(viewportSize: const Size(640, 360));
    expect(c.zoom, inInclusiveRange(c.minZoom, c.maxZoom));
    c.configure(viewportSize: Size.zero);
    expect(c.viewport, const Size(640, 360), reason: 'zero size ignored');
  });
}
