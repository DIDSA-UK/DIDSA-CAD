/// What a server project's local copy knows about the store, persisted so a restart (or a day offline) loses nothing
/// (`docs/shared-storage-scope.md` sections 6 and 7):
///
/// * [ProjectSyncState.tree]: the store's file list at the last contact (what `resolve` / `listFiles` answer offline);
/// * [ProjectSyncState.bases]: per file, the version this device's copy is based on (the version a save is sent as replacing);
/// * [ProjectSyncState.queue]: the saves not sent yet, each with its bytes on disk beside the JSON; one that the store refused
///   as stale carries a [SyncClash] (the chip says "clash");
/// * [ProjectSyncState.cursor]: where the store's change feed was last read;
/// * [ProjectSyncState.mine]: bytes kept when the user chose Take theirs, until the next successful sync.
///
/// The cached *bytes of files that were read* are `FileCache`'s (rebuildable, in the OS cache folder). The queue is not a cache:
/// it holds the only copy of a save the store has not got, so it lives in the application-support folder, which the OS does not
/// clear to make room.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../project_root.dart';
import 'store_client.dart';

/// Why the store refused a save, and what it said is current.
class SyncClash {
  const SyncClash({
    required this.reason,
    this.currentVersion,
    this.deleted = false,
    this.movedTo,
    this.modifiedBy = '',
    this.modifiedAt,
  });

  /// From a 412: the store's `current` (null: the file does not exist). [reason] is `changed`, `exists`, `deleted`, `missing`
  /// (the commit's words) or `path_conflict` (a file where a folder is, or the reverse: Keep mine cannot work).
  factory SyncClash.fromCurrent(Map<String, dynamic>? current, {required bool baseWasCreate}) {
    if (current == null) return const SyncClash(reason: 'missing');
    final deleted = current['deleted'] == true;
    return SyncClash(
      reason: deleted ? 'deleted' : (baseWasCreate ? 'exists' : 'changed'),
      currentVersion: current['version'] as int?,
      deleted: deleted,
      movedTo: current['moved_to'] as String?,
      modifiedBy: (current['modified_by'] as String?) ?? '',
      modifiedAt: DateTime.tryParse((current['modified_at'] as String?) ?? ''),
    );
  }

  /// From one entry of a commit 409's `conflicts`.
  factory SyncClash.fromConflict(Map<String, dynamic> conflict) {
    final current = conflict['current'];
    final reason = (conflict['reason'] as String?) ?? 'changed';
    final base = SyncClash.fromCurrent(current is Map<String, dynamic> ? current : null, baseWasCreate: conflict['base_version'] == null);
    return SyncClash(
      reason: reason,
      currentVersion: base.currentVersion ?? (conflict['current_version'] as int?),
      deleted: base.deleted || reason == 'deleted',
      movedTo: base.movedTo,
      modifiedBy: base.modifiedBy,
      modifiedAt: base.modifiedAt,
    );
  }

  factory SyncClash.fromJson(Map<String, dynamic> json) => SyncClash(
        reason: json['reason'] as String,
        currentVersion: json['currentVersion'] as int?,
        deleted: json['deleted'] == true,
        movedTo: json['movedTo'] as String?,
        modifiedBy: (json['modifiedBy'] as String?) ?? '',
        modifiedAt: DateTime.tryParse((json['modifiedAt'] as String?) ?? ''),
      );

  final String reason;
  final int? currentVersion;
  final bool deleted;
  final String? movedTo;
  final String modifiedBy;
  final DateTime? modifiedAt;

  /// Keep mine writes over what is there. Not possible when the path itself is the problem.
  bool get canKeepMine => reason != 'path_conflict';

  Map<String, dynamic> toJson() => {
        'reason': reason,
        'currentVersion': currentVersion,
        'deleted': deleted,
        'movedTo': movedTo,
        'modifiedBy': modifiedBy,
        'modifiedAt': modifiedAt?.toUtc().toIso8601String(),
      };
}

