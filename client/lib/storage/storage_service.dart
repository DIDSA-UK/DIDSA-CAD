import 'dart:typed_data';

import 'file_handle.dart';
import 'project_root.dart';

/// Raised by any `StorageService` operation that can't complete - a
/// missing file, a revoked SAF permission, an unreachable network-mounted
/// drive. Callers that want the "always latest, fall back to a cached
/// snapshot" staleness policy (`docs/assembly-scope.md` decision #5) catch
/// this around `readFile`/`lastModified`/`exists` and fall back to
/// `FileCache` rather than surfacing a hard error - see that class's own
/// docstring.
class StorageException implements Exception {
  StorageException(this.message, {this.cause});

  final String message;
  final Object? cause;

  @override
  String toString() => 'StorageException: $message${cause != null ? ' (caused by $cause)' : ''}';
}

/// Where a user's `.didsa` project files live and how the app reads/writes
/// them - one interface, two implementations (`DesktopStorageService`,
/// `SafStorageService`), picked by `createStorageService()` based on
/// platform. Every method works purely in terms of `ProjectRoot`/
/// `FileHandle`/relative paths (never a raw absolute path or SAF URI
/// crossing back out of this layer into application code) so the rest of
/// the app - the multi-file assembly graph composer (Phase 2), the
/// document save/load flow - never has to branch on platform itself.
abstract class StorageService {
  /// Shows the platform's own folder picker (a native folder-create-or-
  /// choose dialog) so the user selects or creates their project folder.
  /// `suggestedName` is a hint for the picker's own "create new folder"
  /// starting point (e.g. `"didsa/projects"`) - never a path this method
  /// creates unilaterally; scoped storage means the app cannot place a
  /// folder at a fixed location without the user's own picker grant
  /// (`docs/assembly-scope.md`'s storage decision).
  Future<ProjectRoot> pickOrCreateProjectRoot({String suggestedName = 'didsa/projects'});

  /// The most recently used project root, if this app has one persisted
  /// and it's still reachable/granted - `null` if there is none yet, or
  /// the persisted one is no longer accessible (e.g. a revoked SAF grant),
  /// in which case the caller should fall back to
  /// `pickOrCreateProjectRoot`.
  Future<ProjectRoot?> lastUsedProjectRoot();

  /// Resolves `relativePath` (POSIX-style, relative to `root`) to a
  /// concrete `FileHandle`, or `null` if nothing exists there yet.
  Future<FileHandle?> resolve(ProjectRoot root, String relativePath);

  /// Reads the full contents of an existing file. Throws
  /// `StorageException` if it can't be read (deleted, offline, permission
  /// revoked) - callers implementing the staleness-fallback policy should
  /// catch this specifically.
  Future<Uint8List> readFile(FileHandle handle);

  /// Writes `bytes` to `relativePath` under `root`, creating any missing
  /// intermediate directories and the file itself if it doesn't exist yet,
  /// or overwriting it in place if it does. Returns the resulting
  /// `FileHandle`.
  ///
  /// [baseVersion] (shared storage, `docs/shared-storage-scope.md` section 7): the version of the file this write replaces, for a
  /// service whose files have versions (the project store). A caller that does not say leaves it to the service, which uses the
  /// version it last read or wrote for that path (null: a new file). The local services ignore it. A server write whose version
  /// is out of date throws `SyncConflictException` (a `StorageException`) and keeps the bytes as a queued save.
  Future<FileHandle> writeFile(ProjectRoot root, String relativePath, Uint8List bytes, {int? baseVersion});

  /// Whether [commit] on [root] is one all-or-nothing write (a server project). Save All uses [commit] when this is true and
  /// writes file by file when it is not (a local folder has no such write).
  bool supportsCommit(ProjectRoot root);

  /// Writes several files at once (`docs/shared-storage-scope.md` section 6). For a server project: one commit, all of it or none
  /// of it; a clash throws `SyncConflictException` listing every clashing file and nothing is written; an unreachable server queues
  /// the changes (the outcome says so). For a local folder (`FileByFileCommit`): file by file, a failure thrown as
  /// [StorageException] after the others were tried.
  Future<CommitOutcome> commit(ProjectRoot root, List<FileChange> changes, {String? message});

