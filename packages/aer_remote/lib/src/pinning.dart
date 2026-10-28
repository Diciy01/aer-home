import 'dart:io';

import 'package:crypto/crypto.dart';

/// SHA-256 of a DER certificate as colon-separated lowercase hex — the
/// format Core and the Gateway print.
String certFingerprint(List<int> der) => sha256
    .convert(der)
    .bytes
    .map((b) => b.toRadixString(16).padLeft(2, '0'))
    .join(':');

/// Drops separators and case so user-typed fingerprints compare equal.
String normalizeFingerprint(String fp) =>
    fp.toLowerCase().replaceAll(RegExp(r'[:\s-]'), '');

/// An [HttpClient] that trusts exactly one certificate.
///
/// No system roots are trusted, so every handshake reaches
/// `badCertificateCallback`, where the pin decides — also for a publicly
/// trusted certificate. [onPeer] reports what the server presented (to
/// show the fingerprint at pairing).
HttpClient pinnedHttpClient(
  String fingerprint, {
  void Function(String fingerprint)? onPeer,
}) {
  final want = normalizeFingerprint(fingerprint);
  final c = HttpClient(context: SecurityContext(withTrustedRoots: false))
    ..connectionTimeout = const Duration(seconds: 15)
    ..idleTimeout = const Duration(seconds: 30);
  c.badCertificateCallback = (cert, host, port) {
    final got = certFingerprint(cert.der);
    onPeer?.call(got);
    return want.length == 64 && normalizeFingerprint(got) == want;
  };
  return c;
}

/// Connects once without trusting anything and returns the fingerprint the
/// server presents — for the pairing screen, where the user compares it
/// with the one AER HOME shows. Nothing is sent but the TLS handshake.
Future<String> probeFingerprint(Uri server) async {
  String? seen;
  final s = await SecureSocket.connect(
    server.host,
    server.hasPort ? server.port : 443,
    context: SecurityContext(withTrustedRoots: false),
    onBadCertificate: (cert) {
      seen = certFingerprint(cert.der);
      return false;
    },
    timeout: const Duration(seconds: 15),
  ).then<SecureSocket?>((s) => s).catchError((Object _) => null);
  await s?.close();
  final fp = seen;
  if (fp == null) {
    throw const SocketException('Сервер не представил сертификат');
  }
  return fp;
}
