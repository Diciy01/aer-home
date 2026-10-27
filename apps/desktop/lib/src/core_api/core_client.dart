import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'models.dart';

/// Returns the bearer token, or null when none is available.
typedef TokenProvider = Future<String?> Function();

/// Core could not be reached at all (process down, wrong port, network).
class CoreUnreachable implements Exception {
  const CoreUnreachable(this.reason);
  final String reason;

  @override
  String toString() => 'CoreUnreachable: $reason';
}

/// Core answered with an error envelope, or with something that is not one.
class CoreApiException implements Exception {
  const CoreApiException({
    required this.statusCode,
    required this.code,
    required this.message,
    this.requestId,
    this.details = const {},
  });

  /// Client-side code for a response that does not follow the envelope.
  static const invalidResponse = 'INVALID_RESPONSE';

  /// Client-side code when no token could be read locally.
  static const tokenMissing = 'TOKEN_MISSING';

  final int statusCode;
  final String code;
  final String message;
  final String? requestId;
  final Map<String, dynamic> details;

  bool get isUnauthorized => code == 'UNAUTHORIZED' || code == tokenMissing;
  bool get isConflict => code == 'CONFLICT';
  bool get isValidation => code == 'VALIDATION_FAILED';
  bool get isNotFound => code == 'NOT_FOUND';

  /// For CONFLICT: revision_mismatch | archived | state | duplicate | cycle.
  String? get conflictReason => details['reason'] as String?;

  /// For VALIDATION_FAILED: field name → human-readable message.
  Map<String, String> get fieldErrors {
    final f = details['fields'];
    if (f is! Map) return const {};
    return {for (final e in f.entries) '${e.key}': '${e.value}'};
  }

  @override
  String toString() => 'CoreApiException($statusCode $code: $message)';
}

/// Typed client for the AER Core REST API (`/api/v1`).
class CoreClient {
  CoreClient({
    required http.Client httpClient,
    required Uri baseUri,
    required TokenProvider tokenProvider,
    this.timeout = const Duration(seconds: 5),
  }) : _http = httpClient,
       _base = baseUri,
       _token = tokenProvider;

  final http.Client _http;
  final Uri _base;
  final TokenProvider _token;
  final Duration timeout;

  Uri get baseUri => _base;

  Future<Health> health() async => Health.fromJson(
    await request('GET', '/health', authenticated: false)
        as Map<String, dynamic>,
  );

  Future<SystemInfo> systemInfo() async => SystemInfo.fromJson(
    await request('GET', '/system/info') as Map<String, dynamic>,
  );

  /// Sends a request to `/api/v1[path]` and returns the envelope's `data`.
  Future<Object?> request(
    String method,
    String path, {
    Map<String, Object?>? query,
    Object? body,
    bool authenticated = true,
    Map<String, String> headers = const {},
  }) async {
    final hdrs = <String, String>{'Accept': 'application/json', ...headers};
    if (authenticated) {
      final token = await _token();
      if (token == null || token.isEmpty) {
        throw const CoreApiException(
          statusCode: 0,
          code: CoreApiException.tokenMissing,
          message: 'API token not found',
        );
      }
      hdrs['Authorization'] = 'Bearer $token';
    }
    if (body != null) hdrs['Content-Type'] = 'application/json';

    final params = <String, dynamic>{};
    query?.forEach((k, v) {
      if (v == null) return;
      params[k] = v is Iterable ? [for (final x in v) '$x'] : '$v';
    });
    final uri = _base.replace(
      path: '${_base.path}/api/v1$path',
      queryParameters: params.isEmpty ? null : params,
    );

    final req = http.Request(method, uri)..headers.addAll(hdrs);
    if (body != null) req.bodyBytes = utf8.encode(jsonEncode(body));
    final http.Response res;
    try {
      res = await http.Response.fromStream(
        await _http.send(req).timeout(timeout),
      ).timeout(timeout);
    } on TimeoutException {
      throw CoreUnreachable('no answer within ${timeout.inSeconds}s');
    } on SocketException catch (e) {
      throw CoreUnreachable(e.message);
    } on http.ClientException catch (e) {
      throw CoreUnreachable(e.message);
    }
    return _decode(res);
  }

  Object? _decode(http.Response res) {
    final Object? body;
    try {
      body = jsonDecode(utf8.decode(res.bodyBytes));
    } on FormatException {
      throw CoreApiException(
        statusCode: res.statusCode,
        code: CoreApiException.invalidResponse,
        message: 'response is not JSON',
      );
    }
    if (body is! Map<String, dynamic>) {
      throw CoreApiException(
        statusCode: res.statusCode,
        code: CoreApiException.invalidResponse,
        message: 'response is not an envelope',
      );
    }
    final meta = body['meta'];
    final requestId = meta is Map<String, dynamic>
        ? meta['requestId'] as String?
        : null;

    final error = body['error'];
    if (error is Map<String, dynamic>) {
      final details = error['details'];
      throw CoreApiException(
        statusCode: res.statusCode,
        code: error['code'] as String? ?? CoreApiException.invalidResponse,
        message: error['message'] as String? ?? '',
        requestId: requestId,
        details: details is Map<String, dynamic> ? details : const {},
      );
    }
    if (res.statusCode >= 300 || !body.containsKey('data')) {
      throw CoreApiException(
        statusCode: res.statusCode,
        code: CoreApiException.invalidResponse,
        message: 'unexpected response shape',
        requestId: requestId,
      );
    }
    return body['data'];
  }
}
