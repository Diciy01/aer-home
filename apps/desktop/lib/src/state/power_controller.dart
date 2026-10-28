import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core_api/power_api.dart';
import 'connection_controller.dart';

/// State of the «Питание» section. Every state-changing action goes
/// confirm (plan + single-use token) → execute (Idempotency-Key) → the job
/// is followed until Core settles it. Nothing is retried automatically.
class PowerController extends ChangeNotifier {
  PowerController(
    this.api,
    this._connection, {
    this.interval = const Duration(seconds: 10),
    this.autoPoll = true,
    this.step = const Duration(seconds: 1),
    this.follow = const Duration(minutes: 10),
  }) {
    _connection.addListener(_onConnection);
  }

  final PowerApi api;
  final ConnectionController _connection;
  final Duration interval;
  final bool autoPoll;

  /// Poll step while a job is running (tests shorten it).
  final Duration step;

  /// How long a job is followed from this window.
  final Duration follow;

  List<PowerDevice> _devices = const [];
  List<PowerJob> _history = const [];
  final Map<String, PowerJob> _followed = {}; // entityId → latest known job
  DateTime? _updatedAt;
  bool _stale = false;
  bool _loading = false;
  Object? _error;
  Timer? _timer;
  bool _disposed = false;
  bool _started = false;
  Future<void>? _inFlight;

  List<PowerDevice> get devices => _devices;
  List<PowerJob> get history => _history;
  DateTime? get updatedAt => _updatedAt;
  bool get isStale => _stale;
  bool get loading => _loading;
  Object? get error => _error;
  bool get canAct => _connection.canAct && !_stale;

  PowerDevice? deviceFor(String entityId) =>
      _devices.where((d) => d.entityId == entityId).firstOrNull;

  /// The job this window started or follows for a device (also finished
  /// ones, until the next refresh shows them as the device's last job).
  PowerJob? followed(String entityId) => _followed[entityId];

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
      final r = await Future.wait([api.devices(), api.jobs(limit: 100)]);
      _devices = r[0] as List<PowerDevice>;
      _history = r[1] as List<PowerJob>;
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

  /// Asks Core for the plan of a state-changing action.
  Future<PowerConfirmation> prepare(
    String entityId,
    PowerAction action, {
    String targetOs = '',
  }) => api.confirm(entityId, action, targetOs: targetOs);

  /// Starts an action the owner confirmed and follows its job.
  Future<PowerJob> run(
    String entityId,
    PowerAction action, {
    PowerConfirmation? confirmation,
    String targetOs = '',
  }) async {
    final j = await api.execute(
      entityId,
      action,
      idempotencyKey: newPowerKey(),
      confirmationToken: confirmation?.token ?? '',
      targetOs: targetOs,
    );
    _followed[entityId] = j;
    _notify();
    if (!j.state.terminal) unawaited(_follow(j));
    unawaited(refresh());
    return j;
  }

  /// Read-only refresh of a device (no confirmation needed).
  Future<PowerJob> check(String entityId) => run(entityId, PowerAction.check);

  Future<void> _follow(PowerJob j) async {
    final until = DateTime.now().add(follow);
    var cur = j;
    while (!_disposed &&
        !cur.state.terminal &&
        DateTime.now().isBefore(until)) {
      await Future<void>.delayed(step);
      if (!_connection.canAct) continue; // Core away: keep the last state
      try {
        final next = await api.job(cur.id);
        if (next.state != cur.state || next.message != cur.message) {
          cur = next;
          _followed[cur.entityId] = cur;
          _notify();
          unawaited(refresh());
        }
      } catch (_) {
        // A failed poll is not a result; try again on the next step.
      }
    }
  }

  Future<PowerJob> cancel(PowerJob j) async {
    final c = await api.cancel(j.id);
    _followed[c.entityId] = c;
    _notify();
    unawaited(refresh());
    return c;
  }

  Future<PowerDevice> setPolicy(String entityId, PowerPolicy p) async {
    final d = await api.setPolicy(entityId, p);
    unawaited(refresh());
    return d;
  }

  Future<PowerDevice> setWoL(String entityId, WoLTarget t) async {
    final d = await api.setWoL(entityId, t);
    unawaited(refresh());
    return d;
  }

  Future<PowerDevice> deleteWoL(String entityId) async {
    final d = await api.deleteWoL(entityId);
    unawaited(refresh());
    return d;
  }

  Future<PowerNet> interfaces() => api.interfaces();

  Future<PowerJob> job(String id) => api.job(id);

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _connection.removeListener(_onConnection);
    super.dispose();
  }
}
