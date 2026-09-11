import 'dart:convert';

import '../storage/file_cache.dart';
import '../storage/project_root.dart';
import '../storage/storage_service.dart';

/// Raised when resolving a `.didsa` file's Occurrences would revisit a file
/// already on the current resolution path (A references B references A,
/// directly or transitively) - a genuinely invalid assembly graph, not a
/// normal "same file referenced from two places" diamond (which is the
/// expected, supported case - see [AssemblyGraphComposer.compose]'s own
/// per-relative-path dedup).
class AssemblyGraphCycleException implements Exception {
  AssemblyGraphCycleException(this.cyclePath);

  /// The relative-path chain that closes the cycle, root-first, with the
  /// revisited path repeated at the end (e.g. `[a, b, a]`).
  final List<String> cyclePath;

  @override
  String toString() => 'Assembly graph cycle detected: ${cyclePath.join(' -> ')}';
}

/// One `.didsa` file's compose result: everything [AssemblyGraphComposer]
/// needed to know about it to fold it into the combined graph.
class ComposedAssemblyGraph {
  ComposedAssemblyGraph({
    required this.rootPartId,
    required this.documentPayload,
    required this.relativePathByPartId,
    required this.staleRelativePaths,
  });

  /// The `id` of the root file's own Part, inside [documentPayload] - what
  /// to call `DocumentApiClient.getAssemblyMesh`/`.../mesh` with after
  /// importing.
  final String rootPartId;

  /// Ready to hand to `DocumentApiClient.importNative` as-is - one combined
  /// `{"schema_version", "document": {"id", "root_part_id", "parts": [...]}
  /// , "sketches": [...]}` payload, every Occurrence's `external_ref`
  /// paired with a `resolved_part_id` naming another Part in this same
  /// payload wherever it was resolved (see `app.document.models.
  /// Occurrence`'s own docstring on the backend for why this pairing is
  /// what lets `resolved_part_id` survive `import_native`'s own
  /// same-payload validation).
  final Map<String, dynamic> documentPayload;

  /// The inverse of what was resolved - which relative path each Part id
  /// in [documentPayload] came from, needed for save-back (Phase 3+: which
  /// file does an edited Part's own `export_native(part_id=...)` write to).
  final Map<String, String> relativePathByPartId;

  /// Relative paths that couldn't be read live and fell back to a cached
  /// last-known-good snapshot (`docs/assembly-scope.md` decision #5) -
  /// the caller should flag these stale in the UI (e.g. the assembly
  /// tree's per-occurrence badge) and retry resolving them on the next
  /// compose rather than assuming they're current.
  final Set<String> staleRelativePaths;
}

/// Assembly support Phase 2 (`docs/assembly-scope.md`): resolves a root
/// `.didsa` file and everything it (transitively) references via
/// `Occurrence.external_ref` into one combined document payload the
/// backend can import in a single `POST /document/import/native` call -
/// the backend has no filesystem/SAF access of its own (decision #6), so
/// this resolution is entirely the client's job.
///
/// Each file already carries its own stable `id` (assigned once, whenever
/// that file's Part was first created) - this composer trusts that id
/// as-is rather than minting new ones, which is also what makes resolving
/// the *same* file from two different Occurrences (a shared library part,
/// or two paths converging on one sub-assembly) a safe, ordinary dedup
/// rather than something needing special handling: both resolve to the
/// same relative path, hit the same cache entry in [_resolvedByPath], and
/// end up as one Part entry in the composed payload either way.
class AssemblyGraphComposer {
  AssemblyGraphComposer({required StorageService storageService, FileCache? fileCache})
    : _storageService = storageService,
      _fileCache = fileCache ?? FileCache();

  final StorageService _storageService;
  final FileCache _fileCache;

