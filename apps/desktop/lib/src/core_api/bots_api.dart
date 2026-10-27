import 'dart:math';

import 'core_client.dart';
import 'monitoring_api.dart';

/// Bots (contract 0.7.0). A bot is a Registry entity plus its bot config;
/// state, metrics, logs and incidents come from Monitoring.

DateTime? _time(Object? v) => v is String ? DateTime.parse(v) : null;

double? _num(Object? v) => v is num ? v.toDouble() : null;

List<String> _strings(Object? v) => [
  for (final x in v as List? ?? const []) '$x',
];

Map<String, dynamic> _obj(Object? v) => v as Map<String, dynamic>;

MonStatus _status(Object? v) =>
    MonStatus.values.where((s) => s.name == v).firstOrNull ?? MonStatus.unknown;

enum JobStatus { pending, running, success, failed, cancelled }

JobStatus _jobStatus(Object? v) =>
    JobStatus.values.where((s) => s.name == v).firstOrNull ?? JobStatus.pending;

const botRuntimes = [
  'python',
  'docker',
  'telegram',
  'n8n',
  'service',
  'custom',
];

const botRuntimeLabels = {
  'python': 'Python-процесс',
  'docker': 'Docker-контейнер',
  'telegram': 'Telegram-бот',
  'n8n': 'n8n',
  'service': 'Фоновая служба',
  'custom': 'Другое приложение',
};

const botTypes = [
  'telegram_bot',
  'process',
  'service',
  'automation',
  'application',
  'docker_container',
];

const logSourceLabels = {
  'heartbeat': 'Heartbeat бота',
  'controller': 'Вывод процесса (Core)',
  'docker': 'Docker',
  'n8n': 'Выполнения n8n',
  'none': 'Не собирать',
};

class EntityRef {
  const EntityRef({
    required this.id,
    required this.name,
    required this.type,
    this.relation = '',
    this.status = MonStatus.unknown,
    this.reason = '',
  });

  factory EntityRef.fromJson(Map<String, dynamic> j) => EntityRef(
    id: j['id'] as String,
    name: j['name'] as String,
    type: j['type'] as String,
    relation: j['relation'] as String? ?? '',
    status: _status(j['status']),
    reason: j['reason'] as String? ?? '',
  );

  final String id;
  final String name;
  final String type;
  final String relation;
  final MonStatus status;
  final String reason;
}

class BotHeartbeat {
  const BotHeartbeat({
    required this.credentials,
    required this.active,
    required this.intervalSec,
    required this.timeoutSec,
    this.lastSeenAt,
    this.library = '',
  });

  factory BotHeartbeat.fromJson(Map<String, dynamic> j) => BotHeartbeat(
    credentials: j['credentials'] as int,
    active: j['active'] as bool,
    lastSeenAt: _time(j['lastSeenAt']),
    intervalSec: j['intervalSec'] as int,
    timeoutSec: j['timeoutSec'] as int,
    library: j['library'] as String? ?? '',
  );

  final int credentials;
  final bool active;
  final DateTime? lastSeenAt;
  final int intervalSec;
  final int timeoutSec;
  final String library;
}

/// What a management adapter knows: «running» means the process exists,
/// not that the bot works.
class RuntimeState {
  const RuntimeState({
    required this.adapter,
    required this.state,
    required this.reason,
    this.pid = 0,
    this.since,
  });

  factory RuntimeState.fromJson(Map<String, dynamic> j) => RuntimeState(
    adapter: j['adapter'] as String,
    state: j['state'] as String,
    reason: j['reason'] as String? ?? '',
    pid: j['pid'] as int? ?? 0,
    since: _time(j['since']),
  );

  final String adapter;
  final String state;
  final String reason;
  final int pid;
  final DateTime? since;
}

class BotJob {
  const BotJob({
    required this.id,
    required this.name,
    required this.status,
    required this.source,
    this.externalId = '',
    this.startedAt,
    this.finishedAt,
    this.durationMs,
    this.result = '',
    this.error = '',
    this.retryable = false,
    this.retryOf = '',
  });

