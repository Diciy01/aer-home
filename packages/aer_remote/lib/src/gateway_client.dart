import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'connect_auth.dart';
import 'registration.dart';
import 'errors.dart';
import 'models.dart';
import 'pinning.dart';

/// The owner's Remote Gateway as the user configured it: an address
/// (static IP, DDNS name or own domain — never built in) and the pinned
/// certificate fingerprint confirmed at pairing.
class GatewayServer {
  const GatewayServer(this.base, this.fingerprint);

  /// Parses what the user typed: `home.example.net`, `203.0.113.5:8443`
  /// or a full `https://` URL. Plain http is refused.
  factory GatewayServer.parse(String address, String fingerprint) {
    var a = address.trim();
    if (!a.contains('://')) a = 'https://$a';
    final u = Uri.parse(a);
    if (u.scheme != 'https' || u.host.isEmpty) {
      throw const FormatException('Адрес сервера: https://имя[:порт]');
    }
    return GatewayServer(
      Uri(scheme: 'https', host: u.host, port: u.hasPort ? u.port : 443),
      fingerprint,
    );
  }

  final Uri base;
  final String fingerprint;

  Uri resolve(String path, [Map<String, String>? query]) =>
      base.replace(path: path, queryParameters: query);
}

/// Result of pairing: the credential to keep in the OS secret store.
class PairResult {
  const PairResult(this.clientId, this.name, this.credential);
  final String clientId;
  final String name;
  final String credential;
}

