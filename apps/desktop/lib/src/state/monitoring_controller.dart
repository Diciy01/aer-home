import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../core_api/monitoring_api.dart';
import '../scene/binding/scene_binding.dart';
import '../scene/model/scene_document.dart';
import 'connection_controller.dart';

/// How fresh the monitoring data on screen is.
enum MonFreshness {
  /// Nothing known yet.
  none,

  /// Answered by Core in the last poll.
  live,

  /// Last known data (Core unreachable or the last poll failed).
  stale,
}

/// Last known monitoring snapshot, kept on disk for offline viewing.
class MonitoringSnapshot {
  const MonitoringSnapshot(this.overview, this.states, this.savedAt);
  final MonOverview overview;
  final List<DeviceState> states;
  final DateTime savedAt;
}

/// Local, non-canonical snapshot `<data>/monitoring-cache.json` (atomic).
class MonitoringCache {
  MonitoringCache(this.file);

  /// Next to the scene cache.
  factory MonitoringCache.beside(File sceneCache) => MonitoringCache(
    File(
      '${sceneCache.parent.path}${Platform.pathSeparator}monitoring-cache.json',
    ),
  );

  final File file;

  Future<MonitoringSnapshot?> read() async {
    try {
      if (!await file.exists()) return null;
      final m = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      if (m['cacheVersion'] != 1) return null;
      return MonitoringSnapshot(
        MonOverview.fromJson(m['overview'] as Map<String, dynamic>),
        [
          for (final s in m['states'] as List)
            DeviceState.fromJson(s as Map<String, dynamic>),
        ],
        DateTime.parse(m['savedAt'] as String),
      );
    } catch (_) {
      return null; // a broken cache is only a missed convenience
    }
  }

  Future<void> write(MonitoringSnapshot s) async {
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(
      jsonEncode({
        'cacheVersion': 1,
        'savedAt': s.savedAt.toUtc().toIso8601String(),
        'overview': s.overview.toJson(),
        'states': [for (final d in s.states) d.toJson()],
      }),
      flush: true,
    );
    await tmp.rename(file.path);
  }
}

/// In-memory cache for widget tests (no real file I/O in fake async).
class MemoryMonitoringCache extends MonitoringCache {
  MemoryMonitoringCache() : super(File('/nonexistent/monitoring-cache.json'));
  MonitoringSnapshot? data;

  @override
  Future<MonitoringSnapshot?> read() async => data;

  @override
  Future<void> write(MonitoringSnapshot s) async => data = s;
}

/// Polls Monitoring while Core is reachable and keeps the last known state.
/// Collection itself runs in Core; this only displays it.
class MonitoringController extends ChangeNotifier {
  MonitoringController(
    this.api,
    this._connection, {
    this._cache,
    this.interval = const Duration(seconds: 10),
    this.autoPoll = true,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now {
    _connection.addListener(_onConnection);
  }

  final MonitoringApi api;
  final ConnectionController _connection;
  final MonitoringCache? _cache;
  final Duration interval;

  /// Periodic polling (widget tests switch it off).
  final bool autoPoll;
  final DateTime Function() _now;

  MonOverview? _overview;
  Map<String, DeviceState> _states = {};
  DateTime? _updatedAt;
  MonFreshness _freshness = MonFreshness.none;
  Object? _error;
  bool _loading = false;
  Timer? _timer;
  bool _disposed = false;
  bool _started = false;
  Future<void>? _inFlight;
  List<MonNotification> _notifications = const [];

  MonOverview? get overview => _overview;
  List<DeviceState> get states => _states.values.toList();
  DeviceState? stateFor(String entityId) => _states[entityId];
  DateTime? get updatedAt => _updatedAt;
  MonFreshness get freshness => _freshness;
  bool get isStale => _freshness == MonFreshness.stale;
  Object? get error => _error;
  bool get loading => _loading;

  /// Actions (acknowledge, agents) need a live Core.
  bool get canAct => _connection.canAct;
  List<MonNotification> get notifications => _notifications;
  int get unread => _overview?.unread ?? 0;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  /// Loads the cached snapshot, then polls.
  Future<void> start() async {
    if (_started) return;
    _started = true;
    final cached = await _cache?.read();
    if (cached != null && _overview == null) {
      _overview = cached.overview;
      _states = {for (final s in cached.states) s.entityId: s};
      _updatedAt = cached.savedAt;
      _freshness = MonFreshness.stale;
      _notify();
    }
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
      if (_freshness != MonFreshness.live && _started) unawaited(refresh());
    } else if (_freshness == MonFreshness.live) {
      _freshness = MonFreshness.stale;
      _notify();
    }
  }

  Future<void> refresh() =>
      _inFlight ??= _refresh().whenComplete(() => _inFlight = null);

  Future<void> _refresh() async {
    if (!_connection.canAct) {
      if (_freshness == MonFreshness.live) _freshness = MonFreshness.stale;
      _notify();
      return;
    }
    _loading = true;
    _notify();
    try {
      final results = await Future.wait([api.overview(), api.states()]);
      _overview = results[0] as MonOverview;
      final list = results[1] as List<DeviceState>;
      _states = {for (final s in list) s.entityId: s};
      _updatedAt = _now();
      _freshness = MonFreshness.live;
      _error = null;
      unawaited(
        _cache
            ?.write(MonitoringSnapshot(_overview!, list, _updatedAt!))
            .catchError((_) {}),
      );
    } catch (e) {
      _error = e;
      if (_overview != null) _freshness = MonFreshness.stale;
    } finally {
      _loading = false;
      _notify();
    }
  }

  Future<Incident> acknowledge(String id, {String note = ''}) async {
    final r = await api.acknowledge(id, note: note);
    unawaited(refresh());
    return r;
  }

  Future<void> loadNotifications() async {
    final (items, _) = await api.notifications();
    _notifications = items;
    _notify();
  }

  Future<void> markAllRead() async {
    await api.markRead();
    await loadNotifications();
    await refresh();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _connection.removeListener(_onConnection);
    super.dispose();
  }
}

/// Maps a Monitoring state onto the scene's small status model.
LiveStatus? liveStatusOf(MonitoringController mon, String entityId) {
  final st = mon.stateFor(entityId);
  if (st == null) return null;
  final status = switch (st.status) {
    MonStatus.online => SceneStatus.online,
    MonStatus.degraded =>
      st.worstSeverity == MonSeverity.critical
          ? SceneStatus.critical
          : SceneStatus.warning,
    MonStatus.offline => SceneStatus.offline,
    _ => SceneStatus.unknown,
  };
  return LiveStatus(
    status: status,
    note: st.reason.isEmpty ? 'Состояние из мониторинга' : st.reason,
    stale: mon.isStale,
    lastContactAt: st.lastContactAt,
    openIncidents: st.openIncidents,
  );
}
