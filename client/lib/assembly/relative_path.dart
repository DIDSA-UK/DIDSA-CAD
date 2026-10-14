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

/// The native project file extension: `.didsa` is the **current** format and
/// the only extension the app ever *writes* (Save, Save As, auto-assigned
/// component paths, tree Rename of a file with no native extension, AI-created
/// files). It replaced `.DIDSAprt` once part and assembly files were known to
/// be one file format (one Part that can hold both Features and Occurrences,
/// `docs/assembly-scope.md`). DIDSA-VR also writes `.didsa`.
///
/// See [kLegacyNativeFileExtensions] for what is still *read*. Decision record:
/// `docs/bug-report-2026-10-14-plan.md` item 9.
const String kNativeFileExtension = '.didsa';

/// Legacy native extensions: **read-only**, never created. `.DIDSAprt` is what
/// the flat app wrote before the migration; `.didsacad` is the pre-July name
/// (`docs/status.md`). All three hold byte-for-byte the same `schema_version: 1`
/// JSON, so the extension only decides whether a file is *listed and
/// recognised*, never how it is parsed.
///
/// An existing file always keeps its own path and extension on Save: other
/// assemblies' `external_ref`s point at that exact path, so nothing renames it
/// implicitly.
const List<String> kLegacyNativeFileExtensions = ['.DIDSAprt', '.didsacad'];

/// Every extension that is recognised as a native file, current first.
const List<String> _allNativeFileExtensions = [kNativeFileExtension, ...kLegacyNativeFileExtensions];

/// True when [name] looks like a native project file: the current `.didsa` or
/// a legacy extension, case-insensitively, optionally with the ` (1)`/`_1`
/// suffix a download or copy adds after the extension. This is what
/// lists/opens accept; only [kNativeFileExtension] is ever written.
bool isNativeProjectFileName(String name) => _nativeFileNamePattern.hasMatch(name.trim());

final RegExp _nativeFileNamePattern = RegExp(
  '(${_allNativeFileExtensions.map(RegExp.escape).join('|')})(_\\d+| \\(\\d+\\))?\$',
  caseSensitive: false,
);

String _lowerExtensionMatch(String name) {
  final lower = name.trim().toLowerCase();
  for (final extension in _allNativeFileExtensions) {
    if (lower.endsWith(extension.toLowerCase())) return extension;
  }
  return '';
}

/// True when [name] ends with a native extension (current or legacy,
/// case-insensitive). Unlike [isNativeProjectFileName] this does not accept the
/// ` (1)`/`_1` copy suffix: it answers "does this name already carry a native
/// extension", which is what [withDefaultExtension] needs.
bool hasNativeExtension(String name) => _lowerExtensionMatch(name).isNotEmpty;

/// [name] without its native extension (any of the three, any case), or
/// unchanged if it has none. Use this for every display or base name instead
/// of an inline regex.
String stripNativeExtension(String name) {
  final extension = _lowerExtensionMatch(name);
  if (extension.isEmpty) return name;
  final trimmed = name.trim();
  return trimmed.substring(0, trimmed.length - extension.length);
}

/// A collision key for [path]: lower-cased with any native extension removed,
/// so `Bracket.didsa` and `bracket.DIDSAprt` in one folder compare equal. A
/// single `StorageService.resolve` call can't see the other extension, so
/// collision checks compare this against `listNativeFiles` instead.
String nativeBaseNameKey(String path) => stripNativeExtension(path).toLowerCase();

/// The extension to keep when producing a sibling name for [existingPath]:
/// its own native extension (so `Bracket.DIDSAprt` stays `.DIDSAprt` on
/// rename), else [kNativeFileExtension].
String nativeExtensionOf(String existingPath) {
  final extension = _lowerExtensionMatch(existingPath);
  if (extension.isEmpty) return kNativeFileExtension;
  final trimmed = existingPath.trim();
  return trimmed.substring(trimmed.length - extension.length);
}

/// Appends [kNativeFileExtension] unless [raw] already **ends with a native
/// extension** (current or legacy, case-insensitive) - not merely "contains a
/// dot": `Frame 1.5m` becomes `Frame 1.5m.didsa`, `bracket.txt` becomes
/// `bracket.txt.didsa`, while `bracket.DIDSAprt` is left as typed (a legacy
/// extension typed on purpose). A file is never written without a native
/// extension, because [isNativeProjectFileName] would then hide it from every
/// Open dialog and listing.
String withDefaultExtension(String raw) {
  final trimmed = raw.trim();
  if (hasNativeExtension(trimmed)) return trimmed;
  return '$trimmed$kNativeFileExtension';
}

/// The first file in [existingFiles] that [candidatePath] would collide with
/// under [nativeBaseNameKey] (same folder, same base name, either extension),
/// or `null`. Exact-name matches count too.
String? findNativeNameCollision(String candidatePath, Iterable<String> existingFiles) {
  final key = nativeBaseNameKey(candidatePath);
  for (final file in existingFiles) {
    if (nativeBaseNameKey(file) == key) return file;
  }
  return null;
}

/// Save/project overhaul Phase 2 (`docs/save-project-overhaul-scope.md`
/// §3.2): the new relative path for renaming the file at [relativePath] to
/// [newFileName] (a bare file name, never a further relative path) while
/// keeping it in the same directory - `StorageService.renameFile`'s own
/// same-directory-only contract, matching what `saf_util.rename`/iOS's
/// `moveItem` both natively support without a separate move step.
String siblingRelativePath(String relativePath, String newFileName) {
  final lastSlash = relativePath.lastIndexOf('/');
  return lastSlash == -1 ? newFileName : '${relativePath.substring(0, lastSlash + 1)}$newFileName';
}
