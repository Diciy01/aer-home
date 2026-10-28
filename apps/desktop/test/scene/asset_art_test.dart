import 'dart:ui';

import 'package:aer_home_desktop/src/scene/geometry/scene_layout.dart';
import 'package:aer_home_desktop/src/scene/model/scene_document.dart';
import 'package:aer_home_desktop/src/scene/render/scene_picture.dart';
import 'package:flutter_test/flutter_test.dart';

import 'scene_fixtures.dart';

void main() {
  // Regression (found with the M12 lab): the TV painter threw when its screen
  // was on (bound TV while loading/online) — the demo scene only ever had it off.
  test('every asset paints in every status without throwing', () {
    final doc = exampleScene();
    final layout = SceneLayout.build(doc);
    final seen = <String>{};
    for (final g in layout.objects.values) {
      if (!seen.add(g.asset.id)) continue;
      for (final status in [null, ...SceneStatus.values]) {
        for (final rotation in [0, 90, 180, 270]) {
          final recorder = PictureRecorder();
          paintAssetArt(
            Canvas(recorder),
            g.asset,
            g.box,
            rotation: rotation,
            scale: 1,
            status: status,
          );
          recorder.endRecording().dispose();
        }
      }
    }
    expect(seen, hasLength(doc.assets.length));
  });
}