  /// Resolves [rootRelativePath] (and everything it references) under
  /// [root] into one composed graph. Throws [AssemblyGraphCycleException]
  /// for a genuine reference cycle, or [StorageException] if the root file
  /// itself can't be read (live or cached) at all - a referenced *child*
  /// file that can't be read is not fatal (see [ComposedAssemblyGraph]'s
  /// own `staleRelativePaths`/silently-unresolved-Occurrence handling,
  /// mirroring the backend's own `assembly-mesh` endpoint skipping an
  /// unresolved Occurrence rather than failing the whole response).
  Future<ComposedAssemblyGraph> compose(ProjectRoot root, String rootRelativePath) async {
    final resolvedByPath = <String, Map<String, dynamic>>{};
    final partIdByPath = <String, String>{};
    final sketchesById = <String, Map<String, dynamic>>{};
    final stalePaths = <String>{};

    Future<Map<String, dynamic>> readAndDecode(String relativePath) async {
      try {
        final handle = await _storageService.resolve(root, relativePath);
        if (handle == null) {
          throw StorageException('File not found: $relativePath');
        }
        final bytes = await _storageService.readFile(handle);
        final lastModified = await _storageService.lastModified(handle);
        await _fileCache.put(root, relativePath, bytes, lastKnownModified: lastModified);
        return jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      } on StorageException {
        final cached = await _fileCache.get(root, relativePath);
        if (cached == null) rethrow;
        stalePaths.add(relativePath);
        return jsonDecode(utf8.decode(cached.bytes)) as Map<String, dynamic>;
      }
    }

    Future<String?> resolvePart(String relativePath, List<String> ancestorPath) async {
      if (ancestorPath.contains(relativePath)) {
        throw AssemblyGraphCycleException([...ancestorPath, relativePath]);
      }
      final alreadyResolved = partIdByPath[relativePath];
      if (alreadyResolved != null) return alreadyResolved;

      final Map<String, dynamic> payload;
      try {
        payload = await readAndDecode(relativePath);
      } on StorageException {
        // A referenced child that can't be read at all (live or cached) -
        // not fatal for the graph as a whole; the Occurrence pointing at
        // it just stays unresolved (per ComposedAssemblyGraph's own doc
        // comment, mirroring the backend's own assembly-mesh behavior).
        return null;
      }

      final documentData = payload['document'] as Map<String, dynamic>;
      final parts = (documentData['parts'] as List).cast<Map<String, dynamic>>();
      if (parts.length != 1) {
        throw FormatException(
          '$relativePath is not a valid single-file .didsa save (expected exactly one Part, found ${parts.length})',
        );
      }
      final partDict = parts.single;
      final partId = partDict['id'] as String;
      partIdByPath[relativePath] = partId;

      for (final sketch in (payload['sketches'] as List? ?? const [])) {
        final sketchMap = sketch as Map<String, dynamic>;
        sketchesById[sketchMap['id'] as String] = sketchMap;
      }

      final nextAncestorPath = [...ancestorPath, relativePath];
      final occurrences = (partDict['occurrences'] as List? ?? const []).cast<Map<String, dynamic>>();
      for (final occurrence in occurrences) {
        final externalRef = occurrence['external_ref'] as String?;
        if (externalRef == null) continue;
        final resolvedId = await resolvePart(externalRef, nextAncestorPath);
        if (resolvedId != null) {
          occurrence['resolved_part_id'] = resolvedId;
        }
      }

      resolvedByPath[relativePath] = partDict;
      return partId;
    }

    final rootPartId = await resolvePart(rootRelativePath, const []);
    if (rootPartId == null) {
      throw StorageException('Could not read the root assembly file: $rootRelativePath');
    }

    return ComposedAssemblyGraph(
      rootPartId: rootPartId,
      documentPayload: {
        'schema_version': 1,
        'document': {
          'id': 'composed-${DateTime.now().microsecondsSinceEpoch}',
          'root_part_id': rootPartId,
          'parts': resolvedByPath.values.toList(),
        },
        'sketches': sketchesById.values.toList(),
      },
      relativePathByPartId: {for (final entry in partIdByPath.entries) entry.value: entry.key},
      staleRelativePaths: stalePaths,
    );
  }
}
