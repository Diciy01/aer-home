// EXPLICIT OWNER CONSENT ONLY. Real DXGI/SendInput on the current desktop.
// The separately-launched ordinary-user fixture retains production consent/Stop.
// Never save desktop pixels or clipboard contents. Input only at its verified window.
import 'dart:convert';
import 'dart:io';

import 'package:aer_connect/connect_app.dart';
import 'package:aer_connect/controller.dart';
import 'package:aer_remote/aer_remote.dart';
import 'package:aer_widgets/aer_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

class AcceptanceMemoryStore implements ConnectStore {
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
  final run = env['AER_DESKTOP_ACCEPTANCE_DIR'];
  final stopMode = env['AER_DESKTOP_ACCEPTANCE_END'] == 'stop';
  testWidgets('OWNER OPT-IN: actual Windows desktop through Connect/Gateway', (
    t,
  ) async {
    Map<String, dynamic> read(String name) {
      var path = '$run/$name.json';
      if (name == 'target') {
        final snapshots =
            Directory(run!)
                .listSync()
                .whereType<File>()
                .where((f) => RegExp(r'target-\d{8}\.json$').hasMatch(f.path))
                .toList()
              ..sort((a, b) => a.path.compareTo(b.path));
        path = snapshots.last.path;
      }
      return jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;
    }

    var commandId = 0;
    void command(String action) {
      final id = ++commandId;
      final path = '$run/command-${id.toString().padLeft(8, '0')}.json';
      File('$path.tmp').writeAsStringSync(
        jsonEncode({'id': id, 'action': action}),
        flush: true,
      );
      File('$path.tmp').renameSync(path);
    }

    final info = read('lab');
    expect(info['hostMode'], 'desktop');
    expect(Uri.parse(info['gateway'] as String).host, '127.0.0.1');
    expect(Uri.parse(info['coreUrl'] as String).host, '127.0.0.1');
    final c = ConnectController(
      store: AcceptanceMemoryStore(),
      poll: const Duration(milliseconds: 200),
      viewerFactory: (check) =>
          EmbeddedRdpViewer.tryCreate(canReconnect: check)!,
    );
    final surface = GlobalKey<RemoteDesktopViewState>();
    addTearDown(() async {
      await t.pumpWidget(const SizedBox());
      await t.runAsync(() async {
        await c.shutdown().timeout(const Duration(seconds: 15));
        c.dispose();
        command('close');
      });
    });
    await t.pumpWidget(
      ConnectApp(
        controller: c,
        desktopBuilder: (v) => RemoteDesktopView(
          key: surface,
          viewer: v,
          readClipboard: () async => null,
          writeClipboard: (_) async {},
        ),
      ),
    );
    Future<void> step() async {
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      await t.pump(const Duration(milliseconds: 200));
      if (File('$run/fixture-error.json').existsSync()) {
        fail('Fixture stopped: ${read('fixture-error')['error']}');
      }
      if (File('$run/closed.json').existsSync()) {
        fail('Fixture was closed; input is cancelled');
      }
    }

    Future<void> wait(
      String label,
      bool Function() condition, {
      int tries = 125,
    }) async {
      for (var i = 0; i < tries; i++) {
        if (condition()) return;
        if (c.state == RemoteState.failed) {
          fail('Session failed while waiting for $label: ${c.error}');
        }
        await step();
      }
      fail('timeout $label; state=${c.state}, error=${c.error}');
    }

    try {
      await t.runAsync(
        () => c.pair(
          info['gateway'] as String,
          info['fingerprint'] as String,
          info['pairingCode'] as String,
        ),
      );
      await t.pump();
      expect(c.hosts, hasLength(1));
      final initial = read('target');
      expect(initial['elevated'], isFalse);
      debugPrint(
        'LIVE: ordinary-user fixture verified; waiting for MANUAL local consent',
      );
      await t.tap(find.byKey(Key("gw-connect-${info['hostId']}")));
      await wait(
        'local consent and painted DXGI frame',
        () => (surface.currentState?.painted ?? 0) > 0,
        tries: 450,
      );
      final viewer = c.viewer! as EmbeddedRdpViewer;
      final conn = c.connection!;
      expect(conn.session!.route, 'relay');
      expect(conn.grant!.clipboard, isFalse);
      expect(conn.grant!.files, isFalse);
      await wait(
        'visible native Stop and loopback listeners',
        () =>
            (read('target')['hostProcesses'] as List).any(
              (p) => (p as Map)['stopVisible'] == true,
            ) &&
            File('$run/network.json').existsSync(),
      );
      final listeners = read('network')['listeners'] as List;
      expect(listeners.length, greaterThanOrEqualTo(3));
      for (final listener in listeners) {
        expect((listener as Map)['address'], '127.0.0.1');
      }
      final target = read('target');
      expect(target['hostProcesses'], isNotEmpty);
      for (final process in target['hostProcesses'] as List) {
        expect((process as Map)['elevated'], isFalse);
      }
      bool marker(List point, List<int> rgb) {
        final f = viewer.lastFrame;
        if (f == null ||
            f.width != target['width'] ||
            f.height != target['height']) {
          return false;
        }
        final x = point[0] as int, y = point[1] as int;
        final offset = (y * f.width + x) * 4;
        return (f.bgra[offset + 2] - rgb[0]).abs() < 25 &&
            (f.bgra[offset + 1] - rgb[1]).abs() < 25 &&
            (f.bgra[offset] - rgb[2]).abs() < 25;
      }

      await wait(
        'actual test-window markers in DXGI frame',
        () =>
            marker(target['markerA'] as List, [32, 145, 210]) &&
            marker(target['markerB'] as List, [221, 68, 92]),
      );
      expect(conn.rdp!.bytesDown, greaterThan(0));
      expect(conn.rdp!.bytesUp, greaterThan(0));
      debugPrint(
        'LIVE: real DXGI markers painted in Connect; route=relay; clipboard/files disabled',
      );

      if (!stopMode) {
        command('focus');
        await wait('safe target visible/clear', () {
          final s = read('target');
          return s['clear'] == true;
        });
        final before = read('target');
        expect(before['clear'], isTrue);
        expect(
          DateTime.now().millisecondsSinceEpoch - (before['utcMs'] as int),
          lessThan(2000),
        );
        // Only the verified test-window point. No global hotkeys or clipboard input.
        final x = before['x'] as int, y = before['y'] as int;
        expect(x, inInclusiveRange(0, viewer.lastFrame!.width - 1));
        expect(y, inInclusiveRange(0, viewer.lastFrame!.height - 1));
        viewer.mouse(0x0800, x, y); // move
        viewer.mouse(0x9000, x, y); // left down
        viewer.mouse(0x1000, x, y); // left up
        await wait(
          'SendInput mouse delivered to safe target',
          () => (read('target')['clicks'] as int) > (before['clicks'] as int),
        );
        await wait(
          'safe target foreground after remote click',
          () => read('target')['foreground'] == true,
        );
        final focused = read('target');
        expect(focused['foreground'], isTrue);
        expect(focused['clear'], isTrue);
        viewer.key(
          0x1e,
          true,
        ); // A physical key only, current layout is preserved.
        viewer.key(0x1e, false);
        await wait(
          'SendInput keyboard delivered to safe target',
          () => (read('target')['keys'] as int) > (before['keys'] as int),
        );
        expect(read('target')['lastKey'], 0x41);
        debugPrint(
          'LIVE: mouse and keyboard received only by the safe test window',
        );
      }
      final bytesDown = conn.rdp!.bytesDown, bytesUp = conn.rdp!.bytesUp;
      final hostPids = (read('target')['hostProcesses'] as List)
          .map((e) => (e as Map)['pid'])
          .toList();
      final watch = Stopwatch()..start();
      if (stopMode) {
        command(
          'stop-host',
        ); // Production visible button event, own helper only.
        await wait(
          'local visible Stop acknowledged',
          () => read('target')['stopPressed'] == true,
        );
        await wait('local Stop removes viewer', () => c.viewer == null);
      } else {
        await t.runAsync(() async {
          final http = HttpClient();
          try {
            final request = await http.postUrl(
              Uri.parse(
                "${info['coreUrl']}/api/v1/remote/clients/${info['clientId']}/revoke",
              ),
            );
            request.headers.set(
              'Authorization',
              "Bearer ${info['ownerToken']}",
            );
            final response = await request.close();
            expect(response.statusCode, 200);
            await response.drain<void>();
          } finally {
            http.close(force: true);
          }
        });
        await wait('revocation removes viewer', () => c.viewer == null);
        expect(c.unauthorized, isTrue);
      }
      await wait(
        'native helper exits',
        () => (read('target')['hostProcesses'] as List).isEmpty,
      );
      expect(find.byType(RemoteDesktopView), findsNothing);
      final result = {
        'mode': stopMode ? 'stop' : 'revoke',
        'dxgi': true,
        'painted': true,
        'mouse': !stopMode,
        'keyboard': !stopMode,
        'route': 'relay',
        'bytesDown': bytesDown,
        'bytesUp': bytesUp,
        'hostPids': hostPids,
        'ordinaryUser': true,
        'stopVisible': true,
        'loopbackOnly': true,
        'terminalMs': watch.elapsedMilliseconds,
      };
      File('$run/result.json').writeAsStringSync(jsonEncode(result));
      debugPrint('LIVE: ${result['mode']} PASS; native helper exited');
      expect(t.takeException(), isNull);
    } catch (_) {
      // Unexpected behaviour ends this stand immediately; never continue input.
      try {
        await t.runAsync(c.shutdown);
      } finally {
        command('close');
      }
      rethrow;
    }
  }, skip: env['AER_DESKTOP_ACCEPTANCE'] != '1' || run == null);
}
