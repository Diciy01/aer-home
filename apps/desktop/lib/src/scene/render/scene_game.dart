import 'dart:async' as async;
import 'dart:io' show Platform;
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flame/components.dart';
import 'package:flame/game.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/scheduler.dart';

import '../geometry/iso.dart';

import '../art/iso_pen.dart';
import '../binding/scene_binding.dart';
import '../camera/scene_camera.dart';
import '../geometry/scene_layout.dart';
import '../model/scene_document.dart';
import 'scene_picture.dart';

/// Colour per visual state (paired with an icon; never colour alone).
Color statusColor(SceneStatus s) => switch (s) {
  SceneStatus.online => ScenePalette.sageDeep,
  SceneStatus.offline => const Color(0xFF8F8279),
  SceneStatus.warning => const Color(0xFFC98E3E),
  SceneStatus.critical => const Color(0xFFB8604B),
  SceneStatus.unknown => const Color(0xFF9C93AE),
  SceneStatus.loading => const Color(0xFF6F92A6),
  SceneStatus.archived => const Color(0xFF9A8878),
};

/// Flame game that renders a [SceneLayout]. The house is one cached vector
/// picture in the Flame world; the Flame camera mirrors [SceneCamera]. The
/// engine pauses itself when nothing moves, so an idle scene costs no frames.
class SceneGame extends FlameGame {
  SceneGame({SceneCamera? camera}) : view = camera ?? SceneCamera();

  final SceneCamera view;

  /// Bumped whenever the visible transform changes (overlays listen).
  final ValueNotifier<int> viewChanged = ValueNotifier(0);

  SceneLayout? _layout;
  Map<String, ObjectPresentation> _presentations = const {};
  ui.Picture? _picture;
  String? hoveredId;
  String? selectedId;
  bool reduceMotion = false;

  /// Set by input handlers; until then a resize keeps the whole house framed.
  bool userMovedCamera = false;
  bool _sized = false;
  bool _pendingReset = false;
  double _time = 0;
  double _idle = 0;
  Offset _lastCenter = Offset.zero;
  double _lastZoom = 0;

  /// Frame counter for performance checks.
  int framesRendered = 0;

  SceneLayout? get layout => _layout;
  Map<String, ObjectPresentation> get presentations => _presentations;

  @override
  Color backgroundColor() => const Color(0x00000000);

  @override
  Future<void> onLoad() async {
    world.add(_StaticScene(this));
    world.add(_Highlights(this));
    camera.viewport.add(_Badges(this));
  }

  /// Installs a new layout and/or presentations and rebuilds the picture.
  void setScene(
    SceneLayout layout,
    Map<String, ObjectPresentation> presentations, {
    bool resetCamera = false,
  }) {
    final first =
        _layout == null || _layout!.document.sceneId != layout.document.sceneId;
    _layout = layout;
    _presentations = presentations;
    _picture?.dispose();
    _picture = const ScenePictureBuilder().build(layout, presentations);
    _rasterize(layout);
    view.configure(bounds: layout.bounds.inflate(40));
    if (first || resetCamera) {
      userMovedCamera = false;
      if (_sized) {
        view.reset();
      } else {
        _pendingReset = true;
      }
    }
    wake();
  }

  bool get _hasAnimatedBadges =>
      !reduceMotion &&
      _presentations.values.any(
        (p) =>
            p.status == SceneStatus.critical || p.status == SceneStatus.loading,
      );

  /// Resumes rendering for a short while (input, state change, animation).
  void wake() {
    _idle = 0;
    _throttle?.cancel();
    _throttle = null;
    if (paused) resumeEngine();
  }

  async.Timer? _throttle;

  /// Interval between frames when only status badges animate and nothing
  /// else moves (~15 fps is enough for a slow pulse or spinner).
  static const badgeFrameInterval = Duration(milliseconds: 66);

  @override
  void onGameResize(Vector2 size) {
    super.onGameResize(size);
    view.configure(viewportSize: Size(size.x, size.y));
    _sized = true;
    if (_pendingReset || !userMovedCamera) {
      _pendingReset = false;
      view.reset();
    }
    wake();
  }

