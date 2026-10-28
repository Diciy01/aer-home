// TEST DOUBLES ONLY: a fake built-in viewer. The real one (FreeRDP 3 via
// native/aer_rdp) is checked live in packages/aer_remote/test/viewer_lab_test.dart
// and integration_test/remote_embedded_live_test.dart.
import 'dart:async';

import 'package:aer_home_desktop/src/remote/remote_desktop_view.dart';
import 'package:aer_home_desktop/src/state/connection_controller.dart';
import 'package:aer_home_desktop/src/state/remote_controller.dart';
import 'package:aer_remote/aer_remote.dart'
    show InteractiveRemoteViewer, ViewerTarget, RdpPointer;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';

import '../fixtures.dart';
import 'remote_test.dart' hide main;

class FakeViewer implements InteractiveRemoteViewer {
  FakeViewer({this.clipboardAllowed = true});

  ViewerTarget? opened;
  bool closed = false;
  final keys = <(int, bool)>[];
  final mice = <(int, int, int)>[];
  final pushed = <String>[];
  final _status = StreamController<String>.broadcast();
  final _clip = StreamController<String>.broadcast();
  final _frames =
      StreamController<
        ({int width, int height, List<int> bgra, int seq})
      >.broadcast();

  @override
  String statusName = 'connecting';
  @override
  String lastError = '';
  @override
  final bool clipboardAllowed;

  void emit(String s) {
    statusName = s;
    _status.add(s);
  }

  void remoteCopied(String t) => _clip.add(t);

  @override
  Stream<({int width, int height, List<int> bgra, int seq})> get frameData =>
      _frames.stream;
  @override
  Stream<String> get statusNames => _status.stream;
  @override
  Stream<String> get remoteClipboard => _clip.stream;
  @override
  String get id => 'fake';
  @override
  bool get pinsCertificate => true;
  @override
  bool get enforcesClipboard => true;
  @override
  Future<bool> available() async => true;
  @override
  Future<void> open(ViewerTarget target) async => opened = target;
  @override
  Future<void> close() async => closed = true;
  @override
  void key(int scancode, bool down) => keys.add((scancode, down));
  @override
  void mouse(int flags, int x, int y) => mice.add((flags, x, y));
  @override
  bool pushClipboard(String text) {
    if (!clipboardAllowed) return false;
    pushed.add(text);
    return true;
  }
}

