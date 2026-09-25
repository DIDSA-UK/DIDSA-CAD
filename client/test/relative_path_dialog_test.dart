import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:didsa_cad_client/storage/file_handle.dart';
import 'package:didsa_cad_client/storage/project_root.dart';
import 'package:didsa_cad_client/storage/storage_service.dart';
import 'package:didsa_cad_client/viewport3d/relative_path_dialog.dart';

/// A minimal fake `StorageService` for [showOpenProjectPathPromptDialog]'s
/// own tests - only [listFiles] is ever called by this dialog, so every
/// other method throws `UnimplementedError`, the same "small test fakes are
/// copy-pasted, not shared" convention `assembly_document_client_test.dart`'s
/// own fake already documents.
class _FakeStorageService implements StorageService {
  _FakeStorageService({this.files = const [], this.throwOnList = false});

  final List<String> files;
  final bool throwOnList;

  @override
  Future<List<String>> listFiles(ProjectRoot root, {String? extensionFilter}) async {
    if (throwOnList) {
      throw StorageException('Project root is no longer reachable');
    }
    return files;
  }

  @override
  Future<ProjectRoot> pickOrCreateProjectRoot({String suggestedName = 'didsa/projects'}) =>
      throw UnimplementedError();

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
  Future<FileHandle> renameFile(ProjectRoot root, String relativePath, String newFileName) =>
      throw UnimplementedError();
}

void main() {
  const root = DesktopProjectRoot('/fake/project');

  Future<String?>? pendingResult;

  Future<void> openDialog(WidgetTester tester, StorageService storageService) async {
    pendingResult = null;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () {
                pendingResult = showOpenProjectPathPromptDialog(context, storageService: storageService, root: root);
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  group('showOpenProjectPathPromptDialog', () {
    testWidgets('lists every matching file under the root, sorted, as a tappable row', (tester) async {
      final storage = _FakeStorageService(files: ['bracket.DIDSAprt', 'assembly.DIDSAprt']);
      await openDialog(tester, storage);

      final assemblyFinder = find.text('assembly.DIDSAprt');
      final bracketFinder = find.text('bracket.DIDSAprt');
      expect(assemblyFinder, findsOneWidget);
      expect(bracketFinder, findsOneWidget);
      // Sorted, not insertion order - "assembly.DIDSAprt" (< 'b') renders
      // above "bracket.DIDSAprt".
      expect(
        tester.getTopLeft(assemblyFinder).dy,
        lessThan(tester.getTopLeft(bracketFinder).dy),
      );

      await tester.tap(bracketFinder);
      await tester.pumpAndSettle();

      expect(await pendingResult, 'bracket.DIDSAprt');
    });

    testWidgets('typing a path directly and tapping Open resolves it, extension-defaulted', (tester) async {
      final storage = _FakeStorageService(files: ['bracket.DIDSAprt']);
      await openDialog(tester, storage);

      await tester.enterText(find.byType(TextFormField), 'other-project');
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Open'));
      await tester.pumpAndSettle();

      expect(await pendingResult, 'other-project.DIDSAprt');
    });

    testWidgets('shows a "no files found" message and still accepts typed input when the folder is empty', (
      tester,
    ) async {
      final storage = _FakeStorageService(files: const []);
      await openDialog(tester, storage);

      expect(find.text('No .DIDSAprt files found in this folder.'), findsOneWidget);
      expect(find.byType(ListView), findsNothing);

      await tester.enterText(find.byType(TextFormField), 'top');
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Open'));
      await tester.pumpAndSettle();

      expect(await pendingResult, 'top.DIDSAprt');
    });

    testWidgets('falls back to the text field alone when listFiles fails, with an explanatory note', (
      tester,
    ) async {
      final storage = _FakeStorageService(throwOnList: true);
      await openDialog(tester, storage);

      expect(find.textContaining("Couldn't list files in this folder"), findsOneWidget);
      expect(find.byType(ListView), findsNothing);

      await tester.enterText(find.byType(TextFormField), 'top');
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Open'));
      await tester.pumpAndSettle();

      expect(await pendingResult, 'top.DIDSAprt');
    });

    testWidgets('Cancel resolves null', (tester) async {
      final storage = _FakeStorageService(files: ['bracket.DIDSAprt']);
      await openDialog(tester, storage);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(await pendingResult, isNull);
    });
  });
}