  @override
  void update(double dt) {
    super.update(dt);
    _time += dt;
    var moving = view.tick(dt);
    camera.viewfinder.position = Vector2(view.center.dx, view.center.dy);
    camera.viewfinder.zoom = view.zoom;
    if (view.center != _lastCenter || view.zoom != _lastZoom) {
      _lastCenter = view.center;
      _lastZoom = view.zoom;
      _lastMoveAt = _time;
      _announceViewChange();
      // Input-driven pan/zoom counts as activity too, not only flights.
      moving = true;
    }
    if (moving) {
      _idle = 0;
      return;
    }
    _idle += dt;
    if (_idle <= 0.3) return;
    pauseEngine();
    if (_hasAnimatedBadges) {
      // Throttled animation: render one frame, sleep, repeat.
      _throttle = async.Timer(badgeFrameInterval, () {
        _throttle = null;
        if (paused) resumeEngine();
      });
    }
  }

  // --- Raster cache -------------------------------------------------------
  // Impeller re-rasterises vector pictures every frame. While the camera
  // moves, the house is drawn from a texture rendered once per scene state;
  // when it settles at a zoom above the texture's resolution, one crisp
  // vector frame is drawn instead.

  /// Longest side of the cached texture (≈ 24 MB RGBA at 3072×1950).
  static const maxCacheSide = 3072.0;

  ui.Image? _cache;
  Rect _cacheRect = Rect.zero;
  double _cacheScale = 0;
  double _lastMoveAt = -1;

  double get _dpr =>
      ui.PlatformDispatcher.instance.implicitView?.devicePixelRatio ?? 1;

  void _rasterize(SceneLayout layout) {
    final pic = _picture;
    if (pic == null) return;
    final rect = layout.bounds.inflate(8);
    final scale = math.min(
      math.min(maxCacheSide / rect.width, maxCacheSide / rect.height),
      2 * _dpr,
    );
    final recorder = ui.PictureRecorder();
    Canvas(recorder)
      ..scale(scale)
      ..translate(-rect.left, -rect.top)
      ..drawPicture(pic);
    final scaled = recorder.endRecording();
    final image = scaled.toImageSync(
      (rect.width * scale).ceil(),
      (rect.height * scale).ceil(),
    );
    scaled.dispose();
    _cache?.dispose();
    _cache = image;
    _cacheRect = rect;
    _cacheScale = scale;
  }

  bool get _moving => _time - _lastMoveAt < 0.15;

  /// Whether this frame may use the texture instead of the vector picture.
  bool get useRasterCache =>
      _cache != null && (_moving || view.zoom * _dpr <= _cacheScale * 1.05);

  bool _announcePending = false;

  /// Notifies overlays after the frame: update() may run during a widget
  /// build (GameWidget calls it from its LayoutBuilder), where listeners must
  /// not be marked dirty.
  void _announceViewChange() {
    if (_announcePending) return;
    _announcePending = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _announcePending = false;
      viewChanged.value++;
    });
    SchedulerBinding.instance.ensureVisualUpdate();
  }

  /// Diagnostics: AER_SCENE_FPS_LOG=1 prints scene repaints per second.
  static final bool _fpsLog = Platform.environment['AER_SCENE_FPS_LOG'] == '1';
  int _fpsFrames = 0;
  final _fpsClock = Stopwatch()..start();

  @override
  void render(Canvas canvas) {
    super.render(canvas);
    framesRendered++;
    if (_fpsLog) {
      _fpsFrames++;
      final elapsed = _fpsClock.elapsedMilliseconds / 1000;
      if (elapsed >= 1) {
        // ignore: avoid_print
        print(
          'scene fps=${(_fpsFrames / elapsed).toStringAsFixed(1)} cache=${useRasterCache ? 'texture' : 'vector'} zoom=${view.zoom.toStringAsFixed(2)}',
        );
        _fpsFrames = 0;
        _fpsClock.reset();
      }
    }
  }

  @override
  void onRemove() {
    _throttle?.cancel();
    _cache?.dispose();
    _picture?.dispose();
    super.onRemove();
  }
}

