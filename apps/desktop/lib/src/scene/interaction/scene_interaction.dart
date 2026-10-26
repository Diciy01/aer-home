import 'dart:ui';

import 'package:flutter/foundation.dart';

import '../camera/scene_camera.dart';
import '../geometry/scene_layout.dart';

/// Hover and selection logic, independent of the input device and renderer.
/// Hit testing goes through [SceneLayout.hitTest], which respects occlusion.
class SceneInteraction extends ChangeNotifier {
  SceneInteraction(this.camera);

  final SceneCamera camera;
  SceneLayout? layout;
  String? _hoveredId;
  String? _selectedId;

  String? get hoveredId => _hoveredId;
  String? get selectedId => _selectedId;

  ObjectGeometry? get hovered =>
      _hoveredId == null ? null : layout?.objects[_hoveredId];
  ObjectGeometry? get selected =>
      _selectedId == null ? null : layout?.objects[_selectedId];

  ObjectGeometry? pick(Offset screen) =>
      layout?.hitTest(camera.screenToWorld(screen));

  /// Updates the hovered object; returns true if it changed.
  bool hover(Offset? screen) {
    final id = screen == null ? null : pick(screen)?.object.id;
    if (id == _hoveredId) return false;
    _hoveredId = id;
    notifyListeners();
    return true;
  }

  /// Selects the object under [screen], or clears the selection on empty space.
  ObjectGeometry? tap(Offset screen) {
    final g = pick(screen);
    select(g?.object.id);
    return g;
  }

  void select(String? id) {
    if (id == _selectedId) return;
    _selectedId = id;
    notifyListeners();
  }

  /// Drops ids that no longer exist after a document change.
  void syncWith(SceneLayout l) {
    layout = l;
    var changed = false;
    if (_hoveredId != null && !l.objects.containsKey(_hoveredId)) {
      _hoveredId = null;
      changed = true;
    }
    if (_selectedId != null && !l.objects.containsKey(_selectedId)) {
      _selectedId = null;
      changed = true;
    }
    if (changed) notifyListeners();
  }
}