/// One save not yet in the store.
class QueuedSave {
  QueuedSave({required this.path, required this.baseVersion, required this.queuedAt, this.clash, this.reconciled});

  factory QueuedSave.fromJson(Map<String, dynamic> json) => QueuedSave(
        path: json['path'] as String,
        baseVersion: json['baseVersion'] as int?,
        queuedAt: DateTime.fromMillisecondsSinceEpoch(json['queuedAtMs'] as int),
        clash: json['clash'] is Map<String, dynamic> ? SyncClash.fromJson(json['clash'] as Map<String, dynamic>) : null,
        reconciled: json['reconciled'] as int?,
      );

  final String path;

  /// The version this save replaces; null: it creates the file.
  int? baseVersion;
  DateTime queuedAt;

  /// Set when the store refused the save as stale: it waits for the user's choice.
  SyncClash? clash;

  /// The store's version this save was last weighed against (Keep mine sets it to the version it overwrites): the change feed
  /// reporting that same change is not a new clash.
  int? reconciled;

  Map<String, dynamic> toJson() => {
        'path': path,
        'baseVersion': baseVersion,
        'queuedAtMs': queuedAt.millisecondsSinceEpoch,
        if (clash != null) 'clash': clash!.toJson(),
        if (reconciled != null) 'reconciled': reconciled,
      };
}

/// A chunked upload that has begun (S4), kept so a closed app resumes it instead of sending a 150 MB file again.
class UploadSession {
  UploadSession({required this.id, required this.sha, required this.size, required this.atMs});

  factory UploadSession.fromJson(Map<String, dynamic> json) =>
      UploadSession(id: json['id'] as String, sha: json['sha'] as String, size: json['size'] as int, atMs: json['atMs'] as int);

  final String id;
  final String sha;
  final int size;
  int atMs;

  Map<String, dynamic> toJson() => {'id': id, 'sha': sha, 'size': size, 'atMs': atMs};
}

enum SyncFileState { synced, toSend, clash }

class ProjectSyncState {
  ProjectSyncState();

  factory ProjectSyncState.fromJson(Map<String, dynamic> json) {
    final state = ProjectSyncState();
    for (final f in (json['tree'] as List? ?? const [])) {
      final file = StoreFile.fromJson(f as Map<String, dynamic>);
      state.tree[file.path] = file;
    }
    for (final f in (json['bases'] as List? ?? const [])) {
      final file = StoreFile.fromJson(f as Map<String, dynamic>);
      state.bases[file.path] = file;
    }
    for (final q in (json['queue'] as List? ?? const [])) {
      final save = QueuedSave.fromJson(q as Map<String, dynamic>);
      state.queue[save.path] = save;
    }
    for (final entry in (json['mine'] as Map? ?? const {}).entries) {
      state.mine[entry.key as String] = DateTime.fromMillisecondsSinceEpoch(entry.value as int);
    }
    for (final entry in (json['uploadSessions'] as Map? ?? const {}).entries) {
      state.uploadSessions[entry.key as String] = UploadSession.fromJson((entry.value as Map).cast<String, dynamic>());
    }
    state.cursor = json['cursor'] as String?;
    state.lastSyncedAt = json['lastSyncedAtMs'] == null ? null : DateTime.fromMillisecondsSinceEpoch(json['lastSyncedAtMs'] as int);
    return state;
  }

  final Map<String, StoreFile> tree = {};
  final Map<String, StoreFile> bases = {};
  final Map<String, QueuedSave> queue = {};
  final Map<String, DateTime> mine = {};

  /// path -> the chunked upload begun for it (S4).
  final Map<String, UploadSession> uploadSessions = {};
  String? cursor;
  DateTime? lastSyncedAt;

  SyncFileState stateOf(String path) {
    final queued = queue[path];
    if (queued == null) return SyncFileState.synced;
    return queued.clash != null ? SyncFileState.clash : SyncFileState.toSend;
  }

