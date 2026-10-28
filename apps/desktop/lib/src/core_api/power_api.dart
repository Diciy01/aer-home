import 'core_client.dart';
import 'bots_api.dart' show newIdempotencyKey;

/// AER Power (contract 0.9.0). Core sends Wake-on-LAN; shutdown, reboot,
/// suspend and the one-time OS switch run on the computer's own agent
/// through fixed adapters. The client only names an action from a closed
/// list — never a command.

DateTime? _time(Object? v) => v is String ? DateTime.parse(v) : null;

Map<String, dynamic> _obj(Object? v) => v as Map<String, dynamic>;

List<Map<String, dynamic>> _list(Object? v) => [
  for (final x in (v as List?) ?? const []) x as Map<String, dynamic>,
];

const osLabels = {'linux': 'Ubuntu', 'windows': 'Windows'};

String osLabel(String os) => osLabels[os] ?? (os.isEmpty ? '—' : os);

enum PowerAction {
  wake,
  shutdown,
  reboot,
  suspend,
  switchOs,
  check;

  String get wire => this == switchOs ? 'switch_os' : name;

  static PowerAction? parse(Object? v) => switch (v) {
    'switch_os' => switchOs,
    final String s => PowerAction.values.where((a) => a.name == s).firstOrNull,
    _ => null,
  };

  String get label => switch (this) {
    wake => 'Включить',
    shutdown => 'Выключить',
    reboot => 'Перезагрузить',
    suspend => 'Сон',
    switchOs => 'Сменить ОС',
    check => 'Проверить',
  };
}

enum JobState {
  queued,
  sent,
  waiting,
  succeeded,
  failed,
  timeout,
  cancelled,
  simulated,
  rejected;

  static JobState parse(Object? v) =>
      JobState.values.where((s) => s.name == v).firstOrNull ?? failed;

  bool get terminal => index >= succeeded.index;

  String get label => switch (this) {
    queued => 'В очереди — ждёт агента',
    sent => 'Передано агенту',
    waiting => 'Выполняется — ждём результат',
    succeeded => 'Выполнено',
    failed => 'Ошибка',
    timeout => 'Нет подтверждения — состояние неизвестно',
    cancelled => 'Отменено',
    simulated => 'SIMULATED — ничего не выполнено',
    rejected => 'Отклонено',
  };
}

class WoLTarget {
  const WoLTarget({
    required this.mac,
    this.broadcast = '255.255.255.255',
    this.interface = '',
    this.port = 0,
  });

  factory WoLTarget.fromJson(Map<String, dynamic> j) => WoLTarget(
    mac: j['mac'] as String? ?? '',
    broadcast: j['broadcast'] as String? ?? '',
    interface: j['interface'] as String? ?? '',
    port: j['port'] as int? ?? 0,
  );

  final String mac;
  final String broadcast;
  final String interface;
  final int port;

  Map<String, Object?> toJson() => {
    'mac': mac,
    'broadcast': broadcast,
    'interface': interface,
    'port': port,
  };
}

class PowerPolicy {
  const PowerPolicy({
    this.enabled = true,
    this.wake = true,
    this.shutdown = true,
    this.reboot = true,
    this.suspend = true,
    this.switchOs = false,
    this.allowWithBitLocker = false,
    this.revision = 0,
  });

  factory PowerPolicy.fromJson(Map<String, dynamic> j) => PowerPolicy(
    enabled: j['enabled'] == true,
    wake: j['wake'] == true,
    shutdown: j['shutdown'] == true,
    reboot: j['reboot'] == true,
    suspend: j['suspend'] == true,
    switchOs: j['switchOs'] == true,
    allowWithBitLocker: j['allowWithBitLocker'] == true,
    revision: j['revision'] as int? ?? 0,
  );

  final bool enabled;
  final bool wake;
  final bool shutdown;
  final bool reboot;
  final bool suspend;
  final bool switchOs;
  final bool allowWithBitLocker;
  final int revision;

  PowerPolicy copyWith({
    bool? enabled,
    bool? wake,
    bool? shutdown,
    bool? reboot,
    bool? suspend,
    bool? switchOs,
    bool? allowWithBitLocker,
  }) => PowerPolicy(
    enabled: enabled ?? this.enabled,
    wake: wake ?? this.wake,
    shutdown: shutdown ?? this.shutdown,
    reboot: reboot ?? this.reboot,
    suspend: suspend ?? this.suspend,
    switchOs: switchOs ?? this.switchOs,
    allowWithBitLocker: allowWithBitLocker ?? this.allowWithBitLocker,
    revision: revision,
  );

