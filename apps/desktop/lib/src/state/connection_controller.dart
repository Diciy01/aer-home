import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core_api/core_client.dart';
import '../core_api/models.dart';

/// What the client knows about its link to Core.
enum CoreLink {
  /// First check has not finished yet.
  checking,

  /// Core answered and the token was accepted.
  online,

  /// Core answered but reports a problem (e.g. database not responding).
  degraded,

  /// Core answered but the token is missing or rejected.
  unauthorized,

  /// Core could not be reached.
  offline,

  /// Core answered with something this client does not understand.
  incompatible,
}

/// Polls Core and exposes the latest known state.
///
/// When Core goes away the last [info] is kept and [isStale] becomes true, so
/// the UI can show cached data clearly marked as old instead of nothing.
class ConnectionController extends ChangeNotifier {
  ConnectionController(
    this._client, {
    this.onlineInterval = const Duration(seconds: 10),
    this.maxOfflineInterval = const Duration(seconds: 30),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final CoreClient _client;
  final Duration onlineInterval;
  final Duration maxOfflineInterval;
  final DateTime Function() _now;

  CoreLink _link = CoreLink.checking;
  Health? _health;
  SystemInfo? _info;
  DateTime? _lastCheckedAt;
  DateTime? _lastOnlineAt;
  String? _detail;
  int _failures = 0;
  Timer? _timer;
  Future<void>? _inFlight;
  bool _disposed = false;

  CoreLink get link => _link;
  Health? get health => _health;
  SystemInfo? get info => _info;
  DateTime? get lastCheckedAt => _lastCheckedAt;
  DateTime? get lastOnlineAt => _lastOnlineAt;

  /// Technical detail of the last failure, for the details panel.
  String? get detail => _detail;
  Uri get endpoint => _client.baseUri;

  /// True when [info] is shown from an earlier successful check.
  bool get isStale =>
      _info != null && _link != CoreLink.online && _link != CoreLink.degraded;

  /// Destructive actions must be blocked unless this is true.
  bool get canAct => _link == CoreLink.online;

  /// Starts periodic polling (adaptive: slower while offline).
  void start() {
    unawaited(refresh());
  }

  /// Checks Core now. Concurrent calls share one request.
  Future<void> refresh() => _inFlight ??= _check().whenComplete(() {
    _inFlight = null;
    _scheduleNext();
  });

  Future<void> _check() async {
    try {
      final health = await _client.health();
      _health = health;
      final info = await _client.systemInfo();
      _info = info;
      _lastOnlineAt = _now();
      _detail = null;
      _failures = 0;
      _link = health.isOk ? CoreLink.online : CoreLink.degraded;
    } on CoreUnreachable catch (e) {
      _failures++;
      _link = CoreLink.offline;
      _detail = e.reason;
    } on CoreApiException catch (e) {
      _failures++;
      _link = e.isUnauthorized ? CoreLink.unauthorized : CoreLink.incompatible;
      _detail = '${e.code}: ${e.message}';
    } on FormatException catch (e) {
      _failures++;
      _link = CoreLink.incompatible;
      _detail = e.message;
    } on TypeError catch (e) {
      // A field had an unexpected type: Core speaks a different contract.
      _failures++;
      _link = CoreLink.incompatible;
      _detail = e.toString();
    }
    _lastCheckedAt = _now();
    if (!_disposed) notifyListeners();
  }

  void _scheduleNext() {
    _timer?.cancel();
    if (_disposed) return;
    final delay = _failures == 0 ? onlineInterval : _backoff(_failures);
    _timer = Timer(delay, () => unawaited(refresh()));
  }

  Duration _backoff(int failures) {
    final seconds = 5 * (1 << (failures - 1).clamp(0, 4));
    final d = Duration(seconds: seconds);
    return d > maxOfflineInterval ? maxOfflineInterval : d;
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}
