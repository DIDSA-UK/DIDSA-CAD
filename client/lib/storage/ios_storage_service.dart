import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../assembly/relative_path.dart';
import 'file_handle.dart';
import 'ios_bookmark_channel.dart';
import 'project_root.dart';
import 'recent_project_store.dart';
import 'storage_service.dart';

/// `StorageService` for iOS: a project root is a security-scoped bookmark
/// the user granted via `UIDocumentPickerViewController`, not a plain
/// filesystem path - iOS's App Sandbox means the app can't read/write
/// arbitrary paths outside its own container any other way
/// (`docs/assembly-scope.md`'s storage decision). Unlike Android's SAF,
/// which addresses everything by `content://` URI, iOS still ultimately
/// deals in real POSIX filesystem paths once a bookmark is resolved - so
/// every file-touching method here resolves the *root's* bookmark to a
/// path first (`IosBookmarkChannel.resolveBookmark`, bracketed by
/// `start/stopAccessingSecurityScopedResource` native-side, ref-counted so
/// concurrent Dart-side calls don't prematurely close the scope), then
/// joins `relativePath` onto that resolved path for the actual native
/// call - never holding the security-scoped access open across more than
/// one bracketed native call.
///
/// iOS only. See `IosBookmarkChannel` for the platform-channel wrapper
/// this delegates to, and `IosProjectRoot`/`IosFileHandle`
/// (`project_root.dart`/`file_handle.dart`) for the two types this speaks
/// in - only the root folder carries a persisted bookmark, an individual
/// file's resolved path is a live-session convenience only.
class IosStorageService implements StorageService {
  IosStorageService({IosBookmarkChannel? channel, RecentProjectStore? recentProjectStore})
    : _channel = channel ?? IosBookmarkChannel(),
      _recentProjectStore = recentProjectStore ?? RecentProjectStore();

  final IosBookmarkChannel _channel;
  final RecentProjectStore _recentProjectStore;

  @override
  Future<ProjectRoot> pickOrCreateProjectRoot({String suggestedName = 'didsa/projects'}) async {
    // Like SafStorageService's own picker, iOS's document picker always
    // lets the user navigate to or create a folder wherever they like -
    // there is no API to force a suggested name/location, only to show
    // the picker itself.
    final picked = await _channel.pickFolder();
    if (picked == null) {
      throw StorageException('No folder was selected');
    }
    final root = IosProjectRoot(bookmarkBase64: picked.bookmarkBase64, displayName: picked.displayName);
    await _recentProjectStore.save(persistedKey: root.persistedKey, displayName: root.displayName);
    return root;
  }

  @override
  Future<ProjectRoot?> lastUsedProjectRoot() async {
    final last = await _recentProjectStore.last();
    if (last == null) return null;
    // Re-validate the persisted bookmark is actually still good, not just
    // remembered - same "don't trust a cached success" contract
    // SafStorageService.lastUsedProjectRoot documents. A bookmark that
    // fails to resolve at all (folder deleted, access revoked) or that
    // resolves but is reported stale (folder moved/renamed since the
    // bookmark was minted) both fall back to `null`, so the caller
    // re-prompts the picker rather than trusting a grant that's no longer
    // exactly what the user last confirmed.
    final resolved = await _channel.resolveBookmark(last.persistedKey);
    if (resolved == null || resolved.isStale) return null;
    await _channel.stopAccessing(resolved.path);
    return IosProjectRoot(bookmarkBase64: last.persistedKey, displayName: last.displayName);
  }

  @override
  Future<FileHandle?> resolve(ProjectRoot root, String relativePath) async {
    final iosRoot = _requireIosRoot(root);
    return _withRootAccess(iosRoot, (rootPath) async {
      final fullPath = _fullPath(rootPath, relativePath);
      if (!await _channel.exists(fullPath)) return null;
      return IosFileHandle(root: iosRoot, relativePath: relativePath, resolvedPath: fullPath);
    });
  }

  @override
  Future<Uint8List> readFile(FileHandle handle) async {
    final iosHandle = _requireIosHandle(handle);
    return _withRootAccess(iosHandle.root, (rootPath) async {
      final fullPath = _fullPath(rootPath, iosHandle.relativePath);
      try {
        return await _channel.readFile(fullPath);
      } catch (e) {
        throw StorageException('Failed to read ${iosHandle.relativePath}', cause: e);
      }
    });
  }