  factory BotJob.fromJson(Map<String, dynamic> j) => BotJob(
    id: j['id'] as String,
    externalId: j['externalId'] as String? ?? '',
    name: j['name'] as String,
    status: _jobStatus(j['status']),
    source: j['source'] as String? ?? '',
    startedAt: _time(j['startedAt']),
    finishedAt: _time(j['finishedAt']),
    durationMs: j['durationMs'] as int?,
    result: j['result'] as String? ?? '',
    error: j['error'] as String? ?? '',
    retryable: j['retryable'] as bool? ?? false,
    retryOf: j['retryOf'] as String? ?? '',
  );

  final String id;
  final String externalId;
  final String name;
  final JobStatus status;
  final String source;
  final DateTime? startedAt;
  final DateTime? finishedAt;
  final int? durationMs;
  final String result;
  final String error;
  final bool retryable;
  final String retryOf;
}

class JobPage {
  const JobPage(this.items, this.nextBefore, this.total);
  final List<BotJob> items;
  final String? nextBefore;
  final int total;
}

class BotAction {
  const BotAction({
    required this.id,
    required this.label,
    required this.available,
    required this.reason,
    required this.confirm,
    required this.risk,
  });

  factory BotAction.fromJson(Map<String, dynamic> j) => BotAction(
    id: j['id'] as String,
    label: j['label'] as String,
    available: j['available'] as bool,
    reason: j['reason'] as String? ?? '',
    confirm: j['confirm'] as bool? ?? true,
    risk: j['risk'] as String? ?? '',
  );

  final String id;
  final String label;
  final bool available;
  final String reason;
  final bool confirm;
  final String risk;
}

class BotConfirmation {
  const BotConfirmation({
    required this.token,
    required this.action,
    required this.summary,
    required this.risks,
    required this.expiresAt,
    this.jobId = '',
  });

  factory BotConfirmation.fromJson(Map<String, dynamic> j) => BotConfirmation(
    token: j['token'] as String,
    action: j['action'] as String,
    summary: j['summary'] as String,
    risks: _strings(j['risks']),
    expiresAt: DateTime.parse(j['expiresAt'] as String),
    jobId: j['jobId'] as String? ?? '',
  );

  final String token;
  final String action;
  final String summary;
  final List<String> risks;
  final DateTime expiresAt;
  final String jobId;
}

class BotActionRecord {
  const BotActionRecord({
    required this.id,
    required this.action,
    required this.status,
    required this.message,
    required this.requestedAt,
    this.adapter = '',
    this.jobId = '',
    this.finishedAt,
    this.replayed = false,
  });

  factory BotActionRecord.fromJson(Map<String, dynamic> j) => BotActionRecord(
    id: j['id'] as String,
    action: j['action'] as String,
    status: j['status'] as String,
    message: j['message'] as String? ?? '',
    requestedAt: DateTime.parse(j['requestedAt'] as String),
    adapter: j['adapter'] as String? ?? '',
    jobId: j['jobId'] as String? ?? '',
    finishedAt: _time(j['finishedAt']),
    replayed: j['replayed'] as bool? ?? false,
  );

  final String id;
  final String action;

  /// running | succeeded | failed | rejected
  final String status;
  final String message;
  final DateTime requestedAt;
  final String adapter;
  final String jobId;
  final DateTime? finishedAt;
  final bool replayed;
}

class N8nWorkflow {
  const N8nWorkflow(this.id, this.name, this.active);
  final String id;
  final String name;
  final bool active;
}

class BotIntegration {
  const BotIntegration({
    required this.kind,
    required this.label,
    required this.status,
    required this.reason,
    this.checkedAt,
    this.workflows = const [],
  });

  factory BotIntegration.fromJson(Map<String, dynamic> j) => BotIntegration(
    kind: j['kind'] as String,
    label: j['label'] as String,
    status: j['status'] as String,
    reason: j['reason'] as String? ?? '',
    checkedAt: _time(j['checkedAt']),
    workflows: [
      for (final w in j['workflows'] as List? ?? const [])
        N8nWorkflow(
          '${_obj(w)['id']}',
          _obj(w)['name'] as String? ?? '',
          _obj(w)['active'] as bool? ?? false,
        ),
    ],
  );

