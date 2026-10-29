import 'dart:async';

import 'errors.dart';
import 'gateway_client.dart';
import 'models.dart';
import 'tunnel.dart';

/// What the UI shows about a connection.
class ConnectionUpdate {
  const ConnectionUpdate(this.state, this.message, {this.session, this.error});
  final RemoteState state;
  final String message;
  final RemoteSessionInfo? session;
  final Object? error;
}

/// One relay session from request to end: create → wait for the host →
/// one-time grant → local ports for the viewer (rdp) and the file channel
/// → follow the state until it ends. Fresh tickets for every further leg
/// (reconnects) are fetched on demand. Shared by AER HOME and AER Connect.
class RemoteConnection {
  RemoteConnection(
    this.api, {
    this.poll = const Duration(seconds: 2),
    this.readyTimeout = const Duration(minutes: 3),
  });

  final GatewayClient api;
  final Duration poll;

  /// Waiting for approval on the host can take a while; Core fails the
  /// session itself, this is only the client's upper bound.
  final Duration readyTimeout;

  final _updates = StreamController<ConnectionUpdate>.broadcast();
  Stream<ConnectionUpdate> get updates => _updates.stream;

  RemoteSessionInfo? session;
  RelayGrant? grant;
  LocalForwarder? rdp;
  LocalForwarder? files;
  Timer? _timer;
  var _ended = false;
  var _following = false;

  Future<void> _checkRunning() async {
    if (!_ended) return;
    // end() may arrive while create/grant/port creation is in flight.
    await rdp?.close();
    await files?.close();
    await _endQuietly();
    grant = null;
    throw StateError('Remote session was cancelled');
  }

  void _emit(RemoteState s, String msg, {Object? error}) {
    if (!_updates.isClosed) {
      _updates.add(ConnectionUpdate(s, msg, session: session, error: error));
    }
  }

  /// Ticket for the next leg of [channel]: the grant's first, then fresh.
  Future<String> Function() _tickets(String channel) {
    var first = grant!.tickets[channel];
    return () async {
      final t = first;
      if (t != null) {
        first = null;
        return t;
      }
      return api.ticket(session!.id, channel);
    };
  }

  /// Starts a session to [entityId] and returns once the local RDP port is
  /// ready (or throws). Viewers connect to `127.0.0.1:rdp.port`.
  Future<void> start(String entityId, {int? minutes}) =>
      startWith(() => api.create(entityId, minutes: minutes));

  /// Like [start] for a session created another way (AER Connect by ID and
  /// password: `connectDevice` answers with the session).
  Future<void> startWith(Future<RemoteSessionInfo> Function() create) async {
    await _checkRunning();
    final cred = api.credential;
    if (cred == null) {
      throw const RemoteEngineException(
        401,
        'UNAUTHORIZED',
        'Клиент не сопряжён с сервером',
      );
    }
    session = await create();
    await _checkRunning();
    _emit(session!.state, 'Запрос отправлен');
    final deadline = DateTime.now().add(readyTimeout);
    while (session!.state != RemoteState.connecting) {
      if (session!.state.terminal) {
        _emit(session!.state, session!.reason);
        throw RemoteEngineException(
          409,
          'CONFLICT',
          session!.reason.isEmpty ? session!.state.label : session!.reason,
        );
      }
      if (DateTime.now().isAfter(deadline)) {
        await _endQuietly();
        throw const RemoteEngineException(
          504,
          'UNAVAILABLE',
          'Компьютер не ответил вовремя',
        );
      }
      await Future<void>.delayed(poll);
      await _checkRunning();
      session = await api.session(session!.id);
      await _checkRunning();
      _emit(session!.state, session!.state.label);
    }
    grant = await api.grant(session!.id);
    await _checkRunning();
    final rdpTicket = _tickets('rdp');
    rdp = await LocalForwarder.start(
      () async => openTunnel(
        api.server,
        cred,
        await rdpTicket(),
        path: grant!.tunnelPath,
      ),
    );
    await _checkRunning();
    if (grant!.files) {
      final filesTicket = _tickets('files');
      files = await LocalForwarder.start(
        () async => openTunnel(
          api.server,
          cred,
          await filesTicket(),
          path: grant!.tunnelPath,
        ),
      );
      await _checkRunning();
    }
    _emit(session!.state, 'Готово к подключению просмотрщика');
    _timer = Timer.periodic(poll, (_) => _follow());
  }

  Future<void> _follow() async {
    if (_ended || _following) return;
    _following = true;
    try {
      final s = await api.session(session!.id);
      if (_ended) return;
      final changed = s.state != session!.state;
      session = s;
      if (changed) _emit(s.state, s.reason.isEmpty ? s.state.label : s.reason);
      if (s.state.terminal) await _stop();
    } on RemoteEngineException catch (e) {
      if (e.unauthorized) {
        _emit(RemoteState.revoked, 'Доступ клиента отозван', error: e);
        await _stop();
      }
    } catch (e) {
      _emit(session!.state, 'Нет связи с сервером, повторяем…', error: e);
    } finally {
      _following = false;
    }
  }

  Future<void> _stop() async {
    if (_ended) return;
    _ended = true;
    _timer?.cancel();
    await rdp?.close();
    await files?.close();
    grant = null;
    if (!_updates.isClosed) await _updates.close();
  }

  Future<void> _endQuietly() async {
    try {
      if (session != null) session = await api.end(session!.id);
    } catch (_) {}
  }

  /// Ends the session (host disables access) and closes local ports.
  Future<void> end() async {
    await _endQuietly();
    _emit(session?.state ?? RemoteState.disconnected, 'Сеанс завершён');
    await _stop();
  }
}
