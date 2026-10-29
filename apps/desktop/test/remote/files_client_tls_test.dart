// Public TEST ONLY keys; never use these fixtures outside loopback tests.
import 'dart:convert';
import 'dart:io';

import 'package:aer_home_desktop/src/remote/files_client.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final fixture = Directory('test/remote/fixtures');
  final payload = utf8.encode('AER тестовый файл');
  late HttpServer server;
  late String base;
  late String pin;
  var requests = 0;
  var badHash = false;
  var redirect = false;
  List<int>? uploaded;

  Future<void> start(String name) async {
    final cert = File('${fixture.path}/$name-test-cert.pem');
    final context = SecurityContext()
      ..useCertificateChain(cert.path)
      ..usePrivateKey('${fixture.path}/$name-test-key.pem');
    final pem = await cert.readAsString();
    final der = base64.decode(
      pem.split('-----')[2].replaceAll(RegExp(r'\s'), ''),
    );
    pin = RemoteFilesClient.fingerprint(der);
    server = await HttpServer.bindSecure(
      InternetAddress.loopbackIPv4,
      0,
      context,
    );
    base = 'https://127.0.0.1:${server.port}';
    server.listen((req) async {
      requests++;
      expect(req.headers.value('Authorization'), 'Bearer test-only-session');
      if (redirect) {
        req.response.statusCode = 302;
        req.response.headers.set('Location', '$base/redirected');
      } else if (req.method == 'PUT') {
        uploaded = await req.fold<List<int>>([], (a, b) => a..addAll(b));
        expect(
          req.headers.value('X-AER-SHA256'),
          sha256.convert(uploaded!).toString(),
        );
        req.response.statusCode = 201;
      } else if (req.uri.path == '/v1/files') {
        req.response.write(
          jsonEncode({
            'files': [
              {
                'name': 'report.txt',
                'size': payload.length,
                'modified': '2026-10-28T00:00:00Z',
              },
            ],
          }),
        );
      } else {
        req.response.headers.set(
          'X-AER-SHA256',
          badHash ? 'wrong' : sha256.convert(payload).toString(),
        );
        req.response.add(payload);
      }
      await req.response.close();
    });
  }

  RemoteFilesClient client(String fingerprint) => RemoteFilesClient(
    baseUrl: base,
    token: 'test-only-session',
    certSha256: fingerprint,
  );

  setUpAll(() {
    // Process-local only. No Windows certificate store is modified.
    SecurityContext.defaultContext.setTrustedCertificates(
      '${fixture.path}/loopback-test-cert.pem',
    );
  });
  setUp(() {
    requests = 0;
    badHash = false;
    redirect = false;
    uploaded = null;
  });
  tearDown(() async {
    await server.close(force: true);
  });

  test('reproduces old bypass: trusted certificate skips callback', () async {
    await start('loopback');
    var checked = false;
    final old = HttpClient()
      ..badCertificateCallback = (_, _, _) {
        checked = true;
        return false;
      };
    try {
      final req = await old.getUrl(Uri.parse('$base/v1/files'));
      req.headers.set('Authorization', 'Bearer test-only-session');
      await (await req.close()).drain<void>();
      expect(checked, isFalse);
      expect(requests, 1);
    } finally {
      old.close(force: true);
    }
  });

  for (final name in ['loopback', 'untrusted']) {
    for (final correct in [true, false]) {
      test('$name certificate, ${correct ? 'correct' : 'wrong'} pin', () async {
        await start(name);
        final c = client(correct ? pin.toUpperCase() : 'ab' * 32);
        try {
          if (correct) {
            expect((await c.list()).single.name, 'report.txt');
            expect(requests, 1);
          } else {
            await expectLater(c.list(), throwsA(isA<HandshakeException>()));
            expect(
              requests,
              0,
              reason: 'No session token or HTTP request before pin acceptance',
            );
          }
        } finally {
          c.close();
        }
      });
    }
  }

  test('pinned list/upload/download and checksum rejection', () async {
    await start('loopback');
    final dir = await Directory.systemTemp.createTemp('aer-file-tls-');
    final c = client(pin);
    try {
      final source = File('${dir.path}/source.txt');
      await source.writeAsBytes(payload);
      await c.upload(source, 'report.txt');
      expect(uploaded, payload);
      expect(
        await (await c.download('report.txt', dir)).readAsBytes(),
        payload,
      );
      badHash = true;
      await expectLater(
        c.download('corrupt.txt', dir),
        throwsA(isA<TransferError>()),
      );
      expect(await File('${dir.path}/corrupt.txt').exists(), isFalse);
      expect(
        await dir.list().where((f) => f.path.contains('.aer-download-')).length,
        0,
      );
    } finally {
      c.close();
      await dir.delete(recursive: true);
    }
  });

  test('redirect cannot forward session credentials', () async {
    await start('loopback');
    redirect = true;
    final c = client(pin);
    try {
      await expectLater(c.list(), throwsA(isA<TransferError>()));
      expect(requests, 1);
    } finally {
      c.close();
    }
  });

  test('plaintext HTTP is rejected before sending credentials', () async {
    await start('loopback');
    final c = RemoteFilesClient(
      baseUrl: base.replaceFirst('https:', 'http:'),
      token: 'test-only-session',
      certSha256: pin,
    );
    try {
      await expectLater(c.list(), throwsA(isA<TransferError>()));
      expect(requests, 0);
    } finally {
      c.close();
    }
  });

  test('download names cannot escape the selected directory or use Windows devices', () async {
    await start('loopback');
    final c = client(pin);
    try {
      final names = ['../escape.txt', r'..\escape.txt', '/absolute', '.hidden',
        if (Platform.isWindows) ...['report.txt:secret','CON','LPT1.txt','trailing.','trailing ']];
      for (final name in names) {
        await expectLater(c.download(name, Directory.systemTemp), throwsA(isA<TransferError>()));
      }
      expect(requests,0);
    } finally { c.close(); }
  });
}
