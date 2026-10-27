import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../core_api/remote_api.dart';
import '../remote/files_client.dart';
import '../remote/rdp_launcher.dart';
import 'connection_controller.dart';

/// Where the local connection attempt is.
enum RemotePhase {
  requesting,
  waitingHost,
  launching,
  running,
  clientClosed,
  ended,
  failed,
}

/// The session this client runs. The grant lives only here, in memory,
/// and is dropped when the session ends.
class ActiveRemote {
  ActiveRemote(this.host);

  final RemoteHost host;
  RemotePhase phase = RemotePhase.requesting;
  RemoteSession? session;
  RemoteGrant? _grant;
  RdpClientHandle? client;
  RemoteFilesClient? files;
  Duration? latency;
  String message = '';

  bool get live => phase != RemotePhase.ended && phase != RemotePhase.failed;
}

/// State of the «Удалённый доступ» section.
class RemoteController extends ChangeNotifier {
  RemoteController(
    this.api,
    this._connection, {
    RdpLauncher? launcher,
    this.sourceName = 'AER HOME Desktop',
    this.interval = const Duration(seconds: 10),
    this.autoPoll = true,
    this.step = const Duration(milliseconds: 500),
    this.probe = probeLatency,
  }) : launcher = launcher ?? defaultLauncher() {
    _connection.addListener(_onConnection);
  }

  final RemoteApi api;
  final ConnectionController _connection;
  final RdpLauncher launcher;
  final String sourceName;
  final Duration interval;
  final bool autoPoll;

  /// Poll step while a session is being set up (tests shorten it).
  final Duration step;
  final Future<Duration?> Function(String host, int port) probe;

  List<RemoteHost> _hosts = const [];
  List<RemoteSession> _history = const [];
  DateTime? _updatedAt;
  bool _stale = false;
  bool _loading = false;
  Object? _error;
  ActiveRemote? _active;
  Timer? _timer;
  Timer? _sessionTimer;
  bool _disposed = false;
  bool _started = false;
  Future<void>? _inFlight;

  List<RemoteHost> get hosts => _hosts;
  List<RemoteSession> get history => _history;
  DateTime? get updatedAt => _updatedAt;
  bool get isStale => _stale;
  bool get loading => _loading;
  Object? get error => _error;
  bool get canAct => _connection.canAct;
  ActiveRemote? get active => _active;

  RemoteHost? hostFor(String entityId) =>
      _hosts.where((h) => h.entityId == entityId).firstOrNull;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> start() async {
    if (_started) return;
    _started = true;
    await refresh();
    if (autoPoll) _schedule();
  }

  void _schedule() {
    _timer?.cancel();
    if (_disposed) return;
    _timer = Timer(interval, () async {
      if (_connection.canAct) await refresh();
      _schedule();
    });
  }

  void _onConnection() {
    if (_connection.canAct) {
      if (_stale && _started) unawaited(refresh());
    } else if (!_stale && _updatedAt != null) {
      _stale = true; // last known data stays visible, marked as old
      _notify();
    }
  }

  Future<void> refresh() =>
      _inFlight ??= _refresh().whenComplete(() => _inFlight = null);

  Future<void> _refresh() async {
    if (!_connection.canAct) {
      if (_updatedAt != null) _stale = true;
      _notify();
      return;
    }
    _loading = true;
    _notify();
    try {
      final r = await Future.wait([api.hosts(), api.sessions(limit: 50)]);
      _hosts = r[0] as List<RemoteHost>;
      _history = r[1] as List<RemoteSession>;
      _updatedAt = DateTime.now();
      _stale = false;
      _error = null;
    } catch (e) {
      _error = e;
      if (_updatedAt != null) _stale = true;
    } finally {
      _loading = false;
      _notify();
    }
  }

  Future<RemoteHost> setPolicy(String entityId, RemotePolicy p) async {
    final h = await api.setPolicy(entityId, p);
    unawaited(refresh());
    return h;
  }

