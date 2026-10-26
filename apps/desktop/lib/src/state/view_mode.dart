import 'package:flutter/foundation.dart';

/// The two equal-rights presentations of the same data (docs/UX_DESIGN.md).
enum ViewMode { house, classic }

/// Holds the current presentation. Both views stay mounted, so switching never
/// loses their state.
class ViewModeController extends ValueNotifier<ViewMode> {
  ViewModeController([super.initial = ViewMode.classic]);
}
