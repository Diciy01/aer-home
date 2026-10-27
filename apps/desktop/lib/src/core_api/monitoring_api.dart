import 'core_client.dart';

/// Availability of an entity as Monitoring sees it (contract 0.6.0).
enum MonStatus { online, degraded, offline, unknown, unsupported }

enum MonSeverity { info, warning, critical }

MonStatus _status(Object? v) =>
    MonStatus.values.where((s) => s.name == v).firstOrNull ?? MonStatus.unknown;

MonSeverity _severity(Object? v) =>
    MonSeverity.values.where((s) => s.name == v).firstOrNull ??
    MonSeverity.info;

DateTime? _time(Object? v) => v is String ? DateTime.parse(v) : null;

double? _num(Object? v) => v is num ? v.toDouble() : null;

class MetricValue {
  const MetricValue({
    required this.metric,
    required this.label,
    required this.value,
    required this.unit,
    required this.at,
    required this.quality,
    required this.reason,
    required this.source,
  });

  factory MetricValue.fromJson(Map<String, dynamic> j) => MetricValue(
    metric: j['metric'] as String,
    label: j['label'] as String? ?? '',
    value: _num(j['value']),
    unit: j['unit'] as String? ?? '',
    at: DateTime.parse(j['at'] as String),
    quality: j['quality'] as String? ?? 'ok',
    reason: j['reason'] as String? ?? '',
    source: j['source'] as String? ?? '',
  );

  final String metric;
  final String label;

  /// Null when the value is unsupported or unavailable (never shown as 0).
  final double? value;
  final String unit;
  final DateTime at;
  final String quality;
  final String reason;
  final String source;

  Map<String, Object?> toJson() => {
    'metric': metric,
    'label': label,
    'value': value,
    'unit': unit,
    'at': at.toUtc().toIso8601String(),
    'quality': quality,
    'reason': reason,
    'source': source,
  };
}

class MonAgent {
  const MonAgent({
    required this.id,
    required this.entityId,
    required this.name,
    required this.kind,
    required this.active,
    this.lastSeenAt,
    this.revokedAt,
    this.os = '',
    this.osVersion = '',
    this.version = '',
    this.lastError = '',
    this.lastSuccessAt,
  });

  factory MonAgent.fromJson(Map<String, dynamic> j) {
    final info = j['info'] as Map<String, dynamic>?;
    final bot = j['bot'] as Map<String, dynamic>?;
    return MonAgent(
      id: j['id'] as String,
      entityId: j['entityId'] as String,
      name: j['name'] as String,
      kind: j['kind'] as String,
      active: j['active'] as bool? ?? false,
      lastSeenAt: _time(j['lastSeenAt']),
      revokedAt: _time(j['revokedAt']),
      os: info?['os'] as String? ?? '',
      osVersion: info?['osVersion'] as String? ?? '',
      version: info?['version'] as String? ?? '',
      lastError: bot?['lastError'] as String? ?? '',
      lastSuccessAt: _time(bot?['lastSuccessAt']),
    );
  }

  final String id;
  final String entityId;
  final String name;
  final String kind;
  final bool active;
  final DateTime? lastSeenAt;
  final DateTime? revokedAt;
  final String os;
  final String osVersion;
  final String version;
  final String lastError;
  final DateTime? lastSuccessAt;

  Map<String, Object?> toJson() => {
    'id': id,
    'entityId': entityId,
    'name': name,
    'kind': kind,
    'active': active,
    'lastSeenAt': lastSeenAt?.toUtc().toIso8601String(),
    'revokedAt': revokedAt?.toUtc().toIso8601String(),
    'info': {'os': os, 'osVersion': osVersion, 'version': version},
    'bot': {
      'lastError': lastError,
      'lastSuccessAt': lastSuccessAt?.toUtc().toIso8601String(),
    },
  };
}

class DeviceState {
  const DeviceState({
    required this.entityId,
    required this.name,
    required this.type,
    required this.status,
    required this.reason,
    required this.checkKind,
    this.lastContactAt,
    this.lastCheckAt,
    this.changedAt,
    this.keyMetrics = const [],
    this.openIncidents = 0,
    this.worstSeverity,
    this.agents = const [],
  });

