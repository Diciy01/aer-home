import 'dart:convert';
import 'dart:io';

import 'package:aer_remote/aer_remote.dart';
import 'package:test/test.dart';

void main() {
  final v = jsonDecode(
    File('test/fixtures/registration.json').readAsStringSync(),
  ) as Map<String, dynamic>;
  test(
    'Go enrollment envelopes open only for the installation and context',
    () async {
      Future<String> open({String? key, String? id, String? instance}) =>
          openRegistration(
            key ?? v['privateKey'] as String,
            id ?? v['id'] as String,
            instance ?? v['instance'] as String,
            v['challenge'] as Map<String, dynamic>,
          );
      expect(await open(), 'CHALLENGE-TEST-ONLY');
      expect(open(id: 'OTHER'), throwsA(anything));
      expect(open(instance: 'OTHER'), throwsA(anything));
      expect(
        open(key: base64Url.encode(List.filled(32, 111)).replaceAll('=', '')),
        throwsA(anything),
      );
      final plain = await openRegistration(
        v['privateKey'] as String,
        v['id'] as String,
        v['instance'] as String,
        v['credentials'] as Map<String, dynamic>,
      );
      expect(
        DeviceEnrollment.fromJson(jsonDecode(plain) as Map<String, dynamic>)
            .number,
        '482913507',
      );
      final damaged = Map<String, dynamic>.from(v['challenge'] as Map)
        ..['nonce'] = 'AAAA';
      expect(
        openRegistration(
          v['privateKey'] as String,
          v['id'] as String,
          v['instance'] as String,
          damaged,
        ),
        throwsA(anything),
      );
    },
  );
}
