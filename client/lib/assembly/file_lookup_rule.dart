/// Finding moved files (`docs/moved-files-scope.md` section 2): the rule that finds the file an Occurrence places when its path
/// misses. Dart copy of `backend/app/document/file_lookup.py` (the reference) - keep the two in matching shape; both are tested
/// against `docs/file-lookup/vectors.json` (`test/file_lookup_rule_test.dart`). Pure: no file system, so it is the same
/// function whatever the platform's `StorageService`.
///
/// 1. The path: a file there with the stored id, or any file there when the reference has no stored id (an older file), is
///    found via [LookupVia.path]. A file there with a *different* id is not used: [FileLookup.pathMismatch], and the search
///    goes on.
/// 2. The id: exactly one file in the index with the stored id is found via [LookupVia.id] (the caller uses it, says so, and
///    writes the corrected path on the next save); several are [LookupResult.ask] (nothing is loaded until the user picks).
/// 2b. The folder shift (Flutter-testing feedback 2026-11-11, item 1b): for a reference with **no stored id**, exactly one name match
///    with the largest number of trailing path segments in common (`k >= 2`, and one path is the other with leading folders
///    dropped) is [LookupResult.likely] (`via: suffix`). Never used by the rule itself: the caller asks the user first. A
///    stored id never gets it (the file would not carry the id): that is only a suggestion.
/// 3. The name: files anywhere in the index with the reference's file name (native extension and letter case set aside), plus
///    a mismatched file at the path, are only ever a [LookupResult.suggest]ion; never used without the user saying so.
/// 4. Otherwise [LookupResult.missing].
library;

/// A native file in the project folder with the root Part id read from it (`null` when it could not be read).
class IndexedFile {
  const IndexedFile(this.path, this.partId);

  final String path;
  final String? partId;
}

enum LookupResult { found, likely, ask, suggest, missing }

enum LookupVia { path, id, suffix }

class FileLookup {
  const FileLookup(this.result, {this.path, this.via, this.candidates = const [], this.pathMismatch = false});

  final LookupResult result;

  /// The file to use ([LookupResult.found]), or the one that probably moved with the folder ([LookupResult.likely]).
  final String? path;
  final LookupVia? via;

  /// Sorted paths for [LookupResult.ask] / [LookupResult.suggest].
  final List<String> candidates;

  /// A file is at the reference's path but carries another id (reported whatever else happens).
  final bool pathMismatch;
}

const List<String> _nativeExtensions = ['didsa', 'DIDSAprt', 'didsacad'];

/// A file's name for step 3: the last path segment, lower-cased, with any native extension removed, so
/// `parts/Bracket.didsa` and `old/bracket.DIDSAprt` compare equal.
String lookupNameKey(String path) {
  final normalised = path.trim().replaceAll(r'\', '/');
  final lower = normalised.substring(normalised.lastIndexOf('/') + 1).toLowerCase();
  for (final extension in _nativeExtensions) {
    final suffix = '.${extension.toLowerCase()}';
    if (lower.endsWith(suffix)) return lower.substring(0, lower.length - suffix.length);
  }
  return lower;
}

FileLookup _answer(
  LookupResult result, {
  String? path,
  LookupVia? via,
  Iterable<String> candidates = const [],
  bool mismatch = false,
}) =>
    FileLookup(result, path: path, via: via, candidates: candidates.toList(), pathMismatch: mismatch);

/// A path's segments for the folder-shift step: separators unified, empty and `.` segments dropped, lower-cased, and the file name
/// without its native extension (`Proj/Parts/Bracket.didsa` -> `[proj, parts, bracket]`).
List<String> lookupSegments(String path) {
  final parts = [
    for (final segment in path.trim().replaceAll(r'\', '/').split('/'))
      if (segment.isNotEmpty && segment != '.') segment,
  ];
  if (parts.isEmpty) return const [];
  return [for (final p in parts.take(parts.length - 1)) p.toLowerCase(), lookupNameKey(parts.last)];
}

/// How many trailing segments [a] and [b] have in common.
int lookupSharedTail(List<String> a, List<String> b) {
  var count = 0;
  while (count < a.length && count < b.length && a[a.length - 1 - count] == b[b.length - 1 - count]) {
    count++;
  }
  return count;
}

/// Where the file a reference places is now. [atPath] is the file the existing path lookup found (exact name, then another
/// native extension or letter case in the same folder) with its root Part id, or null when it found nothing. [index] is every
/// native file in the project folder.
FileLookup findFile({
  required String externalRef,
  required String? refPartId,
  required IndexedFile? atPath,
  required List<IndexedFile> index,
}) {
  final refId = (refPartId == null || refPartId.isEmpty) ? null : refPartId;
  var mismatch = false;
  if (atPath != null) {
    if (refId == null || atPath.partId == refId) {
      return _answer(LookupResult.found, path: atPath.path, via: LookupVia.path);
    }
    mismatch = true;
  }
  if (refId != null) {
    final byId = {
      for (final entry in index)
        if (entry.partId == refId) entry.path
    }.toList()
      ..sort();
    if (byId.length == 1) {
      return _answer(LookupResult.found, path: byId.single, via: LookupVia.id, mismatch: mismatch);
    }
    if (byId.isNotEmpty) return _answer(LookupResult.ask, candidates: byId, mismatch: mismatch);
  }
  final wanted = externalRef.trim();
  if (wanted.isNotEmpty) {
    final wantedSegments = lookupSegments(wanted);
    final key = lookupNameKey(wanted);
    final byName = {
      for (final entry in index)
        if (lookupNameKey(entry.path) == key) entry.path
    };
    if (mismatch) byName.add(atPath!.path);
    if (byName.isNotEmpty) {
      final scored = [
        for (final path in byName) (k: lookupSharedTail(wantedSegments, lookupSegments(path)), path: path),
      ]..sort((a, b) => a.k != b.k ? b.k.compareTo(a.k) : a.path.compareTo(b.path));
      final best = scored.first;
      final uniqueBest = scored.length == 1 || scored[1].k < best.k;
      final wholeSuffix = best.k == (wantedSegments.length < lookupSegments(best.path).length
          ? wantedSegments.length
          : lookupSegments(best.path).length);
      if (refId == null && uniqueBest && best.k >= 2 && wholeSuffix) {
        return _answer(LookupResult.likely, path: best.path, via: LookupVia.suffix);
      }
      return _answer(LookupResult.suggest, candidates: [for (final s in scored) s.path], mismatch: mismatch);
    }
  }
  return _answer(LookupResult.missing, mismatch: mismatch);
}
