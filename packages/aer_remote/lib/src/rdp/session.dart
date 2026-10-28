import 'dart:async';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../viewer.dart';
import 'native.dart';

enum RdpState { idle, connecting, connected, disconnected, failed }

/// One native RDP connection (FreeRDP 3 via aer_rdp). Not reusable: a
/// reconnect is a new [RdpSession].
class RdpSession {
  RdpSession(this._n) : _h = _n.newHandle() {
    if (_h == nullptr) throw StateError('aer_rdp_new failed');
  }

  final RdpNative _n;
  Pointer<Void> _h;
  int _seq = -1;
  final Pointer<Uint64> _clipSeq = calloc<Uint64>();

  bool get _alive => _h != nullptr;

  /// Starts connecting; [ViewerTarget.certSha256] is the only certificate
  /// accepted. False when the connection could not even be started.
  bool connect(ViewerTarget t, {int width = 1280, int height = 800}) {
    final host = t.host.toNativeUtf8(), user = t.username.toNativeUtf8();
    final pass = t.password.toNativeUtf8(), pin = t.certSha256.toNativeUtf8();
    try {
      return _n.connect(
            _h,
            host,
            t.port,
            user,
            pass,
            pin,
            width,
            height,
            t.clipboard ? 1 : 0,
          ) ==
          0;
    } finally {
      for (final p in [host, user, pass, pin]) {
        p
            .cast<Uint8>()
            .asTypedList(p.length)
            .fillRange(0, p.length, 0); // wipe the password copy
        calloc.free(p);
      }
    }
  }

  RdpState get state => _alive
      ? RdpState.values[_n.state(_h).clamp(0, 4)]
      : RdpState.disconnected;

  String get error => _alive ? _n.error(_h).toDartString() : '';

  /// The newest frame, or null when nothing changed since the last call.
  RdpFrame? takeFrame() {
    if (!_alive) return null;
    final w = calloc<Int32>(),
        h = calloc<Int32>(),
        s = calloc<Int32>(),
        seq = calloc<Uint64>();
    try {
      final p = _n.frameLock(_h, w, h, s, seq);
      if (p == nullptr) return null;
      try {
        if (seq.value == _seq) return null;
        _seq = seq.value;
        final width = w.value, height = h.value, stride = s.value;
        final out = Uint8List(width * 4 * height);
        final src = p.asTypedList(stride * height);
        if (stride == width * 4) {
          out.setAll(0, src);
        } else {
          for (var y = 0; y < height; y++) {
            out.setRange(y * width * 4, (y + 1) * width * 4, src, y * stride);
          }
        }
        return RdpFrame(width, height, out, _seq);
      } finally {
        _n.frameUnlock(_h);
      }
    } finally {
      for (final p in [w, h, s, seq]) {
        calloc.free(p);
      }
    }
  }

  void mouse(int flags, int x, int y) {
    if (_alive) _n.mouse(_h, flags, x, y);
  }

  void key(int scancode, bool down) {
    if (_alive) _n.key(_h, scancode, down ? 1 : 0);
  }

  void unicode(int codepoint, bool down) {
    if (_alive) _n.unicode(_h, codepoint, down ? 1 : 0);
  }

  /// Offers local text to the remote clipboard (refused when the session
  /// has no clipboard right).
  bool setClipboard(String text) {
    if (!_alive) return false;
    final p = text.toNativeUtf8();
    try {
      return _n.clipSet(_h, p) == 0;
    } finally {
      calloc.free(p);
    }
  }

  /// The remote clipboard text when it changed since the last call.
  String? takeRemoteClipboard() {
    if (!_alive) return null;
    final p = _n.clipGet(_h, _clipSeq);
    if (p == nullptr) return null;
    try {
      return p.toDartString();
    } finally {
      _n.memFree(p.cast());
    }
  }

  void disconnect() {
    if (_alive) _n.disconnect(_h);
  }

  /// Joins the connection thread and frees the native side.
  void dispose() {
    if (!_alive) return;
    _n.free(_h);
    _h = nullptr;
    calloc.free(_clipSeq);
  }
}

/// What the viewer UI shows.
enum ViewerStatus { connecting, connected, reconnecting, closed, failed }

/// Built-in viewer (ADR-017, M14.3): drives [RdpSession]s for one target,
/// reconnects after an unexpected drop while [canReconnect] says the AER
/// session is still alive, and exposes frames, status and the remote
/// clipboard. UI-agnostic: the Flutter widget only paints and forwards input.
class EmbeddedRdpViewer implements InteractiveRemoteViewer {
  EmbeddedRdpViewer(
    this._native, {
    this.canReconnect,
    this.maxReconnects = 5,
    this.poll = const Duration(milliseconds: 16),
    this.width = 1280,
    this.height = 800,
  });

