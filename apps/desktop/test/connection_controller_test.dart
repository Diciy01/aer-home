import 'package:aer_home_desktop/src/state/connection_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'fixtures.dart';

void main() {
  ConnectionController controllerFor(
    MockClient http, {
    String? token = testToken,
  }) {
    final c = ConnectionController(clientFor(http, token: token));
    addTearDown(c.dispose);
    return c;
  }

  test('starts in checking state', () {
    expect(controllerFor(healthyCore()).link, CoreLink.checking);
  });

  test('healthy Core is online and allows actions', () async {
    final c = controllerFor(healthyCore());
    await c.refresh();
    expect(c.link, CoreLink.online);
    expect(c.info?.instanceId, fixtureInstanceId);
    expect(c.canAct, isTrue);
    expect(c.isStale, isFalse);
    expect(c.lastOnlineAt, isNotNull);
  });

  test(
    'going offline keeps last data marked stale and blocks actions',
    () async {
      var alive = true;
      final c = controllerFor(
        MockClient((req) async {
          if (!alive) throw http.ClientException('Connection refused', req.url);
          return healthyHandler(req);
        }),
      );
      await c.refresh();
      final onlineAt = c.lastOnlineAt;

      alive = false;
      await c.refresh();

      expect(c.link, CoreLink.offline);
      expect(c.info?.instanceId, fixtureInstanceId, reason: 'cached info kept');
      expect(c.isStale, isTrue);
      expect(c.canAct, isFalse);
      expect(c.lastOnlineAt, onlineAt);
      expect(c.detail, contains('Connection refused'));
    },
  );

  test('missing token is reported as unauthorized, not offline', () async {
    final c = controllerFor(healthyCore(), token: null);
    await c.refresh();
    expect(c.link, CoreLink.unauthorized);
    expect(c.canAct, isFalse);
  });

  test('degraded health is surfaced', () async {
    final c = controllerFor(
      MockClient(
        (req) async => req.url.path.endsWith('/health')
            ? jsonResponse(envelope(healthJson(status: 'degraded')))
            : jsonResponse(envelope(systemInfoJson())),
      ),
    );
    await c.refresh();
    expect(c.link, CoreLink.degraded);
    expect(c.canAct, isFalse);
  });

  test('payload with wrong types is incompatible, not a crash', () async {
    final c = controllerFor(
      MockClient(
        (req) async => req.url.path.endsWith('/health')
            ? jsonResponse(envelope(healthJson()))
            : jsonResponse(
                envelope({...systemInfoJson(), 'uptimeSeconds': 'sixty'}),
              ),
      ),
    );
    await c.refresh();
    expect(c.link, CoreLink.incompatible);
  });
}