  final String kind;
  final String label;
  final String status;
  final String reason;
  final DateTime? checkedAt;
  final List<N8nWorkflow> workflows;
}

/// List/card view of a bot.
class Bot {
  const Bot({
    required this.entityId,
    required this.name,
    required this.type,
    required this.runtime,
    required this.status,
    required this.heartbeat,
    required this.revision,
    this.description = '',
    this.tags = const [],
    this.category = '',
    this.controllerId = '',
    this.n8nInstanceId = '',
    this.n8nWorkflowIds = const [],
    this.telegramTokenId = '',
    this.container = '',
    this.logSource = 'heartbeat',
    this.notes = '',
    this.archived = false,
    this.host,
    this.statusReason = '',
    this.lastContactAt,
    this.openIncidents = 0,
    this.version = '',
    this.startedAt,
    this.uptimeSec,
    this.lastError = '',
    this.lastErrorAt,
    this.lastSuccessAt,
    this.apiOk,
    this.cpuPercent,
    this.memBytes,
    this.runtimeState,
    this.lastJobOk,
    this.lastJobFailed,
    this.success24h = 0,
    this.failed24h = 0,
    this.runningJobs = 0,
  });

  factory Bot.fromJson(Map<String, dynamic> j) {
    final jobs = j['jobs'] as Map<String, dynamic>? ?? const {};
    return Bot(
      entityId: j['entityId'] as String,
      name: j['name'] as String,
      type: j['type'] as String,
      runtime: j['runtime'] as String,
      status: _status(j['status']),
      heartbeat: BotHeartbeat.fromJson(_obj(j['heartbeat'])),
      revision: j['revision'] as int,
      description: j['description'] as String? ?? '',
      tags: _strings(j['tags']),
      category: j['category'] as String? ?? '',
      controllerId: j['controllerId'] as String? ?? '',
      n8nInstanceId: j['n8nInstanceId'] as String? ?? '',
      n8nWorkflowIds: _strings(j['n8nWorkflowIds']),
      telegramTokenId: j['telegramTokenId'] as String? ?? '',
      container: j['container'] as String? ?? '',
      logSource: j['logSource'] as String? ?? 'heartbeat',
      notes: j['notes'] as String? ?? '',
      archived: j['archived'] as bool? ?? false,
      host: j['host'] == null ? null : EntityRef.fromJson(_obj(j['host'])),
      statusReason: j['statusReason'] as String? ?? '',
      lastContactAt: _time(j['lastContactAt']),
      openIncidents: j['openIncidents'] as int? ?? 0,
      version: j['version'] as String? ?? '',
      startedAt: _time(j['startedAt']),
      uptimeSec: j['uptimeSec'] as int?,
      lastError: j['lastError'] as String? ?? '',
      lastErrorAt: _time(j['lastErrorAt']),
      lastSuccessAt: _time(j['lastSuccessAt']),
      apiOk: j['apiOk'] as bool?,
      cpuPercent: _num(j['cpuPercent']),
      memBytes: _num(j['memBytes']),
      runtimeState: j['runtimeState'] == null
          ? null
          : RuntimeState.fromJson(_obj(j['runtimeState'])),
      lastJobOk: j['lastJobOk'] == null
          ? null
          : BotJob.fromJson(_obj(j['lastJobOk'])),
      lastJobFailed: j['lastJobFailed'] == null
          ? null
          : BotJob.fromJson(_obj(j['lastJobFailed'])),
      success24h: jobs['success24h'] as int? ?? 0,
      failed24h: jobs['failed24h'] as int? ?? 0,
      runningJobs: jobs['running'] as int? ?? 0,
    );
  }

  final String entityId;
  final String name;
  final String type;
  final String runtime;
  final MonStatus status;
  final BotHeartbeat heartbeat;

