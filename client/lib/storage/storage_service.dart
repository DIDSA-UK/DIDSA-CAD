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
  Future<FileHandle> writeFile(ProjectRoot root, String relativePath, Uint8List bytes);

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
}
