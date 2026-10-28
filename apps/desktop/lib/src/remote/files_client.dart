import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aer_remote/aer_remote.dart' show pinnedHttpClient;
import 'package:crypto/crypto.dart';

/// One file in the host's exchange folder.
class RemoteFile {
  const RemoteFile(this.name, this.size, this.modified);
  final String name;
  final int size;
  final DateTime modified;
}

/// Cancels a running transfer.
class TransferCancel {
  HttpClientRequest? _req;
  HttpClientResponse? _res;
  bool cancelled = false;

  void cancel() {
    cancelled = true;
    _req?.abort();
    _res?.detachSocket().then((s) => s.destroy()).ignore();
  }
}

class TransferError implements Exception {
  const TransferError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// The session file channel: HTTPS straight to the host agent (never via
/// Core), the host certificate pinned by its SHA-256 from Core, a session
/// token, SHA-256 checked on both directions.
class RemoteFilesClient {
  RemoteFilesClient({
    required this.baseUrl,
    required this.token,
    required this.certSha256,
  }) : _http = pinnedHttpClient(certSha256)
         ..connectionTimeout = const Duration(seconds: 5);

  final String baseUrl;
  final String token;
  final String certSha256;
  final HttpClient _http;

  /// `aa:bb:…` SHA-256 of a DER certificate (as Core reports it).
  static String fingerprint(List<int> der) => sha256
      .convert(der)
      .bytes
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join(':');

  void close() => _http.close(force: true);

  Future<HttpClientRequest> _open(String method, String path) async {
    final uri = Uri.parse('$baseUrl$path');
    if (uri.scheme != 'https' || uri.userInfo.isNotEmpty) {
      throw const TransferError(
        'File channel requires HTTPS without user info',
      );
    }
    final req = await _http.openUrl(method, uri);
    // A session token must never follow a redirect to a different endpoint.
    req.followRedirects = false;
    req.headers.set('Authorization', 'Bearer $token');
    return req;
  }

  Future<String> _error(HttpClientResponse res) async {
    try {
      final m = jsonDecode(await utf8.decodeStream(res)) as Map;
      return '${m['error'] ?? 'HTTP ${res.statusCode}'}';
    } catch (_) {
      return 'HTTP ${res.statusCode}';
    }
  }

  Future<List<RemoteFile>> list() async {
    final res = await (await _open('GET', '/v1/files')).close();
    if (res.statusCode != 200) throw TransferError(await _error(res));
    final m = jsonDecode(await utf8.decodeStream(res)) as Map<String, dynamic>;
    return [
      for (final f in m['files'] as List)
        RemoteFile(
          f['name'] as String,
          f['size'] as int,
          DateTime.parse(f['modified'] as String),
        ),
    ];
  }

  /// Uploads [file] as [name]; [progress] gets sent bytes.
  Future<void> upload(
    File file,
    String name, {
    void Function(int sent, int total)? progress,
    TransferCancel? cancel,
  }) async {
    final total = await file.length();
    final digest = await sha256.bind(file.openRead()).first;
    final req = await _open('PUT', '/v1/files/${Uri.encodeComponent(name)}');
    cancel?._req = req;
    req.contentLength = total;
    req.headers.set('X-AER-SHA256', digest.toString());
    var sent = 0;
    try {
      await req.addStream(
        file.openRead().map((chunk) {
          if (cancel?.cancelled ?? false) throw const TransferError('Отменено');
          sent += chunk.length;
          progress?.call(sent, total);
          return chunk;
        }),
      );
      final res = await req.close();
      if (res.statusCode != 201) throw TransferError(await _error(res));
      await res.drain<void>();
    } on TransferError {
      req.abort();
      rethrow;
    } on Object {
      if (cancel?.cancelled ?? false) throw const TransferError('Отменено');
      rethrow;
    }
  }

  /// Downloads [name] into [dir]; the file appears only after the SHA-256
  /// sent by the host matches. Returns the saved file.
  Future<File> download(
    String name,
    Directory dir, {
    void Function(int got, int total)? progress,
    TransferCancel? cancel,
  }) async {
    final req = await _open('GET', '/v1/files/${Uri.encodeComponent(name)}');
    cancel?._req = req;
    final res = await req.close();
    cancel?._res = res;
    if (res.statusCode != 200) throw TransferError(await _error(res));
    final want = res.headers.value('X-AER-SHA256') ?? '';
    await dir.create(recursive: true);
    final tmp = File(
      '${dir.path}/.aer-download-${DateTime.now().microsecondsSinceEpoch}',
    );
    final sink = tmp.openWrite();
    final out = AccumulatorSink<Digest>();
    final hash = sha256.startChunkedConversion(out);
    var got = 0;
    try {
      await for (final chunk in res) {
        if (cancel?.cancelled ?? false) throw const TransferError('Отменено');
        sink.add(chunk);
        hash.add(chunk);
        got += chunk.length;
        progress?.call(got, res.contentLength);
      }
      await sink.close();
      hash.close();
      if (out.events.single.toString() != want) {
        throw const TransferError(
          'Контрольная сумма не совпала — файл отброшен',
        );
      }
      var target = File('${dir.path}/$name');
      for (var i = 1; await target.exists(); i++) {
        target = File('${dir.path}/($i) $name');
      }
      return await tmp.rename(target.path);
    } catch (e) {
      await sink.close().catchError((_) {});
      if (await tmp.exists()) await tmp.delete();
      if (cancel?.cancelled ?? false) throw const TransferError('Отменено');
      rethrow;
    }
  }
}

/// Collects chunked conversion output (minimal, to avoid another package).
class AccumulatorSink<T> implements Sink<T> {
  final events = <T>[];
  @override
  void add(T event) => events.add(event);
  @override
  void close() {}
}
