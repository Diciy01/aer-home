import 'dart:async';

import 'package:flutter/services.dart';

import 'app_section.dart';
import 'monitoring_controller.dart';

/// Windows shell notifications contain counts only, never incident/log text.
/// Establish a live baseline first so startup and reconnect do not replay old
/// notifications. Failure of the optional shell integration cannot break UI.
class DesktopNotifications {
  DesktopNotifications(this.monitoring, this.section);

  static const channel = MethodChannel('aer.home/desktop');
  final MonitoringController monitoring;
  final AppSectionController section;
  int? _unread;

  void start() {
    monitoring.addListener(_changed);
    channel.setMethodCallHandler((call) async {
      if (call.method == 'openMonitoring') {
        section.value = AppSection.monitoring;
      }
    });
  }

  void _changed() {
    if (monitoring.freshness != MonFreshness.live || monitoring.loading) {
      if (monitoring.freshness != MonFreshness.live) _unread = null;
      return;
    }
    final previous = _unread;
    _unread = monitoring.unread;
    if (previous != null && monitoring.unread > previous) {
      unawaited(_notify(monitoring.unread));
    }
  }

  Future<void> _notify(int count) async {
    try {
      await channel.invokeMethod<bool>('notifyUnread', count);
    } on PlatformException {
      // Windows may disable shell notifications.
    } on MissingPluginException {
      // Optional shell integration is absent in widget tests.
    }
  }

  void dispose() {
    monitoring.removeListener(_changed);
    channel.setMethodCallHandler(null);
  }
}
