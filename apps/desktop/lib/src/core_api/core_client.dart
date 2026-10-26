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
  });

  /// Client-side code for a response that does not follow the envelope.
  static const invalidResponse = 'INVALID_RESPONSE';

  /// Client-side code when no token could be read locally.
  static const tokenMissing = 'TOKEN_MISSING';

  final int statusCode;
  final String code;
  final String message;
  final String? requestId;

  bool get isUnauthorized => code == 'UNAUTHORIZED' || code == tokenMissing;

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

  Future<Health> health() async =>
      Health.fromJson(await _get('/health', authenticated: false));

  Future<SystemInfo> systemInfo() async =>
      SystemInfo.fromJson(await _get('/system/info'));

  Future<Map<String, dynamic>> _get(
    String path, {
    bool authenticated = true,
  }) async {
    final headers = <String, String>{'Accept': 'application/json'};
    if (authenticated) {
      final token = await _token();
      if (token == null || token.isEmpty) {
        throw const CoreApiException(
          statusCode: 0,
          code: CoreApiException.tokenMissing,
          message: 'API token not found',
        );
      }
      headers['Authorization'] = 'Bearer $token';
    }

    final uri = _base.replace(path: '${_base.path}/api/v1$path');
    final http.Response res;
    try {
      res = await _http.get(uri, headers: headers).timeout(timeout);
    } on TimeoutException {
      throw CoreUnreachable('no answer within ${timeout.inSeconds}s');
    } on SocketException catch (e) {
      throw CoreUnreachable(e.message);
    } on http.ClientException catch (e) {
      throw CoreUnreachable(e.message);
    }
    return _decode(res);
  }

  Map<String, dynamic> _decode(http.Response res) {
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
      throw CoreApiException(
        statusCode: res.statusCode,
        code: error['code'] as String? ?? CoreApiException.invalidResponse,
        message: error['message'] as String? ?? '',
        requestId: requestId,
      );
    }
    final data = body['data'];
    if (res.statusCode >= 300 || data is! Map<String, dynamic>) {
      throw CoreApiException(
        statusCode: res.statusCode,
        code: CoreApiException.invalidResponse,
        message: 'unexpected response shape',
        requestId: requestId,
      );
    }
    return data;
  }
}
