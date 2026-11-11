import 'file_lookup_rule.dart';

/// A project-folder change as the leading folders it added or removed: `from` is replaced by `to` at the start of every stored
/// path (Flutter-testing feedback 2026-11-11, item 1c). Learned from one reference that was found (`parts/x.didsa` ->
/// `proj/parts/x.didsa` gives from `[]`, to `[proj]`), then applied to the others that moved the same way.
class FolderShift {
  const FolderShift(this.from, this.to);

  final List<String> from;
  final List<String> to;

  /// The shift between a [storedPath] and the [foundPath] it was found at: the trailing segments they share are the unchanged
  /// tail, the rest is the shift. Null when nothing shifted (same folders, a plain rename) or they share no tail at all.
  static FolderShift? between(String storedPath, String foundPath) {
    final stored = segmentsOf(storedPath), found = segmentsOf(foundPath);
    final tail = lookupSharedTail([for (final s in stored) s.toLowerCase()], [for (final s in found) s.toLowerCase()]);
    if (tail < 1) return null;
    final from = stored.sublist(0, stored.length - tail), to = found.sublist(0, found.length - tail);
    if (from.isEmpty && to.isEmpty) return null;
    return FolderShift(from, to);
  }

  /// [storedPath] with the shift applied, or null when it does not start with [from].
  String? apply(String storedPath) {
    final stored = segmentsOf(storedPath);
    if (stored.length < from.length) return null;
    for (var i = 0; i < from.length; i++) {
      if (stored[i].toLowerCase() != from[i].toLowerCase()) return null;
    }
    return [...to, ...stored.sublist(from.length)].join('/');
  }

  bool sameAs(FolderShift other) => from.join('/') == other.from.join('/') && to.join('/') == other.to.join('/');

  /// A path's segments as written (separators unified, empty and `.` dropped).
  static List<String> segmentsOf(String path) => [
        for (final segment in path.trim().replaceAll(r'\', '/').split('/'))
          if (segment.isNotEmpty && segment != '.') segment,
      ];

  /// The files of [index] at [candidatePath], compared the way the lookup rule compares paths (case and native extension set aside).
  static List<IndexedFile> filesAt(String candidatePath, List<IndexedFile> index) {
    final wanted = lookupSegments(candidatePath).join('/');
    return [
      for (final entry in index)
        if (lookupSegments(entry.path).join('/') == wanted) entry,
    ];
  }
}
