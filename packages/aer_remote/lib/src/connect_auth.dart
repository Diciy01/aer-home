import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// AER Connect Anywhere (ADR-018), viewer side: the password is sealed to
/// the remote computer's X25519 key for one attempt; the server relays
/// ciphertext it cannot open. Mirrors core/internal/remoteengine/connectauth.go
/// (wire format pinned by a shared test vector).
const authVersion = 'aer-connect-auth/1';
const identityProofVersion = 'aer-connect-identity/1';

String _b64(List<int> b) => base64Url.encode(b).replaceAll('=', '');

Uint8List _unb64(String s) {
  final pad = (4 - s.length % 4) % 4;
  return base64Url.decode(s + '=' * pad);
}

/// Spaces and dashes a user may type are ignored.
String normalizeDeviceNumber(String s) => s.replaceAll(RegExp(r'[\s\- ]'), '');

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
    this.identityProof = '',
  });

  factory ConnectChallenge.fromJson(Map<String, dynamic> j) => ConnectChallenge(
    attemptId: j['attemptId'] as String,
    number: j['number'] as String,
    name: j['name'] as String? ?? '',
    boxPub: j['boxPub'] as String,
    viewerNumber: j['viewerNumber'] as String? ?? '',
    identityProof: j['identityProof'] as String? ?? '',
  );

  final String attemptId;
  final String number;
  final String name;
  final String boxPub;
  final String viewerNumber;
  final String identityProof;
}

/// A sealed password for exactly one attempt.
class SealedPassword {
  const SealedPassword(
    this.attemptId,
    this.ephPub,
    this.ciphertext, {
    this.identityProof,
  });
  final String attemptId;
  final String ephPub;
  final String ciphertext;
  final String? identityProof;
}

/// Seals [password] for the attempt [c]. [ephemeral] is for test vectors
/// only; a fresh key is generated otherwise.
Future<SealedPassword> sealPassword(
  ConnectChallenge c,
  String password, {
  DateTime? now,
  SimpleKeyPair? ephemeral,
  String? installationKey,
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
  final key = await Hkdf(
    hmac: Hmac.sha256(),
    outputLength: 32,
  ).deriveKey(secretKey: shared, nonce: salt, info: info);
  final t = (now ?? DateTime.now()).millisecondsSinceEpoch;
  final plain = utf8.encode(jsonEncode({'v': 1, 'p': password, 't': t}));
  final box = await AesGcm.with256bits().encrypt(
    plain,
    secretKey: key,
    nonce: List.filled(12, 0),
    aad: utf8.encode(c.attemptId),
  );
  final sealed = SealedPassword(
    c.attemptId,
    _b64(ephPub),
    _b64([...box.cipherText, ...box.mac.bytes]),
  );
  if (installationKey == null || c.identityProof != identityProofVersion)
    return sealed;
  final viewer = await x.newKeyPairFromSeed(_unb64(installationKey));
  final viewerPub = (await viewer.extractPublicKey()).bytes;
  final identityShared = await x.sharedSecretKey(
    keyPair: viewer,
    remotePublicKey: SimplePublicKey(hostPub, type: KeyPairType.x25519),
  );
  final identityKey = await Hkdf(hmac: Hmac.sha256(), outputLength: 32)
      .deriveKey(
        secretKey: identityShared,
        nonce: salt,
        info: [
          ...utf8.encode('$identityProofVersion\u0000'),
          ...viewerPub,
          ...hostPub,
        ],
      );
  final message =
      '$identityProofVersion\u0000${c.attemptId}\u0000${c.viewerNumber}\u0000${c.number}\u0000${sealed.ephPub}\u0000${sealed.ciphertext}';
  final mac = await Hmac.sha256().calculateMac(
    utf8.encode(message),
    secretKey: identityKey,
  );
  return SealedPassword(
    sealed.attemptId,
    sealed.ephPub,
    sealed.ciphertext,
    identityProof: _b64(mac.bytes),
  );
}

Future<String> installationFingerprint(String privateKey) async {
  final key = await X25519().newKeyPairFromSeed(_unb64(privateKey));
  final h = await Sha256().hash((await key.extractPublicKey()).bytes);
  return h.bytes.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
}

class TrustedDevice {
  const TrustedDevice({
    required this.number,
    required this.name,
    required this.fingerprint,
    this.revoked = false,
  });
  factory TrustedDevice.fromJson(Map<String, dynamic> j) => TrustedDevice(
    number: j['number'] as String,
    name: j['name'] as String,
    fingerprint: j['fingerprint'] as String,
    revoked: j['revokedAt'] != null,
  );
  final String number, name, fingerprint;
  final bool revoked;
}

class DeviceTrust {
  const DeviceTrust({this.enabled = false, this.devices = const []});
  factory DeviceTrust.fromJson(Map<String, dynamic> j) => DeviceTrust(
    enabled: j['enabled'] == true,
    devices: (j['devices'] as List)
        .map((v) => TrustedDevice.fromJson(v as Map<String, dynamic>))
        .toList(),
  );
  final bool enabled;
  final List<TrustedDevice> devices;
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
