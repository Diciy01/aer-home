// TEST FIXTURES ONLY — not real Core data.
import 'dart:convert';

import 'package:aer_home_desktop/src/core_api/core_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const testToken = 'test-token-not-a-secret';

const fixtureInstanceId = '00000000-0000-4000-8000-000000000001';

Map<String, dynamic> envelope(Object data) => {
  'data': data,
  'meta': {'requestId': 'req-test', 'apiVersion': 'v1'},
};

Map<String, dynamic> errorEnvelope(String code, String message) => {
  'error': {'code': code, 'message': message},
  'meta': {'requestId': 'req-err', 'apiVersion': 'v1'},
};

Map<String, dynamic> healthJson({String status = 'ok'}) => {
  'status': status,
  'timestamp': '2026-10-26T18:00:00Z',
  'apiVersion': 'v1',
};

Map<String, dynamic> systemInfoJson() => {
  'coreVersion': '0.1.0-test',
  'apiVersion': 'v1',
  'mode': 'development',
  'demo': true,
  'instanceId': fixtureInstanceId,
  'instanceCreatedAt': '2026-10-26T17:00:00Z',
  'startedAt': '2026-10-26T17:59:00Z',
  'uptimeSeconds': 60,
  'schema': [
    {'module': 'foundation', 'version': 1},
  ],
  'modules': <Object>[],
};

http.Response jsonResponse(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

/// Answers like a healthy aer-core.
Future<http.Response> healthyHandler(http.Request req) async {
  switch (req.url.path) {
    case '/api/v1/health':
      return jsonResponse(envelope(healthJson()));
    case '/api/v1/system/info':
      if (req.headers['Authorization'] != 'Bearer $testToken') {
        return jsonResponse(errorEnvelope('UNAUTHORIZED', 'bad token'), 401);
      }
      return jsonResponse(envelope(systemInfoJson()));
  }
  return jsonResponse(errorEnvelope('NOT_FOUND', 'no such endpoint'), 404);
}

/// A fake Core that answers like a healthy aer-core.
MockClient healthyCore() => MockClient(healthyHandler);

/// A Core that is not running.
MockClient deadCore() => MockClient(
  (req) async => throw http.ClientException('Connection refused', req.url),
);

CoreClient clientFor(http.Client http, {String? token = testToken}) =>
    CoreClient(
      httpClient: http,
      baseUri: Uri.parse('http://127.0.0.1:8787'),
      tokenProvider: () async => token,
    );
