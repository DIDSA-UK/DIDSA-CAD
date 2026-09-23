/// Assembly support Phase 15 (`docs/assembly-scope.md` §6): validation for
/// a user-typed `ProjectRoot`-relative path (the "Create Component…"/"Save
/// All" prompt, `relative_path_dialog.dart`). Pure, no `dart:io`/Flutter
/// dependency, directly unit-testable.
///
/// Rejects the concrete path-traversal risk both `StorageService`
/// implementations are exposed to: `DesktopStorageService._fullPath` does a
/// bare `p.join(root.path, relativePath)` with no sanitization, and
/// `SafStorageService`'s own segment-by-segment `mkdirp` would silently
/// treat a `..` segment as a literal folder name rather than walking back
/// up. Deliberately lenient on everything else - there is no folder browser
/// yet (`StorageService.listFiles` is Phase 18's own scope), so this is the
/// only guard between a typed string and a real file write.
library;

/// Returns a user-facing error message if [raw] isn't safe/usable as a
/// `ProjectRoot`-relative path, or `null` if it's fine as-is.
String? validateProjectRelativePath(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) {
    return 'Enter a file name';
  }
  if (trimmed.startsWith('/') || trimmed.startsWith(r'\')) {
    return 'Path must be relative to the project folder';
  }
  if (RegExp(r'^[a-zA-Z]:').hasMatch(trimmed)) {
    return 'Path must be relative to the project folder';
  }
  final segments = trimmed.split(RegExp(r'[/\\]'));
  if (segments.any((segment) => segment == '..')) {
    return 'Path cannot contain ".."';
  }
  if (segments.any((segment) => segment.trim().isEmpty)) {
    return 'Path cannot contain an empty segment';
  }
  return null;
}

/// The extension every native project file round-trips through today
/// (`PartScreen._saveAsNativeFile`'s own suggested filename,
/// `_displayPartName`'s strip regex) - `.didsa`/`.didsacad` are this
/// project's own documentation shorthand for "a native file" in general,
/// never what's actually written to disk.
const String kNativeFileExtension = '.DIDSAprt';

/// Appends [kNativeFileExtension] to [raw] if it has no extension at all -
/// lenient, not a hard requirement, matching `_openNativeFile`'s own
/// `FileType.any` posture (an unusual extension is never rejected, only a
/// bare name with none is helped along).
String withDefaultExtension(String raw) {
  final trimmed = raw.trim();
  final lastSegment = trimmed.split(RegExp(r'[/\\]')).last;
  if (lastSegment.contains('.')) {
    return trimmed;
  }
  return '$trimmed$kNativeFileExtension';
}
