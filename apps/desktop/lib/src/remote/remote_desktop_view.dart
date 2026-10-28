import 'dart:async';
import 'dart:ui' as ui;

import 'package:aer_remote/aer_remote.dart'
    show InteractiveRemoteViewer, RdpPointer, rdpScancodeForHid;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// The remote desktop inside AER HOME (built-in viewer, ADR-017 M14.3):
/// paints the engine's frames scaled to fit, forwards mouse, wheel and
/// physical keys, and syncs the text clipboard only when the session
/// allows it. All protocol work stays in the engine (`aer_remote`).
class RemoteDesktopView extends StatefulWidget {
  const RemoteDesktopView({
    super.key,
    required this.viewer,
    this.readClipboard = _readClipboard,
    this.writeClipboard = _writeClipboard,
  });

  final InteractiveRemoteViewer viewer;
  final Future<String?> Function() readClipboard;
  final Future<void> Function(String) writeClipboard;

  static Future<String?> _readClipboard() async =>
      (await Clipboard.getData(Clipboard.kTextPlain))?.text;
  static Future<void> _writeClipboard(String t) =>
      Clipboard.setData(ClipboardData(text: t));

  @override
  State<RemoteDesktopView> createState() => RemoteDesktopViewState();
}

/// Maps a point in the view to remote desktop coordinates for an image of
/// [remote] size painted with BoxFit.contain into [view]; null when the
/// point is on the letterbox.
Offset? toRemote(Offset local, Size view, Size remote) {
  if (remote.isEmpty || view.isEmpty) return null;
  final s = (view.width / remote.width) < (view.height / remote.height)
      ? view.width / remote.width
      : view.height / remote.height;
  final dx = (view.width - remote.width * s) / 2;
  final dy = (view.height - remote.height * s) / 2;
  final x = (local.dx - dx) / s, y = (local.dy - dy) / s;
  if (x < 0 || y < 0 || x >= remote.width || y >= remote.height) return null;
  return Offset(x, y);
}

class RemoteDesktopViewState extends State<RemoteDesktopView> {
  final _focus = FocusNode(debugLabel: 'remote desktop');
  StreamSubscription<Object?>? _frames, _status, _clip;
  ui.Image? _image;
  Size _remote = Size.zero;
  int _buttons = 0;
  String? _lastPushed;
  Future<void> _keys = Future.value();
  bool _decoding = false;
  ({int width, int height, List<int> bgra, int seq})? _pending;

  /// Frames painted so far (tests and diagnostics).
  int painted = 0;

  InteractiveRemoteViewer get v => widget.viewer;

  @override
  void initState() {
    super.initState();
    _frames = v.frameData.listen(_onFrame);
    _status = v.statusNames.listen((_) => setState(() {}));
    if (v.clipboardAllowed) {
      _clip = v.remoteClipboard.listen((t) {
        _lastPushed = t; // do not echo it back
        unawaited(widget.writeClipboard(t));
      });
    }
    _focus.addListener(() {
      if (_focus.hasFocus) unawaited(_syncLocalClipboard());
    });
  }

  void _onFrame(({int width, int height, List<int> bgra, int seq}) f) {
    _pending = f;
    if (!_decoding) _decodeNext();
  }

  void _decodeNext() {
    final f = _pending;
    _pending = null;
    if (f == null || !mounted) return;
    _decoding = true;
    ui.decodeImageFromPixels(
      f.bgra is Uint8List ? f.bgra as Uint8List : Uint8List.fromList(f.bgra),
      f.width,
      f.height,
      ui.PixelFormat.bgra8888,
      (img) {
        _decoding = false;
        if (!mounted) {
          img.dispose();
          return;
        }
        final old = _image;
        setState(() {
          _image = img;
          _remote = Size(f.width.toDouble(), f.height.toDouble());
          painted++;
        });
        old?.dispose();
        _decodeNext();
      },
    );
  }

  Future<void> _syncLocalClipboard() async {
    if (!v.clipboardAllowed) return;
    final t = await widget.readClipboard();
    if (t == null || t.isEmpty || t == _lastPushed) return;
    _lastPushed = t;
    v.pushClipboard(t);
  }

  Offset? _map(Offset local) {
    final box = context.findRenderObject() as RenderBox?;
    return box == null ? null : toRemote(local, box.size, _remote);
  }

  void _move(PointerEvent e) {
    final p = _map(e.localPosition);
    if (p != null) v.mouse(RdpPointer.move, p.dx.round(), p.dy.round());
  }

  static int _flag(int button) => switch (button) {
    kPrimaryButton => RdpPointer.button1,
    kSecondaryButton => RdpPointer.button2,
    kMiddleMouseButton => RdpPointer.button3,
    _ => 0,
  };

  void _buttonsChanged(PointerEvent e) {
    final p = _map(e.localPosition);
    if (p == null) return;
    for (final b in [kPrimaryButton, kSecondaryButton, kMiddleMouseButton]) {
      final was = _buttons & b != 0, now = e.buttons & b != 0;
      if (was == now) continue;
      v.mouse(
        _flag(b) | (now ? RdpPointer.down : 0),
        p.dx.round(),
        p.dy.round(),
      );
    }
    _buttons = e.buttons;
  }

  void _scroll(PointerSignalEvent e) {
    if (e is! PointerScrollEvent) return;
    final p = _map(e.localPosition);
    if (p == null) return;
    if (e.scrollDelta.dy != 0) {
      v.mouse(
        RdpPointer.wheelFlags(e.scrollDelta.dy > 0 ? -120 : 120),
        p.dx.round(),
        p.dy.round(),
      );
    }
    if (e.scrollDelta.dx != 0) {
      v.mouse(
        RdpPointer.wheelFlags(
          e.scrollDelta.dx > 0 ? 120 : -120,
          horizontal: true,
        ),
        p.dx.round(),
        p.dy.round(),
      );
    }
  }

  KeyEventResult _key(FocusNode _, KeyEvent e) {
    final sc = rdpScancodeForHid(e.physicalKey.usbHidUsage);
    if (sc == null) return KeyEventResult.ignored;
    final down = e is! KeyUpEvent;
    final paste =
        down &&
        e.physicalKey == PhysicalKeyboardKey.keyV &&
        (HardwareKeyboard.instance.isControlPressed ||
            HardwareKeyboard.instance.isMetaPressed);
    // Keys stay in order; a paste first offers the local clipboard.
    _keys = _keys.then((_) async {
      if (paste) await _syncLocalClipboard();
      v.key(sc, down);
    });
    return KeyEventResult.handled;
  }

  @override
  void dispose() {
    _frames?.cancel();
    _status?.cancel();
    _clip?.cancel();
    _focus.dispose();
    _image?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final status = v.statusName;
    return Focus(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: _key,
      child: Listener(
        onPointerHover: _move,
        onPointerMove: (e) {
          _move(e);
          _buttonsChanged(e);
        },
        onPointerDown: (e) {
          _focus.requestFocus();
          _move(e);
          _buttonsChanged(e);
        },
        onPointerUp: _buttonsChanged,
        onPointerSignal: _scroll,
        child: ColoredBox(
          color: Colors.black,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (_image != null)
                RawImage(
                  image: _image,
                  fit: BoxFit.contain,
                  filterQuality: FilterQuality.medium,
                ),
              if (status != 'connected')
                Center(
                  child: Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(switch (status) {
                        'connecting' => 'Подключение к рабочему столу…',
                        'reconnecting' => 'Связь прервана — переподключаемся…',
                        'failed' => 'Не удалось подключиться: ${v.lastError}',
                        _ => 'Удалённый рабочий стол закрыт',
                      }),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
