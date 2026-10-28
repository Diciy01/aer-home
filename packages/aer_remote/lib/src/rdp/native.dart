import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

/// Bindings to native/aer_rdp (a thin C layer over FreeRDP 3).
class RdpNative {
  RdpNative._(DynamicLibrary lib)
    : version = lib.lookupFunction<Int32 Function(), int Function()>(
        'aer_rdp_version',
      ),
      newHandle = lib
          .lookupFunction<Pointer<Void> Function(), Pointer<Void> Function()>(
            'aer_rdp_new',
          ),
      connect = lib
          .lookupFunction<
            Int32 Function(
              Pointer<Void>,
              Pointer<Utf8>,
              Int32,
              Pointer<Utf8>,
              Pointer<Utf8>,
              Pointer<Utf8>,
              Int32,
              Int32,
              Int32,
            ),
            int Function(
              Pointer<Void>,
              Pointer<Utf8>,
              int,
              Pointer<Utf8>,
              Pointer<Utf8>,
              Pointer<Utf8>,
              int,
              int,
              int,
            )
          >('aer_rdp_connect'),
      state = lib
          .lookupFunction<
            Int32 Function(Pointer<Void>),
            int Function(Pointer<Void>)
          >('aer_rdp_state'),
      error = lib
          .lookupFunction<
            Pointer<Utf8> Function(Pointer<Void>),
            Pointer<Utf8> Function(Pointer<Void>)
          >('aer_rdp_error'),
      frameLock = lib
          .lookupFunction<
            Pointer<Uint8> Function(
              Pointer<Void>,
              Pointer<Int32>,
              Pointer<Int32>,
              Pointer<Int32>,
              Pointer<Uint64>,
            ),
            Pointer<Uint8> Function(
              Pointer<Void>,
              Pointer<Int32>,
              Pointer<Int32>,
              Pointer<Int32>,
              Pointer<Uint64>,
            )
          >('aer_rdp_frame_lock'),
      frameUnlock = lib
          .lookupFunction<
            Void Function(Pointer<Void>),
            void Function(Pointer<Void>)
          >('aer_rdp_frame_unlock'),
      mouse = lib
          .lookupFunction<
            Void Function(Pointer<Void>, Int32, Int32, Int32),
            void Function(Pointer<Void>, int, int, int)
          >('aer_rdp_mouse'),
      key = lib
          .lookupFunction<
            Void Function(Pointer<Void>, Int32, Int32),
            void Function(Pointer<Void>, int, int)
          >('aer_rdp_key'),
      unicode = lib
          .lookupFunction<
            Void Function(Pointer<Void>, Int32, Int32),
            void Function(Pointer<Void>, int, int)
          >('aer_rdp_unicode'),
      clipSet = lib
          .lookupFunction<
            Int32 Function(Pointer<Void>, Pointer<Utf8>),
            int Function(Pointer<Void>, Pointer<Utf8>)
          >('aer_rdp_clip_set'),
      clipGet = lib
          .lookupFunction<
            Pointer<Utf8> Function(Pointer<Void>, Pointer<Uint64>),
            Pointer<Utf8> Function(Pointer<Void>, Pointer<Uint64>)
          >('aer_rdp_clip_get'),
      disconnect = lib
          .lookupFunction<
            Void Function(Pointer<Void>),
            void Function(Pointer<Void>)
          >('aer_rdp_disconnect'),
      free = lib
          .lookupFunction<
            Void Function(Pointer<Void>),
            void Function(Pointer<Void>)
          >('aer_rdp_free'),
      memFree = lib
          .lookupFunction<
            Void Function(Pointer<Void>),
            void Function(Pointer<Void>)
          >('aer_rdp_mem_free');

  /// ABI version this binding expects.
  static const abi = 1;

  static RdpNative? _cached;

  /// Loads the library: `AER_RDP_LIB`, then the Flutter bundle
  /// (`lib/libaer_rdp.so`; on Windows `aer_rdp.dll` beside the exe, by full
  /// path), then the loader's search path. Null when it is missing — the UI
  /// then offers the external client.
  static RdpNative? load() {
    if (_cached != null) return _cached;
    final name = Platform.isWindows ? 'aer_rdp.dll' : 'libaer_rdp.so';
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    for (final path in [
      Platform.environment['AER_RDP_LIB'],
      Platform.isWindows ? '$exeDir\\$name' : '$exeDir/lib/$name',
      name,
    ]) {
      if (path == null || path.isEmpty) continue;
      try {
        final n = RdpNative._(DynamicLibrary.open(path));
        if (n.version() != abi) continue;
        return _cached = n;
      } on ArgumentError {
        continue;
      }
    }
    return null;
  }

  final int Function() version;
  final Pointer<Void> Function() newHandle;
  final int Function(
    Pointer<Void>,
    Pointer<Utf8>,
    int,
    Pointer<Utf8>,
    Pointer<Utf8>,
    Pointer<Utf8>,
    int,
    int,
    int,
  )
  connect;
  final int Function(Pointer<Void>) state;
  final Pointer<Utf8> Function(Pointer<Void>) error;
  final Pointer<Uint8> Function(
    Pointer<Void>,
    Pointer<Int32>,
    Pointer<Int32>,
    Pointer<Int32>,
    Pointer<Uint64>,
  )
  frameLock;
  final void Function(Pointer<Void>) frameUnlock;
  final void Function(Pointer<Void>, int, int, int) mouse;
  final void Function(Pointer<Void>, int, int) key;
  final void Function(Pointer<Void>, int, int) unicode;
  final int Function(Pointer<Void>, Pointer<Utf8>) clipSet;
  final Pointer<Utf8> Function(Pointer<Void>, Pointer<Uint64>) clipGet;
  final void Function(Pointer<Void>) disconnect;
  final void Function(Pointer<Void>) free;
  final void Function(Pointer<Void>) memFree;
}

/// One decoded frame: BGRA, top-down, [width]*4 bytes per row.
class RdpFrame {
  const RdpFrame(this.width, this.height, this.bgra, this.seq);
  final int width;
  final int height;
  final Uint8List bgra;
  final int seq;
}
