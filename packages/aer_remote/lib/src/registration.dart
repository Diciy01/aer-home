import 'dart:convert';

import 'package:cryptography/cryptography.dart';

const registrationVersion = 'aer-connect-registration/1';

List<int> _decode(String s) =>
    base64Url.decode(s.padRight((s.length + 3) ~/ 4 * 4, '='));

class RegistrationReply {
  const RegistrationReply(this.id, this.status, [this.box]);
  factory RegistrationReply.fromJson(Map<String, dynamic> j) =>
      RegistrationReply(
        j['id'] as String,
        j['status'] as String,
        (j['box'] as Map?)?.cast<String, dynamic>(),
      );
  final String id, status;
  final Map<String, dynamic>? box;
}

/// Domain-separated X25519 / HKDF-SHA256 / AES-256-GCM, matching Go.
/// The Core request ID, machine instance and recipient key are authenticated.
Future<String> openRegistration(
  String privateKey,
  String id,
  String instance,
  Map<String, dynamic> box,
) async {
  final x = X25519();
  final key = await x.newKeyPairFromSeed(_decode(privateKey));
  final recipient = (await key.extractPublicKey()).bytes;
  final eph = _decode(box['ephPub'] as String);
  final nonce = _decode(box['nonce'] as String);
  final encrypted = _decode(box['ciphertext'] as String);
  if (eph.length != 32 || nonce.length != 12 || encrypted.length < 16) {
    throw const FormatException('Повреждён ответ регистрации');
  }
  final shared = await x.sharedSecretKey(
    keyPair: key,
    remotePublicKey: SimplePublicKey(eph, type: KeyPairType.x25519),
  );
  final aad = utf8.encode('$registrationVersion\u0000$id\u0000$instance');
  final salt = (await Sha256().hash(aad)).bytes;
  final derived = await Hkdf(hmac: Hmac.sha256(), outputLength: 32).deriveKey(
    secretKey: shared,
    nonce: salt,
    info: [...utf8.encode('$registrationVersion\u0000'), ...recipient],
  );
  final plain = await AesGcm.with256bits().decrypt(
    SecretBox(
      encrypted.sublist(0, encrypted.length - 16),
      nonce: nonce,
      mac: Mac(encrypted.sublist(encrypted.length - 16)),
    ),
    secretKey: derived,
    aad: aad,
  );
  return utf8.decode(plain);
}