  Map<String, dynamic> toJson() => {
        'tree': [for (final f in tree.values) f.toJson()],
        'bases': [for (final f in bases.values) f.toJson()],
        'queue': [for (final q in queue.values) q.toJson()],
        'mine': {for (final e in mine.entries) e.key: e.value.millisecondsSinceEpoch},
        'uploadSessions': {for (final e in uploadSessions.entries) e.key: e.value.toJson()},
        'cursor': cursor,
        'lastSyncedAtMs': lastSyncedAt?.millisecondsSinceEpoch,
      };
}

/// Reads and writes a project's [ProjectSyncState] and the bytes of its queued saves and kept "mine" copies.
class SyncStore {
  SyncStore({Directory? directory}) : _directoryOverride = directory;

  final Directory? _directoryOverride;
  final Map<String, ProjectSyncState> _loaded = {};

  Future<Directory> _dir() async {
    final override = _directoryOverride;
    if (override != null) {
      await override.create(recursive: true);
      return override;
    }
    final base = await getApplicationSupportDirectory();
    final dir = Directory(p.join(base.path, 'didsa-server-projects'));
    await dir.create(recursive: true);
    return dir;
  }

  static String _hash(String text) => sha256.convert(utf8.encode(text)).toString();

  String _projectKey(ServerProjectRoot root) => _hash(root.persistedKey).substring(0, 24);

  Future<Directory> _projectDir(ServerProjectRoot root) async {
    final dir = Directory(p.join((await _dir()).path, _projectKey(root)));
    await dir.create(recursive: true);
    return dir;
  }

  Future<ProjectSyncState> load(ServerProjectRoot root) async {
    final cached = _loaded[root.persistedKey];
    if (cached != null) return cached;
    final file = File(p.join((await _projectDir(root)).path, 'sync.json'));
    var state = ProjectSyncState();
    if (await file.exists()) {
      try {
        state = ProjectSyncState.fromJson(jsonDecode(await file.readAsString()) as Map<String, dynamic>);
      } on FormatException {
        // A half-written file (killed mid-save) is the only way here: the atomic rename in [save] makes it unlikely. Start clean
        // rather than refuse to open the project;.
      } on TypeError {
        // The same, for a file of another shape.
      }
    }
    return _loaded[root.persistedKey] = state;
  }

  Future<void> save(ServerProjectRoot root) async {
    final state = _loaded[root.persistedKey];
    if (state == null) return;
    final dir = await _projectDir(root);
    final temp = File(p.join(dir.path, 'sync.json.tmp'));
    await temp.writeAsString(jsonEncode(state.toJson()), flush: true);
    await temp.rename(p.join(dir.path, 'sync.json'));
  }

  Future<File> _bytesFile(ServerProjectRoot root, String kind, String path) async {
    final dir = Directory(p.join((await _projectDir(root)).path, kind));
    await dir.create(recursive: true);
    return File(p.join(dir.path, '${_hash(path)}.bin'));
  }

  Future<void> putQueued(ServerProjectRoot root, String path, Uint8List bytes) async =>
      (await _bytesFile(root, 'queue', path)).writeAsBytes(bytes, flush: true);

  Future<Uint8List?> getQueued(ServerProjectRoot root, String path) async {
    final file = await _bytesFile(root, 'queue', path);
    return await file.exists() ? file.readAsBytes() : null;
  }

  Future<void> deleteQueued(ServerProjectRoot root, String path) async {
    final file = await _bytesFile(root, 'queue', path);
    if (await file.exists()) await file.delete();
  }

  Future<void> putMine(ServerProjectRoot root, String path, Uint8List bytes) async =>
      (await _bytesFile(root, 'mine', path)).writeAsBytes(bytes, flush: true);

  Future<Uint8List?> getMine(ServerProjectRoot root, String path) async {
    final file = await _bytesFile(root, 'mine', path);
    return await file.exists() ? file.readAsBytes() : null;
  }

  Future<void> deleteMine(ServerProjectRoot root, String path) async {
    final file = await _bytesFile(root, 'mine', path);
    if (await file.exists()) await file.delete();
  }
}
