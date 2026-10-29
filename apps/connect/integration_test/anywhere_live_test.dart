// AER Connect Anywhere in the real Flutter window (ADR-018): own loopback
// Core/Gateway from `aer-remotelab -anywhere -shadow`, whose host DEVICE
// serves a real RDP stream from the SYNTHETIC source. This app registers
// itself through the UI, connects by ID and password and shows the frames.
// Its own host half starts as the real aer-connect-host child process.
// Nothing captures or controls the user's desktop; clipboard handlers are
// test-only. Screenshots contain only this Flutter surface.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:aer_connect/connect_app.dart';
import 'package:aer_connect/controller.dart';
import 'package:aer_connect/device.dart';
import 'package:aer_remote/aer_remote.dart';
import 'package:aer_widgets/aer_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

class LabStore implements ConnectStore {
  String? value;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String v) async => value = v;
  @override
  Future<void> delete() async => value = null;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final env = Platform.environment;
  testWidgets(
    'Connect Anywhere: register via UI, ID and password, real synthetic frames, input, clipboard, end, revoke',
    (t) async {
      final lab = await Process.start(env['AER_REMOTELAB_BIN']!, [
        '-anywhere',
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
      final stateDir = Directory.systemTemp.createTempSync(
        'aer-anywhere-live-',
      );
      final devices = LabStore();
      final c = ConnectController(
        store: LabStore(),
        deviceStore: devices,
        poll: const Duration(milliseconds: 200),
        tools: HostTools(
          hostExe: env['AER_CONNECT_HOST_EXE']!,
          shadowExe: env['AER_SHADOW_BIN']!,
          stateDir: stateDir.path,
        ),
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
            const Duration(seconds: 15),
            onTimeout: () {
              lab.kill();
              return -1;
            },
          );
          final log = await errors;
          expect(log, isNot(contains('aerc1.')));
          expect(log, isNot(contains('aer1.')));
          stateDir.deleteSync(recursive: true);
        });
      });
      final boundary = GlobalKey();
      GlobalKey<RemoteDesktopViewState>? surface;
      InteractiveRemoteViewer? lastViewer;
      String? received;
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
                readClipboard: () async => 'Привет из AER Connect TEST ONLY',
                writeClipboard: (s) async => received = s,
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

      Future<void> wait(String label, bool Function() cond) async {
        for (var i = 0; i < 150; i++) {
          if (cond()) return;
          await step();
        }
        fail(
          'timeout: $label; state=${c.state}; error=${c.error}; host=${c.host.link} ${c.host.error}',
        );
      }

      Future<void> shot(String name) async {
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

      String password() =>
          File(info['devicePasswordFile'] as String).readAsStringSync();

      // First run: address → fingerprint → name + enrollment code.
      await step();
      await shot('a1-setup');
      await t.enterText(
        find.byKey(const Key('gw-address')),
        info['gateway'] as String,
      );
      await t.tap(find.byKey(const Key('gw-probe')));
      await wait(
        'fingerprint',
        () => find.byKey(const Key('gw-confirm')).evaluate().isNotEmpty,
      );
      await t.tap(find.byKey(const Key('gw-confirm')));
      await step();
      await t.enterText(find.byKey(const Key('gw-name')), 'Ноутбук (стенд)');
      await t.enterText(
        find.byKey(const Key('gw-code')),
        info['enrollCode'] as String,
      );
      await t.tap(find.byKey(const Key('gw-enroll')));
      await wait(
        'registered',
        () => find.byKey(const Key('this-pc')).evaluate().isNotEmpty,
      );
      final myNumber = c.device!.number;
      expect(find.text(formatDeviceNumber(myNumber)), findsOneWidget);
      expect(devices.value, isNot(contains(info['enrollCode'] as String)));
      // The host half really runs: online for an ordinary user, an explicit
      // refusal when this session is elevated (accepted security model).
      await wait(
        'host half reported',
        () =>
            c.host.link == HostLink.online ||
            c.host.link == HostLink.unavailable,
      );
      debugPrint('LIVE: host half ${c.host.link} ${c.host.error}');
      if (c.host.link == HostLink.unavailable) {
        expect(c.host.error, contains('администратора'));
      } else {
        expect(c.host.tempPassword, hasLength(8));
      }
      await shot('a2-this-computer');

      // Wrong password, then the right one → real frames.
      await t.enterText(
        find.byKey(const Key('remote-id')),
        formatDeviceNumber(info['deviceNumber'] as String),
      );
      await t.enterText(find.byKey(const Key('remote-password')), 'wrong-pass');
      await t.tap(find.byKey(const Key('remote-connect')));
      await wait(
        'wrong password shown',
        () => c.error == 'Неверный пароль.' && !c.busy,
      );
      await shot('a3-wrong-password');
      final used = password();
      debugPrint(
        'LIVE: now=${DateTime.now().toIso8601String()} len=${used.length}',
      );
      expect(
        t
            .widget<TextField>(find.byKey(const Key('remote-password')))
            .controller!
            .text,
        isEmpty,
        reason: 'a refused password is cleared',
      );
      await t.tap(find.byKey(const Key('remote-password')));
      await t.enterText(find.byKey(const Key('remote-password')), used);
      await t.tap(find.byKey(const Key('remote-connect')));
      try {
        await wait(
          'real frame by ID',
          () => (surface?.currentState?.painted ?? 0) > 0,
        );
      } catch (_) {
        await t.runAsync(() async {
          final owner = HttpClient();
          final r = await owner.getUrl(
            Uri.parse('${info['coreUrl']}/api/v1/remote/sessions?limit=3'),
          );
          r.headers.set('Authorization', 'Bearer ${info['ownerToken']}');
          final body = await (await r.close()).transform(utf8.decoder).join();
          debugPrint('LIVE: sessions $body');
          owner.close(force: true);
        });
        rethrow;
      }
      await shot('a4-desktop-synthetic');
      await t.tap(find.byType(RemoteDesktopView));
      await step();
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
      await wait(
        'unicode clipboard echo',
        () => received == 'Привет из AER Connect TEST ONLY',
      );

      // End from the desktop page; the remote temporary password rotates.
      await t.tap(find.text('Завершить'));
      await wait('session ended', () => c.viewer == null && !c.live);
      await step();
      await wait('remote password rotated', () => password() != used);
      await shot('a5-ended');

      // The owner revokes this device on the server.
      await t.runAsync(() async {
        final owner = HttpClient();
        try {
          final list = await owner.getUrl(
            Uri.parse('${info['coreUrl']}/api/v1/remote/devices'),
          );
          list.headers.set('Authorization', 'Bearer ${info['ownerToken']}');
          final devs =
              (jsonDecode(
                    await (await list.close()).transform(utf8.decoder).join(),
                  ) as Map)['data']
                  as List;
          final me = devs.cast<Map>().firstWhere(
            (d) => d['number'] == myNumber,
          );
          final req = await owner.postUrl(
            Uri.parse(
              '${info['coreUrl']}/api/v1/remote/devices/${me['id']}/revoke',
            ),
          );
          req.headers.set('Authorization', 'Bearer ${info['ownerToken']}');
          final res = await req.close();
          expect(res.statusCode, 200);
          await res.drain<void>();
        } finally {
          owner.close(force: true);
        }
        await c.refresh();
      });
      await wait(
        'revoked banner',
        () => find.byKey(const Key('device-revoked')).evaluate().isNotEmpty,
      );
      await shot('a6-revoked');
      expect(t.takeException(), isNull);
    },
    skip:
        env['AER_REMOTELAB_BIN'] == null ||
        env['AER_SHADOW_BIN'] == null ||
        env['AER_CONNECT_HOST_EXE'] == null,
  );
}
