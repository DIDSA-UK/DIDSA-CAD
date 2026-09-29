import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:didsa_cad_client/sketch/sketcher_settings_screen.dart';
import 'package:didsa_cad_client/storage/file_handle.dart';
import 'package:didsa_cad_client/storage/project_root.dart';
import 'package:didsa_cad_client/storage/recent_project_store.dart';
import 'package:didsa_cad_client/storage/storage_service.dart';

/// Fake whose picker either "picks" [pickResult] (persisting it the way the
/// real services do) or throws `StorageException` to model a cancel.
class _FakePickerStorage implements StorageService {
  _FakePickerStorage({this.pickResult});

  final ProjectRoot? pickResult;
  int pickCalls = 0;

  @override
  Future<ProjectRoot> pickOrCreateProjectRoot({String suggestedName = 'didsa/projects'}) async {
    pickCalls++;
    final result = pickResult;
    if (result == null) throw StorageException('No folder was selected');
    await RecentProjectStore().save(persistedKey: result.persistedKey, displayName: result.displayName);
    return result;
  }

  @override
  Future<ProjectRoot?> lastUsedProjectRoot() => throw UnimplementedError();
  @override
  Future<FileHandle?> resolve(ProjectRoot root, String relativePath) => throw UnimplementedError();
  @override
  Future<Uint8List> readFile(FileHandle handle) => throw UnimplementedError();
  @override
  Future<FileHandle> writeFile(ProjectRoot root, String relativePath, Uint8List bytes) =>
      throw UnimplementedError();
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

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<void> pumpScreen(WidgetTester tester, StorageService storage) async {
    await tester.pumpWidget(MaterialApp(home: SketcherSettingsScreen(storageService: storage)));
    await tester.pumpAndSettle();
  }

  testWidgets('shows "Not set" when no project folder has been chosen yet', (tester) async {
    await pumpScreen(tester, _FakePickerStorage());

    expect(find.text('Project Folder'), findsOneWidget);
    expect(find.text('Not set'), findsOneWidget);
  });

  testWidgets('shows the persisted project folder name', (tester) async {
    SharedPreferences.setMockInitialValues({
      'didsa.storage.last_project_root.key': '/home/me/cad',
      'didsa.storage.last_project_root.display_name': 'cad',
    });
    await pumpScreen(tester, _FakePickerStorage());

    expect(find.text('cad'), findsOneWidget);
    expect(find.text('Not set'), findsNothing);
  });

  testWidgets('cancelling the folder picker leaves the display unchanged and does not throw', (tester) async {
    final storage = _FakePickerStorage(); // null pick => StorageException
    await pumpScreen(tester, storage);

    await tester.tap(find.text('Current Folder'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(storage.pickCalls, 1);
    expect(find.text('Not set'), findsOneWidget);
  });

  testWidgets('picking a folder updates the displayed name', (tester) async {
    final storage = _FakePickerStorage(pickResult: const DesktopProjectRoot('/home/me/newproj'));
    await pumpScreen(tester, storage);

    await tester.tap(find.text('Current Folder'));
    await tester.pumpAndSettle();

    expect(storage.pickCalls, 1);
    expect(find.text('newproj'), findsOneWidget);
    expect(find.text('Not set'), findsNothing);
  });
}
