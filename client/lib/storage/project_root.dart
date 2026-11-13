import 'dart:io';

/// Assembly support's project-root abstraction (`docs/assembly-scope.md`):
/// where a user's `.didsa` files live, resolved once via
/// `StorageService.pickOrCreateProjectRoot`/`lastUsedProjectRoot` and then
/// referenced by every later file operation as `(ProjectRoot,
/// relativePath)` rather than a raw absolute path - relative paths inside
/// one root stay valid if the whole folder is moved, copied, or synced to
/// a different device/path (decision #4 from the assembly brainstorm: an
/// `Occurrence.external_ref`, `backend/app/document/models.py`, is exactly
/// such a relative path, never a platform-specific absolute one).
///
/// Four variants: desktop (a plain OS directory), Android SAF (a tree
/// URI), iOS (a persisted security-scoped bookmark), and a project on the
/// project store (`ServerProjectRoot`, `docs/shared-storage-scope.md`).
sealed class ProjectRoot {
  const ProjectRoot();

  /// A short label for display (e.g. in a "recent projects" list) - the
  /// last path segment for desktop, the SAF tree's own display name for
  /// Android.
  String get displayName;

  /// An opaque string this root can be reconstructed from on the next app
  /// launch (see `RecentProjectStore`) - never parsed by anything other
  /// than the `StorageService` that produced it.
  String get persistedKey;
}

/// A plain OS directory path - desktop (Windows/Linux/macOS) only.
final class DesktopProjectRoot extends ProjectRoot {
  const DesktopProjectRoot(this.path);

  final String path;

  @override
  String get displayName {
    final segments = path.split(Platform.pathSeparator).where((s) => s.isNotEmpty);
    return segments.isEmpty ? path : segments.last;
  }

  @override
  String get persistedKey => path;

  @override
  bool operator ==(Object other) => other is DesktopProjectRoot && other.path == path;

  @override
  int get hashCode => path.hashCode;
}

/// A Storage Access Framework tree the user granted persistent access to
/// (Android only) - `treeUri` is the `content://` URI returned by
/// `SafUtil.pickDirectory(persistablePermission: true)`.
final class SafProjectRoot extends ProjectRoot {
  const SafProjectRoot({required this.treeUri, required String displayName}) : _displayName = displayName;

  final String treeUri;
  final String _displayName;

  @override
  String get displayName => _displayName;

  @override
  String get persistedKey => treeUri;

  @override
  bool operator ==(Object other) => other is SafProjectRoot && other.treeUri == treeUri;

  @override
  int get hashCode => treeUri.hashCode;
}

/// A security-scoped bookmark to a folder the user granted access to via
/// `UIDocumentPickerViewController` (iOS only) - iOS has no Storage Access
/// Framework, so persisted access to a user-chosen folder across app
/// launches instead relies on `URL.bookmarkData(options: [])` /
/// `URL(resolvingBookmarkData:...)`, bracketed by
/// `start/stopAccessingSecurityScopedResource()` around each use
/// (`IosStoragePlugin.swift`). `bookmarkBase64` is that bookmark's raw
/// `Data`, base64-encoded so it round-trips through the platform channel
/// and `RecentProjectStore`'s plain-string persistence unchanged.
final class IosProjectRoot extends ProjectRoot {
  const IosProjectRoot({required this.bookmarkBase64, required String displayName}) : _displayName = displayName;

  final String bookmarkBase64;
  final String _displayName;

  @override
  String get displayName => _displayName;

  @override
  String get persistedKey => bookmarkBase64;

  @override
  bool operator ==(Object other) => other is IosProjectRoot && other.bookmarkBase64 == bookmarkBase64;

  @override
  int get hashCode => bookmarkBase64.hashCode;
}

/// A project kept on the project store (`project-store/`, `docs/shared-storage-scope.md`): the store's address plus the project's
/// name. The store's key is **not** part of the root (a root is persisted and shown); it is read from the server settings
/// (`ApiConfig.storeApiKey`) each time the store is called. Served by `RemoteStorageService`.
final class ServerProjectRoot extends ProjectRoot {
  const ServerProjectRoot({required this.serverUrl, required this.project});

  /// The store's base URL without a trailing slash, e.g. `https://store.example.com`.
  final String serverUrl;

  /// The project's name: a top-level folder of the store.
  final String project;

  @override
  String get displayName => project;

  @override
  String get persistedKey => 'server:$serverUrl|$project';

  @override
  bool operator ==(Object other) => other is ServerProjectRoot && other.serverUrl == serverUrl && other.project == project;

  @override
  int get hashCode => Object.hash(serverUrl, project);
}
