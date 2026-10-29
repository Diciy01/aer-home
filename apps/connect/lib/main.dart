import 'dart:async';
import 'dart:io';

import 'package:aer_remote/aer_remote.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'connect_app.dart';
import 'controller.dart';

void main(List<String> args) {
  WidgetsFlutterBinding.ensureInitialized();
  final native = RdpNative.load();
  final c = ConnectController(
    store: ConnectSecureStore(),
    deviceStore: ConnectSecureStore(ConnectSecureStore.deviceKey),
    // Owner-built installers may carry the server address and pin; the
    // enrollment code is always typed by the user.
    preset: ServerPreset.read(
      '${File(Platform.resolvedExecutable).parent.path}${Platform.pathSeparator}connect.json',
    ),
    viewerFactory: (check) {
      if (native == null) {
        throw StateError(
          'Компонент просмотра не найден. Переустановите полный пакет AER Connect.',
        );
      }
      return EmbeddedRdpViewer(native, canReconnect: check);
    },
  );
  const window = MethodChannel('aer.connect/window');
  window.setMethodCallHandler((call) async {
    if (call.method == 'closing') {
      try {
        await c.shutdown().timeout(const Duration(seconds: 4));
      } finally {
        await window.invokeMethod<void>('close');
      }
    }
  });
  runApp(ConnectApp(controller: c));
  // Packaging smoke checks must never read an existing user's profile or dial
  // its Gateway. This switch opens an unpaired window and changes no store.
  if (!args.contains('--no-profile')) unawaited(c.load());
}