  factory DeviceState.fromJson(Map<String, dynamic> j) => DeviceState(
    entityId: j['entityId'] as String,
    name: j['name'] as String,
    type: j['type'] as String,
    status: _status(j['status']),
    reason: j['reason'] as String? ?? '',
    checkKind: j['checkKind'] as String? ?? 'none',
    lastContactAt: _time(j['lastContactAt']),
    lastCheckAt: _time(j['lastCheckAt']),
    changedAt: _time(j['changedAt']),
    keyMetrics: [
      for (final m in j['keyMetrics'] as List? ?? const [])
        MetricValue.fromJson(m as Map<String, dynamic>),
    ],
    openIncidents: j['openIncidents'] as int? ?? 0,
    worstSeverity: j['worstSeverity'] == null
        ? null
        : _severity(j['worstSeverity']),
    agents: [
      for (final a in j['agents'] as List? ?? const [])
        MonAgent.fromJson(a as Map<String, dynamic>),
    ],
  );

  final String entityId;
  final String name;
  final String type;
  final MonStatus status;
  final String reason;
  final String checkKind;
  final DateTime? lastContactAt;
  final DateTime? lastCheckAt;
  final DateTime? changedAt;
  final List<MetricValue> keyMetrics;
  final int openIncidents;
  final MonSeverity? worstSeverity;
  final List<MonAgent> agents;

  MetricValue? metric(String id, [String? label]) => keyMetrics
      .where((m) => m.metric == id && (label == null || m.label == label))
      .firstOrNull;

  Map<String, Object?> toJson() => {
    'entityId': entityId,
    'name': name,
    'type': type,
    'status': status.name,
    'reason': reason,
    'checkKind': checkKind,
    'lastContactAt': lastContactAt?.toUtc().toIso8601String(),
    'lastCheckAt': lastCheckAt?.toUtc().toIso8601String(),
    'changedAt': changedAt?.toUtc().toIso8601String(),
    'keyMetrics': [for (final m in keyMetrics) m.toJson()],
    'openIncidents': openIncidents,
    'worstSeverity': worstSeverity?.name,
    'agents': [for (final a in agents) a.toJson()],
  };
}

class MonEvent {
  const MonEvent({
    required this.id,
    required this.at,
    required this.kind,
    required this.severity,
    required this.message,
    this.entityId,
    this.incidentId,
  });

  factory MonEvent.fromJson(Map<String, dynamic> j) => MonEvent(
    id: j['id'] as int,
    at: DateTime.parse(j['at'] as String),
    kind: j['kind'] as String,
    severity: _severity(j['severity']),
    message: j['message'] as String,
    entityId: j['entityId'] as String?,
    incidentId: j['incidentId'] as String?,
  );

  final int id;
  final DateTime at;
  final String kind;
  final MonSeverity severity;
  final String message;
  final String? entityId;
  final String? incidentId;

  Map<String, Object?> toJson() => {
    'id': id,
    'at': at.toUtc().toIso8601String(),
    'kind': kind,
    'severity': severity.name,
    'message': message,
    'entityId': entityId,
    'incidentId': incidentId,
  };
}

class IntegrationStatus {
  const IntegrationStatus(this.id, this.label, this.status, this.reason);

  factory IntegrationStatus.fromJson(Map<String, dynamic> j) =>
      IntegrationStatus(
        j['id'] as String,
        j['label'] as String,
        j['status'] as String,
        j['reason'] as String? ?? '',
      );

  final String id;
  final String label;
  final String status;
  final String reason;

  Map<String, Object?> toJson() => {
    'id': id,
    'label': label,
    'status': status,
    'reason': reason,
  };
}

class MonOverview {
  const MonOverview({
    required this.generatedAt,
    required this.devices,
    required this.byStatus,
    required this.openIncidents,
    required this.criticalOpen,
    required this.unread,
    required this.integrations,
    required this.recentEvents,
  });

  factory MonOverview.fromJson(Map<String, dynamic> j) => MonOverview(
    generatedAt: DateTime.parse(j['generatedAt'] as String),
    devices: j['devices'] as int,
    byStatus: {
      for (final e in (j['byStatus'] as Map<String, dynamic>).entries)
        _status(e.key): e.value as int,
    },
    openIncidents: j['openIncidents'] as int,
    criticalOpen: j['criticalOpen'] as int,
    unread: j['unreadNotifications'] as int,
    integrations: [
      for (final i in j['integrations'] as List? ?? const [])
        IntegrationStatus.fromJson(i as Map<String, dynamic>),
    ],
    recentEvents: [
      for (final e in j['recentEvents'] as List? ?? const [])
        MonEvent.fromJson(e as Map<String, dynamic>),
    ],
  );

