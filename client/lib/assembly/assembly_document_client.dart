import 'dart:convert';

import '../api/document_api_client.dart';
import '../storage/project_root.dart';
import '../storage/storage_service.dart';
import 'assembly_graph_composer.dart';

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
  });

  final String rootPartId;
  final Map<String, String> relativePathByPartId;
  final Set<String> staleRelativePaths;
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
  }) : _storageService = storageService,
       _documentApiClient = documentApiClient ?? DocumentApiClient(),
       _composer = composer ?? AssemblyGraphComposer(storageService: storageService);

  final StorageService _storageService;
  final DocumentApiClient _documentApiClient;
  final AssemblyGraphComposer _composer;

  /// Resolves [rootRelativePath] and everything it references under [root]
  /// (`AssemblyGraphComposer.compose`), then imports the whole composed
  /// graph into the backend session in one call
  /// (`DocumentApiClient.importNative` - a full replace, same as opening a
  /// plain single-file Part today). Throws [AssemblyGraphCycleException]
  /// for a genuine reference cycle, or [StorageException] if the root file
  /// itself can't be read.
  Future<OpenedAssembly> openAssembly(ProjectRoot root, String rootRelativePath) async {
    final composed = await _composer.compose(root, rootRelativePath);
    await _documentApiClient.importNative(composed.documentPayload);
    return OpenedAssembly(
      rootPartId: composed.rootPartId,
      relativePathByPartId: composed.relativePathByPartId,
      staleRelativePaths: composed.staleRelativePaths,
    );
  }

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
  Future<void> savePart(ProjectRoot root, String partId, String relativePath) async {
    final exported = await _documentApiClient.exportNative(partId: partId);
    final bytes = utf8.encode(jsonEncode(exported));
    await _storageService.writeFile(root, relativePath, bytes);
  }
}
