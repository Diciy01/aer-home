import 'core_client.dart';
import 'monitoring_api.dart';

/// AER Network + TV (contract 0.10.0). Core observes; the client only
/// shows the overview and may ask for a read-only check.

DateTime? _time(Object? v) => v is String ? DateTime.parse(v) : null;

Map<String, dynamic> _obj(Object? v) => v as Map<String, dynamic>;

List<Map<String, dynamic>> _list(Object? v) => [
  for (final x in (v as List?) ?? const []) x as Map<String, dynamic>,
];

double? _num(Object? v) => (v as num?)?.toDouble();

/// The five states of the network view.
enum NetStatus {
  up,
  down,
  error,
  unconfigured,
  unknown;

  static NetStatus parse(Object? v) =>
      NetStatus.values.where((s) => s.name == v).firstOrNull ?? unknown;

  String get label => switch (this) {
    up => 'Доступен',
    down => 'Недоступен',
    error => 'Ошибка проверки',
    unconfigured => 'Не настроен',
    unknown => 'Нет данных',
  };
}

class NetTarget {
  const NetTarget(this.target, this.ok, this.latencyMs, this.error);
  final String target;
  final bool ok;
  final double? latencyMs;
  final String error;
}

class NetDetails {
  const NetDetails({
    this.targets = const [],
    this.connection = '',
    this.physicalLink = '',
    this.uptimeSec,
    this.downMbps,
    this.upMbps,
    this.streaming,
    this.version = '',
    this.currentApp,
    this.webReachable,
  });

  factory NetDetails.fromJson(Map<String, dynamic> j) => NetDetails(
    targets: [
      for (final t in _list(j['targets']))
        NetTarget(
          t['target'] as String? ?? '',
          t['ok'] == true,
          _num(t['latencyMs']),
          t['error'] as String? ?? '',
        ),
    ],
    connection: j['connection'] as String? ?? '',
    physicalLink: j['physicalLink'] as String? ?? '',
    uptimeSec: j['uptimeSec'] as int?,
    downMbps: _num(j['downMbps']),
    upMbps: _num(j['upMbps']),
    streaming: j['streaming'] as bool?,
    version: j['version'] as String? ?? '',
    currentApp: j['currentApp'] as int?,
    webReachable: j['webReachable'] as bool?,
  );

  final List<NetTarget> targets;
  final String connection;
  final String physicalLink;
  final int? uptimeSec;
  final double? downMbps;
  final double? upMbps;
  final bool? streaming;
  final String version;
  final int? currentApp;
  final bool? webReachable;
}

class NetCheck {
  const NetCheck({
    required this.key,
    required this.kind,
    required this.name,
    required this.status,
    required this.reason,
    this.entityId = '',
    this.latencyMs,
    this.lastCheckAt,
    this.lastOkAt,
    this.changedAt,
    this.failures = 0,
    this.stale = false,
    this.details,
  });

  factory NetCheck.fromJson(Map<String, dynamic> j) => NetCheck(
    key: j['key'] as String? ?? '',
    kind: j['kind'] as String? ?? '',
    name: j['name'] as String? ?? '',
    entityId: j['entityId'] as String? ?? '',
    status: NetStatus.parse(j['status']),
    reason: j['reason'] as String? ?? '',
    latencyMs: _num(j['latencyMs']),
    lastCheckAt: _time(j['lastCheckAt']),
    lastOkAt: _time(j['lastOkAt']),
    changedAt: _time(j['changedAt']),
    failures: j['failures'] as int? ?? 0,
    stale: j['stale'] == true,
    details: j['details'] == null
        ? null
        : NetDetails.fromJson(_obj(j['details'])),
  );

  final String key;
  final String kind;
  final String name;
  final String entityId;
  final NetStatus status;
  final String reason;
  final double? latencyMs;
  final DateTime? lastCheckAt;
  final DateTime? lastOkAt;
  final DateTime? changedAt;
  final int failures;
  final bool stale;
  final NetDetails? details;
}

class NetDevice {
  const NetDevice({
    required this.entityId,
    required this.name,
    required this.type,
    required this.status,
    required this.reason,
    this.address = '',
    this.monitoringStatus = '',
    this.latencyMs,
    this.latencyAt,
    this.lastContactAt,
    this.lastCheckAt,
    this.changedAt,
    this.stale = false,
    this.openIncidents = 0,
  });

  factory NetDevice.fromJson(Map<String, dynamic> j) => NetDevice(
    entityId: j['entityId'] as String,
    name: j['name'] as String? ?? '',
    type: j['type'] as String? ?? '',
    address: j['address'] as String? ?? '',
    status: NetStatus.parse(j['status']),
    reason: j['reason'] as String? ?? '',
    monitoringStatus: j['monitoringStatus'] as String? ?? '',
    latencyMs: _num(j['latencyMs']),
    latencyAt: _time(j['latencyAt']),
    lastContactAt: _time(j['lastContactAt']),
    lastCheckAt: _time(j['lastCheckAt']),
    changedAt: _time(j['changedAt']),
    stale: j['stale'] == true,
    openIncidents: j['openIncidents'] as int? ?? 0,
  );