  @override
  Future<FileHandle> writeFile(ProjectRoot root, String relativePath, Uint8List bytes) async {
    final iosRoot = _requireIosRoot(root);
    return _withRootAccess(iosRoot, (rootPath) async {
      final fullPath = _fullPath(rootPath, relativePath);
      try {
        await _channel.writeFile(fullPath, bytes);
      } catch (e) {
        throw StorageException('Failed to write $relativePath', cause: e);
      }
      return IosFileHandle(root: iosRoot, relativePath: relativePath, resolvedPath: fullPath);
    });
  }

  @override
  Future<DateTime?> lastModified(FileHandle handle) async {
    final iosHandle = _requireIosHandle(handle);
    return _withRootAccess(iosHandle.root, (rootPath) async {
      final fullPath = _fullPath(rootPath, iosHandle.relativePath);
      final ms = await _channel.lastModifiedMs(fullPath);
      if (ms == null) return null;
      return DateTime.fromMillisecondsSinceEpoch(ms);
    });
  }

  @override
  Future<bool> exists(FileHandle handle) async {
    final iosHandle = _requireIosHandle(handle);
    try {
      return await _withRootAccess(iosHandle.root, (rootPath) async {
        final fullPath = _fullPath(rootPath, iosHandle.relativePath);
        return _channel.exists(fullPath);
      });
    } on StorageException {
      // An unreachable root (revoked bookmark) reads as "doesn't exist"
      // here too - see StorageService.exists's own doc comment: never
      // throws, an unreachable file reads the same as a genuinely deleted
      // one.
      return false;
    }
  }

  @override
  Future<List<String>> listFiles(ProjectRoot root, {String? extensionFilter}) async {
    final iosRoot = _requireIosRoot(root);
    // _withRootAccess itself throws StorageException if the root's
    // bookmark can't be resolved at all - that's the only case this method
    // throws for. A failure partway through the native recursive walk
    // (one unreadable subtree) is handled native-side by skipping that
    // subtree and continuing (see IosStoragePlugin.swift's `listFiles
    // Recursive`), matching StorageService.listFiles's own "best-effort
    // per subtree" contract - nothing here needs to re-implement that.
    return _withRootAccess(iosRoot, (rootPath) async {
      try {
        return await _channel.listFilesRecursive(rootPath, extensionFilter: extensionFilter);
      } catch (e) {
        throw StorageException('Failed to list files under ${iosRoot.displayName}', cause: e);
      }
    });
  }

  /// Resolves `root`'s bookmark to a filesystem path, runs `action`
  /// against it, then always releases the security-scoped access grant -
  /// the single bracket every file-touching method above goes through, so
  /// the scope is never held open longer than one action.
  Future<T> _withRootAccess<T>(IosProjectRoot root, Future<T> Function(String rootPath) action) async {
    final resolved = await _channel.resolveBookmark(root.bookmarkBase64);
    if (resolved == null) {
      throw StorageException('Failed to resolve iOS bookmark for ${root.displayName}');
    }
    try {
      return await action(resolved.path);
    } finally {
      await _channel.stopAccessing(resolved.path);
    }
  }

  @override
  Future<FileHandle> renameFile(ProjectRoot root, String relativePath, String newFileName) async {
    final iosRoot = _requireIosRoot(root);
    final newRelativePath = siblingRelativePath(relativePath, newFileName);
    return _withRootAccess(iosRoot, (rootPath) async {
      final fullPath = _fullPath(rootPath, relativePath);
      final newFullPath = _fullPath(rootPath, newRelativePath);
      if (await _channel.exists(newFullPath)) {
        throw StorageException('A file already exists at $newRelativePath');
      }
      try {
        await _channel.renameFile(fullPath, newFileName);
      } catch (e) {
        throw StorageException('Failed to rename $relativePath to $newFileName', cause: e);
      }
      return IosFileHandle(root: iosRoot, relativePath: newRelativePath, resolvedPath: newFullPath);
    });
  }

  String _fullPath(String rootPath, String relativePath) => p.posix.join(rootPath, relativePath);

  IosProjectRoot _requireIosRoot(ProjectRoot root) {
    if (root is! IosProjectRoot) {
      throw StorageException('IosStorageService given a non-iOS ProjectRoot: $root');
    }
    return root;
  }

  IosFileHandle _requireIosHandle(FileHandle handle) {
    if (handle is! IosFileHandle) {
      throw StorageException('IosStorageService given a non-iOS FileHandle: $handle');
    }
    return handle;
  }
}