  Map<String, Object?> toJson() => {
    'enabled': enabled,
    'wake': wake,
    'shutdown': shutdown,
    'reboot': reboot,
    'suspend': suspend,
    'switchOs': switchOs,
    'allowWithBitLocker': allowWithBitLocker,
    'revision': revision,
  };
}

class PowerTarget {
  const PowerTarget({
    required this.os,
    required this.label,
    required this.entryId,
    required this.available,
    required this.reason,
  });

  factory PowerTarget.fromJson(Map<String, dynamic> j) => PowerTarget(
    os: j['os'] as String? ?? '',
    label: j['label'] as String? ?? '',
    entryId: j['entryId'] as String? ?? '',
    available: j['available'] == true,
    reason: j['reason'] as String? ?? '',
  );

  final String os;
  final String label;
  final String entryId;
  final bool available;
  final String reason;
}

class PowerActionInfo {
  const PowerActionInfo({
    required this.action,
    required this.label,
    required this.available,
    required this.reason,
    this.dangerous = false,
    this.targets = const [],
  });

  factory PowerActionInfo.fromJson(Map<String, dynamic> j) => PowerActionInfo(
    action: PowerAction.parse(j['id']) ?? PowerAction.check,
    label: j['label'] as String? ?? '',
    available: j['available'] == true,
    reason: j['reason'] as String? ?? '',
    dangerous: j['dangerous'] == true,
    targets: [for (final t in _list(j['targets'])) PowerTarget.fromJson(t)],
  );

  final PowerAction action;
  final String label;
  final bool available;
  final String reason;
  final bool dangerous;
  final List<PowerTarget> targets;
}

class PowerAgentInfo {
  const PowerAgentInfo({
    required this.agentId,
    required this.name,
    required this.active,
    required this.lastHelloAt,
    required this.os,
    this.hostname = '',
    this.dryRun = true,
    this.firmware = 'unknown',
    this.secureBoot = 'unknown',
    this.bitlocker = 'unknown',
    this.bootManager = 'unknown',
  });

  factory PowerAgentInfo.fromJson(Map<String, dynamic> j) {
    final i = _obj(j['info'] ?? const <String, dynamic>{});
    return PowerAgentInfo(
      agentId: j['agentId'] as String? ?? '',
      name: j['name'] as String? ?? '',
      active: j['active'] == true,
      lastHelloAt: _time(j['lastHelloAt']),
      os: i['os'] as String? ?? '',
      hostname: i['hostname'] as String? ?? '',
      dryRun: i['dryRun'] == true,
      firmware: i['firmware'] as String? ?? 'unknown',
      secureBoot: i['secureBoot'] as String? ?? 'unknown',
      bitlocker: i['bitlocker'] as String? ?? 'unknown',
      bootManager: i['bootManager'] as String? ?? 'unknown',
    );
  }

  final String agentId;
  final String name;
  final bool active;
  final DateTime? lastHelloAt;
  final String os;
  final String hostname;
  final bool dryRun;
  final String firmware;
  final String secureBoot;
  final String bitlocker;
  final String bootManager;
}

class PowerEvent {
  const PowerEvent(this.at, this.kind, this.message);
  final DateTime at;
  final String kind;
  final String message;
}

class PowerJob {
  const PowerJob({
    required this.id,
    required this.entityId,
    required this.deviceName,
    required this.action,
    required this.state,
    required this.message,
    required this.requestedAt,
    this.targetOs = '',
    this.fromOs = '',
    this.simulated = false,
    this.replayed = false,
    this.finishedAt,
    this.deadline,
    this.events = const [],
  });

  factory PowerJob.fromJson(Map<String, dynamic> j) => PowerJob(
    id: j['id'] as String,
    entityId: j['entityId'] as String? ?? '',
    deviceName: j['deviceName'] as String? ?? '',
    action: PowerAction.parse(j['action']) ?? PowerAction.check,
    state: JobState.parse(j['state']),
    message: j['message'] as String? ?? '',
    requestedAt: _time(j['requestedAt']) ?? DateTime.now(),
    targetOs: j['targetOs'] as String? ?? '',
    fromOs: j['fromOs'] as String? ?? '',
    simulated: j['simulated'] == true,
    replayed: j['replayed'] == true,
    finishedAt: _time(j['finishedAt']),
    deadline: _time(j['deadline']),
    events: [
      for (final e in _list(j['events']))
        PowerEvent(
          _time(e['at']) ?? DateTime.now(),
          e['kind'] as String? ?? '',
          e['message'] as String? ?? '',
        ),
    ],
  );

