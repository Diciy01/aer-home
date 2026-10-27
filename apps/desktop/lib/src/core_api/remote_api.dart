import 'core_client.dart';
import 'monitoring_api.dart';
import 'bots_api.dart' show newIdempotencyKey;

/// AER Remote (contract 0.8.0). Core is the control plane only: video,
/// input and clipboard go client ↔ host over RDP, files go to the host
/// agent directly.

DateTime? _time(Object? v) => v is String ? DateTime.parse(v) : null;

Map<String, dynamic> _obj(Object? v) => v as Map<String, dynamic>;

MonStatus _status(Object? v) =>
    MonStatus.values.where((s) => s.name == v).firstOrNull ?? MonStatus.unknown;

enum RemoteState {
  pending,
  awaitingApproval,
  connecting,
  connected,
  reconnecting,
  disconnected,
  failed,
  expired,
  revoked;

  static RemoteState parse(Object? v) => switch (v) {
    'awaiting_approval' => awaitingApproval,
    final String s =>
      RemoteState.values.where((x) => x.name == s).firstOrNull ?? failed,
    _ => failed,
  };

  bool get terminal => index >= disconnected.index;

  String get label => switch (this) {
    pending => 'Запрошен',
    awaitingApproval => 'Ждём подтверждения на компьютере',
    connecting => 'Подключение',
    connected => 'Подключено',
    reconnecting => 'Связь прервана, ждём переподключения',
    disconnected => 'Завершён',
    failed => 'Ошибка',
    expired => 'Истёк',
    revoked => 'Отозван',
  };
}

class RemoteCaps {
  const RemoteCaps({
    this.desktop = false,
    this.input = false,
    this.clipboard = false,
    this.files = false,
    this.apps = false,
  });

  factory RemoteCaps.fromJson(Object? v) {
    final j = v as Map<String, dynamic>? ?? const {};
    return RemoteCaps(
      desktop: j['desktop'] == true,
      input: j['input'] == true,
      clipboard: j['clipboard'] == true,
      files: j['files'] == true,
      apps: j['apps'] == true,
    );
  }

  final bool desktop;
  final bool input;
  final bool clipboard;
  final bool files;
  final bool apps;
}

class RemotePolicy {
  const RemotePolicy({
    this.enabled = true,
    this.desktop = true,
    this.clipboard = true,
    this.files = false,
    this.maxMinutes = 60,
    this.revision = 0,
  });

  factory RemotePolicy.fromJson(Map<String, dynamic> j) => RemotePolicy(
    enabled: j['enabled'] == true,
    desktop: j['desktop'] == true,
    clipboard: j['clipboard'] == true,
    files: j['files'] == true,
    maxMinutes: j['maxMinutes'] as int? ?? 60,
    revision: j['revision'] as int? ?? 0,
  );

  final bool enabled;
  final bool desktop;
  final bool clipboard;
  final bool files;
  final int maxMinutes;
  final int revision;

  RemotePolicy copyWith({
    bool? enabled,
    bool? clipboard,
    bool? files,
    int? maxMinutes,
  }) => RemotePolicy(
    enabled: enabled ?? this.enabled,
    desktop: desktop,
    clipboard: clipboard ?? this.clipboard,
    files: files ?? this.files,
    maxMinutes: maxMinutes ?? this.maxMinutes,
    revision: revision,
  );

  Map<String, Object?> toJson() => {
    'enabled': enabled,
    'desktop': desktop,
    'clipboard': clipboard,
    'files': files,
    'maxMinutes': maxMinutes,
    'revision': revision,
  };
}

class RemoteHostAgent {
  const RemoteHostAgent({
    required this.os,
    required this.backend,
    required this.address,
    required this.port,
    required this.caps,
    required this.approval,
    required this.ready,
    required this.reason,
    this.version = '',
    this.monitors = 1,
  });

  factory RemoteHostAgent.fromJson(Map<String, dynamic> j) => RemoteHostAgent(
    os: j['os'] as String? ?? '',
    backend: j['backend'] as String? ?? '',
    address: j['address'] as String? ?? '',
    port: j['port'] as int? ?? 0,
    caps: RemoteCaps.fromJson(j['capabilities']),
    approval: j['approval'] as String? ?? 'auto',
    ready: j['ready'] == true,
    reason: j['reason'] as String? ?? '',
    version: j['version'] as String? ?? '',
    monitors: j['monitors'] as int? ?? 1,
  );

