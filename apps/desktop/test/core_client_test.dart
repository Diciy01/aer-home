import 'package:aer_home_desktop/src/core_api/core_client.dart';
import 'package:aer_home_desktop/src/core_api/endpoint.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'fixtures.dart';

void main() {
  test('health is fetched without a token', () async {
    http.Request? seen;
    final client = clientFor(
      MockClient((req) async {
        seen = req;
        return jsonResponse(envelope(healthJson()));
      }),
      token: null,
    );

    final health = await client.health();

    expect(health.isOk, isTrue);
    expect(health.apiVersion, 'v1');
    expect(seen!.url.toString(), 'http://127.0.0.1:8787/api/v1/health');
    expect(seen!.headers.containsKey('Authorization'), isFalse);
  });

  test('systemInfo sends the bearer token and parses the payload', () async {
    final info = await clientFor(healthyCore()).systemInfo();
    expect(info.instanceId, fixtureInstanceId);
    expect(info.demo, isTrue);
    expect(info.schema.single.module, 'foundation');
  });

  test('missing token fails locally without a request', () async {
    var calls = 0;
    final client = clientFor(
      MockClient((req) async {
        calls++;
        return jsonResponse(envelope(systemInfoJson()));
      }),
      token: null,
    );

    await expectLater(
      client.systemInfo(),
      throwsA(
        isA<CoreApiException>()
            .having((e) => e.code, 'code', CoreApiException.tokenMissing)
            .having((e) => e.isUnauthorized, 'isUnauthorized', isTrue),
      ),
    );
    expect(calls, 0);
  });

  test(
    'error envelope becomes CoreApiException with code and requestId',
    () async {
      final client = clientFor(healthyCore(), token: 'wrong');
      await expectLater(
        client.systemInfo(),
        throwsA(
          isA<CoreApiException>()
              .having((e) => e.statusCode, 'status', 401)
              .having((e) => e.code, 'code', 'UNAUTHORIZED')
              .having((e) => e.requestId, 'requestId', 'req-err'),
        ),
      );
    },
  );

  test('connection failure becomes CoreUnreachable', () async {
    await expectLater(
      clientFor(deadCore()).health(),
      throwsA(isA<CoreUnreachable>()),
    );
  });

  test('non-envelope response is rejected', () async {
    final client = clientFor(
      MockClient((req) async => http.Response('<html>proxy</html>', 200)),
    );
    await expectLater(
      client.health(),
      throwsA(
        isA<CoreApiException>().having(
          (e) => e.code,
          'code',
          CoreApiException.invalidResponse,
        ),
      ),
    );
  });

  test('endpoint honours environment overrides', () {
    final e = CoreEndpoint.fromEnvironment({
      'AER_CORE_URL': 'http://198.51.100.5:9000',
      'AER_CORE_TOKEN_FILE': '/tmp/test.token',
      'HOME': '/home/test',
    });
    expect(e.baseUri.toString(), 'http://198.51.100.5:9000');
    expect(e.tokenFile, '/tmp/test.token');
  });

  test('endpoint defaults to loopback and the Core data dir', () {
    final e = CoreEndpoint.fromEnvironment({'HOME': '/home/test'});
    expect(e.baseUri.toString(), CoreEndpoint.defaultUrl);
    expect(e.tokenFile, '/home/test/.local/share/aer-home/core/core.token');
  }, testOn: 'linux');
}