  final String id;
  final String entityId;
  final String deviceName;
  final PowerAction action;
  final JobState state;
  final String message;
  final DateTime requestedAt;
  final String targetOs;
  final String fromOs;
  final bool simulated;
  final bool replayed;
  final DateTime? finishedAt;
  final DateTime? deadline;
  final List<PowerEvent> events;

  String get title => action == PowerAction.switchOs
      ? 'Сменить ОС: ${osLabel(fromOs)} → ${osLabel(targetOs)}'
      : action.label;
}

class PowerDevice {
  const PowerDevice({
    required this.entityId,
    required this.name,
    required this.type,
    required this.state,
    required this.stateReason,
    this.currentOs = '',
    this.lastContactAt,
    this.monitoringStatus = '',
    this.wol,
    this.sameMachine = false,
    this.sameMachineNote = '',
    this.agents = const [],
    this.policy = const PowerPolicy(),
    this.actions = const [],
    this.activeJob,
    this.lastJob,
  });

  factory PowerDevice.fromJson(Map<String, dynamic> j) => PowerDevice(
    entityId: j['entityId'] as String,
    name: j['name'] as String? ?? '',
    type: j['type'] as String? ?? '',
    state: j['state'] as String? ?? 'unknown',
    stateReason: j['stateReason'] as String? ?? '',
    currentOs: j['currentOs'] as String? ?? '',
    lastContactAt: _time(j['lastContactAt']),
    monitoringStatus: j['monitoringStatus'] as String? ?? '',
    wol: j['wol'] == null ? null : WoLTarget.fromJson(_obj(j['wol'])),
    sameMachine: j['sameMachineAsCore'] == true,
    sameMachineNote: j['sameMachineNote'] as String? ?? '',
    agents: [for (final a in _list(j['agents'])) PowerAgentInfo.fromJson(a)],
    policy: PowerPolicy.fromJson(
      _obj(j['policy'] ?? const <String, dynamic>{}),
    ),
    actions: [for (final a in _list(j['actions'])) PowerActionInfo.fromJson(a)],
    activeJob: j['activeJob'] == null
        ? null
        : PowerJob.fromJson(_obj(j['activeJob'])),
    lastJob: j['lastJob'] == null
        ? null
        : PowerJob.fromJson(_obj(j['lastJob'])),
  );

  final String entityId;
  final String name;
  final String type;

  /// online | offline | waking | shutting_down | rebooting | switching |
  /// suspending | unknown
  final String state;
  final String stateReason;
  final String currentOs;
  final DateTime? lastContactAt;
  final String monitoringStatus;
  final WoLTarget? wol;
  final bool sameMachine;
  final String sameMachineNote;
  final List<PowerAgentInfo> agents;
  final PowerPolicy policy;
  final List<PowerActionInfo> actions;
  final PowerJob? activeJob;
  final PowerJob? lastJob;

  PowerActionInfo? action(PowerAction a) =>
      actions.where((x) => x.action == a).firstOrNull;

  PowerAgentInfo? get activeAgent => agents.where((a) => a.active).firstOrNull;

  String get stateLabel => switch (state) {
    'online' => 'Включён',
    'offline' => 'Не отвечает',
    'waking' => 'Включается',
    'shutting_down' => 'Выключается',
    'rebooting' => 'Перезагружается',
    'switching' => 'Переключает ОС',
    'suspending' => 'Засыпает',
    _ => 'Неизвестно',
  };
}

class PowerCheck {
  const PowerCheck(this.name, this.ok, this.message);
  final String name;
  final bool ok;
  final String message;
}

class PowerConfirmation {
  const PowerConfirmation({
    required this.token,
    required this.summary,
    required this.risks,
    required this.checks,
    required this.expiresAt,
    this.targetOs = '',
  });

  factory PowerConfirmation.fromJson(Map<String, dynamic> j) =>
      PowerConfirmation(
        token: j['token'] as String,
        summary: j['summary'] as String? ?? '',
        risks: [for (final r in (j['risks'] as List?) ?? const []) '$r'],
        checks: [
          for (final c in _list(j['checks']))
            PowerCheck(
              c['name'] as String? ?? '',
              c['ok'] == true,
              c['message'] as String? ?? '',
            ),
        ],
        expiresAt: _time(j['expiresAt']) ?? DateTime.now(),
        targetOs: j['targetOs'] as String? ?? '',
      );

  final String token;
  final String summary;
  final List<String> risks;
  final List<PowerCheck> checks;
  final DateTime expiresAt;
  final String targetOs;
}

class PowerInterface {
  const PowerInterface({
    required this.name,
    this.mac = '',
    this.addresses = const [],
    this.broadcasts = const [],
    this.up = false,
    this.loopback = false,
  });

