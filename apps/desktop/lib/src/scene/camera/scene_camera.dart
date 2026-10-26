import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/animation.dart' show Curves;

import '../geometry/iso.dart';

/// Camera state and math, independent of Flame and of input devices, so the
/// desktop (mouse), future mobile (touch) and tests drive the same API.
///
/// World pixels are the projected scene at zoom 1 (see [Iso]). The camera
/// shows [center] in the middle of the viewport at [zoom].
class SceneCamera {
  SceneCamera({this.maxZoom = 3.5, this.minZoomFactor = 0.6});

  final double maxZoom;

  /// The smallest zoom is this fraction of "fit the whole house".
  final double minZoomFactor;

  Offset center = Offset.zero;
  double zoom = 1;
  Size viewport = const Size(800, 600);
  Rect sceneBounds = const Rect.fromLTWH(-100, -100, 200, 200);

  _Flight? _flight;

  bool get isAnimating => _flight != null;

  double get minZoom => math.max(0.15, fitZoom(sceneBounds) * minZoomFactor);

  /// Zoom that fits [rect] into the viewport with [padding] pixels around it.
  double fitZoom(Rect rect, {double padding = 48}) {
    final w = math.max(1.0, viewport.width - padding * 2);
    final h = math.max(1.0, viewport.height - padding * 2);
    return math.min(w / math.max(rect.width, 1), h / math.max(rect.height, 1));
  }

  Offset worldToScreen(Offset world) =>
      (world - center) * zoom + Offset(viewport.width / 2, viewport.height / 2);

  Offset screenToWorld(Offset screen) =>
      (screen - Offset(viewport.width / 2, viewport.height / 2)) / zoom +
      center;

  /// Sets the scene bounds and viewport; call on load and on window resize.
  void configure({Rect? bounds, Size? viewportSize}) {
    if (bounds != null) sceneBounds = bounds;
    if (viewportSize != null && !viewportSize.isEmpty) viewport = viewportSize;
    _clamp();
  }

  /// Frames the whole house.
  void reset({bool animate = false}) =>
      focusRect(sceneBounds, animate: animate, padding: 32);

  /// Frames [rect] (e.g. a room), optionally with a smooth flight.
  void focusRect(Rect rect, {bool animate = true, double padding = 64}) {
    final z = clampDouble(fitZoom(rect, padding: padding), minZoom, maxZoom);
    if (!animate) {
      _flight = null;
      center = rect.center;
      zoom = z;
      _clamp();
      return;
    }
    _flight = _Flight(center, zoom, rect.center, z);
  }

  /// Zooms by [factor] keeping the world point under [screenFocus] fixed
  /// (mouse wheel at cursor, pinch focal point).
  void zoomAt(Offset screenFocus, double factor) {
    _flight = null;
    final before = screenToWorld(screenFocus);
    zoom = clampDouble(zoom * factor, minZoom, maxZoom);
    final after = screenToWorld(screenFocus);
    center += before - after;
    _clamp();
  }

  /// Moves the view by a screen-space drag delta.
  void panBy(Offset screenDelta) {
    _flight = null;
    center -= screenDelta / zoom;
    _clamp();
  }

  /// Advances an animation; returns true while still moving.
  bool tick(double dt) {
    final f = _flight;
    if (f == null) return false;
    f.t = math.min(1, f.t + dt / f.duration);
    final e = Curves.easeInOutCubic.transform(f.t);
    center = Offset.lerp(f.fromCenter, f.toCenter, e)!;
    // Interpolate zoom geometrically so the motion feels uniform.
    zoom = f.fromZoom * math.pow(f.toZoom / f.fromZoom, e);
    if (f.t >= 1) {
      _flight = null;
      _clamp();
      return false;
    }
    return true;
  }

  /// Keeps the house reachable: the viewport centre may not leave the scene
  /// bounds, so part of the house is always on screen.
  void _clamp() {
    zoom = clampDouble(zoom, minZoom, maxZoom);
    center = Offset(
      clampDouble(center.dx, sceneBounds.left, sceneBounds.right),
      clampDouble(center.dy, sceneBounds.top, sceneBounds.bottom),
    );
  }
}

class _Flight {
  _Flight(this.fromCenter, this.fromZoom, this.toCenter, this.toZoom);
  final Offset fromCenter, toCenter;
  final double fromZoom, toZoom;
  final double duration = 0.45;
  double t = 0;
}