  final DateTime generatedAt;
  final int devices;
  final Map<MonStatus, int> byStatus;
  final int openIncidents;
  final int criticalOpen;
  final int unread;
  final List<IntegrationStatus> integrations;
  final List<MonEvent> recentEvents;

  int count(MonStatus s) => byStatus[s] ?? 0;

  Map<String, Object?> toJson() => {
    'generatedAt': generatedAt.toUtc().toIso8601String(),
    'devices': devices,
    'byStatus': {for (final e in byStatus.entries) e.key.name: e.value},
    'openIncidents': openIncidents,
    'criticalOpen': criticalOpen,
    'unreadNotifications': unread,
    'integrations': [for (final i in integrations) i.toJson()],
    'recentEvents': [for (final e in recentEvents) e.toJson()],
  };
}

class IncidentEvent {
  const IncidentEvent(this.at, this.kind, this.message);
  final DateTime at;
  final String kind;
  final String message;
}

class Incident {
  const Incident({
    required this.id,
    required this.title,
    required this.source,
    required this.severity,
    required this.status,
    required this.openedAt,
    required this.updatedAt,
    required this.cause,
    required this.related,
    required this.occurrences,
    required this.lastMessage,
    this.entityId,
    this.acknowledgedAt,
    this.resolvedAt,
    this.timeline = const [],
  });

  factory Incident.fromJson(Map<String, dynamic> j) => Incident(
    id: j['id'] as String,
    title: j['title'] as String,
    source: j['source'] as String,
    severity: _severity(j['severity']),
    status: j['status'] as String,
    openedAt: DateTime.parse(j['openedAt'] as String),
    updatedAt: DateTime.parse(j['updatedAt'] as String),
    cause: j['cause'] as String? ?? '',
    related: [for (final r in j['related'] as List? ?? const []) '$r'],
    occurrences: j['occurrences'] as int? ?? 1,
    lastMessage: j['lastMessage'] as String? ?? '',
    entityId: j['entityId'] as String?,
    acknowledgedAt: _time(j['acknowledgedAt']),
    resolvedAt: _time(j['resolvedAt']),
    timeline: [
      for (final e in j['timeline'] as List? ?? const [])
        IncidentEvent(
          DateTime.parse((e as Map<String, dynamic>)['at'] as String),
          e['kind'] as String,
          e['message'] as String,
        ),
    ],
  );

  final String id;
  final String title;
  final String source;
  final MonSeverity severity;
  final String status;
  final DateTime openedAt;
  final DateTime updatedAt;
  final String cause;
  final List<String> related;
  final int occurrences;
  final String lastMessage;
  final String? entityId;
  final DateTime? acknowledgedAt;
  final DateTime? resolvedAt;
  final List<IncidentEvent> timeline;

  bool get active => status != 'resolved';
}

class LogEntry {
  const LogEntry({
    required this.id,
    required this.at,
    required this.source,
    required this.level,
    required this.message,
    required this.correlationId,
    this.entityId,
    this.incidentId,
    this.fields,
  });

  factory LogEntry.fromJson(Map<String, dynamic> j) => LogEntry(
    id: j['id'] as int,
    at: DateTime.parse(j['at'] as String),
    source: j['source'] as String,
    level: j['level'] as String,
    message: j['message'] as String,
    correlationId: j['correlationId'] as String? ?? '',
    entityId: j['entityId'] as String?,
    incidentId: j['incidentId'] as String?,
    fields: j['fields'] as Map<String, dynamic>?,
  );

  final int id;
  final DateTime at;
  final String source;
  final String level;
  final String message;
  final String correlationId;
  final String? entityId;
  final String? incidentId;
  final Map<String, dynamic>? fields;
}

class LogPage {
  const LogPage(this.items, this.nextBefore);
  final List<LogEntry> items;
  final int? nextBefore;
}

class MetricPoint {
  const MetricPoint(this.t, this.value, this.min, this.max);
  final DateTime t;
  final double? value;
  final double? min;
  final double? max;
}

class MetricSeries {
  const MetricSeries({
    required this.metric,
    required this.label,
    required this.unit,
    required this.resolution,
    required this.points,
  });