  factory PowerInterface.fromJson(Map<String, dynamic> j) => PowerInterface(
    name: j['name'] as String? ?? '',
    mac: j['mac'] as String? ?? '',
    addresses: [for (final a in (j['addresses'] as List?) ?? const []) '$a'],
    broadcasts: [for (final a in (j['broadcasts'] as List?) ?? const []) '$a'],
    up: j['up'] == true,
    loopback: j['loopback'] == true,
  );

  final String name;
  final String mac;
  final List<String> addresses;
  final List<String> broadcasts;
  final bool up;
  final bool loopback;
}

typedef PowerNet = ({
  List<PowerInterface> interfaces,
  bool wolEnabled,
  int defaultPort,
});

abstract interface class PowerApi {
  Future<List<PowerDevice>> devices();
  Future<PowerDevice> device(String entityId);
  Future<PowerDevice> setPolicy(String entityId, PowerPolicy p);
  Future<PowerDevice> setWoL(String entityId, WoLTarget t);
  Future<PowerDevice> deleteWoL(String entityId);
  Future<PowerConfirmation> confirm(
    String entityId,
    PowerAction action, {
    String targetOs = '',
  });
  Future<PowerJob> execute(
    String entityId,
    PowerAction action, {
    required String idempotencyKey,
    String confirmationToken = '',
    String targetOs = '',
  });
  Future<List<PowerJob>> jobs({String? entityId, int limit = 50});
  Future<PowerJob> job(String id);
  Future<PowerJob> cancel(String id);
  Future<PowerNet> interfaces();
}

class HttpPowerApi implements PowerApi {
  HttpPowerApi(this._client);
  final CoreClient _client;

  PowerDevice _dev(Object? v) => PowerDevice.fromJson(_obj(v));

  @override
  Future<List<PowerDevice>> devices() async => [
    for (final d in await _client.request('GET', '/power/devices') as List)
      _dev(d),
  ];

  @override
  Future<PowerDevice> device(String entityId) async =>
      _dev(await _client.request('GET', '/power/devices/$entityId'));

  @override
  Future<PowerDevice> setPolicy(String entityId, PowerPolicy p) async => _dev(
    await _client.request(
      'PUT',
      '/power/devices/$entityId/policy',
      body: p.toJson(),
    ),
  );

  @override
  Future<PowerDevice> setWoL(String entityId, WoLTarget t) async => _dev(
    await _client.request(
      'PUT',
      '/power/devices/$entityId/wol',
      body: t.toJson(),
    ),
  );

  @override
  Future<PowerDevice> deleteWoL(String entityId) async =>
      _dev(await _client.request('DELETE', '/power/devices/$entityId/wol'));

  @override
  Future<PowerConfirmation> confirm(
    String entityId,
    PowerAction action, {
    String targetOs = '',
  }) async => PowerConfirmation.fromJson(
    _obj(
      await _client.request(
        'POST',
        '/power/devices/$entityId/actions/${action.wire}/confirm',
        body: {if (targetOs.isNotEmpty) 'targetOs': targetOs},
      ),
    ),
  );

  @override
  Future<PowerJob> execute(
    String entityId,
    PowerAction action, {
    required String idempotencyKey,
    String confirmationToken = '',
    String targetOs = '',
  }) async => PowerJob.fromJson(
    _obj(
      await _client.request(
        'POST',
        '/power/devices/$entityId/actions/${action.wire}',
        headers: {'Idempotency-Key': idempotencyKey},
        body: {
          if (confirmationToken.isNotEmpty)
            'confirmationToken': confirmationToken,
          if (targetOs.isNotEmpty) 'targetOs': targetOs,
        },
      ),
    ),
  );

  @override
  Future<List<PowerJob>> jobs({String? entityId, int limit = 50}) async => [
    for (final j in await _client.request(
      'GET',
      '/power/jobs',
      query: {'entityId': ?entityId, 'limit': limit},
    ) as List)
      PowerJob.fromJson(_obj(j)),
  ];

  @override
  Future<PowerJob> job(String id) async =>
      PowerJob.fromJson(_obj(await _client.request('GET', '/power/jobs/$id')));

  @override
  Future<PowerJob> cancel(String id) async => PowerJob.fromJson(
    _obj(await _client.request('POST', '/power/jobs/$id/cancel')),
  );

  @override
  Future<PowerNet> interfaces() async {
    final m = _obj(await _client.request('GET', '/power/interfaces'));
    return (
      interfaces: [
        for (final i in _list(m['interfaces'])) PowerInterface.fromJson(i),
      ],
      wolEnabled: m['wolEnabled'] == true,
      defaultPort: m['defaultPort'] as int? ?? 9,
    );
  }
}

String newPowerKey() => newIdempotencyKey();