  final String entityId;
  final String name;
  final String type;
  final String address;
  final NetStatus status;
  final String reason;
  final String monitoringStatus;
  final double? latencyMs;
  final DateTime? latencyAt;
  final DateTime? lastContactAt;
  final DateTime? lastCheckAt;
  final DateTime? changedAt;
  final bool stale;
  final int openIncidents;
}

class NetRouter {
  const NetRouter({
    required this.device,
    required this.adapter,
    required this.adapterNote,
    this.wan,
  });

  factory NetRouter.fromJson(Map<String, dynamic> j) => NetRouter(
    device: NetDevice.fromJson(_obj(j['device'])),
    adapter: j['adapter'] as String? ?? 'none',
    adapterNote: j['adapterNote'] as String? ?? '',
    wan: j['wan'] == null ? null : NetCheck.fromJson(_obj(j['wan'])),
  );

  final NetDevice device;
  final String adapter;
  final String adapterNote;
  final NetCheck? wan;
}

class NetSunshine {
  const NetSunshine({
    required this.id,
    required this.name,
    required this.check,
    this.webUrl = '',
    this.entity,
    this.tv,
  });

  factory NetSunshine.fromJson(Map<String, dynamic> j) => NetSunshine(
    id: j['id'] as String? ?? '',
    name: j['name'] as String? ?? '',
    webUrl: j['webUrl'] as String? ?? '',
    check: NetCheck.fromJson(_obj(j['check'])),
    entity: j['entity'] == null ? null : NetDevice.fromJson(_obj(j['entity'])),
    tv: j['tv'] == null ? null : NetDevice.fromJson(_obj(j['tv'])),
  );

  final String id;
  final String name;
  final String webUrl;
  final NetCheck check;
  final NetDevice? entity;
  final NetDevice? tv;
}

class NetSummary {
  const NetSummary(this.level, this.title, this.issues);
  final String level; // ok | warning | critical | unconfigured
  final String title;
  final List<String> issues;
}

class NetworkOverview {
  const NetworkOverview({
    required this.summary,
    required this.internet,
    this.routers = const [],
    this.devices = const [],
    this.tvs = const [],
    this.sunshine = const [],
    this.incidents = const [],
    this.recent = const [],
    this.intervalSec = 30,
    this.generatedAt,
  });

  factory NetworkOverview.fromJson(Map<String, dynamic> j) {
    final s = _obj(j['summary']);
    return NetworkOverview(
      summary: NetSummary(
        s['level'] as String? ?? 'unconfigured',
        s['title'] as String? ?? '',
        [for (final i in (s['issues'] as List?) ?? const []) '$i'],
      ),
      internet: NetCheck.fromJson(_obj(j['internet'])),
      routers: [for (final r in _list(j['routers'])) NetRouter.fromJson(r)],
      devices: [for (final d in _list(j['devices'])) NetDevice.fromJson(d)],
      tvs: [for (final d in _list(j['tvs'])) NetDevice.fromJson(d)],
      sunshine: [for (final x in _list(j['sunshine'])) NetSunshine.fromJson(x)],
      incidents: [for (final i in _list(j['incidents'])) Incident.fromJson(i)],
      recent: [for (final l in _list(j['recent'])) LogEntry.fromJson(l)],
      intervalSec: j['intervalSec'] as int? ?? 30,
      generatedAt: _time(j['generatedAt']),
    );
  }

  final NetSummary summary;
  final NetCheck internet;
  final List<NetRouter> routers;
  final List<NetDevice> devices;
  final List<NetDevice> tvs;
  final List<NetSunshine> sunshine;
  final List<Incident> incidents;
  final List<LogEntry> recent;
  final int intervalSec;
  final DateTime? generatedAt;

  /// Every device of the view (routers, devices, TVs, Sunshine hosts).
  Iterable<NetDevice> get allDevices sync* {
    for (final r in routers) {
      yield r.device;
    }
    yield* devices;
    yield* tvs;
    for (final s in sunshine) {
      if (s.entity case final e?) yield e;
    }
  }
}

abstract interface class NetworkApi {
  Future<NetworkOverview> overview();
  Future<NetworkOverview> checkNow();
}

class HttpNetworkApi implements NetworkApi {
  HttpNetworkApi(this._client);
  final CoreClient _client;

  @override
  Future<NetworkOverview> overview() async => NetworkOverview.fromJson(
    _obj(await _client.request('GET', '/network/overview')),
  );

  @override
  Future<NetworkOverview> checkNow() async => NetworkOverview.fromJson(
    _obj(await _client.request('POST', '/network/check')),
  );
}