  /// Bot config revision (optimistic locking of edits).
  final int revision;
  final String description;
  final List<String> tags;
  final String category;
  final String controllerId;
  final String n8nInstanceId;
  final List<String> n8nWorkflowIds;
  final String telegramTokenId;
  final String container;
  final String logSource;
  final String notes;
  final bool archived;
  final EntityRef? host;
  final String statusReason;
  final DateTime? lastContactAt;
  final int openIncidents;
  final String version;
  final DateTime? startedAt;
  final int? uptimeSec;
  final String lastError;
  final DateTime? lastErrorAt;
  final DateTime? lastSuccessAt;
  final bool? apiOk;
  final double? cpuPercent;
  final double? memBytes;
  final RuntimeState? runtimeState;
  final BotJob? lastJobOk;
  final BotJob? lastJobFailed;
  final int success24h;
  final int failed24h;
  final int runningJobs;

  /// Only monitoring: no management adapter selected.
  bool get monitorOnly => controllerId.isEmpty;
}

/// The full bot page.
class BotDetail {
  const BotDetail({
    required this.bot,
    this.dependencies = const [],
    this.crashes = const [],
    this.restarts = const [],
    this.actions = const [],
    this.integration,
  });

  factory BotDetail.fromJson(Map<String, dynamic> j) => BotDetail(
    bot: Bot.fromJson(j),
    dependencies: [
      for (final d in j['dependencies'] as List? ?? const [])
        EntityRef.fromJson(_obj(d)),
    ],
    crashes: [
      for (final c in j['crashes'] as List? ?? const [])
        Incident.fromJson(_obj(c)),
    ],
    restarts: [
      for (final e in j['restarts'] as List? ?? const [])
        MonEvent.fromJson(_obj(e)),
    ],
    actions: [
      for (final a in j['actions'] as List? ?? const [])
        BotAction.fromJson(_obj(a)),
    ],
    integration: j['integration'] == null
        ? null
        : BotIntegration.fromJson(_obj(j['integration'])),
  );

  final Bot bot;
  final List<EntityRef> dependencies;
  final List<Incident> crashes;
  final List<MonEvent> restarts;
  final List<BotAction> actions;
  final BotIntegration? integration;

  BotAction? action(String id) => actions.where((a) => a.id == id).firstOrNull;
}

class AdapterInstance {
  const AdapterInstance({
    required this.id,
    required this.label,
    required this.target,
    this.allow = const [],
    this.usedBy = '',
  });

  final String id;
  final String label;
  final String target;
  final List<String> allow;
  final String usedBy;
}

class BotAdapter {
  const BotAdapter({
    required this.id,
    required this.label,
    required this.description,
    required this.capabilities,
    required this.status,
    required this.reason,
    required this.instances,
  });

  factory BotAdapter.fromJson(Map<String, dynamic> j) => BotAdapter(
    id: j['id'] as String,
    label: j['label'] as String,
    description: j['description'] as String? ?? '',
    capabilities: _strings(j['capabilities']),
    status: j['status'] as String,
    reason: j['reason'] as String? ?? '',
    instances: [
      for (final i in j['instances'] as List? ?? const [])
        AdapterInstance(
          id: _obj(i)['id'] as String,
          label: _obj(i)['label'] as String? ?? '',
          target: _obj(i)['target'] as String? ?? '',
          allow: _strings(_obj(i)['allow']),
          usedBy: _obj(i)['usedBy'] as String? ?? '',
        ),
    ],
  );

  final String id;
  final String label;
  final String description;
  final List<String> capabilities;
  final String status;
  final String reason;
  final List<AdapterInstance> instances;

  bool get controls => capabilities.contains('control');
}

/// Fields of a new bot (or of an edit; null fields are not sent on edit).
class BotDraft {
  BotDraft({
    this.entityId,
    this.name = '',
    this.type = 'telegram_bot',
    this.description = '',
    this.tags = const [],
    this.hostId,
    this.dependsOn = const [],
    this.runtime,
    this.category = '',
    this.controllerId = '',
    this.n8nInstanceId = '',
    this.n8nWorkflowIds = const [],
    this.telegramTokenId = '',
    this.container = '',
    this.heartbeatIntervalSec = 15,
    this.heartbeatTimeoutSec = 60,
    this.logSource,
    this.notes = '',
    this.createCredential = true,
  });

