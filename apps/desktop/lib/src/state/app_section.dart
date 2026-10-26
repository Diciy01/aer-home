import 'package:flutter/foundation.dart';

/// Top-level sections. `house` is the isometric mode; `overview` and `devices`
/// make up the classic mode. All sections stay mounted, so switching never
/// loses their state.
enum AppSection { house, overview, devices }

class AppSectionController extends ValueNotifier<AppSection> {
  AppSectionController([super.initial = AppSection.devices]);
}
