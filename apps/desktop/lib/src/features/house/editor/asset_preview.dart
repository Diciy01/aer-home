import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../../scene/geometry/iso.dart';
import '../../../scene/model/scene_document.dart';
import '../../../scene/render/scene_picture.dart';

/// Small isometric preview of an asset, drawn by the same art code as the
/// scene (no separate icon set to keep in sync). Each preview is rendered
/// once into a texture: the scene repaints panels' layers on every frame,
/// and redrawing ~30 vector previews with blurred shadows each time showed
/// up as idle CPU in build mode.
class AssetPreview extends StatelessWidget {
  const AssetPreview({
    super.key,
    required this.asset,
    this.size = const Size(96, 72),
    this.rotation = 0,
  });

  final SceneAsset asset;
  final Size size;
  final int rotation;

  static final _cache = <String, ui.Image>{};

  /// Drops cached textures (tests, memory pressure).
  static void clearCache() {
    for (final i in _cache.values) {
      i.dispose();
    }
    _cache.clear();
  }

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1;
    final key =
        '${asset.id}|${asset.footprint.w}x${asset.footprint.d}x${asset.height}|'
        '$rotation|${size.width}x${size.height}|$dpr';
    final image = _cache[key] ??= _render(dpr);
    return SizedBox.fromSize(
      size: size,
      child: RawImage(
        image: image,
        width: size.width,
        height: size.height,
        filterQuality: FilterQuality.medium,
      ),
    );
  }

  ui.Image _render(double dpr) {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.scale(dpr);
    paintPreview(canvas, size, asset, rotation);
    final pic = recorder.endRecording();
    final img = pic.toImageSync(
      (size.width * dpr).ceil(),
      (size.height * dpr).ceil(),
    );
    pic.dispose();
    return img;
  }
}

/// Draws [asset] centred and scaled to fit [size].
void paintPreview(Canvas canvas, Size size, SceneAsset asset, int rotation) {
  final rotated = rotation == 90 || rotation == 270;
  final w = rotated ? asset.footprint.d : asset.footprint.w;
  final d = rotated ? asset.footprint.w : asset.footprint.d;
  final box = Box3(0, 0, 0, w, d, asset.height);
  final bounds = Iso.screenBounds(box).inflate(4);
  final k = clampDouble(
    (size.width / bounds.width) < (size.height / bounds.height)
        ? size.width / bounds.width
        : size.height / bounds.height,
    0.05,
    2.2,
  );
  canvas.save();
  canvas.translate(size.width / 2, size.height / 2);
  canvas.scale(k);
  canvas.translate(-bounds.center.dx, -bounds.center.dy);
  // Soft contact shadow so the item "stands" in the tile.
  canvas.drawPath(
    Path()..addPolygon([
      Iso.project(-0.1, -0.1),
      Iso.project(w + 0.1, -0.1),
      Iso.project(w + 0.1, d + 0.1),
      Iso.project(-0.1, d + 0.1),
    ], true),
    Paint()
      ..color = const Color(0xFF4A3426).withValues(alpha: 0.14)
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, 3 / k),
  );
  paintAssetArt(canvas, asset, box, rotation: rotation, scale: 1);
  canvas.restore();
}
