import 'dart:async';

import 'package:aer_remote/aer_remote.dart';
import 'package:test/test.dart';

RemoteSessionInfo session(RemoteState state) => RemoteSessionInfo(
  id: 'test',
  entityId: 'host',
  hostName: 'test',
  route: 'relay',
  state: state,
  reason: '',
  allowed: const RemoteCaps(desktop: true),
  expiresAt: DateTime.now().add(const Duration(minutes: 1)),
);

class PendingGateway extends GatewayClient {
  PendingGateway() : super(GatewayServer.parse('home.example.net', 'ab' * 32)) {
    credential = 'aerc1.TEST-ONLY';
  }
  final created = Completer<RemoteSessionInfo>();
  var ends = 0, grants = 0;
  @override
  Future<RemoteSessionInfo> create(
    String entityId, {
    String? idempotencyKey,
    int? minutes,
  }) => created.future;
  @override
  Future<RemoteSessionInfo> end(String id) async {
    ends++;
    return session(RemoteState.disconnected);
  }

  @override
  Future<RelayGrant> grant(String id) async {
    grants++;
    throw StateError('Grant must never be fetched');
  }
}

void main() {
  test(
    'end during in-flight create cancels late session before grant/ports',
    () async {
      final api = PendingGateway();
      addTearDown(api.close);
      final conn = RemoteConnection(api);
      final start = conn.start('host');
      final check = expectLater(start, throwsStateError);
      await Future<void>.delayed(Duration.zero);
      await conn.end();
      api.created.complete(session(RemoteState.connecting));
      await check;
      expect(api.ends, 1);
      expect(api.grants, 0);
      expect(conn.rdp, isNull);
      expect(conn.grant, isNull);
    },
  );
}
