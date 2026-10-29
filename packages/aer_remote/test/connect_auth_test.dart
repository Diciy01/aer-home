import 'dart:convert';
import 'dart:typed_data';

import 'package:aer_remote/aer_remote.dart';
import 'package:cryptography/cryptography.dart';
import 'package:test/test.dart';

// TEST DATA: fixed fixture keys, the same as TestSealVector in
// core/internal/remoteengine/connectauth_test.go.

Future<SimpleKeyPair> fixedKey(int fill) => X25519().newKeyPairFromSeed(
  Uint8List.fromList(List.generate(32, (i) => (fill + i) & 0xff)),
);

String b64(List<int> b) => base64Url.encode(b).replaceAll('=', '');

void main() {
  test(
    'installation proof matches Go and is separate from the password envelope',
    () async {
      final host = await fixedKey(1);
      final c = ConnectChallenge(
        attemptId: 'AAECAwQFBgcICQoLDA0ODw',
        number: '444555666',
        name: 'TEST',
        boxPub: b64((await host.extractPublicKey()).bytes),
        viewerNumber: '111222333',
        identityProof: identityProofVersion,
      );
      final a = await sealPassword(
        c,
        'k7m2x9qp',
        now: DateTime.fromMillisecondsSinceEpoch(1793000000000),
        ephemeral: await fixedKey(101),
        installationKey: b64(List.generate(32, (i) => 51 + i)),
      );
      expect(a.identityProof, 'G0wbdy-7GKc6vq-fr-W7qDevyXSLWUNX-mmUbAh6LLI');
      final bad = await sealPassword(
        c,
        'k7m2x9qp',
        now: DateTime.fromMillisecondsSinceEpoch(1793000000000),
        ephemeral: await fixedKey(101),
        installationKey: b64(List.generate(32, (i) => 52 + i)),
      );
      expect(bad.ciphertext, a.ciphertext);
      expect(bad.identityProof, isNot(a.identityProof));
    },
  );
  test('sealing matches the Go wire format byte for byte', () async {
    final host = await fixedKey(1);
    final hostPub = b64((await host.extractPublicKey()).bytes);
    expect(hostPub, 'B6N8vBQgk8i3VdwbEOhstCY3StFqqFPtC9_AsrhtHHw');
    final s = await sealPassword(
      ConnectChallenge(
        attemptId: 'AAECAwQFBgcICQoLDA0ODw',
        number: '444555666',
        name: 'test',
        boxPub: hostPub,
        viewerNumber: '111222333',
      ),
      'k7m2x9qp',
      now: DateTime.fromMillisecondsSinceEpoch(1793000000000),
      ephemeral: await fixedKey(101),
    );
    expect(s.ephPub, 'VxR2nRFr92Q2rnS8eT0sMK0ZA8WaxSc4BcfiaYtBDDY');
    expect(
      s.ciphertext,
      'zp3V0YT58v4hrZHyjOL44GSFyMlfMf3oqnPu9rBvgKqZIhzTNLci8TCpmvr7yu-9rLiIHHhKmAA',
    );
  });

  test(
    'fresh ephemeral key per attempt, password never in the clear',
    () async {
      final host = await X25519().newKeyPair();
      final c = ConnectChallenge(
        attemptId: 'attempt',
        number: '444555666',
        name: '',
        boxPub: b64((await host.extractPublicKey()).bytes),
        viewerNumber: '',
      );
      final a = await sealPassword(c, 'пароль-кириллица');
      final b = await sealPassword(c, 'пароль-кириллица');
      expect(a.ephPub, isNot(b.ephPub));
      expect(a.ciphertext, isNot(b.ciphertext));
      final raw = base64Url.decode(base64Url.normalize(a.ciphertext));
      expect(utf8.decode(raw, allowMalformed: true), isNot(contains('пароль')));
    },
  );

  test('device numbers', () {
    expect(normalizeDeviceNumber(' 123 456-789 '), '123456789');
    expect(validDeviceNumber('123456789'), isTrue);
    expect(validDeviceNumber('012345678'), isFalse);
    expect(validDeviceNumber('12345678'), isFalse);
    expect(formatDeviceNumber('123456789'), '123 456 789');
  });
}