  factory MetricSeries.fromJson(Map<String, dynamic> j) => MetricSeries(
    metric: j['metric'] as String,
    label: j['label'] as String? ?? '',
    unit: j['unit'] as String? ?? '',
    resolution: j['resolution'] as String,
    points: [
      for (final p in j['points'] as List)
        MetricPoint(
          DateTime.parse((p as Map<String, dynamic>)['t'] as String),
          _num(p['value']),
          _num(p['min']),
          _num(p['max']),
        ),
    ],
  );

  final String metric;
  final String label;
  final String unit;
  final String resolution;
  final List<MetricPoint> points;
}

class MonNotification {
  const MonNotification({
    required this.id,
    required this.at,
    required this.kind,
    required this.severity,
    required this.title,
    required this.body,
    required this.read,
    required this.telegram,
    this.entityId,
    this.incidentId,
  });

  factory MonNotification.fromJson(Map<String, dynamic> j) => MonNotification(
    id: j['id'] as String,
    at: DateTime.parse(j['at'] as String),
    kind: j['kind'] as String,
    severity: _severity(j['severity']),
    title: j['title'] as String,
    body: j['body'] as String? ?? '',
    read: j['readAt'] != null,
    telegram: j['telegram'] as String? ?? 'disabled',
    entityId: j['entityId'] as String?,
    incidentId: j['incidentId'] as String?,
  );

  final String id;
  final DateTime at;
  final String kind;
  final MonSeverity severity;
  final String title;
  final String body;
  final bool read;
  final String telegram;
  final String? entityId;
  final String? incidentId;
}

class DockerContainer {
  const DockerContainer({
    required this.name,
    required this.image,
    required this.state,
    required this.health,
    required this.restartCount,
    required this.lastErrors,
    this.exitCode,
    this.oomKilled = false,
    this.cpuPercent,
    this.memBytes,
    this.startedAt,
    this.changedAt,
    this.entityId,
  });

  factory DockerContainer.fromJson(Map<String, dynamic> j) => DockerContainer(
    name: j['name'] as String,
    image: j['image'] as String,
    state: j['state'] as String,
    health: j['health'] as String? ?? '',
    restartCount: j['restartCount'] as int? ?? 0,
    lastErrors: [for (final e in j['lastErrors'] as List? ?? const []) '$e'],
    exitCode: j['exitCode'] as int?,
    oomKilled: j['oomKilled'] as bool? ?? false,
    cpuPercent: _num(j['cpuPercent']),
    memBytes: _num(j['memBytes']),
    startedAt: _time(j['startedAt']),
    changedAt: _time(j['changedAt']),
    entityId: j['entityId'] as String?,
  );

  final String name;
  final String image;
  final String state;
  final String health;
  final int restartCount;
  final List<String> lastErrors;
  final int? exitCode;
  final bool oomKilled;
  final double? cpuPercent;
  final double? memBytes;
  final DateTime? startedAt;
  final DateTime? changedAt;
  final String? entityId;
}

/// Monitoring endpoints of Core. Tests substitute an in-memory fake.
abstract interface class MonitoringApi {
  Future<MonOverview> overview();
  Future<List<DeviceState>> states();
  Future<DeviceState> state(String entityId);
  Future<MetricSeries> history(
    String entityId,
    String metric, {
    String label = '',
    DateTime? from,
    DateTime? to,
  });
  Future<LogPage> logs({
    String q = '',
    String? entityId,
    String? level,
    String? incidentId,
    DateTime? from,
    int? before,
    int limit = 100,
  });
  Future<List<MonEvent>> events({String? entityId, int limit = 50});
  Future<List<Incident>> incidents({
    String status = 'active',
    String? entityId,
    String? severity,
    int limit = 100,
  });
  Future<Incident> incident(String id);
  Future<Incident> acknowledge(String id, {String note = ''});
  Future<(List<MonNotification>, int)> notifications({int limit = 50});
  Future<void> markRead([List<String> ids = const []]);
  Future<List<MonAgent>> agents();
  Future<(MonAgent, String)> createAgent(
    String entityId,
    String name,
    String kind,
  );
  Future<MonAgent> revokeAgent(String id);
  Future<(IntegrationStatus, List<DockerContainer>)> containers();
}

class HttpMonitoringApi implements MonitoringApi {
  HttpMonitoringApi(this._client);
  final CoreClient _client;

  Future<Object?> _get(String path, [Map<String, Object?>? q]) =>
      _client.request('GET', path, query: q);

  Map<String, dynamic> _obj(Object? v) => v as Map<String, dynamic>;