/// Random Idempotency-Key for creating a session.
String newIdempotencyKey() {
  final r = Random.secure();
  return List.generate(
    16,
    (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
}

/// Client of the Gateway's public API (/gw/v1). Every call goes over TLS
/// pinned to [GatewayServer.fingerprint].
class GatewayClient {
  GatewayClient(this.server, {this.credential})
    : _http = pinnedHttpClient(server.fingerprint);

  final GatewayServer server;

  /// `aerc1.<id>.<secret>`; null before pairing.
  String? credential;
  final HttpClient _http;

  HttpClient get http => _http;

  Future<Object?> _call(
    String method,
    String path, {
    Object? body,
    Map<String, String>? headers,
  }) async {
    final HttpClientRequest req;
    try {
      req = await _http.openUrl(method, server.resolve(path));
    } on HandshakeException {
      throw PinMismatchException(server.fingerprint, '');
    }
    final cred = credential;
    if (cred != null) {
      req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $cred');
    }
    headers?.forEach(req.headers.set);
    if (body != null) {
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(body));
    }
    final HttpClientResponse res;
    try {
      res = await req.close();
    } on HandshakeException {
      throw PinMismatchException(server.fingerprint, '');
    }
    final text = await res.transform(utf8.decoder).join();
    Map<String, dynamic> env;
    try {
      env = jsonDecode(text) as Map<String, dynamic>;
    } on FormatException {
      throw RemoteEngineException(
        res.statusCode,
        'UNAVAILABLE',
        'Неожиданный ответ сервера (HTTP ${res.statusCode})',
      );
    }
    if (res.statusCode >= 300) {
      final e = env['error'] as Map<String, dynamic>? ?? const {};
      final details = e['details'];
      throw RemoteEngineException(
        res.statusCode,
        e['code'] as String? ?? 'UNAVAILABLE',
        e['message'] as String? ?? '',
        reason: details is Map ? details['reason'] as String? ?? '' : '',
      );
    }
    return env['data'];
  }

  /// Redeems the one-time pairing code; stores and returns the credential.
  Future<PairResult> pair(String code, {String deviceName = ''}) async {
    final d = await _call(
      'POST',
      '/gw/v1/pair',
      body: {'code': code, 'deviceName': deviceName},
    ) as Map<String, dynamic>;
    final r = PairResult(
      d['clientId'] as String,
      d['name'] as String? ?? '',
      d['credential'] as String,
    );
    credential = r.credential;
    return r;
  }

  Future<List<RemoteHostSummary>> hosts() async {
    final d = await _call('GET', '/gw/v1/hosts') as Map<String, dynamic>;
    return [
      for (final h in d['hosts'] as List)
        RemoteHostSummary.fromJson(h as Map<String, dynamic>),
    ];
  }

  Future<RemoteSessionInfo> create(
    String entityId, {
    String? idempotencyKey,
    int? minutes,
  }) async => RemoteSessionInfo.fromJson(
    await _call(
      'POST',
      '/gw/v1/sessions',
      body: {'entityId': entityId, 'minutes': ?minutes},
      headers: {'Idempotency-Key': idempotencyKey ?? newIdempotencyKey()},
    ) as Map<String, dynamic>,
  );

  Future<RemoteSessionInfo> session(String id) async =>
      RemoteSessionInfo.fromJson(
        await _call('GET', '/gw/v1/sessions/${Uri.encodeComponent(id)}')
            as Map<String, dynamic>,
      );

  Future<RelayGrant> grant(String id) async => RelayGrant.fromJson(
    await _call('POST', '/gw/v1/sessions/${Uri.encodeComponent(id)}/grant')
        as Map<String, dynamic>,
  );

  /// A fresh one-time ticket for one more leg (reconnect, second TCP).
  Future<String> ticket(String id, String channel) async {
    final d = await _call(
      'POST',
      '/gw/v1/sessions/${Uri.encodeComponent(id)}/tickets',
      body: {'channel': channel},
    ) as Map<String, dynamic>;
    return d['ticket'] as String;
  }

  Future<RemoteSessionInfo> end(String id) async => RemoteSessionInfo.fromJson(
    await _call('POST', '/gw/v1/sessions/${Uri.encodeComponent(id)}/end')
        as Map<String, dynamic>,
  );

  // ---- AER Connect Anywhere (ADR-018) ----

  /// Registers this installation with the owner's enrollment code. The
  /// answer carries both device credentials once; keep them in the OS store.
  Future<DeviceEnrollment> enroll({
    required String code,
    required String deviceName,
    required String boxPub,
    required String instance,
  }) async {
    final d = await _call(
      'POST',
      '/gw/v1/devices/enroll',
      body: {
        'code': code.trim(),
        'deviceName': deviceName,
        'boxPub': boxPub,
        'instance': instance,
      },
    ) as Map<String, dynamic>;
    final e = DeviceEnrollment.fromJson(d);
    credential = e.clientCredential;
    return e;
  }

  Future<RegistrationReply> registerInstallation({
    required String deviceName,
    required String boxPub,
    required String instance,
    String proof = '',
  }) async => RegistrationReply.fromJson(
    await _call(
      'POST',
      '/gw/v1/devices/registration',
      body: {
        'deviceName': deviceName,
        'boxPub': boxPub,
        'instance': instance,
        if (proof.isNotEmpty) 'proof': proof,
      },
    ) as Map<String, dynamic>,
  );

  /// This device as the server knows it (number, online, revoked …).
  Future<DeviceInfo> me() async => DeviceInfo.fromJson(
    await _call('GET', '/gw/v1/devices/me') as Map<String, dynamic>,
  );

  /// Opens one password attempt to the device [number].
  Future<ConnectChallenge> challenge(String number) async =>
      ConnectChallenge.fromJson(
        await _call(
          'POST',
          '/gw/v1/connect/challenge',
          body: {'number': normalizeDeviceNumber(number)},
        ) as Map<String, dynamic>,
      );

  /// Redeems an attempt with the sealed password; answers after the
  /// remote computer checked it (then the usual session follows).
  Future<RemoteSessionInfo> connectDevice(
    SealedPassword sealed, {
    bool? clipboard,
    bool? files,
  }) async => RemoteSessionInfo.fromJson(
    await _call(
      'POST',
      '/gw/v1/connect',
      body: {
        'attemptId': sealed.attemptId,
        'ephPub': sealed.ephPub,
        'ciphertext': sealed.ciphertext,
        'identityProof': ?sealed.identityProof,
        'clipboard': ?clipboard,
        'files': ?files,
      },
    ) as Map<String, dynamic>,
  );

  Future<DeviceTrust> trust() async => DeviceTrust.fromJson(
    await _call('GET', '/gw/v1/devices/me/trust') as Map<String, dynamic>,
  );
  Future<DeviceTrust> setUnattended(bool enabled) async => DeviceTrust.fromJson(
    await _call('PUT', '/gw/v1/devices/me/trust', body: {'enabled': enabled})
        as Map<String, dynamic>,
  );
  Future<TrustedDevice> trustCandidate(String number) async =>
      TrustedDevice.fromJson(
        await _call(
          'POST',
          '/gw/v1/devices/me/trust/candidate',
          body: {'number': normalizeDeviceNumber(number)},
        ) as Map<String, dynamic>,
      );
  Future<DeviceTrust> grantTrust(TrustedDevice device) async =>
      DeviceTrust.fromJson(
        await _call(
          'POST',
          '/gw/v1/devices/me/trust/grant',
          body: {'number': device.number, 'fingerprint': device.fingerprint},
        ) as Map<String, dynamic>,
      );
  Future<DeviceTrust> revokeTrust(String number) async => DeviceTrust.fromJson(
    await _call(
      'POST',
      '/gw/v1/devices/me/trust/revoke',
      body: {'number': number},
    ) as Map<String, dynamic>,
  );

  void close() => _http.close(force: true);
}
