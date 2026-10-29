// Native handles only: no servers, desktop capture, input or clipboard OS API.
import 'dart:io';

import 'package:aer_remote/aer_remote.dart';
import 'package:test/test.dart';

void main() {
  test(
    'FFI repeated/concurrent disposal has one owner and joins the same future',
    () async {
      final native = RdpNative.load();
      expect(native, isNotNull);
      for (var i = 0; i < 50; i++) {
        final s = RdpSession(native!);
        final first = s.disposeAsync(), second = s.disposeAsync();
        expect(identical(first, second), isTrue);
        await Future.wait([first, second]);
        await s.disposeAsync();
        s.dispose();
        s.disconnect();
        expect(s.state, RdpState.disconnected);
        expect(s.takeFrame(), isNull);
        expect(s.takeRemoteClipboard(), isNull);
        expect(s.setClipboard('TEST ONLY'), isFalse);
      }
      for (var i = 0; i < 100; i++) {
        final s = RdpSession(native!);
        s.dispose();
        s.dispose();
        await s.disposeAsync();
      }
    },
    skip: Platform.environment['AER_RDP_LIB'] == null
        ? 'set AER_RDP_LIB to the native DLL under test'
        : false,
  );
}
