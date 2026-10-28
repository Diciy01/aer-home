import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core_api/core_client.dart';
import '../core_api/network_api.dart';
import 'connection_controller.dart';

/// State of the «Сеть и ТВ» section: the last overview from Core, kept and
/// marked as old when Core is away.
class NetworkController extends ChangeNotifier {
  NetworkController(
    this.api,
    this._connection, {
    this.interval = const Duration(seconds: 15),
    this.autoPoll = true,
  }) {
    _connection.addListener(_onConnection);
  }

  final NetworkApi api;
  final ConnectionController _connection;
  final Duration interval;
  final bool autoPoll;

  NetworkOverview? _overview;
  DateTime? _updatedAt;
  bool _stale = false;
  bool _loading = false;
  bool _checking = false;
  Object? _error;
  Timer? _timer;
  bool _disposed = false;
  bool _started = false;
  Future<void>? _inFlight;

  NetworkOverview? get overview => _overview;
  DateTime? get updatedAt => _updatedAt;
  bool get isStale => _stale;
  bool get loading => _loading;
  bool get checking => _checking;
  Object? get error => _error;
  bool get canAct => _connection.canAct && !_stale;

  /// Every device known to the network view, by Registry id.
  NetDevice? deviceFor(String entityId) =>
      _overview?.allDevices.where((d) => d.entityId == entityId).firstOrNull;

  /// Sunshine servers linked to an object (its own or its TV).
  List<NetSunshine> sunshineFor(String entityId) => [
    for (final s in _overview?.sunshine ?? const <NetSunshine>[])
      if (s.entity?.entityId == entityId || s.tv?.entityId == entityId) s,
  ];

  NetRouter? routerFor(String entityId) => _overview?.routers
      .where((r) => r.device.entityId == entityId)
      .firstOrNull;

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
      _stale = true;
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
      _set(await api.overview());
    } catch (e) {
      _error = e;
      if (_updatedAt != null) _stale = true;
    } finally {
      _loading = false;
      _notify();
    }
  }

  void _set(NetworkOverview o) {
    _overview = o;
    _updatedAt = DateTime.now();
    _stale = false;
    _error = null;
  }

  /// Runs all checks now. Returns a message when Core refused (too soon).
  Future<String?> checkNow() async {
    if (!canAct || _checking) return null;
    _checking = true;
    _notify();
    try {
      _set(await api.checkNow());
      return null;
    } on CoreApiException catch (e) {
      if (e.isConflict) return e.message;
      _error = e;
      return e.message;
    } catch (e) {
      _error = e;
      return '$e';
    } finally {
      _checking = false;
      _notify();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _connection.removeListener(_onConnection);
    super.dispose();
  }
}