class _StaticScene extends Component {
  _StaticScene(this.game);
  final SceneGame game;

  final _paint = Paint()..filterQuality = FilterQuality.medium;

  @override
  void render(Canvas canvas) {
    final img = game._cache;
    if (img != null && game.useRasterCache) {
      canvas.drawImageRect(
        img,
        Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
        game._cacheRect,
        _paint,
      );
      return;
    }
    final pic = game._picture;
    if (pic != null) canvas.drawPicture(pic);
  }
}

/// Hover/selection outlines in world space (thin strokes keep constant width).
class _Highlights extends Component {
  _Highlights(this.game);
  final SceneGame game;
  final _stroke = Paint()
    ..style = PaintingStyle.stroke
    ..strokeJoin = StrokeJoin.round
    ..isAntiAlias = true;
  final _fill = Paint()..isAntiAlias = true;

  @override
  void render(Canvas canvas) {
    final layout = game._layout;
    if (layout == null) return;
    final z = game.view.zoom;
    void outline(
      String? id,
      Color color,
      double width,
      double fillAlpha, {
      bool glow = false,
    }) {
      final g = id == null ? null : layout.objects[id];
      if (g == null) return;
      final path = Path()..addPolygon(g.silhouette, true);
      canvas.drawPath(path, _fill..color = color.withValues(alpha: fillAlpha));
      if (glow) {
        canvas.drawPath(
          path,
          _stroke
            ..color = color.withValues(alpha: 0.35)
            ..strokeWidth = 7 / z
            ..maskFilter = MaskFilter.blur(BlurStyle.normal, 4 / z),
        );
        _stroke.maskFilter = null;
      }
      canvas.drawPath(
        path,
        _stroke
          ..color = color
          ..strokeWidth = width / z,
      );
    }

    if (game.hoveredId != game.selectedId) {
      outline(game.hoveredId, const Color(0xFFFFF8EC), 2, 0.10);
    }
    outline(game.selectedId, const Color(0xFFB27C52), 2.5, 0.08, glow: true);
  }
}

/// Status badges in screen space, so they stay legible at any zoom.
class _Badges extends Component {
  _Badges(this.game);
  final SceneGame game;
  final _fill = Paint()..isAntiAlias = true;
  final _stroke = Paint()
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round
    ..isAntiAlias = true;

  final _labels = <String, TextPainter>{};