  /// Connects to [host]: request → wait for the host (approval) → one-time
  /// grant → external client. Only one local session at a time.
  Future<void> connect(
    RemoteHost host, {
    bool clipboard = true,
    bool files = true,
  }) async {
    if (_active?.live ?? false) return;
    final a = ActiveRemote(host);
    _active = a;
    _notify();
    try {
      if (!launcher.available) {
        throw StateError(
          '${launcher.clientName} не установлен — удалённый рабочий стол открывается во внешнем клиенте',
        );
      }
      a.session = await api.create(
        host.entityId,
        sourceName: sourceName,
        idempotencyKey: newRemoteKey(),
        clipboard: clipboard,
        files: files,
      );
      a.phase = RemotePhase.waitingHost;
      _notify();
      final deadline = DateTime.now().add(const Duration(minutes: 3));
      while (a.session!.state != RemoteState.connecting) {
        if (a.session!.state.terminal) {
          throw StateError(
            a.session!.reason.isEmpty
                ? a.session!.state.label
                : a.session!.reason,
          );
        }
        if (DateTime.now().isAfter(deadline) || !a.live) {
          throw StateError('Хост не подготовил сеанс вовремя');
        }
        await Future<void>.delayed(step);
        a.session = await api.session(a.session!.id);
        _notify();
      }
      a._grant = await api.grant(a.session!.id);
      final g = a._grant!;
      if (g.filesUrl != null && g.filesToken != null) {
        a.files = RemoteFilesClient(
          baseUrl: g.filesUrl!,
          token: g.filesToken!,
          certSha256: g.certSha256,
        );
      }
      await _launch(a);
      _sessionTimer?.cancel();
      _sessionTimer = Timer.periodic(
        const Duration(seconds: 2),
        (_) => _follow(a),
      );
    } catch (e) {
      a.phase = RemotePhase.failed;
      a.message = e is StateError ? e.message : '$e';
      final s = a.session;
      if (s != null && !s.state.terminal) {
        unawaited(api.end(s.id).then((_) {}, onError: (_) {}));
      }
      _drop(a);
    }
    _notify();
  }

  Future<void> _launch(ActiveRemote a) async {
    a.phase = RemotePhase.launching;
    _notify();
    final c = await launcher.launch(a._grant!);
    a.client = c;
    a.phase = RemotePhase.running;
    a.message = 'Изображение и управление — в окне ${launcher.clientName}';
    _notify();
    unawaited(
      c.exitCode.then((_) {
        if (a.client == c && a.live) {
          a.phase = RemotePhase.clientClosed;
          a.message =
              'Окно ${launcher.clientName} закрыто. Можно переподключиться, пока сеанс не истёк';
          _notify();
        }
      }),
    );
  }

  /// Opens the external client again for the same, still valid session.
  Future<void> reconnect() async {
    final a = _active;
    if (a == null || !a.live || a._grant == null) return;
    a.client?.stop();
    await _launch(a);
  }

  Future<void> _follow(ActiveRemote a) async {
    if (!a.live || a.session == null) {
      _sessionTimer?.cancel();
      return;
    }
    try {
      a.session = await api.session(a.session!.id);
      final g = a._grant;
      if (g != null) a.latency = await probe(g.host, g.port);
      if (a.session!.state.terminal) {
        a.phase = RemotePhase.ended;
        a.message = a.session!.reason;
        a.client?.stop();
        _drop(a);
        unawaited(refresh());
      }
    } catch (_) {
      // Core unreachable: the RDP session itself continues; the host agent
      // still ends it at its expiry.
      a.message = 'Нет связи с Core: сеанс RDP продолжается до истечения срока';
    }
    _notify();
  }

  void _drop(ActiveRemote a) {
    a._grant = null; // the password never outlives the session
    a.files?.close();
    a.files = null;
    _sessionTimer?.cancel();
  }

  /// Ends the local session (and closes the client window).
  Future<void> end() async {
    final a = _active;
    if (a == null) return;
    a.client?.stop();
    final s = a.session;
    if (s != null && !s.state.terminal) {
      try {
        a.session = await api.end(s.id);
      } catch (_) {}
    }
    a.phase = RemotePhase.ended;
    a.message = 'Сеанс завершён';
    _drop(a);
    _notify();
    unawaited(refresh());
  }

  /// Forgets a finished local session card.
  void dismiss() {
    if (_active?.live ?? false) return;
    _active = null;
    _notify();
  }

  /// Revokes any session (owner action from the history or the host card).
  Future<void> revoke(String sessionId) async {
    await api.revoke(sessionId);
    if (_active?.session?.id == sessionId) {
      _active!.client?.stop();
      _active!.phase = RemotePhase.ended;
      _active!.message = 'Доступ отозван';
      _drop(_active!);
    }
    await refresh();
  }

  /// Where downloads go: ~/Downloads/AER Remote.
  static Directory downloadsDir() {
    final home =
        Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        Directory.systemTemp.path;
    return Directory(
      '$home${Platform.pathSeparator}Downloads${Platform.pathSeparator}AER Remote',
    );
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _sessionTimer?.cancel();
    _active?.files?.close();
    _connection.removeListener(_onConnection);
    super.dispose();
  }
}
