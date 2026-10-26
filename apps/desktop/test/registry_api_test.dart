import 'dart:convert';

import 'package:aer_home_desktop/src/core_api/core_client.dart';
import 'package:aer_home_desktop/src/core_api/registry_api.dart';
import 'package:aer_home_desktop/src/core_api/registry_models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'fixtures.dart';

// TEST FIXTURE entity in the exact wire format of contracts/openapi.yaml 0.3.0.
Map<String, dynamic> entityJson({int revision = 1, String? address}) => {
  'id': '00000000-0000-4000-8000-0000000000aa',
  'name': 'Сервер (тест)',
  'type': 'server',
  'description': '',
  'icon': 'server',
  'tags': ['home'],
  'parentId': null,
  'discovery': 'manual',
  'address': address,
  'secretRefs': [
    {'name': 'ssh', 'ref': 'keyring:aer/test'},
  ],
  'attributes': {'os': 'linux'},
  'capabilities': ['network.ping'],
  'revision': revision,
  'createdAt': '2026-10-26T12:00:00Z',
  'updatedAt': '2026-10-26T12:00:00Z',
  'archived': false,
  'archivedAt': null,
};

void main() {
  late List<http.Request> seen;
  HttpRegistryApi apiWith(Future<http.Response> Function(http.Request) h) {
    seen = [];
    return HttpRegistryApi(
      clientFor(
        MockClient((req) {
          seen.add(req);
          return h(req);
        }),
      ),
    );
  }

  test('list sends filters as query parameters and parses the page', () async {
    final api = apiWith(
      (_) async => jsonResponse(
        envelope({
          'items': [entityJson()],
          'total': 7,
          'limit': 50,
          'offset': 0,
        }),
      ),
    );
    final page = await api.list(
      const EntityQuery(text: ' сервер ', type: 'server', archived: true),
    );
    final q = seen.single.url.queryParameters;
    expect(seen.single.url.path, '/api/v1/registry/entities');
    expect(q['q'], 'сервер');
    expect(q['type'], 'server');
    expect(q['archived'], 'true');
    expect(q['limit'], '50');
    expect(page.total, 7);
    expect(page.items.single.secretRefs.single.ref, 'keyring:aer/test');
    expect(page.items.single.attributes['os'], 'linux');
  });

  test('create posts only filled fields', () async {
    final api = apiWith((_) async => jsonResponse(envelope(entityJson()), 201));
    await api.create(const EntityDraft(name: 'Сервер', type: 'server'));
    expect(seen.single.method, 'POST');
    expect(jsonDecode(seen.single.body), {'name': 'Сервер', 'type': 'server'});
  });

  test('update sends revision and null to clear a field', () async {
    final api = apiWith(
      (_) async => jsonResponse(envelope(entityJson(revision: 2))),
    );
    final e = await api.update('id-1', 1, {'address': null, 'name': 'X'});
    expect(seen.single.method, 'PATCH');
    expect(seen.single.headers['Content-Type'], startsWith('application/json'));
    expect(jsonDecode(seen.single.body), {
      'address': null,
      'name': 'X',
      'revision': 1,
    });
    expect(e.revision, 2);
  });

  test('409 exposes conflict reason and current revision', () async {
    final api = apiWith(
      (_) async => jsonResponse({
        'error': {
          'code': 'CONFLICT',
          'message': 'stale',
          'details': {'reason': 'revision_mismatch', 'currentRevision': 3},
        },
        'meta': {'requestId': 'r', 'apiVersion': 'v1'},
      }, 409),
    );
    await expectLater(
      api.archive('id-1', 1),
      throwsA(
        isA<CoreApiException>()
            .having((e) => e.isConflict, 'conflict', isTrue)
            .having((e) => e.conflictReason, 'reason', 'revision_mismatch')
            .having((e) => e.details['currentRevision'], 'rev', 3),
      ),
    );
  });

  test('422 exposes per-field messages', () async {
    final api = apiWith(
      (_) async => jsonResponse({
        'error': {
          'code': 'VALIDATION_FAILED',
          'message': 'bad',
          'details': {
            'fields': {'address': 'Для этого типа нужен адрес'},
          },
        },
        'meta': {'requestId': 'r', 'apiVersion': 'v1'},
      }, 422),
    );
    await expectLater(
      api.create(const EntityDraft(name: 'x', type: 'website')),
      throwsA(
        isA<CoreApiException>().having((e) => e.fieldErrors, 'fields', {
          'address': 'Для этого типа нужен адрес',
        }),
      ),
    );
  });

  test('relations, add and delete use the documented paths', () async {
    final api = apiWith((req) async {
      if (req.method == 'DELETE') return jsonResponse(envelope({'id': 'r1'}));
      if (req.method == 'POST') {
        return jsonResponse(
          envelope({
            'id': 'r1',
            'fromId': 'a',
            'toId': 'b',
            'kind': 'runs_on',
            'label': '',
            'createdAt': '2026-10-26T12:00:00Z',
          }),
          201,
        );
      }
      return jsonResponse(
        envelope([
          {
            'id': 'r1',
            'fromId': 'a',
            'toId': 'b',
            'kind': 'runs_on',
            'label': '',
            'createdAt': '2026-10-26T12:00:00Z',
            'direction': 'outgoing',
            'peer': {
              'id': 'b',
              'name': 'Сервер',
              'type': 'server',
              'archived': false,
            },
          },
        ]),
      );
    });
    final views = await api.relations('a');
    expect(views.single.outgoing, isTrue);
    expect(views.single.peer.name, 'Сервер');
    await api.addRelation('a', 'runs_on', 'b');
    expect(seen.last.url.path, '/api/v1/registry/entities/a/relations');
    expect(jsonDecode(seen.last.body), {'kind': 'runs_on', 'targetId': 'b'});
    await api.deleteRelation('r1');
    expect(seen.last.url.path, '/api/v1/registry/relations/r1');
  });

  test('parseTags normalises input', () {
    expect(parseTags(' Home, media  home,,dev '), ['home', 'media', 'dev']);
  });
}
