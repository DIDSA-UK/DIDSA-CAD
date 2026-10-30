import 'dart:convert';

import '../storage/file_cache.dart';
import '../storage/project_root.dart';
import '../storage/storage_service.dart';
import 'file_lookup_rule.dart';
import 'project_file_index.dart';
import 'reference_report.dart';
import 'relative_path.dart';
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
    this.rootDiskPartId,
    this.references = const [],
  });

  /// The root file's Part id as it is on disk. Differs from [rootPartId] when the compose re-minted the file's ids because
  /// they clashed with another file's; what a "this is not the file that was placed here" check compares.
  final String? rootDiskPartId;

  /// References whose file was not simply where the path said (`docs/moved-files-scope.md`): found by id in a new place (the
  /// Occurrence's `external_ref` already holds the new path - an unsaved change), or left unresolved with candidates.
  final List<ReferenceReport> references;

  /// The root file's client-only top-level keys (`section_planes`) - never part of [documentPayload]'s Parts, kept so the
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
  AssemblyGraphComposer({required StorageService storageService, FileCache? fileCache, ProjectFileIndex? fileIndex})
      : _storageService = storageService,
        _fileCache = fileCache ?? FileCache(),
        fileIndex = fileIndex ?? ProjectFileIndex(storageService);

  final StorageService _storageService;
  final FileCache _fileCache;

  /// The project-folder index a missed reference is looked up in (shared with saving, which reads on-disk ids from it).
  final ProjectFileIndex fileIndex;

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
    final reports = <ReferenceReport>[];
    var rootClientExtras = <String, dynamic>{};
    String? rootDiskPartId;

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

    // A live read only (no cache fallback): null when the file is missing or can't be read. A referenced file is read this
    // way first so its id can be checked against the reference before it is used; the cache is the last resort.
    final liveByPath = <String, Map<String, dynamic>?>{};
    Future<Map<String, dynamic>?> readLive(String relativePath) async {
      if (liveByPath.containsKey(relativePath)) return liveByPath[relativePath];
      Map<String, dynamic>? payload;
      try {
        final handle = await _storageService.resolve(root, relativePath);
        if (handle != null) {
          final bytes = await _storageService.readFile(handle);
          final lastModified = await _storageService.lastModified(handle);
          await _fileCache.put(root, relativePath, bytes, lastKnownModified: lastModified);
          payload = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
        }
      } on StorageException {
        payload = null;
      }
      return liveByPath[relativePath] = payload;
    }

    // An `external_ref` written under one native extension (a legacy
    // `Frame_A.DIDSAprt`) must still find the file after the migration to
    // `.didsa` (and vice versa): `StorageService.resolve` is an exact-name
    // lookup, so without this the Occurrence silently stayed unresolved. The
    // exact name always wins; the alternatives are only tried when it is
    // missing. The ref the file was actually found under is written back onto
    // the Occurrence so the next Save heals the stale extension on disk.
    final canonicalPathByRef = <String, String>{};
    Future<String> canonicalPath(String requested) async {
      final known = canonicalPathByRef[requested];
      if (known != null) return known;
      var found = requested;
      if (await _storageService.resolve(root, requested) == null) {
        for (final alternative in nativePathAlternatives(requested)) {
          if (await _storageService.resolve(root, alternative) != null) {
            found = alternative;
            break;
          }
        }
      }
      canonicalPathByRef[requested] = found;
      return found;
    }

    // The project-folder index, built the first time a reference misses (or a file at its path is not the placed part) and
    // then shared by the rest of this compose.
    List<IndexedFile>? index;

    // [resolveOccurrence] and [resolvePart] call each other.
    late Future<String?> Function(String relativePath, List<String> ancestorPath, {Map<String, dynamic>? preloaded})
        resolvePart;

    // Finding moved files (`docs/moved-files-scope.md` section 2): looks the file an Occurrence places up and, when it resolves,
    // points the Occurrence at it (`resolved_part_id`, and `external_ref` as the file was actually found - an unsaved change).
    // [preloaded] on [resolvePart] spares re-reading a file already read.
    Future<void> resolveOccurrence(
      Map<String, dynamic> occurrence,
      String externalRef,
      String parentPartId,
      String parentPath,
      List<String> ancestorPath,
    ) async {
      void bind(String? resolvedId, String foundPath) {
        if (resolvedId == null) return;
        occurrence['resolved_part_id'] = resolvedId;
        occurrence['external_ref'] = foundPath;
      }

      final storedId = _storedPartId(occurrence);
      final path = await canonicalPath(externalRef);
      final live = await readLive(path);
      final liveId = live == null ? null : rootPartIdOf(live);
      // A file at the path is taken as it always was when the reference has no `ref_part_id` of its own: the
      // `resolved_part_id` an older file was saved with can be a session id (a re-minted one) that the file on disk never
      // carried, so it is only good for searching when the path misses, not as proof the file at the path is wrong.
      if (live != null && (occurrence['ref_part_id'] is! String || liveId == storedId)) {
        bind(await resolvePart(path, ancestorPath, preloaded: live), path);
        return;
      }

      index ??= await fileIndex.build(root);
      final lookup = findFile(
        externalRef: externalRef,
        refPartId: storedId,
        atPath: live == null ? null : IndexedFile(path, liveId),
        // The unreadable file at the path itself is no candidate for anything.
        index: [
          for (final entry in index!)
            if (live != null || entry.path != path) entry
        ],
      );

      ReferenceReport report({bool stale = false, String? foundPath}) => ReferenceReport(
            parentPartId: parentPartId,
            parentPath: parentPath,
            occurrenceId: occurrence['id'] as String? ?? '',
            requestedPath: externalRef,
            storedPartId: storedId,
            outcome: ReferenceReport.outcomeOf(lookup.result),
            foundPath: foundPath,
            candidates: lookup.candidates,
            pathMismatch: lookup.pathMismatch,
            staleCopy: stale,
          );

      if (lookup.result == LookupResult.found) {
        final target = lookup.path!;
        final targetPayload = target == path ? live : await readLive(target);
        if (targetPayload != null) {
          final resolved = await resolvePart(target, ancestorPath, preloaded: targetPayload);
          if (resolved != null) {
            reports.add(report(foundPath: target));
            bind(resolved, target);
            return;
          }
        }
      }

      // Nothing usable by id. A file at the path with another id is never swapped in; a file that could not be read at
      // all still shows its last cached copy, marked stale (`docs/assembly-scope.md` decision #5).
      if (live == null) {
        final cached = await _fileCache.get(root, path);
        if (cached != null) {
          stalePaths.add(path);
          final resolved = await resolvePart(
            path,
            ancestorPath,
            preloaded: jsonDecode(utf8.decode(cached.bytes)) as Map<String, dynamic>,
          );
          if (resolved != null) {
            reports.add(report(stale: true));
            bind(resolved, path);
            return;
          }
        }
      }
      reports.add(report());
    }

    resolvePart = (
      String relativePath,
      List<String> ancestorPath, {
      Map<String, dynamic>? preloaded,
    }) async {
      if (ancestorPath.contains(relativePath)) {
        throw AssemblyGraphCycleException([...ancestorPath, relativePath]);
      }
      final alreadyResolved = partIdByPath[relativePath];
      if (alreadyResolved != null) return alreadyResolved;

      var payload = preloaded;
      if (payload == null) {
        try {
          payload = await readAndDecode(relativePath);
        } on StorageException {
          // The root file can't be read at all (live or cached): the caller reports it. A child never gets here - it is
          // read by [resolveOccurrence] first, which leaves the Occurrence unresolved (per ComposedAssemblyGraph's own doc
          // comment, mirroring the backend's own assembly-mesh behavior).
          return null;
        }
      }

      final readParts = ((payload['document'] as Map<String, dynamic>)['parts'] as List).cast<Map<String, dynamic>>();
      if (readParts.length != 1) {
        throw FormatException(
          '$relativePath is not a valid single-file .didsa save (expected exactly one Part, found ${readParts.length})',
        );
      }
      if (ancestorPath.isEmpty) rootDiskPartId = readParts.single['id'] as String?;

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
      // `partIdByPath` hit above is the ordinary diamond dedup.) The reference
      // that points at such a file keeps the id on disk until then: saving
      // writes it (`AssemblyDocumentClient.savePart`).
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
          for (final key in const ['section_planes'])
            if (payload[key] != null) key: payload[key],
        };
      }

      final documentData = payload['document'] as Map<String, dynamic>;
      final parts = (documentData['parts'] as List).cast<Map<String, dynamic>>();
      var partDict = parts.single;
      // Hide / Show is Part state now (`hidden_feature_ids` on the Part, `docs/touch-viewport-ux-plan.md` section 6.1). A
      // file saved before that has the root Part's set only as the top-level key, which this compose would otherwise drop
      // (only the Part dicts reach the import): move it into the root Part, as the backend's own import does for a whole
      // file.
      if (ancestorPath.isEmpty && payload['hidden_feature_ids'] is List && !partDict.containsKey('hidden_feature_ids')) {
        partDict = {...partDict, 'hidden_feature_ids': payload['hidden_feature_ids']};
      }
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
        await resolveOccurrence(occurrence, externalRef, partId, relativePath, nextAncestorPath);
      }

      resolvedByPath[relativePath] = partDict;
      return partId;
    };

    final rootPartId = await resolvePart(await canonicalPath(rootRelativePath), const []);
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
      rootDiskPartId: rootDiskPartId,
      references: reports,
    );
  }
}

/// The id of the file an Occurrence placed: its `ref_part_id`, else (a file saved before that field existed) the
/// `resolved_part_id` it was saved with, as the backend seeds it. Null for an older reference with neither.
String? _storedPartId(Map<String, dynamic> occurrence) {
  for (final key in const ['ref_part_id', 'resolved_part_id']) {
    final value = occurrence[key];
    if (value is String && value.isNotEmpty) return value;
  }
  return null;
}
