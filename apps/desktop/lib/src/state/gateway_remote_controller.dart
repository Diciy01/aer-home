import 'dart:async';
import 'dart:io';

import 'package:aer_remote/aer_remote.dart' as engine;
import 'package:flutter/foundation.dart';

import '../core_api/remote_api.dart' show RemoteGrant;
import '../remote/files_client.dart';
import '../remote/gateway_profile.dart';
import '../remote/rdp_launcher.dart';
import 'remote_controller.dart' show EmbeddedFactory;

/// Where the «Через Gateway» flow is.
enum GatewayPhase { notPaired, ready, unauthorized }

/// A session to a home computer through the owner's Remote Gateway.
class GatewayActive {
  GatewayActive(this.host);
  final engine.RemoteHostSummary host;
  engine.RemoteConnection? conn;
  engine.InteractiveRemoteViewer? viewer;
  RdpClientHandle? external;
  RemoteFilesClient? files;
  engine.RemoteState state = engine.RemoteState.pending;
  String message = 'Запрашиваем сеанс…';
  bool live = true;
}

/// AER HOME as a remote access client outside the home (M14.5, ADR-017):
/// add the owner's server, confirm and pin its certificate, pair with a
/// one-time code, list the allowed computers, open them in the built-in
/// viewer. Everything protocol-related is the shared engine
/// (`package:aer_remote`); this class is state for the UI.
class GatewayRemoteController extends ChangeNotifier {
  GatewayRemoteController({
    required this.profiles,
    required this.credentials,
    this.embedded,
    RdpLauncher? launcher,
    this.deviceName = 'AER HOME',
    this.poll = const Duration(seconds: 2),
    @visibleForTesting
    engine.GatewayClient Function(engine.GatewayServer)? client,
    @visibleForTesting Future<String> Function(Uri)? probe,
  }) : launcher = launcher ?? defaultLauncher(),
       _newClient = client ?? ((s) => engine.GatewayClient(s)),
       _probe = probe ?? engine.probeFingerprint;

  final GatewayProfileStore profiles;
  final CredentialStore credentials;
  final EmbeddedFactory? embedded;
  final RdpLauncher launcher;
  final String deviceName;
  final Duration poll;
  final engine.GatewayClient Function(engine.GatewayServer) _newClient;
  final Future<String> Function(Uri) _probe;

  GatewayProfile? _profile;
  engine.GatewayClient? _api;
  GatewayPhase _phase = GatewayPhase.notPaired;
  List<engine.RemoteHostSummary> _hosts = const [];
  String? _error;
  bool _loading = false;
  bool _loaded = false;
  GatewayActive? _active;
  bool _disposed = false;

