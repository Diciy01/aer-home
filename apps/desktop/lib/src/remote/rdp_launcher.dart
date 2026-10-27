import 'dart:async';
import 'dart:io';

import '../core_api/remote_api.dart';

/// A running external RDP client.
class RdpClientHandle {
  RdpClientHandle(this._process);
  final Process _process;

  Future<int> get exitCode => _process.exitCode;
  void stop() => _process.kill();
}

/// Starts the platform's RDP client for a one-time grant. The image, input,
/// scaling, full screen and monitors are handled by that client's window —
/// AER does not embed RDP (ADR-013).
abstract interface class RdpLauncher {
  /// Human name shown in the UI («окно Remmina»).
  String get clientName;
  bool get available;
  Future<RdpClientHandle> launch(RemoteGrant g);
}

RdpLauncher defaultLauncher() => Platform.isWindows
    ? WindowsMstscLauncher()
    : RemminaLauncher.fromEnvironment();

/// Linux: Remmina (FreeRDP 3). The host certificate from Core is written to
/// FreeRDP's known-server store first, so TLS fails if anybody else answers
/// (verified on the lab: a changed key is refused).
class RemminaLauncher implements RdpLauncher {
  RemminaLauncher({required this.command, required this.freerdpDir});

  /// `AER_REMOTE_CLIENT` overrides the argv prefix (tests run Remmina in an
  /// isolated display); `AER_REMOTE_FREERDP_DIR` the FreeRDP config dir.
  factory RemminaLauncher.fromEnvironment() {
    final env = Platform.environment;
    final cmd = (env['AER_REMOTE_CLIENT'] ?? 'remmina -c')
        .split(' ')
        .where((s) => s.isNotEmpty)
        .toList();
    final home = env['HOME'] ?? '';
    final cfg = env['XDG_CONFIG_HOME'] ?? '$home/.config';
    return RemminaLauncher(
      command: cmd,
      freerdpDir: env['AER_REMOTE_FREERDP_DIR'] ?? '$cfg/freerdp',
    );
  }

  final List<String> command;
  final String freerdpDir;

  @override
  String get clientName => 'Remmina';

  @override
  bool get available =>
      command.first.contains('/') ||
      [
        '/usr/bin',
        '/usr/local/bin',
        '/snap/bin',
      ].any((d) => File('$d/${command.first}').existsSync());

  /// FreeRDP stores a server as `<host>.<port>_<port>.pem` when Remmina
  /// passes an explicit port (observed with Remmina 1.4.43 / FreeRDP 3.32).
  File pinFile(RemoteGrant g) =>
      File('$freerdpDir/server/${g.host}.${g.port}_${g.port}.pem');

  Uri uri(RemoteGrant g) => Uri(
    scheme: 'rdp',
    userInfo: '${g.username}:${g.password}',
    host: g.host,
    port: g.port,
  );

  @override
  Future<RdpClientHandle> launch(RemoteGrant g) async {
    final pin = pinFile(g);
    await pin.parent.create(recursive: true);
    await pin.writeAsString(g.certPem, flush: true);
    // The password is in argv for the life of the client process (visible
    // to the same user only); it is valid for this session alone.
    final p = await Process.start(command.first, [
      ...command.skip(1),
      uri(g).toString(),
    ], mode: ProcessStartMode.normal);
    unawaited(p.stdout.drain<void>());
    unawaited(p.stderr.drain<void>());
    return RdpClientHandle(p);
  }
}

/// Windows: the built-in «Подключение к удалённому рабочему столу». The
/// Windows host uses the OS account, so no password is handed over.
/// UNVERIFIED — see docs/REMOTE_WINDOWS_VALIDATION.md.
class WindowsMstscLauncher implements RdpLauncher {
  @override
  String get clientName => 'Подключение к удалённому рабочему столу (mstsc)';

  @override
  bool get available => true;

  @override
  Future<RdpClientHandle> launch(RemoteGrant g) async {
    final dir = await Directory.systemTemp.createTemp('aer-rdp-');
    final f = File('${dir.path}\\aer.rdp');
    await f.writeAsString(
      [
        'full address:s:${g.host}:${g.port}',
        if (g.username.isNotEmpty) 'username:s:${g.username}',
        'prompt for credentials:i:1',
        'authentication level:i:2',
        'redirectclipboard:i:${g.clipboard ? 1 : 0}',
        'drivestoredirect:s:',
      ].join('\r\n'),
    );
    final p = await Process.start('mstsc', [f.path]);
    return RdpClientHandle(p);
  }
}

/// TCP connect time to the host's RDP port: a cheap, honest network
/// latency probe (not the image latency, which only the RDP client sees).
Future<Duration?> probeLatency(String host, int port) async {
  final times = <int>[];
  for (var i = 0; i < 3; i++) {
    final sw = Stopwatch()..start();
    try {
      final s = await Socket.connect(
        host,
        port,
        timeout: const Duration(seconds: 2),
      );
      sw.stop();
      s.destroy();
      times.add(sw.elapsedMicroseconds);
    } catch (_) {
      return null;
    }
  }
  times.sort();
  return Duration(microseconds: times[1]);
}
