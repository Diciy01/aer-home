import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core_api/bots_api.dart';
import '../core_api/monitoring_api.dart';
import 'connection_controller.dart';

/// Filters of the bot list (applied on the client: tens of bots).
class BotFilter {
  const BotFilter({
    this.query = '',
    this.status,
    this.runtime,
    this.category,
    this.archived = false,
  });

  final String query;
  final MonStatus? status;
  final String? runtime;
  final String? category;
  final bool archived;

  BotFilter copyWith({
    String? query,
    MonStatus? Function()? status,
    String? Function()? runtime,
    String? Function()? category,
    bool? archived,
  }) => BotFilter(
    query: query ?? this.query,
    status: status == null ? this.status : status(),
    runtime: runtime == null ? this.runtime : runtime(),
    category: category == null ? this.category : category(),
    archived: archived ?? this.archived,
  );

  bool matches(Bot b) {
    if (status != null && b.status != status) return false;
    if (runtime != null && b.runtime != runtime) return false;
    if (category != null && b.category != category) return false;
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return true;
    final hay = [
      b.name,
      b.description,
      b.category,
      b.runtime,
      b.type,
      ...b.tags,
    ].join(' ').toLowerCase();
    return q.split(RegExp(r'\s+')).every(hay.contains);
  }
}

/// Bots section state: polls the bot list while Core is reachable. Actions
/// always go through a confirmation from Core and an idempotency key.
class BotsController extends ChangeNotifier {
  BotsController(
    this.api,
    this._connection, {
    this.interval = const Duration(seconds: 10),
    this.autoPoll = true,
  }) {
    _connection.addListener(_onConnection);
  }

  final BotsApi api;
  final ConnectionController _connection;
  final Duration interval;
  final bool autoPoll;

  List<Bot> _bots = const [];
  List<BotAdapter> _adapters = const [];
  BotFilter _filter = const BotFilter();
  DateTime? _updatedAt;
  bool _stale = false;
  bool _loading = false;
  Object? _error;
  Timer? _timer;
  bool _disposed = false;
  bool _started = false;
  Future<void>? _inFlight;
  bool _again = false;

  List<Bot> get all => _bots;
  List<Bot> get visible => _bots.where(_filter.matches).toList();
  List<BotAdapter> get adapters => _adapters;
  BotFilter get filter => _filter;
  DateTime? get updatedAt => _updatedAt;

  /// The list is the last known one: Core unreachable or the poll failed.
  bool get isStale => _stale;
  bool get loading => _loading;
  Object? get error => _error;
  bool get canAct => _connection.canAct;

  List<String> get categories => {
    for (final b in _bots)
      if (b.category.isNotEmpty) b.category,
  }.toList()..sort();

  /// The bot bound to a Registry entity, if that entity is a bot.
  Bot? botFor(String entityId) =>
      _bots.where((b) => b.entityId == entityId).firstOrNull;

  BotAdapter? adapter(String id) =>
      _adapters.where((a) => a.id == id).firstOrNull;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  set filter(BotFilter f) {
    final reload = f.archived != _filter.archived;
    _filter = f;
    _notify();
    if (reload) unawaited(refresh());
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
      if ((_stale || _updatedAt == null) && _started) unawaited(refresh());
    } else if (!_stale && _updatedAt != null) {
      _stale = true;
      _notify();
    }
  }

  /// Refreshes the list; a request made during a running refresh (e.g. the
  /// archive filter changed) runs once more afterwards with the new filter.
  Future<void> refresh() {
    if (_inFlight case final running?) {
      _again = true;
      return running;
    }
    return _inFlight = _refresh().whenComplete(() {
      _inFlight = null;
      if (_again) {
        _again = false;
        unawaited(refresh());
      }
    });
  }

  Future<void> _refresh() async {
    if (!_connection.canAct) {
      if (_updatedAt != null) _stale = true;
      _notify();
      return;
    }
    _loading = true;
    _notify();
    try {
      final r = await Future.wait([
        api.list(archived: _filter.archived ? 'true' : 'false'),
        api.adapters(),
      ]);
      _bots = r[0] as List<Bot>;
      _adapters = r[1] as List<BotAdapter>;
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

  Future<(BotDetail, String)> create(BotDraft d) async {
    final r = await api.create(d);
    unawaited(refresh());
    return r;
  }

  Future<BotDetail> update(String id, BotDraft d, int revision) async {
    final r = await api.update(id, d, revision);
    unawaited(refresh());
    return r;
  }

  Future<BotDetail> setArchived(String id, bool archived) async {
    final r = await api.setArchived(id, archived);
    unawaited(refresh());
    return r;
  }

  /// Runs an action that Core already confirmed (token from [api.confirm]).
  Future<BotActionRecord> run(
    String id,
    String action, {
    BotConfirmation? confirmation,
    String? jobId,
    String? idempotencyKey,
  }) async {
    final r = await api.execute(
      id,
      action,
      idempotencyKey: idempotencyKey ?? newIdempotencyKey(),
      confirmationToken: confirmation?.token,
      jobId: jobId,
    );
    unawaited(refresh());
    return r;
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _connection.removeListener(_onConnection);
    super.dispose();
  }
}
