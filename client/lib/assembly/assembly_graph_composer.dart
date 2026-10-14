import 'dart:convert';

import '../storage/file_cache.dart';
import '../storage/project_root.dart';
import '../storage/storage_service.dart';
import 'remint_identity.dart';

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
    this.rootClientExtras = const {},
  });

  /// The root file's client-only top-level keys (`hidden_feature_ids`,
  /// `section_planes`) - never part of [documentPayload]'s Parts, kept so the
  /// screen can restore them the way a legacy bundle Open does.
  final Map<String, dynamic> rootClientExtras;

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
/// as-is rather than minting new ones (except to heal a collision between
/// two *different* files, see the comment in [compose]), which is also what
/// makes resolving
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
    var rootClientExtras = <String, dynamic>{};

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

      Map<String, dynamic> payload;
      try {
        payload = await readAndDecode(relativePath);
      } on StorageException {
        // A referenced child that can't be read at all (live or cached) -
        // not fatal for the graph as a whole; the Occurrence pointing at
        // it just stays unresolved (per ComposedAssemblyGraph's own doc
        // comment, mirroring the backend's own assembly-mesh behavior).
        return null;
      }

      final readParts = ((payload['document'] as Map<String, dynamic>)['parts'] as List).cast<Map<String, dynamic>>();
      if (readParts.length != 1) {
        throw FormatException(
          '$relativePath is not a valid single-file .didsa save (expected exactly one Part, found ${readParts.length})',
        );
      }

      // Heal id collisions between *different* files (bug report 2026-10-14,
      // item 3). The Part and sketch ids are session-global on the backend,
      // so two files sharing one (typically a pre-fix "Save As" copy that was
      // then edited) would otherwise overwrite each other in the composed
      // payload and collapse to one entry in `relativePathByPartId` - and a
      // later Save All would write the mixed Part to whichever path survived.
      // A file whose Part id is already claimed by another path, or whose
      // sketch id is already present with different content, is re-minted
      // before it is folded in. The new ids live only in this session; the
      // next Save of that Part writes them to disk, so the files heal
      // themselves. (Resolving the *same* path twice never reaches here - the
      // `partIdByPath` hit above is the ordinary diamond dedup.)
      final partIdTaken = partIdByPath.values.contains(readParts.single['id']);
      final sketchCollides = (payload['sketches'] as List? ?? const []).any((sketch) {
        final existing = sketchesById[(sketch as Map<String, dynamic>)['id']];
        return existing != null && jsonEncode(existing) != jsonEncode(sketch);
      });
      if (partIdTaken || sketchCollides) {
        payload = remintNativeIdentity(payload);
      }

      if (ancestorPath.isEmpty) {
        rootClientExtras = {
          for (final key in const ['hidden_feature_ids', 'section_planes'])
            if (payload[key] != null) key: payload[key],
        };
      }

      final documentData = payload['document'] as Map<String, dynamic>;
      final parts = (documentData['parts'] as List).cast<Map<String, dynamic>>();
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
      rootClientExtras: rootClientExtras,
    );
  }
}
