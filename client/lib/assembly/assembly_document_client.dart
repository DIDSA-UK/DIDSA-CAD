import 'dart:convert';
import 'dart:typed_data';

import '../api/document_api_client.dart';
import '../storage/project_root.dart';
import '../storage/server/sync_conflicts.dart';
import '../storage/storage_service.dart';
import 'assembly_graph_composer.dart';
import 'local_file_stamps.dart';
import 'project_file_index.dart';
import 'reference_report.dart';
import 'remint_identity.dart';
import 'save_all.dart';

export 'save_all.dart' show ChangedOnDiskChoice, PartSaveFailure, SaveAllResult;

/// The result of opening a `.didsa` assembly file - everything a caller
/// (Phase 3's screen) needs to keep working with the session the backend
/// now holds: which Part is the root, where every resolved Part's own
/// content actually lives on disk (for save-back), and which of them were
/// only reachable via a cached, possibly-out-of-date snapshot.
class OpenedAssembly {
  OpenedAssembly({
    required this.rootPartId,
    required this.relativePathByPartId,
    required this.staleRelativePaths,
    this.rootClientExtras = const {},
    this.references = const [],
  });

  /// References that were not simply where their path said (found by id in a new place, or left unresolved with candidates).
  /// A reference found by id already holds its new path in the session: the assembly is changed until it is saved.
  final List<ReferenceReport> references;

  final String rootPartId;

  /// The root file's client-only top-level keys (`section_planes`), for the caller to restore - the backend ignores them.
  /// (Hide / Show is Part state now, not a client extra.)
  final Map<String, dynamic> rootClientExtras;
  final Map<String, String> relativePathByPartId;
  final Set<String> staleRelativePaths;
}

/// Removes every Occurrence's `resolved_part_id` from a single-Part export.
/// That id names a Part in the *session* (often one re-minted on import), so
/// written to a single-Part file it points at nothing - the backend discards
/// it on import and [AssemblyGraphComposer] recomputes it from `external_ref`.
/// Kept only where there is no `external_ref` to recompute it from.
Map<String, dynamic> stripSessionResolvedIds(Map<String, dynamic> exported) {
  final document = exported['document'];
  if (document is! Map) return exported;
  final parts = document['parts'];
  if (parts is! List) return exported;
  return {
    ...exported,
    'document': {
      ...document,
      'parts': [
        for (final part in parts)
          if (part is Map && part['occurrences'] is List)
            {
              ...part,
              'occurrences': [
                for (final occurrence in part['occurrences'] as List)
                  if (occurrence is Map && occurrence['external_ref'] != null)
                    {
                      for (final entry in occurrence.entries)
                        if (entry.key != 'resolved_part_id') entry.key: entry.value,
                    }
                  else
                    occurrence,
              ],
            }
          else
            part,
      ],
    },
  };
}

/// Assembly support Phase 2 (`docs/assembly-scope.md`): ties
/// [AssemblyGraphComposer], [StorageService], and [DocumentApiClient]
/// together into the three operations a caller actually needs - open a
/// `.didsa` file (composing and importing its whole referenced graph),
/// fetch its assembly-mesh, and save one Part's own content back to its
/// file. Deliberately thin - no dirty-tracking or UI state here, that's
/// Phase 3's screen to own; this class only knows how to move a composed
/// graph between disk and the backend.
class AssemblyDocumentClient {
  AssemblyDocumentClient({
    required StorageService storageService,
    DocumentApiClient? documentApiClient,
    AssemblyGraphComposer? composer,
  })  : _storageService = storageService,
        _documentApiClient = documentApiClient ?? DocumentApiClient(),
        _composer = composer ?? AssemblyGraphComposer(storageService: storageService);

  final StorageService _storageService;
  final DocumentApiClient _documentApiClient;
  final AssemblyGraphComposer _composer;

  /// The project-folder index the composer looks moved files up in (the Review sheet's folder-change offer reads it too).
  ProjectFileIndex get fileIndex => _composer.fileIndex;

  /// Resolves [rootRelativePath] and everything it references under [root]
  /// (`AssemblyGraphComposer.compose`), then imports the whole composed
  /// graph into the backend session in one call
  /// (`DocumentApiClient.importNative` - a full replace, same as opening a
  /// plain single-file Part today). Throws [AssemblyGraphCycleException]
  /// for a genuine reference cycle, or [StorageException] if the root file
  /// itself can't be read.
  Future<OpenedAssembly> openAssembly(ProjectRoot root, String rootRelativePath, {bool acceptLikely = false}) async =>
      importComposed(await _composer.compose(root, rootRelativePath, acceptLikely: acceptLikely));

