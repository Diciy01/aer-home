import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// AER Connect Anywhere (ADR-018), viewer side: the password is sealed to
/// the remote computer's X25519 key for one attempt; the server relays
/// ciphertext it cannot open. Mirrors core/internal/remoteengine/connectauth.go
/// (wire format pinned by a shared test vector).
const authVersion = 'aer-connect-auth/1';

String _b64(List<int> b) => base64Url.encode(b).replaceAll('=', '');

Uint8List _unb64(String s) {
  final pad = (4 - s.length % 4) % 4;
  return base64Url.decode(s + '=' * pad);
}

/// Spaces and dashes a user may type are ignored.
String normalizeDeviceNumber(String s) =>
    s.replaceAll(RegExp(r'[\s\- ]'), '');

/// 9 digits, never starting with 0.
bool validDeviceNumber(String s) => RegExp(r'^[1-9][0-9]{8}$').hasMatch(s);

/// `123456789` → `123 456 789` for display.
String formatDeviceNumber(String s) {
  final n = normalizeDeviceNumber(s);
  if (n.length != 9) return n;
  return '${n.substring(0, 3)} ${n.substring(3, 6)} ${n.substring(6)}';
}

/// What `POST /gw/v1/connect/challenge` returns.
class ConnectChallenge {
  const ConnectChallenge({
    required this.attemptId,
    required this.number,
    required this.name,
    required this.boxPub,
    required this.viewerNumber,
  });

  factory ConnectChallenge.fromJson(Map<String, dynamic> j) => ConnectChallenge(
    attemptId: j['attemptId'] as String,
    number: j['number'] as String,
    name: j['name'] as String? ?? '',
    boxPub: j['boxPub'] as String,
    viewerNumber: j['viewerNumber'] as String? ?? '',
  );

  final String attemptId;
  final String number;
  final String name;
  final String boxPub;
  final String viewerNumber;
}

/// A sealed password for exactly one attempt.
class SealedPassword {
  const SealedPassword(this.attemptId, this.ephPub, this.ciphertext);
  final String attemptId;
  final String ephPub;
  final String ciphertext;
}

/// Seals [password] for the attempt [c]. [ephemeral] is for test vectors
/// only; a fresh key is generated otherwise.
Future<SealedPassword> sealPassword(
  ConnectChallenge c,
  String password, {
  DateTime? now,
  SimpleKeyPair? ephemeral,
}) async {
  final x = X25519();
  final eph = ephemeral ?? await x.newKeyPair();
  final hostPub = _unb64(c.boxPub);
  if (hostPub.length != 32) {
    throw const FormatException('Ключ компьютера повреждён');
  }
  final shared = await x.sharedSecretKey(
    keyPair: eph,
    remotePublicKey: SimplePublicKey(hostPub, type: KeyPairType.x25519),
  );
  final ephPub = (await eph.extractPublicKey()).bytes;
  final salt = (await Sha256().hash(utf8.encode(c.attemptId))).bytes;
  final info = <int>[
    ...utf8.encode(authVersion),
    0,
    ...utf8.encode(c.viewerNumber),
    0,
    ...utf8.encode(c.number),
    0,
    ...ephPub,
    ...hostPub,
  ];
  final key = await Hkdf(hmac: Hmac.sha256(), outputLength: 32).deriveKey(
    secretKey: shared,
    nonce: salt,
    info: info,
  );
  final t = (now ?? DateTime.now()).millisecondsSinceEpoch;
  final plain = utf8.encode(jsonEncode({'v': 1, 'p': password, 't': t}));
  final box = await AesGcm.with256bits().encrypt(
    plain,
    secretKey: key,
    nonce: List.filled(12, 0),
    aad: utf8.encode(c.attemptId),
  );
  return SealedPassword(
    c.attemptId,
    _b64(ephPub),
    _b64([...box.cipherText, ...box.mac.bytes]),
  );
}

/// Credentials handed to a newly registered device (once).
class DeviceEnrollment {
  const DeviceEnrollment({
    required this.deviceId,
    required this.number,
    required this.name,
    required this.agentToken,
    required this.clientCredential,
  });

  factory DeviceEnrollment.fromJson(Map<String, dynamic> j) => DeviceEnrollment(
    deviceId: j['deviceId'] as String,
    number: j['number'] as String,
    name: j['name'] as String? ?? '',
    agentToken: j['agentToken'] as String,
    clientCredential: j['clientCredential'] as String,
  );

  final String deviceId;
  final String number;
  final String name;
  final String agentToken;
  final String clientCredential;
}

/// This device as the server sees it.
class DeviceInfo {
  const DeviceInfo(this.number, this.name, this.status);
  factory DeviceInfo.fromJson(Map<String, dynamic> j) => DeviceInfo(
    j['number'] as String? ?? '',
    j['name'] as String? ?? '',
    j['status'] as String? ?? 'offline',
  );
  final String number;
  final String name;

  /// online | offline | revoked | conflict.
  final String status;
}
