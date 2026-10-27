import 'package:flutter/foundation.dart';

/// Top-level sections. `house` is the isometric mode; `overview` and `devices`
/// make up the classic mode. Sections stay mounted once visited, so switching
/// never loses their state.
enum AppSection { house, overview, devices, monitoring, bots }

class AppSectionController extends ValueNotifier<AppSection> {
  AppSectionController([super.initial = AppSection.house]) {
    visited.add(value);
  }

  /// Sections opened at least once (heavy ones are built on first visit).
  final Set<AppSection> visited = {};

  @override
  set value(AppSection v) {
    visited.add(v);
    super.value = v;
  }
}
