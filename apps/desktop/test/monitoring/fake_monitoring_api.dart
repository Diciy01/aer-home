// TEST DOUBLE ONLY — in-memory Monitoring API with explicitly fake data.
import 'package:aer_home_desktop/src/core_api/monitoring_api.dart';

final t0 = DateTime.utc(2026, 10, 27, 10);

MetricValue mv(
  String metric,
  double? v,
  String unit, {
  String label = '',
  String quality = 'ok',
  String reason = '',
}) => MetricValue(
  metric: metric,
  label: label,
  value: v,
  unit: unit,
  at: t0,
  quality: quality,
  reason: reason,
  source: 'agent:test',
);

DeviceState device(
  String id,
  String name,
  String type,
  MonStatus st, {
  int incidents = 0,
  MonSeverity? worst,
  List<MetricValue> metrics = const [],
  String reason = 'тестовая причина',
}) => DeviceState(
  entityId: id,
  name: name,
  type: type,
  status: st,
  reason: reason,
  checkKind: 'agent',
  lastContactAt: t0,
  lastCheckAt: t0,
  keyMetrics: metrics,
  openIncidents: incidents,
  worstSeverity: worst,
  agents: [
    MonAgent(
      id: 'a-$id',
      entityId: id,
      name: 'ubuntu',
      kind: 'host',
      active: st == MonStatus.online,
      lastSeenAt: t0,
      osVersion: 'Ubuntu (тест)',
    ),
  ],
);

class FakeMonitoringApi implements MonitoringApi {
  Object? failWith;
  int overviewCalls = 0;
  final acked = <String>[];
  bool readAll = false;

  List<DeviceState> devices = [
    device(
      '11111111-1111-4111-8111-111111111111',
      'Сервер (тест)',
      'server',
      MonStatus.online,
      metrics: [
        mv('cpu.usage', 12, '%'),
        mv('mem.used_percent', 40, '%'),
        mv('disk.used_percent', 55, '%', label: '/'),
        mv(
          'gpu.temperature',
          null,
          '°C',
          quality: 'unsupported',
          reason: 'Нет датчика',
        ),
      ],
    ),
    device(
      '22222222-2222-4222-8222-222222222222',
      'ПК (тест)',
      'computer',
      MonStatus.degraded,
      incidents: 1,
      worst: MonSeverity.warning,
      metrics: [mv('cpu.usage', 80, '%')],
    ),
    device(
      '33333333-3333-4333-8333-333333333333',
      'Бот (тест)',
      'telegram_bot',
      MonStatus.offline,
      incidents: 1,
      worst: MonSeverity.critical,
      reason: 'Нет heartbeat',
    ),
  ];

  late List<Incident> incidentList = [
    Incident(
      id: 'inc-1',
      title: 'Бот «Бот (тест)» перестал отправлять heartbeat',
      source: 'availability/heartbeat',
      severity: MonSeverity.critical,
      status: 'open',
      openedAt: t0,
      updatedAt: t0,
      cause: '',
      related: const [],
      occurrences: 3,
      lastMessage: 'Нет heartbeat',
      entityId: devices[2].entityId,
    ),
    Incident(
      id: 'inc-2',
      title: 'Мало места на «ПК (тест)»: /',
      source: 'metrics/disk',
      severity: MonSeverity.warning,
      status: 'resolved',
      openedAt: t0,
      updatedAt: t0,
      cause: '',
      related: const [],
      occurrences: 1,
      lastMessage: '',
      entityId: devices[1].entityId,
      resolvedAt: t0,
    ),
  ];

  void _guard() {
    if (failWith != null) throw failWith!;
  }

  @override
  Future<MonOverview> overview() async {
    _guard();
    overviewCalls++;
    final by = <MonStatus, int>{
      for (final s in MonStatus.values)
        s: devices.where((d) => d.status == s).length,
    };
    return MonOverview(
      generatedAt: t0,
      devices: devices.length,
      byStatus: by,
      openIncidents: incidentList.where((i) => i.active).length,
      criticalOpen: incidentList
          .where((i) => i.active && i.severity == MonSeverity.critical)
          .length,
      unread: readAll ? 0 : 2,
      integrations: const [
        IntegrationStatus('checks', 'Проверки доступности', 'ok', '3 объекта'),
        IntegrationStatus(
          'docker',
          'Docker',
          'unavailable',
          'Сокет не найден (тест)',
        ),
      ],
      recentEvents: [
        MonEvent(
          id: 1,
          at: t0,
          kind: 'status_changed',
          severity: MonSeverity.critical,
          message: 'Бот (тест): в сети → недоступен',
          entityId: devices.last.entityId,
        ),
      ],
    );
  }

