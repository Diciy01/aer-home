/// AER Remote Engine for Dart clients (ADR-017).
///
/// Shared by AER HOME and AER Connect: everything about reaching a remote
/// computer through the owner's Remote Gateway, nothing about UI.
library;

export 'src/connect_auth.dart';
export 'src/registration.dart';
export 'src/errors.dart';
export 'src/models.dart';
export 'src/pinning.dart';
export 'src/gateway_client.dart';
export 'src/tunnel.dart';
export 'src/session.dart';
export 'src/viewer.dart';
export 'src/rdp/native.dart' show RdpNative, RdpFrame;
export 'src/rdp/scancodes.dart';
export 'src/rdp/session.dart';
export 'src/files_client.dart';
