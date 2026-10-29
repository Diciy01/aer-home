// Own loopback Core/Gateway + real RDP server with SYNTHETIC source only.
// Screenshots contain only this Flutter surface, never the user's desktop.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:aer_connect/connect_app.dart';
import 'package:aer_connect/controller.dart';
import 'package:aer_remote/aer_remote.dart';
import 'package:aer_widgets/aer_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class LabStore implements ConnectStore {
  String? value;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String v) async {
    value = v;
  }

  @override
  Future<void> delete() async {
    value = null;
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final env = Platform.environment;
  testWidgets(
    'Connect Windows: pin/pair, real frames through Gateway, input, reconnect, revoke',
    (t) async {
      final lab = await Process.start(env['AER_REMOTELAB_BIN']!, [
        '-shadow',
        env['AER_SHADOW_BIN']!,
      ]);
      final errors = lab.stderr.transform(utf8.decoder).join();
      late Map<String, dynamic> info;
      await t.runAsync(() async {
        info = jsonDecode(
          await lab.stdout
              .transform(utf8.decoder)
              .transform(const LineSplitter())
              .first,
        ) as Map<String, dynamic>;
      });
      final c = ConnectController(
        store: LabStore(),
        poll: const Duration(milliseconds: 200),
        viewerFactory: (check) =>
            EmbeddedRdpViewer.tryCreate(canReconnect: check)!,
      );
      addTearDown(() async {
        await t.pumpWidget(const SizedBox());
        await t.runAsync(() async {
          await c.shutdown().timeout(const Duration(seconds: 15));
          c.dispose();
          await lab.stdin.close();
          await lab.exitCode.timeout(
            const Duration(seconds: 12),
            onTimeout: () {
              lab.kill();
              return -1;
            },
          );
          expect(await errors, isNot(contains('aerc1.')));
        });
      });
      final boundary = GlobalKey();
      GlobalKey<RemoteDesktopViewState>? surface;
      InteractiveRemoteViewer? lastViewer;
      String? received;
      var reads = 0;
      await t.pumpWidget(
        RepaintBoundary(
          key: boundary,
          child: ConnectApp(
            controller: c,
            desktopBuilder: (v) {
              if (!identical(v, lastViewer)) {
                lastViewer = v;
                surface = GlobalKey<RemoteDesktopViewState>();
              }
              return RemoteDesktopView(
                key: surface!,
                viewer: v,
                readClipboard: () async {
                  reads++;
                  return 'AER Connect TEST ONLY';
                },
                writeClipboard: (s) async {
                  received = s;
                },
              );
            },
          ),
        ),
      );
      Future<void> step() async {
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 200)),
        );
        await t.pump(const Duration(milliseconds: 250));
      }

      Future<void> wait(String label, bool Function() condition) async {
        for (var i = 0; i < 150; i++) {
          if (condition()) return;
          await step();
        }
        fail(
          'timeout: $label; state=${c.state}; busy=${c.busy}; error=${c.error}; message=${c.message}; clipboardReads=$reads; receivedLength=${received?.length}',
        );
      }

      Future<void> screenshot(String name) async {
        final dir = env['AER_CONNECT_SHOTS'];
        if (dir == null) return;
        await step();
        await t.runAsync(() async {
          final image =
              await (boundary.currentContext!.findRenderObject()!
                      as RenderRepaintBoundary)
                  .toImage(pixelRatio: 1);
          final png = await image.toByteData(format: ui.ImageByteFormat.png);
          await Directory(dir).create(recursive: true);
          await File('$dir/$name.png').writeAsBytes(png!.buffer.asUint8List());
          image.dispose();
        });
      }

      await step();
      await screenshot('01-pairing');
      await t.enterText(
        find.byKey(const Key('gw-address')),
        info['gateway'] as String,
      );
      await t.tap(find.byKey(const Key('gw-probe')));
      await wait(
        'fingerprint',
        () => find.byKey(const Key('gw-confirm')).evaluate().isNotEmpty,
      );
      expect(find.text(info['fingerprint'] as String), findsOneWidget);
      await screenshot('02-fingerprint');
      await t.tap(find.byKey(const Key('gw-confirm')));
      await step();
      await t.enterText(
        find.byKey(const Key('gw-code')),
        info['pairingCode'] as String,
      );
      await t.tap(find.byKey(const Key('gw-pair')));
      await wait(
        'hosts',
        () => find
            .byKey(Key('gw-connect-${info['hostId']}'))
            .evaluate()
            .isNotEmpty,
      );
      await screenshot('03-hosts');
      await t.tap(find.byKey(Key('gw-connect-${info['hostId']}')));
      await wait(
        'real frame in Connect',
        () => (surface?.currentState?.painted ?? 0) > 0,
      );
      await screenshot('04-desktop-synthetic');
      debugPrint('LIVE: frame received');
      await t.tap(find.byType(RemoteDesktopView));
      await step();
      debugPrint('LIVE: viewer focused; clipboard reads=$reads');
      await t.sendKeyDownEvent(LogicalKeyboardKey.keyA);
      await t.sendKeyUpEvent(LogicalKeyboardKey.keyA);
      await t.sendKeyDownEvent(
        LogicalKeyboardKey.controlLeft,
        physicalKey: PhysicalKeyboardKey.controlLeft,
      );
      await t.sendKeyEvent(
        LogicalKeyboardKey.keyV,
        physicalKey: PhysicalKeyboardKey.keyV,
      );
      await t.sendKeyUpEvent(
        LogicalKeyboardKey.controlLeft,
        physicalKey: PhysicalKeyboardKey.controlLeft,
      );
      debugPrint('LIVE: key sequence complete');
      await wait('clipboard echo', () => received == 'AER Connect TEST ONLY');
      debugPrint('LIVE: clipboard received');
      var reconnected = false;
      unawaited(
        c.reconnect().then((_) {
          reconnected = true;
        }),
      );
      await wait('reconnect completed', () => reconnected);
      await step();
      await wait(
        'frame after reconnect',
        () => (surface?.currentState?.painted ?? 0) > 0,
      );
      await t.runAsync(() async {
        final owner = HttpClient();
        try {
          final req = await owner.postUrl(
            Uri.parse(
              '${info['coreUrl']}/api/v1/remote/clients/${info['clientId']}/revoke',
            ),
          );
          req.headers.set('Authorization', 'Bearer ${info['ownerToken']}');
          final res = await req.close();
          expect(res.statusCode, 200);
          await res.drain<void>();
        } finally {
          owner.close(force: true);
        }
      });
      await wait('revoked viewer removed', () => c.viewer == null);
      await step();
      expect(find.byType(RemoteDesktopView), findsNothing);
      await t.pageBack();
      await step();
      await screenshot('05-revoked');
      expect(c.unauthorized, isTrue);
      expect(t.takeException(), isNull);

      // Unique key in AER Connect's DPAPI namespace; never reads/deletes HOME credentials.
      const store = FlutterSecureStorage();
      final key = 'aer-connect.test.${DateTime.now().microsecondsSinceEpoch}';
      await t.runAsync(() async {
        try {
          await store.write(key: key, value: 'aerc1.TEST-ONLY');
          expect(await store.read(key: key), 'aerc1.TEST-ONLY');
        } finally {
          await store.delete(key: key);
        }
        expect(await store.read(key: key), isNull);
      });
    },
    skip: env['AER_REMOTELAB_BIN'] == null || env['AER_SHADOW_BIN'] == null,
  );
}