  TextPainter _label(String text) => _labels.putIfAbsent(
    text,
    () => TextPainter(
      text: TextSpan(
        text: text,
        style: const TextStyle(
          fontSize: 13,
          color: Color(0xFF6B5D53),
          fontWeight: FontWeight.w600,
          letterSpacing: 0.3,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout(),
  );

  /// Room names at the centre of each room's floor.
  void _roomLabels(Canvas canvas, SceneLayout layout) {
    if (game.view.zoom < 0.42) return;
    for (final r in layout.rooms) {
      final tp = _label(r.room.name);
      final at = game.view.worldToScreen(
        Iso.project((r.x0 + r.x1) / 2, (r.y0 + r.y1) / 2),
      );
      final rect = Rect.fromCenter(
        center: at,
        width: tp.width + 18,
        height: tp.height + 8,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(10)),
        _fill..color = const Color(0xD9FFFBF4),
      );
      tp.paint(canvas, rect.topLeft + const Offset(9, 4));
    }
  }

  @override
  void render(Canvas canvas) {
    final layout = game._layout;
    if (layout == null) return;
    _roomLabels(canvas, layout);
    final r = 8.5 * game.view.zoom.clamp(0.75, 1.35);
    for (final g in layout.objects.values) {
      final p = game._presentations[g.object.id];
      final s = p?.status;
      if (p == null || s == null) continue;
      final c = game.view.worldToScreen(g.topAnchor) - Offset(0, r + 6);
      _badge(canvas, c, r, s, p.isDemo, p.stale);
    }
  }

  void _badge(
    Canvas canvas,
    Offset c,
    double r,
    SceneStatus s,
    bool demo,
    bool stale,
  ) {
    final color = statusColor(s);
    final alpha = stale ? 0.6 : 1.0;
    if (s == SceneStatus.critical && !game.reduceMotion) {
      final phase = (game._time % 1.8) / 1.8;
      canvas.drawCircle(
        c,
        r + 2 + phase * 9,
        _stroke
          ..color = color.withValues(alpha: 0.45 * (1 - phase))
          ..strokeWidth = 2,
      );
    }
    canvas.drawCircle(
      c.translate(0, 1.5),
      r + 1.5,
      _fill..color = const Color(0x33000000),
    );
    canvas.drawCircle(
      c,
      r + 1.6,
      _fill..color = const Color(0xFFFFFBF4).withValues(alpha: alpha),
    );
    canvas.drawCircle(c, r, _fill..color = color.withValues(alpha: alpha));
    _stroke
      ..color = const Color(0xFFFFFBF4).withValues(alpha: alpha)
      ..strokeWidth = r * 0.24;
    final k = r * 0.45;
    switch (s) {
      case SceneStatus.online:
        canvas.drawPath(
          Path()
            ..moveTo(c.dx - k, c.dy)
            ..lineTo(c.dx - k * 0.2, c.dy + k * 0.75)
            ..lineTo(c.dx + k, c.dy - k * 0.7),
          _stroke,
        );
      case SceneStatus.offline:
        canvas.drawArc(
          Rect.fromCircle(center: c.translate(0, k * 0.1), radius: k * 0.95),
          -math.pi / 2 + 0.7,
          2 * math.pi - 1.4,
          false,
          _stroke,
        );
        canvas.drawLine(
          c.translate(0, -k * 1.05),
          c.translate(0, -k * 0.1),
          _stroke,
        );
      case SceneStatus.warning:
        canvas.drawLine(c.translate(0, -k), c.translate(0, k * 0.25), _stroke);
        canvas.drawCircle(
          c.translate(0, k * 0.85),
          r * 0.13,
          _fill..color = _stroke.color,
        );
      case SceneStatus.critical:
        canvas.drawLine(
          c.translate(-k * 0.8, -k * 0.8),
          c.translate(k * 0.8, k * 0.8),
          _stroke,
        );
        canvas.drawLine(
          c.translate(k * 0.8, -k * 0.8),
          c.translate(-k * 0.8, k * 0.8),
          _stroke,
        );
      case SceneStatus.unknown:
        canvas.drawArc(
          Rect.fromCircle(center: c.translate(0, -k * 0.35), radius: k * 0.6),
          math.pi,
          math.pi * 1.4,
          false,
          _stroke,
        );
        canvas.drawLine(
          c.translate(0, k * 0.15),
          c.translate(0, k * 0.4),
          _stroke,
        );
        canvas.drawCircle(
          c.translate(0, k * 0.95),
          r * 0.12,
          _fill..color = _stroke.color,
        );
      case SceneStatus.loading:
        final start = game.reduceMotion ? 0.0 : game._time * 4;
        canvas.drawArc(
          Rect.fromCircle(center: c, radius: k),
          start,
          math.pi * 1.3,
          false,
          _stroke,
        );
      case SceneStatus.archived:
        canvas.drawRect(
          Rect.fromCenter(
            center: c.translate(0, k * 0.2),
            width: k * 1.7,
            height: k * 1.2,
          ),
          _stroke..strokeWidth = r * 0.18,
        );
        canvas.drawLine(
          c.translate(-k, -k * 0.65),
          c.translate(k, -k * 0.65),
          _stroke,
        );
    }
    if (demo) {
      // Test-state marker: small lavender tab, explained in the legend.
      final t = c.translate(r * 0.8, -r * 0.8);
      canvas.drawCircle(t, r * 0.42, _fill..color = const Color(0xFFFFFBF4));
      canvas.drawCircle(t, r * 0.32, _fill..color = ScenePalette.lavender);
    }
  }
}
