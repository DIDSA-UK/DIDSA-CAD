import 'project_root.dart';

/// A resolved reference to one file inside a `ProjectRoot` - what
/// `StorageService.resolve`/`writeFile` hand back, and what
/// `readFile`/`lastModified`/`exists` take. Always carries `relativePath`
/// (POSIX-style, relative to its `root`) alongside the platform-specific
/// locator, since `relativePath` is what actually gets persisted into an
/// `Occurrence.external_ref` (`backend/app/document/models.py`) - the
/// platform locator (`path`/`uri`) is a live-session convenience, not
/// something written to disk.
sealed class FileHandle {
  const FileHandle();

  ProjectRoot get root;
  String get relativePath;
}

final class DesktopFileHandle extends FileHandle {
  const DesktopFileHandle({required this.root, required this.relativePath, required this.path});

  @override
  final DesktopProjectRoot root;
  @override
  final String relativePath;

  /// The full OS path (`root.path` + `relativePath`, joined) - a plain
  /// `dart:io` `File`/`Directory` target.
  final String path;
}

final class SafFileHandle extends FileHandle {
  const SafFileHandle({required this.root, required this.relativePath, required this.uri});

  @override
  final SafProjectRoot root;
  @override
  final String relativePath;

  /// The file's own `content://` URI, resolved by walking `root.treeUri`
  /// via `SafUtil.child`. Stable across a session but never persisted -
  /// see `FileHandle`'s own docstring for why `relativePath` is the
  /// portable identity instead.
  final String uri;
}

/// An iOS file handle. Only the *root folder* carries a persisted
/// security-scoped bookmark (`IosProjectRoot.bookmarkBase64`) - resolving
/// a bookmark for every individual file inside a project would mean
/// minting and storing one bookmark per file, which iOS's bookmark API was
/// never designed for. Instead, an individual file is reached by resolving
/// the *root's* bookmark to a filesystem path once
/// (`IosBookmarkChannel.resolveBookmark`) and then addressing the file as
/// `resolvedPath` + `relativePath` for the remainder of that session -
/// exactly the same "URI/path is a live-session convenience,
/// `relativePath` is the portable identity" contract `SafFileHandle.uri`
/// documents, just with the persisted half living one level up at the
/// root instead of per file.
final class IosFileHandle extends FileHandle {
  const IosFileHandle({required this.root, required this.relativePath, required this.resolvedPath});

  @override
  final IosProjectRoot root;
  @override
  final String relativePath;

  /// The root's bookmark resolved to a real filesystem path for *this*
  /// session, joined with `relativePath`. Never persisted - a later
  /// session must re-resolve `root.bookmarkBase64` from scratch, since the
  /// underlying path can change between launches even when the bookmark
  /// itself is still valid (e.g. the OS relocated the app's sandbox
  /// container).
  final String resolvedPath;
}
