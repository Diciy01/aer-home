// Full Windows app, all sections, and the embedded viewer through a real
// loopback Gateway/host/sample-RDP stand. No user desktop is captured or driven.
import 'dart:convert';
import 'dart:io';

import 'package:aer_home_desktop/main.dart' as entry;
import 'package:aer_home_desktop/src/app.dart';
import 'package:aer_home_desktop/src/core_api/core_client.dart';
import 'package:aer_home_desktop/src/core_api/remote_api.dart';
import 'package:aer_home_desktop/src/remote/remote_desktop_view.dart';
import 'package:aer_home_desktop/src/state/app_section.dart';
import 'package:aer_home_desktop/src/state/connection_controller.dart';
import 'package:aer_remote/aer_remote.dart' as engine;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:integration_test/integration_test.dart';

final env = Platform.environment;

Future<void> settle(WidgetTester tester, [int ms = 400]) async {
  await tester.runAsync(() => Future<void>.delayed(Duration(milliseconds: ms)));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 200));
}

Future<void> until(
  WidgetTester tester,
  String reason,
  bool Function() condition,
) async {
  for (var i = 0; i < 100 && !condition(); i++) {
    await settle(tester, 200);
  }
  expect(condition(), true, reason: reason);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('Windows full app navigation and embedded RDP via own Gateway', (
    tester,
  ) async {
    final core = Uri.tryParse(env['AER_CORE_URL'] ?? '');
    if (!Platform.isWindows ||
        core?.host != '127.0.0.1' ||
        core?.port == 8787 ||
        env['AER_DESKTOP_DATA_DIR'] == null ||
        env['AER_RDP_SAMPLE_LOOPBACK_ONLY'] != '1') {
      markTestSkipped(
        'isolated Windows Core and explicitly loopback-patched sample server required',
      );
      return;
    }
    await tester.runAsync(() async {
      entry.main();
      await Future<void>.delayed(const Duration(seconds: 1));
    });
    await settle(tester);
    final app = tester.widget<AerHomeApp>(find.byType(AerHomeApp));
    await tester.runAsync(app.connection.refresh);
    expect(app.connection.link, CoreLink.online);
    const labels = [
      'Дом',
      'Обзор',
      'Устройства',
      'Мониторинг',
      'Боты',
      'Удалённый\nдоступ',
      'Питание',
      'Сеть и ТВ',
    ];
    for (final section in AppSection.values) {
      await tester.tap(
        find.descendant(
          of: find.byType(NavigationRail),
          matching: find.text(labels[section.index]),
        ),
      );
      await settle(tester, 700);
      expect(app.section.value, section);
      expect(tester.takeException(), isNull, reason: 'section ${section.name}');
    }
    expect(app.remote!.embeddedAvailable, true);

    // Only a sample picture server, built with Open(...,"127.0.0.1",port).
    // It must never be an unpatched upstream sample server (binds all NICs).
    final stand = await tester.runAsync(() async {
      final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = socket.port;
      await socket.close();
      final server = await Process.start(env['AER_RDP_SAMPLE_SERVER']!, [
        '--port=$port',
        '--cert=${env['AER_RDP_SAMPLE_CERT']}',
        '--key=${env['AER_RDP_SAMPLE_KEY']}',
      ], workingDirectory: File(env['AER_RDP_SAMPLE_CERT']!).parent.path);
      server.stdout.drain<void>();
      server.stderr.drain<void>();
      addTearDown(() async {
        server.kill();
        await server.exitCode;
      });
      for (var i = 0; ; i++) {
        try {
          (await Socket.connect('127.0.0.1', port)).destroy();
          break;
        } on SocketException {
          if (i > 100) rethrow;
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
      }
      final lab = await Process.start(env['AER_REMOTELAB_BIN']!, [
        '-rdp',
        '127.0.0.1:$port',
        '-rdp-cert',
        env['AER_RDP_SAMPLE_CERT']!,
        '-rdp-key',
        env['AER_RDP_SAMPLE_KEY']!,
      ]);
      lab.stderr.drain<void>();
      addTearDown(() async {
        await lab.stdin.close();
        await lab.exitCode.timeout(const Duration(seconds: 10));
      });
      return jsonDecode(
        await lab.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .first,
      ) as Map<String, dynamic>;
    });
    final info = stand!;
    final owner = CoreClient(
      httpClient: http.Client(),
      baseUri: Uri.parse(info['coreUrl'] as String),
      tokenProvider: () async => info['ownerToken'] as String,
    );
    final api = HttpRemoteApi(owner);
    final pairing = await tester.runAsync(
      () => api.createClient(
        name: 'Windows app test',
        hosts: [info['hostId'] as String],
        clipboard: false,
        files: false,
      ),
    );
    final gateway = app.remote!.gateway!;
    final pin = await tester.runAsync(
      () => gateway.probe(info['gateway'] as String),
    );
    expect(pin, info['fingerprint']);
    await tester.runAsync(
      () => gateway.pair(info['gateway'] as String, pin!, pairing!.code),
    );
    app.section.value = AppSection.remote;
    await settle(tester);
    await tester.tap(find.byKey(const Key('remote-tab-gateway')));
    await settle(tester);
    await tester.tap(find.byKey(Key('gw-connect-${info['hostId']}')));
    await until(
      tester,
      'embedded desktop page',
      () => find.byType(RemoteDesktopView).evaluate().isNotEmpty,
    );
    await until(
      tester,
      'viewer connected: ${gateway.active!.viewer!.lastError}',
      () => gateway.active!.viewer!.statusName == 'connected',
    );
    await until(
      tester,
      'real frames painted in Flutter',
      () =>
          tester
              .state<RemoteDesktopViewState>(find.byType(RemoteDesktopView))
              .painted >
          0,
    );
    final viewer = gateway.active!.viewer!;
    expect(viewer.clipboardAllowed, false);
    expect(viewer.pushClipboard('test denied'), false);
    expect(gateway.active!.files, isNull);
    final point = tester.getCenter(find.byType(RemoteDesktopView));
    await tester.tapAt(point);
    await tester.sendKeyDownEvent(
      LogicalKeyboardKey.keyA,
      physicalKey: PhysicalKeyboardKey.keyA,
    );
    await tester.sendKeyUpEvent(
      LogicalKeyboardKey.keyA,
      physicalKey: PhysicalKeyboardKey.keyA,
    );
    await settle(tester);
    expect(viewer.statusName, 'connected');
    await tester.tap(find.byKey(const Key('remote-desktop-reconnect')));
    await until(
      tester,
      'new viewer on reconnect',
      () => gateway.active!.viewer != null && gateway.active!.viewer != viewer,
    );
    await until(
      tester,
      'frames after reconnect',
      () =>
          find.byType(RemoteDesktopView).evaluate().isNotEmpty &&
          tester
                  .state<RemoteDesktopViewState>(find.byType(RemoteDesktopView))
                  .painted >
              0,
    );
    await tester.runAsync(() => api.revokeClient(pairing!.client.id));
    await until(
      tester,
      'revocation removes viewer',
      () => !gateway.active!.live && gateway.active!.viewer == null,
    );
    expect(gateway.active!.state, engine.RemoteState.revoked);
    await tester.tap(find.byTooltip('Свернуть (сеанс продолжается)'));
    await settle(tester);
    await tester.runAsync(gateway.forget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    app.network!.dispose();
    app.power!.dispose();
    app.remote!.dispose();
    app.bots!.dispose();
    app.monitoring!.dispose();
    app.scene.dispose();
    app.registry.dispose();
    app.connection.dispose();
    app.section.dispose();
  });
}
