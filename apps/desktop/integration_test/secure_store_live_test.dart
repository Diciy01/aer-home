// LIVE check of the OS secret store behind SecureCredentialStore (M10):
// the real flutter_secure_storage plugin in the real app — DPAPI-encrypted
// file on Windows, libsecret on Linux. Uses a separate TEST key, never the
// Gateway credential, and deletes it at the end. Touches the user's own
// store, so it runs only on request:
//
//   AER_SECURE_STORE_LIVE=1 flutter test integration_test/secure_store_live_test.dart -d windows
import 'dart:io';
import 'dart:math';

import 'package:aer_home_desktop/src/remote/gateway_profile.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final enabled = Platform.environment['AER_SECURE_STORE_LIVE'] == '1';

  test('secret round trip through the OS store, nothing in plain text', () async {
    const storage = FlutterSecureStorage();
    final rnd = Random.secure();
    final key =
        'aer-home.test.secure-store-live.${DateTime.now().microsecondsSinceEpoch}.${rnd.nextInt(1 << 30)}';
    final secret =
        'aerc1.test.${List.generate(32, (_) => rnd.nextInt(16).toRadixString(16)).join()}';
    try {
      await storage.write(key: key, value: secret);
      expect(await storage.read(key: key), secret);
      // The real credential wrapper reads the same store.
      expect(SecureCredentialStore(storage).description, 'связка ключей ОС');
      if (Platform.isWindows) {
        // %APPDATA%\<CompanyName>\<ProductName> (windows/runner/Runner.rc).
        final dir = Directory(
          '${Platform.environment['APPDATA']}\\home.aer\\AER HOME',
        );
        final files = dir.listSync(recursive: true).whereType<File>().toList();
        expect(files, isNotEmpty, reason: 'store file in ${dir.path}');
        for (final f in files) {
          final bytes = f.readAsBytesSync();
          expect(
            String.fromCharCodes(bytes).contains(secret),
            isFalse,
            reason: '${f.path} holds the secret in plain text',
          );
        }
      }
    } finally {
      await storage.delete(key: key);
    }
    expect(await storage.read(key: key), isNull);
  }, skip: enabled ? false : 'set AER_SECURE_STORE_LIVE=1 (uses the OS store)');
}
