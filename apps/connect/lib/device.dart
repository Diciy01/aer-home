import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

/// AER Connect Anywhere (ADR-018): this installation as a device — its
/// number, credentials and host settings. Kept as one JSON value in the
/// app's DPAPI store; never written anywhere else.
class DeviceProfile {
  DeviceProfile({
    required this.address,
    required this.fingerprint,
    required this.deviceId,
    required this.number,
    required this.name,
    required this.agentToken,
    required this.clientCredential,
    required this.boxKey,
    required this.installId,
    this.permanent,
    this.allowIncoming = true,
    this.clipboard = true,
    this.files = false,
    this.filesDir = '',
    this.viewOnly = false,
  });

  factory DeviceProfile.fromJson(Map<String, dynamic> j) {
    if (j['v'] != 2 ||
        !(j['agentToken'] as String).startsWith('aer1.') ||
        !(j['clientCredential'] as String).startsWith('aerc1.')) {
      throw const FormatException('Invalid device profile');
    }
    return DeviceProfile(
      address: j['address'] as String,
      fingerprint: j['fingerprint'] as String,
      deviceId: j['deviceId'] as String,
      number: j['number'] as String,
      name: j['name'] as String,
      agentToken: j['agentToken'] as String,
      clientCredential: j['clientCredential'] as String,
      boxKey: j['boxKey'] as String,
      installId: j['installId'] as String,
      permanent: (j['permanent'] as Map?)?.cast<String, Object?>(),
      allowIncoming: j['allowIncoming'] != false,
      clipboard: j['clipboard'] != false,
      files: j['files'] == true,
      filesDir: j['filesDir'] as String? ?? '',
      viewOnly: j['viewOnly'] == true,
    );
  }

  final String address, fingerprint, deviceId, number, name;
  final String agentToken, clientCredential, boxKey, installId;

  /// PBKDF2 verifier of the permanent password (never the password).
  Map<String, Object?>? permanent;
  bool allowIncoming, clipboard, files, viewOnly;
  String filesDir;

  Map<String, Object?> toJson() => {
    'v': 2,
    'address': address,
    'fingerprint': fingerprint,
    'deviceId': deviceId,
    'number': number,
    'name': name,
    'agentToken': agentToken,
    'clientCredential': clientCredential,
    'boxKey': boxKey,
    'installId': installId,
    'permanent': permanent,
    'allowIncoming': allowIncoming,
    'clipboard': clipboard,
    'files': files,
    'filesDir': filesDir,
    'viewOnly': viewOnly,
  };

  /// The first line the host process reads (its only source of secrets).
  Map<String, Object?> hostInit(String stateDir, String shadowExe) => {
    'type': 'init',
    'gatewayUrl': address,
    'gatewayCertSha256': fingerprint,
    'agentToken': agentToken,
    'boxKey': boxKey,
    'number': number,
    'installId': installId,
    'stateDir': stateDir,
    'shadowExecutable': shadowExe,
    'shadowSource': 'desktop',
    'viewOnly': viewOnly,
    'clipboard': clipboard,
    'files': {'enabled': files && filesDir.isNotEmpty, 'dir': filesDir},
    'permanent': permanent,
    'allowIncoming': allowIncoming,
  };
}

/// Gateway link of this computer as the host process reports it.
enum HostLink {
  starting,
  connecting,
  online,
  reconnecting,
  revoked,
  stopped,
  unavailable;

  static HostLink parse(Object? v) => switch (v) {
    'connecting' => connecting,
    'online' => online,
    'reconnecting' => reconnecting,
    'revoked' => revoked,
    'stopped' => stopped,
    _ => connecting,
  };

  String get label => switch (this) {
    starting => 'Запуск',
    connecting => 'Подключение к серверу',
    online => 'В сети',
    reconnecting => 'Переподключение',
    revoked => 'Отозвано',
    stopped => 'Не в сети',
    unavailable => 'Недоступно',
  };
}

/// The incoming session (one at a time).
class IncomingSession {
  const IncomingSession(this.id, this.viewer, this.state, this.since);
  factory IncomingSession.fromJson(Map<String, dynamic> j) => IncomingSession(
    j['id'] as String? ?? '',
    j['viewer'] as String? ?? '',
    j['state'] as String? ?? '',
    DateTime.tryParse(j['since'] as String? ?? '')?.toLocal() ?? DateTime.now(),
  );
  final String id, viewer, state;
  final DateTime since;