  final String os;
  final String backend;
  final String address;
  final int port;
  final RemoteCaps caps;
  final String approval;
  final bool ready;
  final String reason;
  final String version;
  final int monitors;
}

class RemoteSession {
  const RemoteSession({
    required this.id,
    required this.entityId,
    required this.state,
    required this.createdAt,
    required this.expiresAt,
    this.hostName = '',
    this.sourceName = '',
    this.transport = 'rdp',
    this.reason = '',
    this.allowed = const RemoteCaps(),
    this.connectedAt,
    this.endedAt,
    this.events = const [],
  });

  factory RemoteSession.fromJson(Map<String, dynamic> j) => RemoteSession(
    id: j['id'] as String,
    entityId: j['entityId'] as String,
    state: RemoteState.parse(j['state']),
    createdAt: DateTime.parse(j['createdAt'] as String),
    expiresAt: DateTime.parse(j['expiresAt'] as String),
    hostName: j['hostName'] as String? ?? '',
    sourceName: j['sourceName'] as String? ?? '',
    transport: j['transport'] as String? ?? 'rdp',
    reason: j['reason'] as String? ?? '',
    allowed: RemoteCaps.fromJson(j['allowed']),
    connectedAt: _time(j['connectedAt']),
    endedAt: _time(j['endedAt']),
    events: [
      for (final e in j['events'] as List? ?? const [])
        (
          at: DateTime.parse(_obj(e)['at'] as String),
          kind: _obj(e)['kind'] as String,
          message: _obj(e)['message'] as String,
        ),
    ],
  );

  final String id;
  final String entityId;
  final RemoteState state;
  final DateTime createdAt;
  final DateTime expiresAt;
  final String hostName;
  final String sourceName;
  final String transport;
  final String reason;
  final RemoteCaps allowed;
  final DateTime? connectedAt;
  final DateTime? endedAt;
  final List<({DateTime at, String kind, String message})> events;
}

class RemoteHost {
  const RemoteHost({
    required this.entityId,
    required this.name,
    required this.type,
    required this.policy,
    required this.effective,
    required this.canConnect,
    required this.reason,
    required this.status,
    this.declared = const [],
    this.agent,
    this.agentActive = false,
    this.lastHelloAt,
    this.certSha256 = '',
    this.statusReason = '',
    this.lastContactAt,
    this.activeSession,
    this.lastSession,
  });

  factory RemoteHost.fromJson(Map<String, dynamic> j) => RemoteHost(
    entityId: j['entityId'] as String,
    name: j['name'] as String,
    type: j['type'] as String,
    policy: RemotePolicy.fromJson(_obj(j['policy'])),
    effective: RemoteCaps.fromJson(j['effective']),
    canConnect: j['canConnect'] == true,
    reason: j['reason'] as String? ?? '',
    status: _status(j['status']),
    declared: [for (final c in j['declaredCapabilities'] as List? ?? []) '$c'],
    agent: j['agent'] == null
        ? null
        : RemoteHostAgent.fromJson(_obj(j['agent'])),
    agentActive: j['agentActive'] == true,
    lastHelloAt: _time(j['lastHelloAt']),
    certSha256: j['certSha256'] as String? ?? '',
    statusReason: j['statusReason'] as String? ?? '',
    lastContactAt: _time(j['lastContactAt']),
    activeSession: j['activeSession'] == null
        ? null
        : RemoteSession.fromJson(_obj(j['activeSession'])),
    lastSession: j['lastSession'] == null
        ? null
        : RemoteSession.fromJson(_obj(j['lastSession'])),
  );

  final String entityId;
  final String name;
  final String type;
  final RemotePolicy policy;
  final RemoteCaps effective;
  final bool canConnect;
  final String reason;
  final MonStatus status;
  final List<String> declared;
  final RemoteHostAgent? agent;
  final bool agentActive;
  final DateTime? lastHelloAt;
  final String certSha256;
  final String statusReason;
  final DateTime? lastContactAt;
  final RemoteSession? activeSession;
  final RemoteSession? lastSession;
}

/// One-time connection data. Lives only in memory of the client.
class RemoteGrant {
  const RemoteGrant({
    required this.sessionId,
    required this.host,
    required this.port,
    required this.username,
    required this.password,
    required this.certPem,
    required this.certSha256,
    required this.clipboard,
    required this.expiresAt,
    this.filesUrl,
    this.filesToken,
    this.filesMaxBytes = 0,
  });