void main() {
  test('view → remote coordinates with letterboxing', () {
    const remote = Size(1280, 800);
    // 1600x800 view: image 1280x800 centred, 160 px bars left and right.
    expect(
      toRemote(const Offset(160, 0), const Size(1600, 800), remote),
      Offset.zero,
    );
    expect(
      toRemote(const Offset(800, 400), const Size(1600, 800), remote),
      const Offset(640, 400),
    );
    expect(
      toRemote(const Offset(100, 400), const Size(1600, 800), remote),
      isNull,
    );
    // Half size: coordinates double.
    expect(
      toRemote(const Offset(320, 200), const Size(640, 400), remote),
      const Offset(640, 400),
    );
    expect(toRemote(Offset.zero, const Size(640, 400), Size.zero), isNull);
  });

  test('wheel flags encode direction and size', () {
    expect(RdpPointer.wheelFlags(120), RdpPointer.wheel | 120);
    expect(
      RdpPointer.wheelFlags(-120),
      RdpPointer.wheel | RdpPointer.wheelNegative | 136,
    );
  });

  group('RemoteController with the built-in viewer', () {
    late ConnectionController conn;
    setUp(() async {
      conn = ConnectionController(
        clientFor(MockClient((r) async => healthyHandler(r))),
      );
      await conn.refresh();
    });
    tearDown(() => conn.dispose());

    RemoteController make(
      FakeRemoteApi api,
      FakeLauncher l,
      List<FakeViewer> made, {
      bool available = true,
    }) => RemoteController(
      api,
      conn,
      launcher: l,
      embedded: available
          ? (_) {
              final v = FakeViewer();
              made.add(v);
              return v;
            }
          : null,
      autoPoll: false,
      step: Duration.zero,
      probe: (_, _) async => const Duration(milliseconds: 1),
    );

    test(
      'connect opens the built-in viewer with the pinned grant, not Remmina',
      () async {
        final api = FakeRemoteApi(), l = FakeLauncher(), made = <FakeViewer>[];
        final c = make(api, l, made);
        addTearDown(c.dispose);
        await c.start();
        await c.connect(api.hostsList.first);
        expect(l.launched, isEmpty);
        final v = made.single;
        expect(v.opened!.password, 'TESTpassword1234567890abcdefgh');
        expect(v.opened!.certSha256, isNotEmpty);
        expect(c.active!.viewer, same(v));
        expect(c.active!.phase, RemotePhase.running);
        expect(c.viewerNameFor(c.active), contains('встроенный'));

        v.emit('closed');
        await Future<void>.delayed(Duration.zero);
        expect(c.active!.phase, RemotePhase.clientClosed);
        await c.reconnect();
        expect(
          made,
          hasLength(2),
          reason: 'reconnect = a new viewer, same session',
        );
        expect(v.closed, isTrue);
        expect(api.grants, 1, reason: 'no second grant');

        await c.end();
        expect(made.last.closed, isTrue);
        expect(c.active!.viewer, isNull);
        expect(c.active!.live, isFalse);
      },
    );

    test('revoke closes the built-in viewer', () async {
      final api = FakeRemoteApi(), l = FakeLauncher(), made = <FakeViewer>[];
      final c = make(api, l, made);
      addTearDown(c.dispose);
      await c.start();
      await c.connect(api.hostsList.first);
      await c.revoke('s1');
      expect(made.single.closed, isTrue);
      expect(c.active!.phase, RemotePhase.ended);
    });

    test(
      'external client when the user asks for it or the library is missing',
      () async {
        final api = FakeRemoteApi(), l = FakeLauncher(), made = <FakeViewer>[];
        final c = make(api, l, made)..preferEmbedded = false;
        addTearDown(c.dispose);
        await c.start();
        await c.connect(api.hostsList.first);
        expect(made, isEmpty);
        expect(l.launched, hasLength(1));
        expect(c.active!.message, contains('Remmina'));

        final api2 = FakeRemoteApi(), l2 = FakeLauncher();
        final c2 = make(api2, l2, made, available: false);
        addTearDown(c2.dispose);
        expect(c2.embeddedAvailable, isFalse);
        await c2.start();
        await c2.connect(api2.hostsList.first);
        expect(l2.launched, hasLength(1));
      },
    );

    test('no viewer at all: nothing is requested', () async {
      final api = FakeRemoteApi(),
          l = FakeLauncher(available: false),
          made = <FakeViewer>[];
      final c = make(api, l, made, available: false);
      addTearDown(c.dispose);
      await c.start();
      await c.connect(api.hostsList.first);
      expect(api.created, isEmpty);
      expect(c.active!.phase, RemotePhase.failed);
    });
  });

  group('RemoteDesktopView input and clipboard', () {
    Future<(FakeViewer, List<String>)> pump(
      WidgetTester tester, {
      bool clipboard = true,
      String local = 'локальный текст',
    }) async {
      final v = FakeViewer(clipboardAllowed: clipboard);
      final written = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: RemoteDesktopView(
            viewer: v,
            readClipboard: () async => local,
            writeClipboard: (t) async => written.add(t),
          ),
        ),
      );
      await tester.pump();
      return (v, written);
    }

    testWidgets('physical keys become RDP scancodes, down and up', (
      tester,
    ) async {
      final (v, _) = await pump(tester);
      await tester.sendKeyEvent(
        LogicalKeyboardKey.keyA,
        physicalKey: PhysicalKeyboardKey.keyA,
      );
      await tester.sendKeyEvent(
        LogicalKeyboardKey.enter,
        physicalKey: PhysicalKeyboardKey.enter,
      );
      await tester.sendKeyEvent(
        LogicalKeyboardKey.arrowLeft,
        physicalKey: PhysicalKeyboardKey.arrowLeft,
      );
      await tester.pump();
      expect(v.keys, [
        (0x1E, true), (0x1E, false), // a
        (0x1C, true), (0x1C, false), // Enter
        (0x14B, true), (0x14B, false), // ← (extended)
      ]);
    });

    testWidgets(
      'Ctrl+V offers the local clipboard first; remote copies land locally',
      (tester) async {
        final (v, written) = await pump(tester);
        v.pushed.clear(); // the focus sync may already have offered it
        await tester.sendKeyDownEvent(
          LogicalKeyboardKey.controlLeft,
          physicalKey: PhysicalKeyboardKey.controlLeft,
        );
        await tester.sendKeyEvent(
          LogicalKeyboardKey.keyV,
          physicalKey: PhysicalKeyboardKey.keyV,
        );
        await tester.sendKeyUpEvent(
          LogicalKeyboardKey.controlLeft,
          physicalKey: PhysicalKeyboardKey.controlLeft,
        );
        await tester.pump();
        expect(v.keys.map((k) => k.$1), [0x1D, 0x2F, 0x2F, 0x1D]);

        v.remoteCopied('с удалённого');
        await tester.pump();
        expect(written, ['с удалённого']);
      },
    );

    testWidgets('no clipboard right: nothing is offered or written', (
      tester,
    ) async {
      final (v, written) = await pump(tester, clipboard: false);
      await tester.sendKeyDownEvent(
        LogicalKeyboardKey.controlLeft,
        physicalKey: PhysicalKeyboardKey.controlLeft,
      );
      await tester.sendKeyEvent(
        LogicalKeyboardKey.keyV,
        physicalKey: PhysicalKeyboardKey.keyV,
      );
      await tester.sendKeyUpEvent(
        LogicalKeyboardKey.controlLeft,
        physicalKey: PhysicalKeyboardKey.controlLeft,
      );
      v.remoteCopied('не должно попасть');
      await tester.pump();
      expect(v.pushed, isEmpty);
      expect(written, isEmpty);
      expect(v.keys, hasLength(4), reason: 'keys still go through');
    });

    testWidgets('status overlay explains reconnecting and failure', (
      tester,
    ) async {
      final (v, _) = await pump(tester);
      expect(find.text('Подключение к рабочему столу…'), findsOneWidget);
      v.emit('reconnecting');
      await tester.pump();
      await tester.pump();
      expect(find.textContaining('переподключаемся'), findsOneWidget);
      v.lastError = 'certificate does not match';
      v.emit('failed');
      await tester.pump();
      await tester.pump();
      expect(find.textContaining('certificate does not match'), findsOneWidget);
      v.emit('connected');
      await tester.pump();
      await tester.pump();
      expect(find.byType(Card), findsNothing);
    });
  });
}
