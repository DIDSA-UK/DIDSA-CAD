/// AI Modelling multi-part/assembly overhaul, Phase C
/// (`docs/ai-modelling/13-multi-part-assembly-overhaul.md`): the naming
/// convention for an AI-recognized sub-part's auto-proposed filename - a
/// type prefix (the LLM's own choice, e.g. "PLATE"/"TUBE"/"SHS", never a
/// fixed enum this file hardcodes) plus a zero-padded sequence number,
/// scanning whatever's already on disk to avoid a collision (e.g.
/// `PLATE_001`, `PLATE_002`, `TUBE_001`). No prior art for this existed
/// anywhere in this codebase before this phase (confirmed by a broad grep
/// during planning) - this is a new, small, pure convention, not a reuse of
/// an existing one.
///
/// Deliberately pure/no `dart:io` dependency, same discipline
/// `relative_path.dart` already established for this exact reason (directly
/// unit-testable, no fake filesystem needed). The caller supplies the
/// existing relative paths (`StorageService.listFiles`) and gets back a
/// candidate name only - per this overhaul's own locked "save gate"
/// decision, nothing here writes anything or claims the name; a human still
/// confirms/edits it before any `StorageService.writeFile` call.
library;

/// Matches `<prefix>_<digits>` (case-insensitive on the prefix, e.g. both
/// `PLATE_003` and `plate_003` count against the `PLATE` prefix) as the
/// base name of a path, ignoring any directory/extension.
final RegExp _sequencedNamePattern = RegExp(r'^(.+)_(\d+)$');

/// Returns the next available `<typePrefix>_<sequence>` name (zero-padded
/// to [padWidth] digits) that doesn't collide with anything already present
/// in [existingRelativePaths] - the lowest unused sequence number for that
/// prefix, starting at 1. [typePrefix] is sanitized to uppercase
/// alphanumerics/underscores only (spaces/punctuation collapsed to `_`), so
/// a loosely-formatted LLM-proposed prefix (e.g. "mounting plate") still
/// produces a clean, conventional name ("MOUNTING_PLATE").
///
/// The returned string is a bare name with no extension and no directory -
/// callers combine it with `relative_path.dart`'s `withDefaultExtension`
/// and whatever subdirectory the project uses.
String nextAvailablePartName(List<String> existingRelativePaths, {required String typePrefix, int padWidth = 3}) {
  final prefix = _sanitizeTypePrefix(typePrefix);
  var maxSequence = 0;
  for (final path in existingRelativePaths) {
    final baseName = _baseNameWithoutExtension(path);
    final match = _sequencedNamePattern.firstMatch(baseName);
    if (match == null) continue;
    if (_sanitizeTypePrefix(match.group(1)!) != prefix) continue;
    final sequence = int.tryParse(match.group(2)!);
    if (sequence != null && sequence > maxSequence) maxSequence = sequence;
  }
  final nextSequence = maxSequence + 1;
  return '${prefix}_${nextSequence.toString().padLeft(padWidth, '0')}';
}

String _sanitizeTypePrefix(String raw) {
  final upper = raw.trim().toUpperCase();
  final collapsed = upper.replaceAll(RegExp(r'[^A-Z0-9]+'), '_');
  return collapsed.replaceAll(RegExp(r'^_+|_+$'), '');
}

String _baseNameWithoutExtension(String relativePath) {
  final lastSlash = relativePath.lastIndexOf(RegExp(r'[/\\]'));
  final fileName = lastSlash < 0 ? relativePath : relativePath.substring(lastSlash + 1);
  final dot = fileName.lastIndexOf('.');
  return dot <= 0 ? fileName : fileName.substring(0, dot);
}
