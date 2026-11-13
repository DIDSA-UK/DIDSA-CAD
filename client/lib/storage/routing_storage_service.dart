import 'dart:typed_data';

import 'file_handle.dart';
import 'part_id_index.dart';
import 'project_root.dart';
import 'server/remote_storage_service.dart';
import 'storage_service.dart';

/// The `StorageService` the app hands to every screen: a local folder's service ([local]: desktop, SAF or iOS) and the project
/// store's ([remote]) behind one interface, picked by the root or handle given (`ServerProjectRoot` / `ServerFileHandle` go to
/// [remote], everything else to [local]). Open, Save, Save All and the composer never branch on where a project lives.
///
/// The folder picker and "last used folder" are the local service's: a server project is chosen from File > Server projects.
class RoutingStorageService implements StorageService, PartIdIndex {
  RoutingStorageService({required this.local, required this.remote});

  final StorageService local;
  final RemoteStorageService remote;

  StorageService _for(ProjectRoot root) => root is ServerProjectRoot ? remote : local;

  @override
  Future<ProjectRoot> pickOrCreateProjectRoot({String suggestedName = 'didsa/projects'}) =>
      local.pickOrCreateProjectRoot(suggestedName: suggestedName);

  @override
  Future<ProjectRoot?> lastUsedProjectRoot() => local.lastUsedProjectRoot();

  @override
  Future<FileHandle?> resolve(ProjectRoot root, String relativePath) => _for(root).resolve(root, relativePath);

  @override
  Future<Uint8List> readFile(FileHandle handle) => (handle is ServerFileHandle ? remote : local).readFile(handle);

  @override
  Future<FileHandle> writeFile(ProjectRoot root, String relativePath, Uint8List bytes, {int? baseVersion}) =>
      _for(root).writeFile(root, relativePath, bytes, baseVersion: baseVersion);

  @override
  Future<DateTime?> lastModified(FileHandle handle) => (handle is ServerFileHandle ? remote : local).lastModified(handle);

  @override
  Future<bool> exists(FileHandle handle) => (handle is ServerFileHandle ? remote : local).exists(handle);

  @override
  Future<List<String>> listFiles(ProjectRoot root, {String? extensionFilter}) =>
      _for(root).listFiles(root, extensionFilter: extensionFilter);

  @override
  Future<FileHandle> renameFile(ProjectRoot root, String relativePath, String newFileName) =>
      _for(root).renameFile(root, relativePath, newFileName);

  @override
  bool supportsCommit(ProjectRoot root) => _for(root).supportsCommit(root);

  @override
  Future<CommitOutcome> commit(ProjectRoot root, List<FileChange> changes, {String? message}) =>
      _for(root).commit(root, changes, message: message);

  @override
  bool hasPartIndex(ProjectRoot root) => root is ServerProjectRoot;

  @override
  Future<String?> partIdAt(ProjectRoot root, String path) async => root is ServerProjectRoot ? remote.partIdAt(root, path) : null;

  @override
  Future<List<({String path, String? partId})>?> indexEntries(ProjectRoot root) async =>
      root is ServerProjectRoot ? remote.indexEntries(root) : null;

  @override
  Future<List<String>?> pathsWithPartId(ProjectRoot root, String partId) async =>
      root is ServerProjectRoot ? remote.pathsWithPartId(root, partId) : null;
}
