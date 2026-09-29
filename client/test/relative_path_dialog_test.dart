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
  _FakeStorageService({
    this.files = const [],
    this.throwOnList = false,
    this.pickResult,
    this.filesByRootPath = const {},
    this.existingPaths = const {},
  });

  final List<String> files;
  final bool throwOnList;

  /// What [pickOrCreateProjectRoot] returns; `null` makes it throw
  /// `StorageException`, matching the real services' cancel convention.
  final ProjectRoot? pickResult;
  int pickCalls = 0;

  /// Per-root file listings, overriding [files] for a `DesktopProjectRoot`
  /// whose path is a key here.
  final Map<String, List<String>> filesByRootPath;

  /// Relative paths for which [resolve] reports an existing file.
  final Set<String> existingPaths;
  final List<ProjectRoot> resolvedRoots = [];

  @override
  Future<List<String>> listFiles(ProjectRoot root, {String? extensionFilter}) async {
    if (throwOnList) {
      throw StorageException('Project root is no longer reachable');
    }
    if (root is DesktopProjectRoot && filesByRootPath.containsKey(root.path)) {
      return filesByRootPath[root.path]!;
    }
    return files;
  }

  @override
  Future<ProjectRoot> pickOrCreateProjectRoot({String suggestedName = 'didsa/projects'}) async {
    pickCalls++;
    final result = pickResult;
    if (result == null) throw StorageException('No folder was selected');
    return result;
  }

  @override
  Future<ProjectRoot?> lastUsedProjectRoot() => throw UnimplementedError();

  @override
  Future<FileHandle?> resolve(ProjectRoot root, String relativePath) async {
    resolvedRoots.add(root);
    if (!existingPaths.contains(relativePath)) return null;
    return DesktopFileHandle(
      root: root as DesktopProjectRoot,
      relativePath: relativePath,
      path: '${root.path}/$relativePath',
    );
  }

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

  Future<void> openDialog(
    WidgetTester tester,
    StorageService storageService, {
    ValueChanged<ProjectRoot>? onRootChanged,
  }) async {
    pendingResult = null;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () {
                pendingResult = showOpenProjectPathPromptDialog(
                  context,
                  storageService: storageService,
                  root: root,
                  onRootChanged: onRootChanged,
                );
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

    group('folder navigation', () {
      final nested = ['top.DIDSAprt', 'gears/spur.DIDSAprt', 'gears/helical/a.DIDSAprt'];

      testWidgets('shows folders first, then files, at the root; nested files are hidden', (tester) async {
        await openDialog(tester, _FakeStorageService(files: nested));

        expect(find.text('gears'), findsOneWidget);
        expect(find.text('top.DIDSAprt'), findsOneWidget);
        expect(find.text('spur.DIDSAprt'), findsNothing);
        expect(tester.getTopLeft(find.text('gears')).dy, lessThan(tester.getTopLeft(find.text('top.DIDSAprt')).dy));
        // No breadcrumb controls at the root.
        expect(find.text('Up'), findsNothing);
      });

      testWidgets('tapping a folder enters it; a file inside resolves to its full relative path', (tester) async {
        await openDialog(tester, _FakeStorageService(files: nested));

        await tester.tap(find.text('gears'));
        await tester.pumpAndSettle();

        expect(find.text('spur.DIDSAprt'), findsOneWidget);
        expect(find.text('helical'), findsOneWidget);
        expect(find.text('top.DIDSAprt'), findsNothing);

        await tester.tap(find.text('spur.DIDSAprt'));
        await tester.pumpAndSettle();
        expect(await pendingResult, 'gears/spur.DIDSAprt');
      });

      testWidgets('Up goes to the parent folder and Root returns to the top', (tester) async {
        await openDialog(tester, _FakeStorageService(files: nested));

        await tester.tap(find.text('gears'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('helical'));
        await tester.pumpAndSettle();
        expect(find.text('a.DIDSAprt'), findsOneWidget);

        await tester.tap(find.text('Up'));
        await tester.pumpAndSettle();
        expect(find.text('spur.DIDSAprt'), findsOneWidget);
        expect(find.text('a.DIDSAprt'), findsNothing);

        await tester.tap(find.text('helical'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Root'));
        await tester.pumpAndSettle();
        expect(find.text('top.DIDSAprt'), findsOneWidget);
        expect(find.text('gears'), findsOneWidget);
      });
    });

    group('Change Folder', () {
      testWidgets('is hidden unless the caller supplies onRootChanged', (tester) async {
        await openDialog(tester, _FakeStorageService(files: ['a.DIDSAprt']));
        expect(find.text('Change Folder'), findsNothing);
      });

      testWidgets('cancelling the picker (StorageException) is a silent no-op that keeps the dialog open', (
        tester,
      ) async {
        final storage = _FakeStorageService(files: ['a.DIDSAprt']); // pickResult null => throws
        var changed = false;
        await openDialog(tester, storage, onRootChanged: (_) => changed = true);

        await tester.tap(find.text('Change Folder'));
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        expect(storage.pickCalls, 1);
        expect(changed, isFalse);
        expect(find.text('a.DIDSAprt'), findsOneWidget);
      });

      testWidgets('picking a new folder re-lists its files, reports the new root, and keeps the dialog open', (
        tester,
      ) async {
        const newRoot = DesktopProjectRoot('/other/folder');
        final storage = _FakeStorageService(
          files: ['old.DIDSAprt'],
          pickResult: newRoot,
          filesByRootPath: {
            '/other/folder': ['new.DIDSAprt'],
          },
        );
        ProjectRoot? reported;
        await openDialog(tester, storage, onRootChanged: (r) => reported = r);
        expect(find.text('old.DIDSAprt'), findsOneWidget);

        await tester.tap(find.text('Change Folder'));
        await tester.pumpAndSettle();

        expect(reported, newRoot);
        expect(find.text('old.DIDSAprt'), findsNothing);
        expect(find.text('new.DIDSAprt'), findsOneWidget);

        await tester.tap(find.text('new.DIDSAprt'));
        await tester.pumpAndSettle();
        expect(await pendingResult, 'new.DIDSAprt');
      });
    });
  });

  group('showRelativePathPromptDialog', () {
    Future<void> openSaveDialog(
      WidgetTester tester,
      StorageService storageService, {
      ValueChanged<ProjectRoot>? onRootChanged,
    }) async {
      pendingResult = null;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () {
                  pendingResult = showRelativePathPromptDialog(
                    context,
                    title: 'Save as',
                    initialValue: 'part',
                    storageService: storageService,
                    root: root,
                    onRootChanged: onRootChanged,
                  );
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

    testWidgets('has no Change Folder button unless the caller supplies onRootChanged', (tester) async {
      await openSaveDialog(tester, _FakeStorageService());
      expect(find.text('Change Folder'), findsNothing);
      expect(find.widgetWithText(FilledButton, 'Save'), findsOneWidget);
    });

    testWidgets('Change Folder cancel is a no-op; the dialog stays open and still saves', (tester) async {
      final storage = _FakeStorageService();
      var changed = false;
      await openSaveDialog(tester, storage, onRootChanged: (_) => changed = true);

      await tester.tap(find.text('Change Folder'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(changed, isFalse);

      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();
      expect(await pendingResult, 'part.DIDSAprt');
    });

    testWidgets('Change Folder reports the new root and re-checks collisions against it', (tester) async {
      const newRoot = DesktopProjectRoot('/other/folder');
      final storage = _FakeStorageService(pickResult: newRoot, existingPaths: {'part.DIDSAprt'});
      ProjectRoot? reported;
      await openSaveDialog(tester, storage, onRootChanged: (r) => reported = r);

      await tester.tap(find.text('Change Folder'));
      await tester.pumpAndSettle();

      expect(reported, newRoot);
      expect(storage.resolvedRoots, contains(newRoot));
      expect(find.textContaining('already exists'), findsOneWidget);
      // Dialog is still open (Change Folder does not dismiss it).
      expect(find.widgetWithText(FilledButton, 'Save'), findsOneWidget);
    });
  });
}
