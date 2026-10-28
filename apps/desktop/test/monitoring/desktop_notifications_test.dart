import 'package:aer_home_desktop/src/state/app_section.dart';
import 'package:aer_home_desktop/src/state/connection_controller.dart';
import 'package:aer_home_desktop/src/state/desktop_notifications.dart';
import 'package:aer_home_desktop/src/state/monitoring_controller.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../fixtures.dart';
import 'fake_monitoring_api.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'only live increases notify; startup, repeats, reconnect and reads do not',
    () async {
      var online = true;
      final connection = ConnectionController(
        clientFor(
          MockClient((r) async {
            if (!online) throw http.ClientException('offline');
            return healthyHandler(r);
          }),
        ),
      );
      final api = FakeMonitoringApi();
      final monitoring = MonitoringController(api, connection, autoPoll: false);
      final section = AppSectionController();
      final bridge = DesktopNotifications(monitoring, section);
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(DesktopNotifications.channel, (call) async {
            calls.add(call);
            return true;
          });
      addTearDown(() {
        bridge.dispose();
        monitoring.dispose();
        connection.dispose();
        section.dispose();
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(DesktopNotifications.channel, null);
      });
      bridge.start();
      await connection.refresh();
      await monitoring.start();
      await monitoring.refresh();
      expect(calls, isEmpty, reason: 'no backlog replay or duplicate');
      api.readAll = true;
      await monitoring.refresh();
      api.readAll = false;
      await monitoring.refresh();
      await Future<void>.delayed(Duration.zero);
      expect(calls, hasLength(1));
      expect(calls.single.method, 'notifyUnread');
      expect(
        calls.single.arguments,
        2,
        reason: 'only the count leaves the app',
      );
      online = false;
      await connection.refresh();
      online = true;
      await connection.refresh();
      await monitoring.refresh();
      expect(
        calls,
        hasLength(1),
        reason: 'reconnect establishes a new baseline',
      );
    },
  );
}
