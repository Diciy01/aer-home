import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aer_remote/aer_remote.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

abstract interface class ConnectStore {
  Future<String?> read();
  Future<void> write(String value);
  Future<void> delete();
}

/// Separate ProductName AER Connect and key; current-user DPAPI on Windows.
class ConnectSecureStore implements ConnectStore {
  static const key = 'aer-connect.remote.profile.v1';
  final _store = const FlutterSecureStorage();
  @override
  Future<String?> read() => _store.read(key: key);
  @override
  Future<void> write(String value) => _store.write(key: key, value: value);
  @override
  Future<void> delete() => _store.delete(key: key);
}

typedef ViewerFactory = InteractiveRemoteViewer Function(
  Future<bool> Function(),
);

class ConnectController extends ChangeNotifier {
  ConnectController({
    required this.store,
    required this.viewerFactory,
    GatewayClient Function(GatewayServer)? client,
    Future<String> Function(Uri)? probe,
    this.poll = const Duration(seconds: 2),
  }) : _client = client ?? GatewayClient.new,
       _probe = probe ?? probeFingerprint;
  final ConnectStore store;
  final ViewerFactory viewerFactory;
  final GatewayClient Function(GatewayServer) _client;
  final Future<String> Function(Uri) _probe;
  final Duration poll;
  GatewayClient? api;
  RemoteConnection? connection;
  InteractiveRemoteViewer? viewer;
  RemoteFilesClient? files;
  List<RemoteHostSummary> hosts = [];
  String address = '', fingerprint = '', clientName = '', hostName = '';
  String? error;
  String message = '';
  bool busy = false, paired = false, unauthorized = false;
  RemoteState state = RemoteState.disconnected;
  bool _disposed = false;
  int _generation = 0;
  StreamSubscription<ConnectionUpdate>? _updates;
  bool get live => connection != null && !state.terminal;
  void changed() {
    if (!_disposed) notifyListeners();
  }

  Future<void> load() async {
    try {
      final raw = await store.read();
      if (raw == null) return;
      final j = jsonDecode(raw) as Map<String, dynamic>;
      final s = GatewayServer.parse(
        j['address'] as String,
        j['fingerprint'] as String,
      );
      final credential = j['credential'] as String;
      if (!credential.startsWith('aerc1.')) {
        throw const FormatException('Invalid client credential');
      }
      api = _client(s)..credential = credential;
      address = s.base.toString();
      fingerprint = j['fingerprint'] as String;
      clientName = j['name'] as String;
      paired = true;
      await refresh();
    } catch (_) {
      error = 'Не удалось прочитать защищённый профиль. Удалите сервер и сопрягите заново.';
    } finally {
      changed();
    }
  }

  Future<String> probe(String address) =>
      _probe(GatewayServer.parse(address, '').base);

  Future<void> pair(String address, String pin, String code) async {
    final server = GatewayServer.parse(address, pin);
    final next = _client(server);
    try {
      final r = await next.pair(
        code.trim(),
        deviceName: 'AER Connect (${Platform.localHostname})',
      );
      await store.write(
        jsonEncode({
          'address': server.base.toString(),
          'fingerprint': pin,
          'name': r.name,
          'credential': r.credential,
        }),
      );
      api?.close();
      api = next;
      this.address = server.base.toString();
      fingerprint = pin;
      clientName = r.name;
      paired = true;
      unauthorized = false;
      await refresh();
    } catch (_) {
      next.close();
      rethrow;
    } finally {
      changed();
    }
  }

  Future<void> refresh() async {
    final current = api;
    if (current == null) return;
    try {
      hosts = await current.hosts();
      error = null;
    } catch (e) {
      error = describe(e);
      if (e is RemoteEngineException && e.unauthorized) {
        unauthorized = true;
        hosts = [];
        await _release();
        state = RemoteState.revoked;
        message = 'Доступ отозван владельцем';
      }
    } finally {
      changed();
    }
  }