  factory RemoteGrant.fromJson(Map<String, dynamic> j) {
    final f = j['files'] as Map<String, dynamic>?;
    return RemoteGrant(
      sessionId: j['sessionId'] as String,
      host: j['host'] as String,
      port: j['port'] as int,
      username: j['username'] as String? ?? '',
      password: j['password'] as String? ?? '',
      certPem: j['certPem'] as String? ?? '',
      certSha256: j['certSha256'] as String? ?? '',
      clipboard: j['clipboard'] == true,
      expiresAt: DateTime.parse(j['expiresAt'] as String),
      filesUrl: f?['url'] as String?,
      filesToken: f?['token'] as String?,
      filesMaxBytes: f?['maxBytes'] as int? ?? 0,
    );
  }

  final String sessionId;
  final String host;
  final int port;
  final String username;
  final String password;
  final String certPem;
  final String certSha256;
  final bool clipboard;
  final DateTime expiresAt;
  final String? filesUrl;
  final String? filesToken;
  final int filesMaxBytes;
}

abstract interface class RemoteApi {
  Future<List<RemoteHost>> hosts();
  Future<RemoteHost> setPolicy(String entityId, RemotePolicy p);
  Future<List<RemoteSession>> sessions({String? entityId, int limit = 50});
  Future<RemoteSession> session(String id);
  Future<RemoteSession> create(
    String entityId, {
    required String sourceName,
    required String idempotencyKey,
    bool clipboard = true,
    bool files = true,
  });
  Future<RemoteGrant> grant(String id);
  Future<RemoteSession> end(String id);
  Future<RemoteSession> revoke(String id);
  Future<({String status, String reason})> apps(String entityId);
}

class HttpRemoteApi implements RemoteApi {
  HttpRemoteApi(this._client);
  final CoreClient _client;

  @override
  Future<List<RemoteHost>> hosts() async => [
    for (final h in await _client.request('GET', '/remote/hosts') as List)
      RemoteHost.fromJson(_obj(h)),
  ];

  @override
  Future<RemoteHost> setPolicy(String entityId, RemotePolicy p) async =>
      RemoteHost.fromJson(
        _obj(
          await _client.request(
            'PUT',
            '/remote/hosts/$entityId/policy',
            body: p.toJson(),
          ),
        ),
      );

  @override
  Future<List<RemoteSession>> sessions({
    String? entityId,
    int limit = 50,
  }) async => [
    for (final s in await _client.request(
      'GET',
      '/remote/sessions',
      query: {'entityId': ?entityId, 'limit': limit},
    ) as List)
      RemoteSession.fromJson(_obj(s)),
  ];

  @override
  Future<RemoteSession> session(String id) async => RemoteSession.fromJson(
    _obj(await _client.request('GET', '/remote/sessions/$id')),
  );

  @override
  Future<RemoteSession> create(
    String entityId, {
    required String sourceName,
    required String idempotencyKey,
    bool clipboard = true,
    bool files = true,
  }) async => RemoteSession.fromJson(
    _obj(
      await _client.request(
        'POST',
        '/remote/sessions',
        headers: {'Idempotency-Key': idempotencyKey},
        body: {
          'entityId': entityId,
          'kind': 'desktop',
          'sourceName': sourceName,
          'clipboard': clipboard,
          'files': files,
        },
      ),
    ),
  );

  @override
  Future<RemoteGrant> grant(String id) async => RemoteGrant.fromJson(
    _obj(await _client.request('POST', '/remote/sessions/$id/grant')),
  );

  @override
  Future<RemoteSession> end(String id) async => RemoteSession.fromJson(
    _obj(await _client.request('POST', '/remote/sessions/$id/end')),
  );

  @override
  Future<RemoteSession> revoke(String id) async => RemoteSession.fromJson(
    _obj(await _client.request('POST', '/remote/sessions/$id/revoke')),
  );

  @override
  Future<({String status, String reason})> apps(String entityId) async {
    final m = _obj(
      await _client.request('GET', '/remote/hosts/$entityId/apps'),
    );
    return (status: m['status'] as String, reason: m['reason'] as String);
  }
}

String newRemoteKey() => newIdempotencyKey();