  String _iso(DateTime t) =>
      t.toUtc().toIso8601String().replaceFirst(RegExp(r'\.\d+Z$'), 'Z');

  @override
  Future<MonOverview> overview() async =>
      MonOverview.fromJson(_obj(await _get('/monitoring/overview')));

  @override
  Future<List<DeviceState>> states() async => [
    for (final s in await _get('/monitoring/states') as List)
      DeviceState.fromJson(_obj(s)),
  ];

  @override
  Future<DeviceState> state(String entityId) async =>
      DeviceState.fromJson(_obj(await _get('/monitoring/states/$entityId')));

  @override
  Future<MetricSeries> history(
    String entityId,
    String metric, {
    String label = '',
    DateTime? from,
    DateTime? to,
  }) async => MetricSeries.fromJson(
    _obj(
      await _get('/monitoring/states/$entityId/history', {
        'metric': metric,
        if (label.isNotEmpty) 'label': label,
        if (from != null) 'from': _iso(from),
        if (to != null) 'to': _iso(to),
      }),
    ),
  );

  @override
  Future<LogPage> logs({
    String q = '',
    String? entityId,
    String? level,
    String? incidentId,
    DateTime? from,
    int? before,
    int limit = 100,
  }) async {
    final m = _obj(
      await _get('/monitoring/logs', {
        if (q.trim().isNotEmpty) 'q': q.trim(),
        'entityId': ?entityId,
        'level': ?level,
        'incidentId': ?incidentId,
        if (from != null) 'from': _iso(from),
        'before': ?before,
        'limit': limit,
      }),
    );
    return LogPage([
      for (final l in m['items'] as List) LogEntry.fromJson(_obj(l)),
    ], m['nextBefore'] as int?);
  }

  @override
  Future<List<MonEvent>> events({String? entityId, int limit = 50}) async => [
    for (final e in await _get('/monitoring/events', {
      'entityId': ?entityId,
      'limit': limit,
    }) as List)
      MonEvent.fromJson(_obj(e)),
  ];

  @override
  Future<List<Incident>> incidents({
    String status = 'active',
    String? entityId,
    String? severity,
    int limit = 100,
  }) async {
    final m = _obj(
      await _get('/monitoring/incidents', {
        if (status.isNotEmpty) 'status': status,
        'entityId': ?entityId,
        'severity': ?severity,
        'limit': limit,
      }),
    );
    return [for (final i in m['items'] as List) Incident.fromJson(_obj(i))];
  }

  @override
  Future<Incident> incident(String id) async =>
      Incident.fromJson(_obj(await _get('/monitoring/incidents/$id')));

  @override
  Future<Incident> acknowledge(String id, {String note = ''}) async =>
      Incident.fromJson(
        _obj(
          await _client.request(
            'POST',
            '/monitoring/incidents/$id/acknowledge',
            body: {'note': note},
          ),
        ),
      );

  @override
  Future<(List<MonNotification>, int)> notifications({int limit = 50}) async {
    final m = _obj(await _get('/monitoring/notifications', {'limit': limit}));
    return (
      [for (final n in m['items'] as List) MonNotification.fromJson(_obj(n))],
      m['unread'] as int,
    );
  }

  @override
  Future<void> markRead([List<String> ids = const []]) async {
    await _client.request(
      'POST',
      '/monitoring/notifications/read',
      body: {'ids': ids},
    );
  }

  @override
  Future<List<MonAgent>> agents() async => [
    for (final a in await _get('/monitoring/agents') as List)
      MonAgent.fromJson(_obj(a)),
  ];

  @override
  Future<(MonAgent, String)> createAgent(
    String entityId,
    String name,
    String kind,
  ) async {
    final m = _obj(
      await _client.request(
        'POST',
        '/monitoring/agents',
        body: {'entityId': entityId, 'name': name, 'kind': kind},
      ),
    );
    return (MonAgent.fromJson(_obj(m['agent'])), m['token'] as String);
  }

  @override
  Future<MonAgent> revokeAgent(String id) async => MonAgent.fromJson(
    _obj(await _client.request('POST', '/monitoring/agents/$id/revoke')),
  );

  @override
  Future<(IntegrationStatus, List<DockerContainer>)> containers() async {
    final m = _obj(await _get('/monitoring/docker/containers'));
    return (
      IntegrationStatus.fromJson(_obj(m['integration'])),
      [for (final c in m['items'] as List) DockerContainer.fromJson(_obj(c))],
    );
  }
}