  Future<void> connect(RemoteHostSummary host) async {
    if (busy || live || api == null) return;
    busy = true;
    error = null;
    hostName = host.name;
    final generation = ++_generation;
    state = RemoteState.pending;
    message = 'Запрашиваем сеанс…';
    changed();
    final conn = RemoteConnection(api!, poll: poll);
    connection = conn;
    _updates = conn.updates.listen((u) {
      if (generation != _generation) return;
      state = u.state;
      message = u.message;
      if (u.state.terminal) {
        unawaited(_release());
        if (u.state == RemoteState.revoked) unauthorized = true;
      }
      changed();
    });
    try {
      await conn.start(host.entityId);
      if (generation != _generation) {
        await conn.end();
        return;
      }
      _openFiles();
      await _show();
    } catch (e) {
      if (generation == _generation) {
        error = describe(e);
        message = error!;
        state = RemoteState.failed;
        await _release();
        await conn.end();
      }
    } finally {
      if (generation == _generation) busy = false;
      changed();
    }
  }

  void _openFiles() {
    final conn = connection!, grant = conn.grant!;
    if (grant.files && conn.files != null) {
      files = RemoteFilesClient(
        baseUrl: 'https://127.0.0.1:${conn.files!.port}',
        token: grant.filesToken!,
        certSha256: grant.certSha256,
      );
    }
  }

  Future<void> _show() async {
    final conn = connection!, g = conn.grant!, current = api!;
    final v = viewerFactory(() async {
      try {
        return !(await current.session(conn.session!.id)).state.terminal;
      } catch (_) {
        return false;
      }
    });
    viewer = v;
    await v.open(
      ViewerTarget(
        host: '127.0.0.1',
        port: conn.rdp!.port,
        username: g.username,
        password: g.password,
        certPem: g.certPem,
        certSha256: g.certSha256,
        clipboard: g.clipboard,
      ),
    );
  }

  Future<void> _release() async {
    final v = viewer;
    viewer = null;
    files?.close();
    files = null;
    connection?.rdp?.drop();
    changed();
    await v?.close();
  }

  Future<void> reconnect() async {
    if (!live || connection?.grant == null || busy) return;
    busy = true;
    changed();
    try {
      await _release();
      _openFiles();
      await _show();
      error = null;
    } catch (e) {
      error = describe(e);
    } finally {
      busy = false;
      changed();
    }
  }

  Future<void> end() async {
    ++_generation;
    final conn = connection;
    connection = null;
    await _updates?.cancel();
    _updates = null;
    await _release();
    await conn?.end();
    state = RemoteState.disconnected;
    busy = false;
    message = 'Сеанс завершён';
    changed();
  }

  Future<void> forget() async {
    await end();
    await store.delete();
    api?.close();
    api = null;
    hosts = [];
    paired = false;
    unauthorized = false;
    address = '';
    fingerprint = '';
    error = null;
    changed();
  }

  Future<void> shutdown() async {
    await end();
    api?.close();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(shutdown());
    super.dispose();
  }

  static String describe(Object e) => switch (e) {
    PinMismatchException() || HandshakeException() => 'Сертификат не совпадает с закреплённым — подключение запрещено. Сверьте отпечаток в AER HOME.',
    RemoteEngineException(status: 401) => 'Учётные данные не приняты: код неверен или доступ отозван. Нужно новое сопряжение.',
    RemoteEngineException(status: 429) =>
      'Слишком много попыток. Повторите позже.',
    RemoteEngineException(:final message) => message,
    SocketException() ||
    TimeoutException() => 'Сервер недоступен. Проверьте адрес и соединение.',
    FormatException() => 'Проверьте адрес сервера и отпечаток сертификата.',
    StateError(:final message) => message,
    _ => 'Не удалось выполнить действие. Проверьте соединение и повторите.',
  };
}