  /// Loads the native library; null when it is not available here.
  static EmbeddedRdpViewer? tryCreate({
    Future<bool> Function()? canReconnect,
    int width = 1280,
    int height = 800,
  }) {
    final n = RdpNative.load();
    return n == null
        ? null
        : EmbeddedRdpViewer(
            n,
            canReconnect: canReconnect,
            width: width,
            height: height,
          );
  }

  final RdpNative _native;
  final Future<bool> Function()? canReconnect;
  final int maxReconnects;
  final Duration poll;
  final int width;
  final int height;

  RdpSession? _s;
  ViewerTarget? _target;
  Timer? _timer;
  var _closing = false;
  var _attempts = 0;
  var _wasConnected = false;
  var _busy = false;

  final _status = StreamController<ViewerStatus>.broadcast();
  final _frames = StreamController<RdpFrame>.broadcast();
  final _clipboard = StreamController<String>.broadcast();

  ViewerStatus status = ViewerStatus.connecting;
  @override
  String lastError = '';
  RdpFrame? lastFrame;
  int reconnects = 0;

  Stream<ViewerStatus> get statuses => _status.stream;
  Stream<RdpFrame> get frames => _frames.stream;

  /// Text the remote side put on its clipboard (only with clipboard right).
  @override
  Stream<String> get remoteClipboard => _clipboard.stream;

  @override
  Stream<({int width, int height, List<int> bgra, int seq})> get frameData =>
      _frames.stream.map(
        (f) => (width: f.width, height: f.height, bgra: f.bgra, seq: f.seq),
      );

  @override
  Stream<String> get statusNames => _status.stream.map((s) => s.name);

  @override
  String get statusName => status.name;

  @override
  bool get clipboardAllowed => _target?.clipboard ?? false;

  @override
  String get id => 'embedded-freerdp';

  @override
  bool get pinsCertificate => true;

  @override
  bool get enforcesClipboard => true;

  @override
  Future<bool> available() async => true;

  void _set(ViewerStatus s) {
    if (status == s) return;
    status = s;
    if (!_status.isClosed) _status.add(s);
  }

  @override
  Future<void> open(ViewerTarget target) async {
    _target = target;
    _start();
    _timer = Timer.periodic(poll, (_) => _tick());
  }

  void _start() {
    final s = RdpSession(_native);
    _s = s;
    if (!s.connect(_target!, width: width, height: height)) {
      lastError = s.error;
    }
  }

  Future<void> _tick() async {
    final s = _s;
    if (s == null || _busy) return;
    final f = s.takeFrame();
    if (f != null) {
      lastFrame = f;
      if (!_frames.isClosed) _frames.add(f);
    }
    if (_target!.clipboard) {
      final t = s.takeRemoteClipboard();
      if (t != null && !_clipboard.isClosed) _clipboard.add(t);
    }
    switch (s.state) {
      case RdpState.connected:
        _wasConnected = true;
        _attempts = 0;
        _set(ViewerStatus.connected);
      case RdpState.disconnected || RdpState.failed:
        if (_closing) return;
        _busy = true;
        try {
          lastError = s.error;
          s.dispose();
          _s = null;
          final retry =
              _wasConnected &&
              _attempts < maxReconnects &&
              await _mayReconnect();
          if (!retry) {
            _set(
              s.state == RdpState.failed && !_wasConnected
                  ? ViewerStatus.failed
                  : ViewerStatus.closed,
            );
            _timer?.cancel();
            return;
          }
          _attempts++;
          reconnects++;
          _set(ViewerStatus.reconnecting);
          await Future<void>.delayed(Duration(milliseconds: 300 * _attempts));
          if (!_closing) _start();
        } finally {
          _busy = false;
        }
      case RdpState.idle || RdpState.connecting:
        break;
    }
  }

  /// Any failure to confirm (revoked credential, Core away) means no.
  Future<bool> _mayReconnect() async {
    try {
      return await canReconnect?.call() ?? true;
    } catch (_) {
      return false;
    }
  }

  @override
  void mouse(int flags, int x, int y) => _s?.mouse(flags, x, y);
  @override
  void key(int scancode, bool down) => _s?.key(scancode, down);
  void unicode(int codepoint, bool down) => _s?.unicode(codepoint, down);

  /// Sends local clipboard text, only when the session allows it.
  @override
  bool pushClipboard(String text) =>
      (_target?.clipboard ?? false) && (_s?.setClipboard(text) ?? false);

  @override
  Future<void> close() async {
    _closing = true;
    _timer?.cancel();
    final s = _s;
    _s = null;
    if (s != null) {
      s.disconnect();
      s.dispose();
    }
    _set(ViewerStatus.closed);
    await _status.close();
    await _frames.close();
    await _clipboard.close();
  }
}