  /// Screen is visible to the viewer (after local consent).
  bool get active => state == 'active' || state == 'connected';

  String get label => switch (state) {
    'verifying' => 'Проверка пароля',
    'prompt' => 'Ждёт вашего подтверждения',
    'connected' => 'Подключён — экран виден',
    _ => 'Разрешён — подключается',
  };
}

/// Everything «Этот компьютер» shows.
class HostView {
  const HostView({
    this.link = HostLink.starting,
    this.error = '',
    this.tempPassword = '',
    this.permanent = false,
    this.allowIncoming = true,
    this.lockedUntil,
    this.session,
  });

  final HostLink link;
  final String error, tempPassword;
  final bool permanent, allowIncoming;
  final DateTime? lockedUntil;
  final IncomingSession? session;

  HostView copyWith({HostLink? link, String? error}) => HostView(
    link: link ?? this.link,
    error: error ?? this.error,
    tempPassword: tempPassword,
    permanent: permanent,
    allowIncoming: allowIncoming,
    lockedUntil: lockedUntil,
    session: session,
  );

  factory HostView.fromStatus(Map<String, dynamic> j) => HostView(
    link: HostLink.parse(j['link']),
    error: j['error'] as String? ?? '',
    tempPassword: j['tempPassword'] as String? ?? '',
    permanent: j['permanent'] == true,
    allowIncoming: j['allowIncoming'] == true,
    lockedUntil: DateTime.tryParse(j['lockedUntil'] as String? ?? '')
        ?.toLocal(),
    session: j['session'] is Map
        ? IncomingSession.fromJson((j['session'] as Map).cast())
        : null,
  );
}

/// Messages of the host process other than status.
class HostReply {
  const HostReply(this.type, this.data);
  final String type;
  final Map<String, dynamic> data;
}

/// The host half of this computer (a child process in the product).
abstract interface class HostRuntime {
  Stream<HostView> get updates;
  Stream<HostReply> get replies;
  Future<void> start(Map<String, Object?> init);
  void send(Map<String, Object?> command);
  Future<void> stop();
}

typedef HostRuntimeFactory = HostRuntime Function();

/// Files next to the installed app; overridable for development runs.
class HostTools {
  HostTools({String? hostExe, String? shadowExe, String? stateDir})
    : hostExe =
          hostExe ??
          Platform.environment['AER_CONNECT_HOST_EXE'] ??
          _beside('aer-connect-host.exe'),
      shadowExe =
          shadowExe ??
          Platform.environment['AER_SHADOW_EXE'] ??
          _beside('aer-shadow.exe'),
      stateDir =
          stateDir ??
          '${Platform.environment['LOCALAPPDATA'] ?? Directory.systemTemp.path}'
              '${Platform.pathSeparator}AER Connect${Platform.pathSeparator}host';

  static String _beside(String name) =>
      '${File(Platform.resolvedExecutable).parent.path}${Platform.pathSeparator}$name';

  final String hostExe, shadowExe, stateDir;

  bool get hostAvailable =>
      File(hostExe).existsSync() && File(shadowExe).existsSync();

  /// New X25519 key pair (private stays in the DPAPI profile).
  Future<({String privateKey, String publicKey})> keygen() async {
    final r = await Process.run(hostExe, ['-keygen']);
    if (r.exitCode != 0) throw StateError('Не удалось создать ключ устройства');
    final j = jsonDecode(r.stdout as String) as Map<String, dynamic>;
    return (
      privateKey: j['private'] as String,
      publicKey: j['public'] as String,
    );
  }

  /// Fingerprint of this installation on this machine (clone detection).
  Future<String> instance(String installId) async {
    final r = await Process.run(hostExe, ['-instance', installId]);
    if (r.exitCode != 0) throw StateError('Не удалось определить установку');
    return (r.stdout as String).trim();
  }

  static String newInstallId() {
    final r = Random.secure();
    return List.generate(32, (_) => r.nextInt(16).toRadixString(16)).join();
  }

  // ---- start with Windows (explicit user setting, current user only) ----

  static const _runKey = r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run';
  static const _runValue = 'AER Connect';

  Future<bool> autostart() async {
    if (!Platform.isWindows) return false;
    final r = await Process.run('reg', ['query', _runKey, '/v', _runValue]);
    return r.exitCode == 0;
  }