  /// Imports an already composed graph ([composeGraph]): the second half of [openAssembly], for a caller that looks at the
  /// compose's `references` (and asks the user about the likely ones) before importing.
  Future<OpenedAssembly> importComposed(ComposedAssemblyGraph composed) async {
    await _documentApiClient.importNative(composed.documentPayload);
    return OpenedAssembly(
      rootPartId: composed.rootPartId,
      relativePathByPartId: composed.relativePathByPartId,
      staleRelativePaths: composed.staleRelativePaths,
      rootClientExtras: composed.rootClientExtras,
      references: composed.references,
    );
  }

  /// Composes [relativePath] and everything it references under [root] into
  /// one payload *without* importing it - what "Add Component" folds into the
  /// open session so the inserted file's own sub-components arrive resolved.
  Future<ComposedAssemblyGraph> composeGraph(
    ProjectRoot root,
    String relativePath, {
    bool acceptLikely = false,
    void Function()? onSearching,
  }) =>
      _composer.compose(root, relativePath, acceptLikely: acceptLikely, onSearching: onSearching);

  /// `GET /parts/{partId}/assembly-mesh` - everything visible in
  /// `partId`'s own assembly scene. Requires [openAssembly] (or an
  /// equivalent import) to have already composed the graph into this
  /// session - see `DocumentApiClient.getAssemblyMesh`'s own doc comment.
  Future<AssemblyMeshDto> fetchAssemblyMesh(String partId, {double? meshQuality}) =>
      _documentApiClient.getAssemblyMesh(partId, meshQuality: meshQuality);

  /// Saves one Part's own current content (its own features *and* its own
  /// occurrences/mates - both coexist, `docs/assembly-scope.md` decision
  /// #2) back to [relativePath] under [root] -
  /// `DocumentApiClient.exportNative(partId: partId)` followed by
  /// `StorageService.writeFile`. Never touches any other Part's file, even
  /// ones this Part references or is referenced by.
  ///
  /// [extras] are merged into the top-level payload before encoding (see
  /// below); callers pass them only for the session's root Part.
  ///
  /// [remintIdentity] (Save As to a *new* file, bug report 2026-10-14 item
  /// 3): writes the copy with a fresh document id, Part id and sketch ids
  /// (`remintNativeIdentity`) so it never shares identity with the file it
  /// was copied from - two files with the same ids silently overwrite each
  /// other as soon as they meet in one assembly. The live session's own
  /// Part keeps its ids; the caller decides whether to reopen the copy.
  Future<void> savePart(
    ProjectRoot root,
    String partId,
    String relativePath, {
    bool remintIdentity = false,
    Map<String, dynamic>? extras,
  }) async {
    final bytes = await _partBytes(root, partId, remintIdentity: remintIdentity, extras: extras);
    await _storageService.writeFile(root, relativePath, bytes);
    _composer.fileIndex.forget(root, relativePath);
    await _stampLocalFile(root, relativePath);
  }

  /// One Part's file contents, as [savePart] writes them (the export with on-disk reference ids stamped, session ids stripped,
  /// optionally with a fresh identity, and the client-only [extras] merged in).
  Future<Uint8List> _partBytes(
    ProjectRoot root,
    String partId, {
    bool remintIdentity = false,
    Map<String, dynamic>? extras,
  }) async {
    var exported = stripSessionResolvedIds(
      await _stampOnDiskRefIds(root, await _documentApiClient.exportNative(partId: partId)),
    );
    if (remintIdentity) exported = remintNativeIdentity(exported);
    // Client-only state the backend's export knows nothing about
    // (`section_planes` - see
    // `PartScreen._rootClientExtras`), merged at the top level so the
    // backend's `import_native` ignores it and `_openComposedProject` reads
    // it back. Without this a project-mode save silently dropped it.
    if (extras != null && extras.isNotEmpty) exported = {...exported, ...extras};
    return Uint8List.fromList(utf8.encode(jsonEncode(exported)));
  }

  /// After this session wrote a local file: its modified time now is the one Save All compares against next time.
  Future<void> _stampLocalFile(ProjectRoot root, String relativePath) async {
    if (root is ServerProjectRoot) return;
    try {
      final handle = await _storageService.resolve(root, relativePath);
      if (handle != null) stamps.record(root, relativePath, await _storageService.lastModified(handle));
    } catch (_) {
      // Best effort, and never a reason to fail a save that was written: not being able to stat the file only means the next
      // Save All has nothing to compare for it.
    }
  }