  GatewayProfile? get profile => _profile;
  GatewayPhase get phase => _phase;
  List<engine.RemoteHostSummary> get hosts => _hosts;
  String? get error => _error;
  bool get loading => _loading;
  GatewayActive? get active => _active;
  String get storeDescription => credentials.description;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  /// Reads the saved profile and credential (no network).
  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    final p = await profiles.read();
    final cred = await credentials.read();
    if (p != null && cred != null && cred.isNotEmpty) {
      _profile = p;
      _api = _newClient(engine.GatewayServer.parse(p.address, p.fingerprint))
        ..credential = cred;
      _phase = GatewayPhase.ready;
    }
    _notify();
  }

  /// Step 1 of adding a server: the certificate fingerprint it presents.
  /// Nothing but a TLS handshake is sent; nothing is trusted yet.
  Future<String> probe(String address) async {
    final s = engine.GatewayServer.parse(address, '');
    return _probe(s.base);
  }

  /// Step 2, after the user confirmed [fingerprint]: pair with the one-time
  /// code. The credential goes to the secret store, never to logs.
  Future<void> pair(String address, String fingerprint, String code) async {
    _error = null;
    final server = engine.GatewayServer.parse(address, fingerprint);
    final api = _newClient(server);
    try {
      final r = await api.pair(code.trim(), deviceName: deviceName);
      await credentials.write(r.credential);
      final p = GatewayProfile(
        address: address.trim(),
        fingerprint: fingerprint,
        clientId: r.clientId,
        clientName: r.name,
        pairedAt: DateTime.now(),
      );
      await profiles.write(p);
      _api?.close();
      _api = api;
      _profile = p;
      _phase = GatewayPhase.ready;
      _notify();
      await refreshHosts();
    } catch (e) {
      api.close();
      _error = describe(e);
      _notify();
      rethrow;
    }
  }

  /// Forgets the server and the credential on this computer (the owner
  /// should also revoke the client in Core).
  Future<void> forget() async {
    await end();
    await credentials.delete();
    await profiles.delete();
    _api?.close();
    _api = null;
    _profile = null;
    _hosts = const [];
    _phase = GatewayPhase.notPaired;
    _error = null;
    _active = null;
    _notify();
  }

  Future<void> refreshHosts() async {
    final api = _api;
    if (api == null) return;
    _loading = true;
    _notify();
    try {
      _hosts = await api.hosts();
      _error = null;
      _phase = GatewayPhase.ready;
    } catch (e) {
      _error = describe(e);
      if (e is engine.RemoteEngineException && e.unauthorized) {
        _phase = GatewayPhase.unauthorized;
        _hosts = const [];
      }
    } finally {
      _loading = false;
      _notify();
    }
  }

  /// Opens a relay session to [host] and shows it (built-in viewer, or the
  /// external client when the native library is missing).
  Future<void> connect(engine.RemoteHostSummary host) async {
    final api = _api;
    if (api == null || (_active?.live ?? false)) return;
    final a = GatewayActive(host);
    _active = a;
    _error = null;
    _notify();
    final conn = engine.RemoteConnection(api, poll: poll);
    a.conn = conn;
    conn.updates.listen((u) => _onUpdate(a, u));
    try {
      await conn.start(host.entityId);
      final g = conn.grant!;
      if (g.files && conn.files != null) {
        a.files = RemoteFilesClient(
          baseUrl: 'https://127.0.0.1:${conn.files!.port}',
          token: g.filesToken!,
          certSha256: g.certSha256,
        );
      }
      await _show(a);
    } catch (e) {
      a.live = false;
      a.state = engine.RemoteState.failed;
      a.message = describe(e);
      _closeView(a);
      if (e is engine.RemoteEngineException && e.unauthorized) {
        _phase = GatewayPhase.unauthorized;
      }
      final s = conn.session;
      if (s != null && !s.state.terminal) {
        unawaited(api.end(s.id).then((_) {}, onError: (_) {}));
      }
    }
    _notify();
  }

  Future<void> _show(GatewayActive a) async {
    final conn = a.conn!, g = conn.grant!;
    final target = engine.ViewerTarget(
      host: '127.0.0.1',
      port: conn.rdp!.port,
      username: g.username,
      password: g.password,
      certPem: g.certPem,
      certSha256: g.certSha256,
      clipboard: g.clipboard,
    );
    final v = embedded?.call(() async {
      try {
        return !(await _api!.session(conn.session!.id)).state.terminal;
      } catch (_) {
        return false; // revoked credential or Gateway gone: stop
      }
    });
    if (v != null) {
      await v.open(target);
      a.viewer = v;
      a.message = 'Рабочий стол — во встроенном просмотре, через Gateway';
      return;
    }
    if (!launcher.available) {
      throw StateError(
        'Нет ни встроенного просмотра, ни ${launcher.clientName}',
      );
    }
    a.external = await launcher.launch(
      RemoteGrant(
        sessionId: conn.session!.id,
        host: '127.0.0.1',
        port: conn.rdp!.port,
        username: g.username,
        password: g.password,
        certPem: g.certPem,
        certSha256: g.certSha256,
        clipboard: g.clipboard,
        expiresAt: g.expiresAt,
      ),
    );
    a.message = 'Рабочий стол — в окне ${launcher.clientName}, через Gateway';
  }

  void _onUpdate(GatewayActive a, engine.ConnectionUpdate u) {
    a.state = u.state;
    if (u.state.terminal) {
      a.live = false;
      a.message = switch (u.state) {
        engine.RemoteState.revoked => 'Доступ отозван владельцем',
        engine.RemoteState.expired => 'Срок сеанса истёк',
        _ => u.message.isEmpty ? u.state.label : u.message,
      };
      _closeView(a);
      if (u.error case engine.RemoteEngineException(unauthorized: true)) {
        _phase = GatewayPhase.unauthorized;
        _error = describe(u.error!);
      }
      unawaited(refreshHosts());
    }
    _notify();
  }

  void _closeView(GatewayActive a) {
    final v = a.viewer;
    a.viewer = null;
    if (v != null) unawaited(v.close());
    a.external?.stop();
    a.external = null;
    a.files?.close();
    a.files = null;
  }

  /// Reopens the picture for the same, still valid session.
  Future<void> reconnect() async {
    final a = _active;
    if (a == null || !a.live || a.conn?.grant == null) return;
    _closeView(a);
    await _show(a);
    _notify();
  }

  /// Ends the session: the host closes RDP, local ports close.
  Future<void> end() async {
    final a = _active;
    if (a == null) return;
    _closeView(a);
    if (a.live) {
      a.live = false;
      try {
        await a.conn?.end();
      } catch (_) {}
      a.state = engine.RemoteState.disconnected;
      a.message = 'Сеанс завершён';
    }
    _notify();
    unawaited(refreshHosts());
  }

  void dismiss() {
    if (_active?.live ?? false) return;
    _active = null;
    _notify();
  }

  /// A clear message for the UI (never containing secrets).
  static String describe(Object e) => switch (e) {
    engine.PinMismatchException() =>
      'Сертификат сервера не совпадает с закреплённым — подключение запрещено. '
          'Если сервер действительно сменил сертификат, удалите сервер и добавьте заново, сверив отпечаток',
    engine.RemoteEngineException(status: 401) => 'Учётные данные клиента не приняты: доступ отозван или код неверен. Нужно новое сопряжение',
    engine.RemoteEngineException(status: 429) => 'Слишком много попыток — сервер временно ограничил доступ. Повторите позже',
    engine.RemoteEngineException(:final message) when message.isNotEmpty =>
      message,
    engine.RemoteEngineException(:final status) =>
      'Ошибка сервера (HTTP $status)',
    SocketException() ||
    TimeoutException() ||
    HandshakeException() => 'Сервер недоступен по этому адресу',
    FormatException(:final message) => message,
    StateError(:final message) => message,
    _ => 'Не удалось выполнить действие',
  };

  @override
  void dispose() {
    _disposed = true;
    if (_active != null) _closeView(_active!);
    _api?.close();
    super.dispose();
  }
}