  String? entityId;
  String name;
  String type;
  String description;
  List<String> tags;
  String? hostId;
  List<String> dependsOn;
  String? runtime;
  String category;
  String controllerId;
  String n8nInstanceId;
  List<String> n8nWorkflowIds;
  String telegramTokenId;
  String container;
  int heartbeatIntervalSec;
  int heartbeatTimeoutSec;
  String? logSource;
  String notes;
  bool createCredential;

  Map<String, Object?> toCreateJson() => {
    if (entityId != null)
      'entityId': entityId
    else ...{
      'name': name.trim(),
      'type': type,
      'description': description.trim(),
      'tags': tags,
    },
    'hostId': ?hostId,
    'dependsOn': dependsOn,
    'runtime': ?runtime,
    'category': category.trim(),
    'controllerId': controllerId,
    'n8nInstanceId': n8nInstanceId,
    'n8nWorkflowIds': n8nWorkflowIds,
    'telegramTokenId': telegramTokenId,
    'container': container.trim(),
    'heartbeatIntervalSec': heartbeatIntervalSec,
    'heartbeatTimeoutSec': heartbeatTimeoutSec,
    'logSource': ?logSource,
    'notes': notes,
    'createCredential': createCredential,
  };

  factory BotDraft.of(Bot b) => BotDraft(
    entityId: b.entityId,
    name: b.name,
    type: b.type,
    description: b.description,
    tags: b.tags,
    hostId: b.host?.id,
    runtime: b.runtime,
    category: b.category,
    controllerId: b.controllerId,
    n8nInstanceId: b.n8nInstanceId,
    n8nWorkflowIds: b.n8nWorkflowIds,
    telegramTokenId: b.telegramTokenId,
    container: b.container,
    heartbeatIntervalSec: b.heartbeat.intervalSec,
    heartbeatTimeoutSec: b.heartbeat.timeoutSec,
    logSource: b.logSource,
    notes: b.notes,
    createCredential: false,
  );

  Map<String, Object?> toPatchJson(int revision) => {
    'revision': revision,
    'name': name.trim(),
    'description': description.trim(),
    'tags': tags,
    'hostId': hostId ?? '',
    'runtime': ?runtime,
    'category': category.trim(),
    'controllerId': controllerId,
    'n8nInstanceId': n8nInstanceId,
    'n8nWorkflowIds': n8nWorkflowIds,
    'telegramTokenId': telegramTokenId,
    'container': container.trim(),
    'heartbeatIntervalSec': heartbeatIntervalSec,
    'heartbeatTimeoutSec': heartbeatTimeoutSec,
    'logSource': ?logSource,
    'notes': notes,
  };
}

abstract interface class BotsApi {
  Future<List<BotAdapter>> adapters();
  Future<List<Bot>> list({String archived = 'false'});
  Future<BotDetail> get(String id);

  /// Returns the bot and the heartbeat token (shown once; may be empty).
  Future<(BotDetail, String)> create(BotDraft d);
  Future<BotDetail> update(String id, BotDraft d, int revision);
  Future<BotDetail> setArchived(String id, bool archived);
  Future<String> issueCredential(String id);
  Future<JobPage> jobs(String id, {String? status, String? before});
  Future<LogPage> logs(String id, {String? level, String q = '', int? before});
  Future<List<MonEvent>> activity(String id);
  Future<BotConfirmation> confirm(String id, String action, {String? jobId});
  Future<BotActionRecord> execute(
    String id,
    String action, {
    required String idempotencyKey,
    String? confirmationToken,
    String? jobId,
  });
  Future<List<BotActionRecord>> audit(String id);
}

class HttpBotsApi implements BotsApi {
  HttpBotsApi(this._client);
  final CoreClient _client;