  /// The modified times this session saw when it read or wrote local files (Save All's "changed on disk meanwhile?" check).
  LocalFileStamps get stamps => _composer.stamps;

  /// Of [relativePaths] under the LOCAL folder [root], those whose modified time is later than when this session read or wrote
  /// them: someone (a sync client, another program, another device) changed the file meanwhile. A file this session never read
  /// or wrote, one that is gone, or a time the platform does not give is not reported. Always empty for a server project.
  Future<List<String>> changedOnDisk(ProjectRoot root, Iterable<String> relativePaths) async {
    if (root is ServerProjectRoot) return const [];
    final changed = <String>[];
    for (final path in relativePaths) {
      final recorded = stamps.of(root, path);
      if (recorded == null) continue;
      try {
        final handle = await _storageService.resolve(root, path);
        if (handle == null) continue;
        final now = await _storageService.lastModified(handle);
        if (now != null && now.isAfter(recorded)) changed.add(path);
      } catch (_) {
        // A file that cannot be stat-ed is not reported as changed (the write that follows reports its own failure).
        continue;
      }
    }
    return changed;
  }

  /// Finding moved files: a resolved reference is saved with the id its file has **on disk**, not the id in the session. They
  /// differ when the compose re-minted a clashing file's ids and that file has not been saved yet, and writing the session id
  /// would make the next open report a mismatch at a path that is right. An unresolved reference keeps its stored id as it is
  /// (it is the id the file is looked for by); a file that isn't on disk yet is left to be saved with the session id.
  Future<Map<String, dynamic>> _stampOnDiskRefIds(ProjectRoot root, Map<String, dynamic> exported) async {
    final document = exported['document'];
    if (document is! Map || document['parts'] is! List) return exported;
    final onDisk = <String, String?>{};
    var changed = false;
    final parts = <Object?>[];
    for (final part in document['parts'] as List) {
      if (part is! Map || part['occurrences'] is! List) {
        parts.add(part);
        continue;
      }
      final occurrences = <Object?>[];
      for (final occurrence in part['occurrences'] as List) {
        final path = occurrence is Map ? occurrence['external_ref'] : null;
        final stored = occurrence is Map ? occurrence['ref_part_id'] : null;
        if (path is String && stored is String && occurrence['resolved_part_id'] is String) {
          final id = onDisk[path] ??= await _composer.fileIndex.partIdAt(root, path);
          if (id != null && id != stored) {
            changed = true;
            occurrences.add({...(occurrence as Map<String, dynamic>), 'ref_part_id': id});
            continue;
          }
        }
        occurrences.add(occurrence);
      }
      parts.add({...(part as Map<String, dynamic>), 'occurrences': occurrences});
    }
    if (!changed) return exported;
    return {
      ...exported,
      'document': {...(document as Map<String, dynamic>), 'parts': parts},
    };
  }

