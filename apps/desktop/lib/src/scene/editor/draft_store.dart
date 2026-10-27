import 'dart:convert';
import 'dart:io';

import '../model/scene_codec.dart';
import '../model/scene_document.dart';
import '../repository/scene_repository.dart' show pruneCorruptCopies;

/// An unsaved editor state kept on disk so a crash or a closed window does
/// not lose work.
class SceneDraft {
  const SceneDraft({
    required this.document,
    required this.baseRevision,
    required this.savedAt,
    required this.changes,
  });

  final SceneDocument document;

  /// Core revision the edits started from (null: never saved to Core).
  final int? baseRevision;
  final DateTime savedAt;

  /// Number of history steps at the time of saving (for the restore prompt).
  final int changes;
}

/// Local draft file `<data>/scene-draft.json` next to the scene cache.
/// Writes are atomic (temp file + rename). A corrupt draft is moved aside
/// as `.corrupt-<ms>`; at most [keepCorrupt] such files are kept.
class SceneDraftStore {
  SceneDraftStore(
    this.file, {
    this.keepCorrupt = 3,
    this.codec = const SceneCodec(),
  });

  /// Same directory as the scene cache ([SceneCache.defaultLocation]).
  factory SceneDraftStore.besideCache(File cacheFile) => SceneDraftStore(
    File('${cacheFile.parent.path}${Platform.pathSeparator}scene-draft.json'),
  );

  final File file;
  final int keepCorrupt;
  final SceneCodec codec;

  /// Last read problem (shown to the user), e.g. a corrupt draft set aside.
  String? lastIssue;

  Future<SceneDraft?> read() async {
    if (!await file.exists()) return null;
    try {
      final m = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      if (m['draftVersion'] != 1) {
        throw const FormatException('unknown draft version');
      }
      return SceneDraft(
        document: codec.decode(m['document']),
        baseRevision: m['baseRevision'] as int?,
        savedAt: DateTime.parse(m['savedAt'] as String),
        changes: m['changes'] as int? ?? 0,
      );
    } catch (e) {
      final aside = File(
        '${file.path}.corrupt-${DateTime.now().millisecondsSinceEpoch}',
      );
      try {
        await file.rename(aside.path);
      } catch (_) {}
      await pruneCorruptCopies(file, keep: keepCorrupt);
      lastIssue = 'Черновик редактора повреждён и отложен в ${aside.path}';
      return null;
    }
  }

  Future<void> write(SceneDraft draft) async {
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(
      jsonEncode({
        'draftVersion': 1,
        'savedAt': draft.savedAt.toUtc().toIso8601String(),
        'baseRevision': draft.baseRevision,
        'changes': draft.changes,
        'document': draft.document.toJson(),
      }),
      flush: true,
    );
    await tmp.rename(file.path);
  }

  Future<void> clear() async {
    try {
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      // Already gone.
    }
  }
}

/// In-memory draft store for widget tests (no file I/O in fake async).
class MemoryDraftStore extends SceneDraftStore {
  MemoryDraftStore() : super(File('/nonexistent/scene-draft.json'));
  SceneDraft? data;
  int writes = 0;

  @override
  Future<SceneDraft?> read() async => data;

  @override
  Future<void> write(SceneDraft draft) async {
    writes++;
    data = draft;
  }

  @override
  Future<void> clear() async => data = null;
}