  @override
  Future<List<DeviceState>> states() async {
    _guard();
    return devices;
  }

  @override
  Future<DeviceState> state(String entityId) async {
    _guard();
    return devices.firstWhere((d) => d.entityId == entityId);
  }

  @override
  Future<MetricSeries> history(
    String entityId,
    String metric, {
    String label = '',
    DateTime? from,
    DateTime? to,
  }) async {
    _guard();
    return MetricSeries(
      metric: metric,
      label: label,
      unit: '%',
      resolution: 'raw',
      points: [
        for (var i = 0; i < 40; i++)
          MetricPoint(
            t0.add(Duration(minutes: i)),
            i > 15 && i < 20 ? null : 10.0 + i % 7,
            null,
            null,
          ),
      ],
    );
  }

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
    _guard();
    final all =
        [
              for (var i = 50; i > 0; i--)
                LogEntry(
                  id: i,
                  at: t0,
                  source: 'agent:test/journal',
                  level: i % 5 == 0 ? 'error' : 'warning',
                  message: 'строка журнала $i (тест)',
                  correlationId: '',
                  entityId: devices[i % 3].entityId,
                  incidentId: i == 50 ? 'inc-1' : null,
                ),
            ]
            .where(
              (l) =>
                  (q.isEmpty || l.message.contains(q)) &&
                  (level != 'error' || l.level == 'error') &&
                  (entityId == null || l.entityId == entityId),
            )
            .toList();
    final start = before == null ? 0 : all.indexWhere((l) => l.id < before);
    final page = all.skip(start < 0 ? all.length : start).take(20).toList();
    return LogPage(
      page,
      page.length == 20 && page.last.id > 1 ? page.last.id : null,
    );
  }

  @override
  Future<List<MonEvent>> events({String? entityId, int limit = 50}) async => [
    MonEvent(
      id: 1,
      at: t0,
      kind: 'status_changed',
      severity: MonSeverity.info,
      message: 'событие (тест)',
      entityId: entityId,
    ),
  ];

  @override
  Future<List<Incident>> incidents({
    String status = 'active',
    String? entityId,
    String? severity,
    int limit = 100,
  }) async {
    _guard();
    return incidentList
        .where(
          (i) =>
              (status == '' ||
                  (status == 'active' ? i.active : i.status == status)) &&
              (entityId == null || i.entityId == entityId) &&
              (severity == null || i.severity.name == severity),
        )
        .toList();
  }

  @override
  Future<Incident> incident(String id) async =>
      incidentList.firstWhere((i) => i.id == id);

  @override
  Future<Incident> acknowledge(String id, {String note = ''}) async {
    _guard();
    acked.add(id);
    final i = incidentList.firstWhere((x) => x.id == id);
    final n = Incident(
      id: i.id,
      title: i.title,
      source: i.source,
      severity: i.severity,
      status: 'acknowledged',
      openedAt: i.openedAt,
      updatedAt: t0,
      cause: i.cause,
      related: i.related,
      occurrences: i.occurrences,
      lastMessage: i.lastMessage,
      entityId: i.entityId,
      acknowledgedAt: t0,
    );
    incidentList = [for (final x in incidentList) x.id == id ? n : x];
    return n;
  }

  @override
  Future<(List<MonNotification>, int)> notifications({int limit = 50}) async =>
      (
        [
          MonNotification(
            id: 'n1',
            at: t0,
            kind: 'incident_opened',
            severity: MonSeverity.critical,
            title: 'Бот перестал отвечать (тест)',
            body: '',
            read: readAll,
            telegram: 'disabled',
            entityId: devices[2].entityId,
          ),
        ],
        readAll ? 0 : 1,
      );

  @override
  Future<void> markRead([List<String> ids = const []]) async => readAll = true;

  @override
  Future<List<MonAgent>> agents() async => [
    for (final d in devices) ...d.agents,
  ];

  @override
  Future<(MonAgent, String)> createAgent(
    String entityId,
    String name,
    String kind,
  ) async => (
    MonAgent(
      id: 'new',
      entityId: entityId,
      name: name,
      kind: kind,
      active: false,
    ),
    'aer1.test-token-not-real',
  );

  @override
  Future<MonAgent> revokeAgent(String id) async => MonAgent(
    id: id,
    entityId: '',
    name: 'x',
    kind: 'host',
    active: false,
    revokedAt: t0,
  );

  @override
  Future<(IntegrationStatus, List<DockerContainer>)> containers() async => (
    const IntegrationStatus(
      'docker',
      'Docker',
      'unavailable',
      'Сокет не найден (тест)',
    ),
    <DockerContainer>[],
  );
}