  /// The file's last-modified time, or `null` if that information isn't
  /// available from this platform/provider. Used for the "always try
  /// latest" half of the staleness policy - compared against
  /// `FileCache`'s own cached-at time to decide whether a cached snapshot
  /// is still current enough to skip a re-read.
  Future<DateTime?> lastModified(FileHandle handle);

  /// Whether the file this handle refers to still exists and is reachable
  /// right now. Never throws - an unreachable file (offline network
  /// drive, revoked permission) reads as `false`, the same as a genuinely
  /// deleted one; callers that care about the distinction should catch
  /// `StorageException` from `readFile`/`lastModified` instead.
  Future<bool> exists(FileHandle handle);

  /// Assembly support Phase 18 (`docs/assembly-scope.md` §6 `[2]`):
  /// recursively lists every file (never a directory) under `root`, as
  /// POSIX-style relative paths (the same identity `Occurrence.external_ref`/
  /// `FileHandle.relativePath` use) - optionally filtered to paths whose
  /// name ends in `extensionFilter` (e.g. `kNativeFileExtension`, see
  /// `relative_path.dart`). Ordering is implementation-defined - sort the
  /// result yourself if you need one. Throws `StorageException` only if
  /// `root` itself is unreachable; a mid-walk I/O error on one subtree
  /// (a permission hiccup, a revoked child grant) is swallowed and the walk
  /// continues, returning a partial-but-useful list rather than failing
  /// outright - the sole real consumer today (`ai_component_file_summary.dart`'s
  /// prompt-context fetch) is already a best-effort operation elsewhere in
  /// this codebase.
  Future<List<String>> listFiles(ProjectRoot root, {String? extensionFilter});

  /// Save/project overhaul Phase 2 (`docs/save-project-overhaul-scope.md`
  /// §3.2): the assembly tree's own Rename action - renames the file at
  /// `relativePath` to `newFileName` (a bare file name, e.g.
  /// `"Bracket.didsa"` - never a further relative path/subdirectory of
  /// its own), keeping it in the same directory. Same-directory-only is a
  /// deliberate scope limit, not an oversight: every real call site (this
  /// Rename action, a Create-Component auto-path collision fallback) only
  /// ever changes a file's own name, never its location - and both
  /// platform primitives this delegates to (`saf_util.rename`, iOS's
  /// `moveItem` within one parent) natively support exactly that without
  /// a separate move step. Use `relative_path.dart`'s own
  /// `siblingRelativePath` to compute the resulting relative path from the
  /// return value. Throws `StorageException` if nothing exists at
  /// `relativePath`, or if a file already exists at the destination.
  Future<FileHandle> renameFile(ProjectRoot root, String relativePath, String newFileName);
}

/// One file of a [StorageService.commit].
class FileChange {
  const FileChange({required this.path, required this.bytes, this.baseVersion});

  final String path;
  final Uint8List bytes;

  /// The version this replaces (a server project); null lets the service use the version it last read or wrote.
  final int? baseVersion;
}

/// What [StorageService.commit] did: [sent] files are written; [queued] files were kept to send when the store can be reached
/// (a server project saved offline).
class CommitOutcome {
  const CommitOutcome({this.sent = const [], this.queued = const []});

  final List<String> sent;
  final List<String> queued;
}

/// [StorageService.commit] for a service with no all-or-nothing write: the files one by one. Mixed into the local services.
mixin FileByFileCommit {
  Future<FileHandle> writeFile(ProjectRoot root, String relativePath, Uint8List bytes, {int? baseVersion});

  bool supportsCommit(ProjectRoot root) => false;

  Future<CommitOutcome> commit(ProjectRoot root, List<FileChange> changes, {String? message}) async {
    final sent = <String>[];
    for (final change in changes) {
      await writeFile(root, change.path, change.bytes, baseVersion: change.baseVersion);
      sent.add(change.path);
    }
    return CommitOutcome(sent: sent);
  }
}
