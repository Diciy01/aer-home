import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// The owner's Remote Gateway as this AER HOME knows it (M14.5): address
/// typed by the user, the certificate fingerprint the user confirmed, and
/// which remote client this installation was paired as. No secret here —
/// the client credential lives in a [CredentialStore].
class GatewayProfile {
  const GatewayProfile({
    required this.address,
    required this.fingerprint,
    required this.clientId,
    required this.clientName,
    required this.pairedAt,
  });

  factory GatewayProfile.fromJson(Map<String, dynamic> j) => GatewayProfile(
    address: j['address'] as String,
    fingerprint: j['fingerprint'] as String,
    clientId: j['clientId'] as String? ?? '',
    clientName: j['clientName'] as String? ?? '',
    pairedAt: DateTime.parse(j['pairedAt'] as String),
  );

  final String address;
  final String fingerprint;
  final String clientId;
  final String clientName;
  final DateTime pairedAt;

  Map<String, Object?> toJson() => {
    'address': address,
    'fingerprint': fingerprint,
    'clientId': clientId,
    'clientName': clientName,
    'pairedAt': pairedAt.toUtc().toIso8601String(),
  };
}

/// Where the remote client credential (`aerc1.…`) is kept.
abstract interface class CredentialStore {
  Future<String?> read();
  Future<void> write(String credential);
  Future<void> delete();

  /// Human description for the UI («связка ключей ОС»).
  String get description;
}

/// The OS secret store: libsecret (GNOME Keyring) on Linux, Credential
/// Manager on Windows (UNVERIFIED until M10).
class SecureCredentialStore implements CredentialStore {
  SecureCredentialStore([FlutterSecureStorage? storage])
    : _s = storage ?? const FlutterSecureStorage();
  final FlutterSecureStorage _s;
  static const _key = 'aer-home.remote.gateway.credential';

  @override
  String get description => 'связка ключей ОС';
  @override
  Future<String?> read() => _s.read(key: _key);
  @override
  Future<void> write(String credential) =>
      _s.write(key: _key, value: credential);
  @override
  Future<void> delete() => _s.delete(key: _key);
}

/// A 0600 file — only for isolated test stands
/// (`AER_REMOTE_SECRET_STORE=file` with `AER_DESKTOP_DATA_DIR`), so tests
/// never touch the user's real keyring.
class FileCredentialStore implements CredentialStore {
  FileCredentialStore(this.file);
  final File file;

  @override
  String get description => 'файл тестового стенда';
  @override
  Future<String?> read() async =>
      await file.exists() ? (await file.readAsString()).trim() : null;
  @override
  Future<void> write(String credential) async {
    await file.parent.create(recursive: true);
    await file.writeAsString(credential, flush: true);
    if (!Platform.isWindows) await Process.run('chmod', ['600', file.path]);
  }

  @override
  Future<void> delete() async {
    if (await file.exists()) await file.delete();
  }
}

/// Profile file next to the desktop's other data.
class GatewayProfileStore {
  GatewayProfileStore(this.file);
  final File file;

  Future<GatewayProfile?> read() async {
    if (!await file.exists()) return null;
    try {
      return GatewayProfile.fromJson(
        jsonDecode(await file.readAsString()) as Map<String, dynamic>,
      );
    } catch (_) {
      return null; // a damaged profile is the same as none: pair again
    }
  }

  Future<void> write(GatewayProfile p) async {
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode(p.toJson()), flush: true);
  }

  Future<void> delete() async {
    if (await file.exists()) await file.delete();
  }
}
