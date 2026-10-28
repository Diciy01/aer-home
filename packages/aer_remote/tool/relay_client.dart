// TEST CLIENT for the relay lab (tools/remote-lab/relay_lab.py): the shared
// engine pairs with the lab Gateway, opens a relay session and keeps the
// local RDP port open for an RDP client (Remmina on the lab Xvfb). It writes
// DIR/client.json (port, user, password — TEST DATA of one lab session) and
// the host certificate into FreeRDP's known-server store, then runs until
// stdin closes; state changes go to stdout.
//
//   dart run tool/relay_client.dart LAB_DIR FREERDP_CONFIG_DIR
import 'dart:convert';
import 'dart:io';

import 'package:aer_remote/aer_remote.dart';

Future<void> main(List<String> args) async {
  final dir = args[0], freerdp = args[1];
  final info = jsonDecode(File('$dir/lab.json').readAsStringSync()) as Map<String, dynamic>;
  final server = GatewayServer.parse(info['gateway'] as String, info['fingerprint'] as String);
  final seen = await probeFingerprint(server.base);
  stdout.writeln('gateway fingerprint ${seen == info['fingerprint'] ? 'matches' : 'MISMATCH'}');
  final api = GatewayClient(server);
  await api.pair(info['pairingCode'] as String, deviceName: 'relay lab client');
  final conn = RemoteConnection(api, poll: const Duration(milliseconds: 500));
  conn.updates.listen((u) => stdout.writeln('state ${u.state.name}: ${u.message}'));
  await conn.start(info['hostId'] as String);
  final g = conn.grant!, port = conn.rdp!.port;
  final pin = File('$freerdp/server/127.0.0.1.${port}_$port.pem');
  await pin.parent.create(recursive: true);
  await pin.writeAsString(g.certPem, flush: true);
  await File('$dir/client.json').writeAsString(jsonEncode({
    'rdpPort': port,
    'filesPort': conn.files?.port,
    'username': g.username,
    'password': g.password,
    'filesToken': g.filesToken,
    'certSha256': g.certSha256,
    'sessionId': conn.session!.id,
  }));
  stdout.writeln('ready rdp=127.0.0.1:$port');
  await stdin.drain<void>();
  await conn.end();
  api.close();
  stdout.writeln('ended');
}