  Future<void> setAutostart(bool on) async {
    if (!Platform.isWindows) return;
    final r = on
        ? await Process.run('reg', [
            'add',
            _runKey,
            '/v',
            _runValue,
            '/t',
            'REG_SZ',
            '/d',
            '"${Platform.resolvedExecutable}"',
            '/f',
          ])
        : await Process.run('reg', ['delete', _runKey, '/v', _runValue, '/f']);
    if (r.exitCode != 0 && on) {
      throw StateError('Не удалось включить запуск при входе в Windows');
    }
  }
}

/// Runs aer-connect-host and restarts it after a crash (exponential
/// backoff with jitter). Exit 3 = device revoked, 4 = elevated: no restart.
/// Closing its stdin stops it; it never outlives the app.
class ProcessHostRuntime implements HostRuntime {
  ProcessHostRuntime(this.tools);
  final HostTools tools;
  final _updates = StreamController<HostView>.broadcast();
  final _replies = StreamController<HostReply>.broadcast();
  Process? _p;
  Map<String, Object?>? _init;
  var _stopped = false;
  var _delay = const Duration(seconds: 2);
  HostView _last = const HostView();

  @override
  Stream<HostView> get updates => _updates.stream;
  @override
  Stream<HostReply> get replies => _replies.stream;

  void _emit(HostView v) {
    _last = v;
    if (!_updates.isClosed) _updates.add(v);
  }

  @override
  Future<void> start(Map<String, Object?> init) async {
    _init = init;
    _stopped = false;
    await Directory(tools.stateDir).create(recursive: true);
    await _spawn();
  }

  Future<void> _spawn() async {
    if (_stopped) return;
    final Process p;
    try {
      p = await Process.start(tools.hostExe, const []);
    } catch (_) {
      _emit(
        const HostView(
          link: HostLink.unavailable,
          error: 'Компонент входящих подключений не найден. Переустановите AER Connect.',
        ),
      );
      return;
    }
    _p = p;
    p.stdin.writeln(jsonEncode(_init));
    unawaited(p.stderr.drain<void>());
    final started = DateTime.now();
    var fatal = '';
    p.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((
      line,
    ) {
      final Map<String, dynamic> j;
      try {
        j = jsonDecode(line) as Map<String, dynamic>;
      } on FormatException {
        return;
      }
      switch (j['type']) {
        case 'status':
          _delay = const Duration(seconds: 2);
          _emit(HostView.fromStatus(j));
        case 'fatal':
          fatal = j['message'] as String? ?? '';
        default:
          if (!_replies.isClosed) {
            _replies.add(HostReply(j['type'] as String? ?? '', j));
          }
      }
    });
    final code = await p.exitCode;
    if (identical(_p, p)) _p = null;
    if (_stopped) return;
    if (code == 3) {
      _emit(HostView(link: HostLink.revoked, error: fatal));
      return;
    }
    if (code == 4) {
      _emit(HostView(link: HostLink.unavailable, error: fatal));
      return;
    }
    if (DateTime.now().difference(started) > const Duration(minutes: 2)) {
      _delay = const Duration(seconds: 2);
    }
    _emit(
      _last.copyWith(
        link: HostLink.reconnecting,
        error: fatal.isEmpty
            ? 'Компонент входящих подключений перезапускается'
            : fatal,
      ),
    );
    final jitter = Random().nextInt(_delay.inMilliseconds ~/ 2 + 1);
    await Future<void>.delayed(_delay + Duration(milliseconds: jitter));
    _delay = Duration(
      milliseconds: min(
        _delay.inMilliseconds * 2,
        const Duration(minutes: 1).inMilliseconds,
      ),
    );
    await _spawn();
  }

  @override
  void send(Map<String, Object?> command) {
    try {
      _p?.stdin.writeln(jsonEncode(command));
    } catch (_) {}
  }

  @override
  Future<void> stop() async {
    _stopped = true;
    final p = _p;
    _p = null;
    if (p != null) {
      try {
        await p.stdin.close();
      } catch (_) {}
      final code = await p.exitCode.timeout(
        const Duration(seconds: 6),
        onTimeout: () {
          p.kill();
          return -1;
        },
      );
      if (code == -1) await p.exitCode;
    }
    _emit(const HostView(link: HostLink.stopped));
  }
}