  Future<Object?> _get(String path, [Map<String, Object?>? q]) =>
      _client.request('GET', path, query: q);

  @override
  Future<List<BotAdapter>> adapters() async => [
    for (final a in await _get('/bots/adapters') as List)
      BotAdapter.fromJson(_obj(a)),
  ];

  @override
  Future<List<Bot>> list({String archived = 'false'}) async => [
    for (final b in await _get('/bots', {'archived': archived}) as List)
      Bot.fromJson(_obj(b)),
  ];

  @override
  Future<BotDetail> get(String id) async =>
      BotDetail.fromJson(_obj(await _get('/bots/$id')));

  @override
  Future<(BotDetail, String)> create(BotDraft d) async {
    final m = _obj(
      await _client.request('POST', '/bots', body: d.toCreateJson()),
    );
    return (
      BotDetail.fromJson(_obj(m['bot'])),
      m['heartbeatToken'] as String? ?? '',
    );
  }

  @override
  Future<BotDetail> update(String id, BotDraft d, int revision) async =>
      BotDetail.fromJson(
        _obj(
          await _client.request(
            'PATCH',
            '/bots/$id',
            body: d.toPatchJson(revision),
          ),
        ),
      );

  @override
  Future<BotDetail> setArchived(String id, bool archived) async =>
      BotDetail.fromJson(
        _obj(
          await _client.request(
            'POST',
            '/bots/$id/${archived ? 'archive' : 'restore'}',
          ),
        ),
      );

  @override
  Future<String> issueCredential(String id) async =>
      _obj(await _client.request('POST', '/bots/$id/credentials'))['token']
          as String;

  @override
  Future<JobPage> jobs(String id, {String? status, String? before}) async {
    final m = _obj(
      await _get('/bots/$id/jobs', {
        'status': ?status,
        'before': ?before,
        'limit': 50,
      }),
    );
    return JobPage(
      [for (final j in m['items'] as List) BotJob.fromJson(_obj(j))],
      m['nextBefore'] as String?,
      m['total'] as int,
    );
  }

  @override
  Future<LogPage> logs(
    String id, {
    String? level,
    String q = '',
    int? before,
  }) async {
    final m = _obj(
      await _get('/bots/$id/logs', {
        'level': ?level,
        if (q.trim().isNotEmpty) 'q': q.trim(),
        'before': ?before,
        'limit': 100,
      }),
    );
    return LogPage([
      for (final l in m['items'] as List) LogEntry.fromJson(_obj(l)),
    ], m['nextBefore'] as int?);
  }

  @override
  Future<List<MonEvent>> activity(String id) async => [
    for (final e in await _get('/bots/$id/activity', {'limit': 100}) as List)
      MonEvent.fromJson(_obj(e)),
  ];

  @override
  Future<BotConfirmation> confirm(
    String id,
    String action, {
    String? jobId,
  }) async => BotConfirmation.fromJson(
    _obj(
      await _client.request(
        'POST',
        '/bots/$id/actions/$action/confirm',
        body: {'jobId': ?jobId},
      ),
    ),
  );

  @override
  Future<BotActionRecord> execute(
    String id,
    String action, {
    required String idempotencyKey,
    String? confirmationToken,
    String? jobId,
  }) async => BotActionRecord.fromJson(
    _obj(
      await _client.request(
        'POST',
        '/bots/$id/actions/$action',
        headers: {'Idempotency-Key': idempotencyKey},
        body: {'confirmationToken': ?confirmationToken, 'jobId': ?jobId},
      ),
    ),
  );

  @override
  Future<List<BotActionRecord>> audit(String id) async => [
    for (final r in await _get('/bots/$id/audit') as List)
      BotActionRecord.fromJson(_obj(r)),
  ];
}

final _rnd = Random.secure();

/// One key per user intent: a retried request (network glitch, double
/// click) carries the same key and Core runs the action only once.
String newIdempotencyKey() =>
    'ui-${DateTime.now().millisecondsSinceEpoch}-${List.generate(12, (_) => _rnd.nextInt(36).toRadixString(36)).join()}';
