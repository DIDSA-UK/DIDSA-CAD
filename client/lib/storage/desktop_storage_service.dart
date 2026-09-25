import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;

import '../assembly/relative_path.dart';
import 'file_handle.dart';
import 'project_root.dart';
import 'recent_project_store.dart';
import 'storage_service.dart';

/// `StorageService` for desktop (Windows/Linux/macOS): a project root is
/// just a plain OS directory, so this is a thin wrapper over `dart:io`'s
/// `File`/`Directory` - no scoped-storage constraints apply here, unlike
/// `SafStorageService`. Relocated from what used to be inlined directly in
/// `part_screen.dart`'s save/load methods (`_saveNativeFile`/
/// `_openNativeFile` et al.) - see that file's own history for the
/// `_canPersistFilePathForReuse` desktop-only gate this class now
/// generalizes.
class DesktopStorageService implements StorageService {
  DesktopStorageService({RecentProjectStore? recentProjectStore})
    : _recentProjectStore = recentProjectStore ?? RecentProjectStore();

  final RecentProjectStore _recentProjectStore;

  @override
  Future<ProjectRoot> pickOrCreateProjectRoot({String suggestedName = 'didsa/projects'}) async {
    final picked = await FilePicker.platform.getDirectoryPath(dialogTitle: 'Choose or create a DIDSA project folder');
    if (picked == null) {
      throw StorageException('No folder was selected');
    }
    final root = DesktopProjectRoot(picked);
    await _recentProjectStore.save(persistedKey: root.persistedKey, displayName: root.displayName);
    return root;
  }

  @override
  Future<ProjectRoot?> lastUsedProjectRoot() async {
    final last = await _recentProjectStore.last();
    if (last == null) return null;
    final root = DesktopProjectRoot(last.persistedKey);
    if (!await Directory(root.path).exists()) return null;
    return root;
  }

  @override
  Future<FileHandle?> resolve(ProjectRoot root, String relativePath) async {
    final desktopRoot = _requireDesktopRoot(root);
    final fullPath = _fullPath(desktopRoot, relativePath);
    if (!await File(fullPath).exists()) return null;
    return DesktopFileHandle(root: desktopRoot, relativePath: relativePath, path: fullPath);
  }

  @override
  Future<Uint8List> readFile(FileHandle handle) async {
    final desktopHandle = _requireDesktopHandle(handle);
    try {
      return await File(desktopHandle.path).readAsBytes();
    } on IOException catch (e) {
      throw StorageException('Failed to read ${desktopHandle.relativePath}', cause: e);
    }
  }

  @override
  Future<FileHandle> writeFile(ProjectRoot root, String relativePath, Uint8List bytes) async {
    final desktopRoot = _requireDesktopRoot(root);
    final fullPath = _fullPath(desktopRoot, relativePath);
    try {
      await Directory(p.dirname(fullPath)).create(recursive: true);
      await File(fullPath).writeAsBytes(bytes, flush: true);
    } on IOException catch (e) {
      throw StorageException('Failed to write $relativePath', cause: e);
    }
    return DesktopFileHandle(root: desktopRoot, relativePath: relativePath, path: fullPath);
  }

  @override
  Future<DateTime?> lastModified(FileHandle handle) async {
    final desktopHandle = _requireDesktopHandle(handle);
    try {
      return await File(desktopHandle.path).lastModified();
    } on IOException {
      return null;
    }
  }

  @override
  Future<bool> exists(FileHandle handle) async {
    final desktopHandle = _requireDesktopHandle(handle);
    return File(desktopHandle.path).exists();
  }

  @override
  Future<List<String>> listFiles(ProjectRoot root, {String? extensionFilter}) async {
    final desktopRoot = _requireDesktopRoot(root);
    final rootDir = Directory(desktopRoot.path);
    if (!await rootDir.exists()) {
      throw StorageException('Project root does not exist: ${desktopRoot.path}');
    }
    final result = <String>[];
    try {
      await for (final entity in rootDir.list(recursive: true, followLinks: false)) {
        if (entity is! File) continue;
        final relative = p.relative(entity.path, from: desktopRoot.path).replaceAll(p.separator, '/');
        if (extensionFilter != null && !relative.toLowerCase().endsWith(extensionFilter.toLowerCase())) continue;
        result.add(relative);
      }
    } on IOException {
      // Root was confirmed reachable above; a mid-walk error is a subtree
      // permission hiccup - return whatever was already collected.
    }
    return result;
  }

  @override
  Future<FileHandle> renameFile(ProjectRoot root, String relativePath, String newFileName) async {
    final desktopRoot = _requireDesktopRoot(root);
    final oldFullPath = _fullPath(desktopRoot, relativePath);
    final newRelativePath = siblingRelativePath(relativePath, newFileName);
    final newFullPath = _fullPath(desktopRoot, newRelativePath);
    if (await File(newFullPath).exists()) {
      throw StorageException('A file already exists at $newRelativePath');
    }
    try {
      await File(oldFullPath).rename(newFullPath);
    } on IOException catch (e) {
      throw StorageException('Failed to rename $relativePath to $newFileName', cause: e);
    }
    return DesktopFileHandle(root: desktopRoot, relativePath: newRelativePath, path: newFullPath);
  }

  String _fullPath(DesktopProjectRoot root, String relativePath) => p.join(root.path, relativePath);

  DesktopProjectRoot _requireDesktopRoot(ProjectRoot root) {
    if (root is! DesktopProjectRoot) {
      throw StorageException('DesktopStorageService given a non-desktop ProjectRoot: $root');
    }
    return root;
  }

  DesktopFileHandle _requireDesktopHandle(FileHandle handle) {
    if (handle is! DesktopFileHandle) {
      throw StorageException('DesktopStorageService given a non-desktop FileHandle: $handle');
    }
    return handle;
  }
}
