import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:didsa_cad_client/storage/ensure_project_root.dart';
import 'package:didsa_cad_client/storage/file_handle.dart';
import 'package:didsa_cad_client/storage/project_root.dart';
import 'package:didsa_cad_client/storage/storage_service.dart';

class _FakeStorageService implements StorageService {
  _FakeStorageService({this.lastUsed, this.picked});

  final ProjectRoot? lastUsed;
  final ProjectRoot? picked;
  int lastUsedCallCount = 0;
  int pickOrCreateCallCount = 0;

  @override
  Future<ProjectRoot?> lastUsedProjectRoot() async {
    lastUsedCallCount++;
    return lastUsed;
  }

  @override
  Future<ProjectRoot> pickOrCreateProjectRoot({String suggestedName = 'didsa/projects'}) async {
    pickOrCreateCallCount++;
    final root = picked;
    if (root == null) throw StorageException('cancelled');
    return root;
  }

  @override
  Future<FileHandle?> resolve(ProjectRoot root, String relativePath) => throw UnimplementedError();

  @override
  Future<Uint8List> readFile(FileHandle handle) => throw UnimplementedError();

  @override
  Future<FileHandle> writeFile(ProjectRoot root, String relativePath, Uint8List bytes) => throw UnimplementedError();

  @override
  Future<DateTime?> lastModified(FileHandle handle) => throw UnimplementedError();

  @override
  Future<bool> exists(FileHandle handle) => throw UnimplementedError();

  @override
  Future<List<String>> listFiles(ProjectRoot root, {String? extensionFilter}) => throw UnimplementedError();

  @override
  Future<FileHandle> renameFile(ProjectRoot root, String relativePath, String newFileName) =>
      throw UnimplementedError();
}

/// Multi-part/assembly overhaul, Phase C
/// (`docs/ai-modelling/13-multi-part-assembly-overhaul.md`): the shared
/// "already have one, else last-used, else prompt" resolution
/// `ToolChooserScreen`'s mandatory-folder gate relies on.
void main() {
  test('returns current unchanged, without touching the storage service at all, when already set', () async {
    const current = DesktopProjectRoot('/tmp/already-open');
    final storage = _FakeStorageService();

    final root = await ensureProjectRoot(storage, current: current);

    expect(root, current);
    expect(storage.lastUsedCallCount, 0);
    expect(storage.pickOrCreateCallCount, 0);
  });

  test('falls back to lastUsedProjectRoot when current is null', () async {
    const lastUsed = DesktopProjectRoot('/tmp/last-used');
    final storage = _FakeStorageService(lastUsed: lastUsed);

    final root = await ensureProjectRoot(storage);

    expect(root, lastUsed);
    expect(storage.pickOrCreateCallCount, 0);
  });

  test('falls back to pickOrCreateProjectRoot when neither current nor lastUsed is available', () async {
    const picked = DesktopProjectRoot('/tmp/picked');
    final storage = _FakeStorageService(picked: picked);

    final root = await ensureProjectRoot(storage);

    expect(root, picked);
    expect(storage.lastUsedCallCount, 1);
    expect(storage.pickOrCreateCallCount, 1);
  });

  test('returns null, not a thrown exception, when the picker is cancelled', () async {
    final storage = _FakeStorageService(); // no lastUsed, no picked.

    final root = await ensureProjectRoot(storage);

    expect(root, isNull);
  });
}
