import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'errors.dart';
import 'gateway_client.dart';
import 'pinning.dart';

/// Upgrade token of a relay leg (same as remoteengine.Protocol in Go).
const tunnelProtocol = 'aer-tunnel/1';

/// Opens one client leg: an HTTP/1.1 Upgrade inside TLS pinned to the
/// Gateway, authenticated with the client credential and a one-time
/// ticket. The returned socket is an opaque stream to the host's service;
/// whatever runs inside it (RDP, HTTPS of the file channel) has its own
/// end-to-end TLS with the host.
Future<Socket> openTunnel(
  GatewayServer server,
  String credential,
  String ticket, {
  String path = '/gw/v1/tunnel',
}) async {
  final http = pinnedHttpClient(server.fingerprint);
  try {
    final req = await http.openUrl('GET', server.resolve(path));
    req.headers
      ..set(HttpHeaders.authorizationHeader, 'Bearer $credential')
      ..set('X-AER-Ticket', ticket)
      ..set(HttpHeaders.connectionHeader, 'Upgrade')
      ..set(HttpHeaders.upgradeHeader, tunnelProtocol);
    req.followRedirects = false;
    final res = await req.close();
    if (res.statusCode != HttpStatus.switchingProtocols) {
      final text = await res.transform(utf8.decoder).join();
      var code = 'UNAVAILABLE', msg = 'HTTP ${res.statusCode}';
      try {
        final e =
            (jsonDecode(text) as Map<String, dynamic>)['error']
                as Map<String, dynamic>;
        code = e['code'] as String? ?? code;
        msg = e['message'] as String? ?? msg;
      } catch (_) {}
      throw RemoteEngineException(res.statusCode, code, msg);
    }
    if ((res.headers.value(HttpHeaders.upgradeHeader) ?? '').toLowerCase() !=
        tunnelProtocol) {
      throw const RemoteEngineException(
        502,
        'UNAVAILABLE',
        'Сервер не переключился на aer-tunnel/1',
      );
    }
    return await res.detachSocket();
  } on HandshakeException {
    throw PinMismatchException(server.fingerprint, '');
  } finally {
    http.close();
  }
}

/// Local end of the engine: a port on 127.0.0.1 a viewer connects to (the
/// built-in one or an external RDP client as fallback). Every accepted
/// connection gets its own fresh tunnel leg from [leg].
class LocalForwarder {
  LocalForwarder._(this._server, this._leg);

  /// Binds 127.0.0.1:0 (or [address], e.g. 127.0.0.2 for mstsc, which
  /// may refuse to connect to "itself").
  static Future<LocalForwarder> start(
    Future<Socket> Function() leg, {
    InternetAddress? address,
  }) async {
    final s = await ServerSocket.bind(
      address ?? InternetAddress.loopbackIPv4,
      0,
    );
    final f = LocalForwarder._(s, leg);
    s.listen(f._accept);
    return f;
  }

  final ServerSocket _server;
  final Future<Socket> Function() _leg;
  final _open = <Socket>{};
  final _errors = StreamController<Object>.broadcast();
  var _closed = false;
  int bytesUp = 0, bytesDown = 0;

  InternetAddress get address => _server.address;
  int get port => _server.port;

  /// Live client connections through the tunnel.
  int get active => _open.length ~/ 2;

  /// Leg failures (refused ticket, Gateway unreachable, pin mismatch).
  Stream<Object> get errors => _errors.stream;

  Future<void> _accept(Socket local) async {
    if (_closed) {
      local.destroy();
      return;
    }
    Socket remote;
    try {
      remote = await _leg();
    } catch (e) {
      local.destroy();
      if (!_errors.isClosed) _errors.add(e);
      return;
    }
    if (_closed) {
      local.destroy();
      remote.destroy();
      return;
    }
    _open
      ..add(local)
      ..add(remote);
    void done() {
      _open
        ..remove(local)
        ..remove(remote);
      local.destroy();
      remote.destroy();
    }

    local.listen(
      (d) {
        bytesUp += d.length;
        remote.add(d);
      },
      onDone: done,
      onError: (_) => done(),
      cancelOnError: true,
    );
    remote.listen(
      (d) {
        bytesDown += d.length;
        local.add(d);
      },
      onDone: done,
      onError: (_) => done(),
      cancelOnError: true,
    );
  }

  /// Stops listening and drops every connection.
  Future<void> close() async {
    _closed = true;
    await _server.close();
    for (final s in _open.toList()) {
      s.destroy();
    }
    _open.clear();
    await _errors.close();
  }
}