  /// Saves every Part named in [relativePathByPartId] back to its own file
  /// under [root] - "Save All" (`docs/assembly-scope.md` §6 Phase 15).
  /// [fullSessionExport] is a `DocumentApiClient.exportNative()` snapshot
  /// (no `partId`) of the whole current session, used only to stamp every
  /// Occurrence's `external_ref` (`stampExternalRefs`) before re-importing
  /// it and writing each Part's own file - without this step, an
  /// Add-Component/Create-Component-merged Occurrence's `external_ref`
  /// would still be a stale bare filename or `null`, and the saved files
  /// would silently fail to resolve as a real assembly on a later
  /// [openAssembly]. Re-importing preserves every Part's own id
  /// (`native_format.py`'s `_part_from_dict` never regenerates a given
  /// one), so a caller's own id-keyed screen state stays valid across it.
  ///
  /// Never lets one Part's own [StorageException] (a revoked SAF grant,
  /// disk full) abort the rest - every other Part still gets its own write
  /// attempt, and every failure is collected onto the returned
  /// [SaveAllResult] rather than thrown.
  Future<SaveAllResult> saveAll(
    ProjectRoot root,
    Map<String, dynamic> fullSessionExport,
    Map<String, String> relativePathByPartId, {
    Map<String, Map<String, dynamic>> extrasByPartId = const {},
    Future<ChangedOnDiskChoice> Function(List<String> changed)? onChangedOnDisk,
    String? commitMessage,
  }) async {
    final stamped = stampExternalRefs(
      documentPayload: fullSessionExport,
      relativePathByPartId: relativePathByPartId,
    );
    await _documentApiClient.importNative(stamped);

    // A file placed by another is written first, so the id a reference to it holds on disk is already the new one (a re-minted
    // file is saved with its session ids).
    final order = _placedFirst(relativePathByPartId.keys, stamped);

    // A server project: one all-or-nothing commit (`docs/shared-storage-scope.md` section 6). A clash throws
    // `SyncConflictException` (nothing written, every clash listed) for the caller to settle; the store's queue holds the changes.
    if (_storageService.supportsCommit(root)) {
      final failures = <PartSaveFailure>[];
      final changes = <FileChange>[];
      final partIdByPath = <String, String>{};
      for (final partId in order) {
        final path = relativePathByPartId[partId]!;
        try {
          changes.add(FileChange(path: path, bytes: await _partBytes(root, partId, extras: extrasByPartId[partId])));
          partIdByPath[path] = partId;
        } on StorageException catch (e) {
          failures.add(PartSaveFailure(partId: partId, relativePath: path, message: e.message));
        }
      }
      if (changes.isEmpty) return SaveAllResult(savedRelativePaths: const [], failures: failures);
      try {
        final outcome = await _storageService.commit(root, changes, message: commitMessage);
        for (final change in changes) {
          _composer.fileIndex.forget(root, change.path);
        }
        return SaveAllResult(savedRelativePaths: outcome.sent, queuedRelativePaths: outcome.queued, failures: failures);
      } on StorageException catch (e) {
        if (e is SyncConflictException) rethrow;
        // The commit is all or nothing: none of the files were written.
        return SaveAllResult(
          savedRelativePaths: const [],
          failures: [
            ...failures,
            for (final change in changes) PartSaveFailure(partId: partIdByPath[change.path]!, relativePath: change.path, message: e.message),
          ],
        );
      }
    }

    // A local folder: file by file. First S0-8: a file that changed on disk since this session read it is not overwritten
    // without asking.
    final skipped = <String>[];
    if (onChangedOnDisk != null) {
      final changed = await changedOnDisk(root, order.map((id) => relativePathByPartId[id]!));
      if (changed.isNotEmpty) {
        switch (await onChangedOnDisk(changed)) {
          case ChangedOnDiskChoice.cancel:
            return SaveAllResult(savedRelativePaths: const [], failures: const [], cancelled: true);
          case ChangedOnDiskChoice.skipChanged:
            skipped.addAll(changed);
          case ChangedOnDiskChoice.overwrite:
            break;
        }
      }
    }

    final saved = <String>[];
    final failures = <PartSaveFailure>[];
    for (final partId in order) {
      final entry = MapEntry(partId, relativePathByPartId[partId]!);
      if (skipped.contains(entry.value)) continue;
      try {
        await savePart(root, entry.key, entry.value, extras: extrasByPartId[entry.key]);
        saved.add(entry.value);
      } on StorageException catch (e) {
        failures.add(PartSaveFailure(partId: entry.key, relativePath: entry.value, message: e.message));
      }
    }
    return SaveAllResult(savedRelativePaths: saved, failures: failures, skippedRelativePaths: skipped);
  }
}

/// [partIds] ordered so that a Part comes after every Part its Occurrences place (children first), by `resolved_part_id` in
/// [documentPayload]. Parts that don't place each other keep their given order.
List<String> _placedFirst(Iterable<String> partIds, Map<String, dynamic> documentPayload) {
  final wanted = partIds.toSet();
  final placed = <String, List<String>>{};
  final parts = (documentPayload['document'] is Map ? (documentPayload['document'] as Map)['parts'] : null);
  for (final part in parts is List ? parts : const []) {
    if (part is! Map || part['id'] is! String) continue;
    placed[part['id'] as String] = [
      for (final occurrence in (part['occurrences'] as List? ?? const []))
        if (occurrence is Map && occurrence['resolved_part_id'] is String) occurrence['resolved_part_id'] as String,
    ];
  }
  final ordered = <String>[];
  final visited = <String>{};
  void visit(String id) {
    if (!visited.add(id)) return;
    for (final child in placed[id] ?? const <String>[]) {
      visit(child);
    }
    if (wanted.contains(id)) ordered.add(id);
  }

  partIds.forEach(visit);
  return ordered;
}
