/// Session model of AER Remote (contract 0.11.0, ADR-017), as the Gateway
/// shows it to a remote client.
library;

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
    reconnecting => 'Связь прервана, переподключаемся',
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
  });

  factory RemoteCaps.fromJson(Object? v) {
    final j = v as Map<String, dynamic>? ?? const {};
    return RemoteCaps(
      desktop: j['desktop'] == true,
      input: j['input'] == true,
      clipboard: j['clipboard'] == true,
      files: j['files'] == true,
    );
  }

  final bool desktop;
  final bool input;
  final bool clipboard;
  final bool files;
}

/// A computer this client may connect to (no LAN details).
class RemoteHostSummary {
  const RemoteHostSummary({
    required this.entityId,
    required this.name,
    required this.canConnect,
    required this.reason,
    required this.status,
    required this.os,
    required this.effective,
    this.busy = false,
  });

  factory RemoteHostSummary.fromJson(Map<String, dynamic> j) {
    final agent = j['agent'] as Map<String, dynamic>?;
    return RemoteHostSummary(
      entityId: j['entityId'] as String,
      name: j['name'] as String? ?? '',
      canConnect: j['canConnect'] == true,
      reason: j['reason'] as String? ?? '',
      status: j['status'] as String? ?? 'unknown',
      os: agent?['os'] as String? ?? '',
      effective: RemoteCaps.fromJson(j['effective']),
      busy: j['activeSession'] != null,
    );
  }

  final String entityId;
  final String name;
  final bool canConnect;
  final String reason;
  final String status;
  final String os;
  final RemoteCaps effective;
  final bool busy;
}

class RemoteSessionInfo {
  const RemoteSessionInfo({
    required this.id,
    required this.entityId,
    required this.hostName,
    required this.route,
    required this.state,
    required this.reason,
    required this.allowed,
    required this.expiresAt,
  });

  factory RemoteSessionInfo.fromJson(Map<String, dynamic> j) =>
      RemoteSessionInfo(
        id: j['id'] as String,
        entityId: j['entityId'] as String? ?? '',
        hostName: j['hostName'] as String? ?? '',
        route: j['route'] as String? ?? 'direct',
        state: RemoteState.parse(j['state']),
        reason: j['reason'] as String? ?? '',
        allowed: RemoteCaps.fromJson(j['allowed']),
        expiresAt: DateTime.parse(j['expiresAt'] as String),
      );

  final String id;
  final String entityId;
  final String hostName;
  final String route;
  final RemoteState state;
  final String reason;
  final RemoteCaps allowed;
  final DateTime expiresAt;
}

/// One-time connection data of a relay session. Lives only in memory.
class RelayGrant {
  const RelayGrant({
    required this.sessionId,
    required this.username,
    required this.password,
    required this.certPem,
    required this.certSha256,
    required this.clipboard,
    required this.tunnelPath,
    required this.tickets,
    required this.expiresAt,
    this.filesToken,
    this.filesMaxBytes = 0,
  });

  factory RelayGrant.fromJson(Map<String, dynamic> j) {
    if (j['route'] != 'relay' || j['tunnel'] == null) {
      throw const FormatException('Not a relay grant');
    }
    final t = j['tunnel'] as Map<String, dynamic>;
    final f = j['files'] as Map<String, dynamic>?;
    return RelayGrant(
      sessionId: j['sessionId'] as String,
      username: j['username'] as String? ?? '',
      password: j['password'] as String? ?? '',
      certPem: j['certPem'] as String? ?? '',
      certSha256: j['certSha256'] as String? ?? '',
      clipboard: j['clipboard'] == true,
      tunnelPath: t['path'] as String,
      tickets: (t['tickets'] as Map<String, dynamic>).cast<String, String>(),
      expiresAt: DateTime.parse(j['expiresAt'] as String),
      filesToken: f?['token'] as String?,
      filesMaxBytes: f?['maxBytes'] as int? ?? 0,
    );
  }

  final String sessionId;
  final String username;
  final String password;
  final String certPem;

  /// Pin for the end-to-end TLS with the host (RDP and file channel).
  final String certSha256;
  final bool clipboard;
  final String tunnelPath;

  /// channel (rdp, files) → one-time ticket from the grant.
  final Map<String, String> tickets;
  final DateTime expiresAt;
  final String? filesToken;
  final int filesMaxBytes;

  bool get files => filesToken != null && tickets.containsKey('files');
}
