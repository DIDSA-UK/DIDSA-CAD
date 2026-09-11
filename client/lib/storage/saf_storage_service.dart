import 'dart:typed_data';

import 'package:saf_stream/saf_stream.dart';
import 'package:saf_util/saf_util.dart';

import 'file_handle.dart';
import 'project_root.dart';
import 'recent_project_store.dart';
import 'storage_service.dart';

/// `StorageService` for Android's Storage Access Framework: a project
/// root is a `content://` tree URI the user granted via
/// `SafUtil.pickDirectory(persistablePermission: true)`, not a plain
/// filesystem path - scoped storage (Android 10+) means the app cannot
/// read/write arbitrary shared-storage paths any other way
/// (`docs/assembly-scope.md`'s storage decision). `SafUtil` handles
/// directory/tree navigation (pick, list, mkdirp, child lookup); `SafStream`
/// handles actual file-byte I/O against a resolved URI - two packages from
/// the same maintainer, designed to be used together this way.
///
/// Android only. iOS has no SAF and needs its own security-scoped-bookmark
/// mechanism - not built yet, tracked as a known gap in
/// `docs/assembly-scope.md` rather than guessed at here.
class SafStorageService implements StorageService {
  SafStorageService({SafUtil? safUtil, SafStream? safStream, RecentProjectStore? recentProjectStore})
    : _safUtil = safUtil ?? SafUtil(),
      _safStream = safStream ?? SafStream(),
      _recentProjectStore = recentProjectStore ?? RecentProjectStore();

  static const _defaultMimeType = 'application/octet-stream';

  final SafUtil _safUtil;
  final SafStream _safStream;
  final RecentProjectStore _recentProjectStore;

  @override
  Future<ProjectRoot> pickOrCreateProjectRoot({String suggestedName = 'didsa/projects'}) async {
    // SAF's own folder picker always lets the user navigate to/create a
    // folder wherever they like (including a network-mounted location
    // exposed by another documents-provider app) - there is no API to
    // force a suggested name/location, only to show the picker itself
    // (`docs/assembly-scope.md`'s storage decision: "suggested folder
    // name/label shown in the picker", not a path the app assumes exists).
    final picked = await _safUtil.pickDirectory(writePermission: true, persistablePermission: true);
    if (picked == null) {
      throw StorageException('No folder was selected');
    }
    final root = SafProjectRoot(treeUri: picked.uri, displayName: picked.name);
    await _recentProjectStore.save(persistedKey: root.persistedKey, displayName: root.displayName);
    return root;
  }

  @override
  Future<ProjectRoot?> lastUsedProjectRoot() async {
    final last = await _recentProjectStore.last();
    if (last == null) return null;
    // Re-validate the persisted grant is actually still held, not just
    // remembered - a revoked SAF permission (the user cleared it in
    // Android's own settings, or uninstalled/reinstalled) must fall back
    // to re-prompting the picker, not silently fail every later file op.
    final stat = await _safUtil.stat(last.persistedKey, true, throws: false);
    if (stat == null) return null;
    return SafProjectRoot(treeUri: last.persistedKey, displayName: last.displayName);
  }

  @override
  Future<FileHandle?> resolve(ProjectRoot root, String relativePath) async {
    final safRoot = _requireSafRoot(root);
    final doc = await _safUtil.child(safRoot.treeUri, _splitRelativePath(relativePath));
    if (doc == null || doc.isDir) return null;
    return SafFileHandle(root: safRoot, relativePath: relativePath, uri: doc.uri);
  }

  @override
  Future<Uint8List> readFile(FileHandle handle) async {
    final safHandle = _requireSafHandle(handle);
    try {
      return await _safStream.readFileBytes(safHandle.uri);
    } catch (e) {
      throw StorageException('Failed to read ${safHandle.relativePath}', cause: e);
    }
  }

  @override
  Future<FileHandle> writeFile(ProjectRoot root, String relativePath, Uint8List bytes) async {
    final safRoot = _requireSafRoot(root);
    final segments = _splitRelativePath(relativePath);
    if (segments.isEmpty) {
      throw StorageException('writeFile relativePath must include a file name: $relativePath');
    }
    final fileName = segments.removeLast();
    try {
      final parentUri = segments.isEmpty ? safRoot.treeUri : (await _safUtil.mkdirp(safRoot.treeUri, segments)).uri;

      // Prefer overwriting the existing file's own URI (writeFileUriBytes)
      // over the create-or-rename-on-conflict path (writeFileBytes) when
      // one already exists, so a re-save keeps the same underlying SAF
      // document identity rather than risking a provider minting a
      // "file (1).didsa"-style renamed copy.
      final existing = await _safUtil.child(parentUri, [fileName]);
      final written = existing != null && !existing.isDir
          ? await _safStream.writeFileUriBytes(existing.uri, bytes)
          : await _safStream.writeFileBytes(parentUri, fileName, _defaultMimeType, bytes, overwrite: true);

      return SafFileHandle(root: safRoot, relativePath: relativePath, uri: written.uri.toString());
    } catch (e) {
      throw StorageException('Failed to write $relativePath', cause: e);
    }
  }

  @override
  Future<DateTime?> lastModified(FileHandle handle) async {
    final safHandle = _requireSafHandle(handle);
    final stat = await _safUtil.stat(safHandle.uri, false, throws: false);
    if (stat == null || stat.lastModified <= 0) return null;
    return DateTime.fromMillisecondsSinceEpoch(stat.lastModified);
  }

  @override
  Future<bool> exists(FileHandle handle) async {
    final safHandle = _requireSafHandle(handle);
    return _safUtil.exists(safHandle.uri, false);
  }

  List<String> _splitRelativePath(String relativePath) =>
      relativePath.split('/').where((segment) => segment.isNotEmpty).toList();

  SafProjectRoot _requireSafRoot(ProjectRoot root) {
    if (root is! SafProjectRoot) {
      throw StorageException('SafStorageService given a non-SAF ProjectRoot: $root');
    }
    return root;
  }

  SafFileHandle _requireSafHandle(FileHandle handle) {
    if (handle is! SafFileHandle) {
      throw StorageException('SafStorageService given a non-SAF FileHandle: $handle');
    }
    return handle;
  }
}
