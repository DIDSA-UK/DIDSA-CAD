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
