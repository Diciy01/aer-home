import 'dart:io';

import 'package:aer_home_desktop/src/scene/editor/draft_store.dart';
import 'package:flutter_test/flutter_test.dart';

import '../scene_fixtures.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('aer-draft-test-'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('atomic write, read back, clear', () async {
    final store = SceneDraftStore(File('${dir.path}/scene-draft.json'));
    expect(await store.read(), isNull);
    final doc = exampleScene();
    final at = DateTime.utc(2026, 10, 27, 9, 30);
    await store.write(
      SceneDraft(document: doc, baseRevision: 5, savedAt: at, changes: 4),
    );
    expect(File('${dir.path}/scene-draft.json.tmp').existsSync(), isFalse);
    final back = (await store.read())!;
    expect(back.baseRevision, 5);
    expect(back.changes, 4);
    expect(back.savedAt, at);
    expect(back.document.objects.length, doc.objects.length);
    await store.clear();
    expect(await store.read(), isNull);
  });

  test('corrupt draft is set aside; only 3 corrupt copies are kept', () async {
    final f = File('${dir.path}/scene-draft.json');
    final store = SceneDraftStore(f);
    for (var i = 0; i < 6; i++) {
      f.writeAsStringSync(
        i.isEven ? '{"draftVersion": 1, "document": {' : '{"draftVersion": 9}',
      );
      expect(await store.read(), isNull);
      expect(store.lastIssue, contains('повреждён'));
      await Future<void>.delayed(const Duration(milliseconds: 3));
    }
    expect(f.existsSync(), isFalse);
    final aside = dir
        .listSync()
        .where((e) => e.path.contains('.corrupt-'))
        .toList();
    expect(aside.length, 3);
  });

  test('a draft whose document fails validation counts as corrupt', () async {
    final f = File('${dir.path}/scene-draft.json');
    final store = SceneDraftStore(f);
    final json = exampleFile.readAsStringSync().replaceFirst(
      '"schemaVersion": 1',
      '"schemaVersion": 99',
    );
    f.writeAsStringSync(
      '{"draftVersion":1,"savedAt":"2026-10-27T00:00:00Z","baseRevision":1,"changes":1,"document":$json}',
    );
    expect(await store.read(), isNull);
    expect(store.lastIssue, isNotNull);
  });

  test('besideCache puts the draft next to the scene cache', () {
    final s = SceneDraftStore.besideCache(File('${dir.path}/scene-cache.json'));
    expect(s.file.path, '${dir.path}${Platform.pathSeparator}scene-draft.json');
  });
}
