import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:didsa_cad_client/ai/ai_modelling_screen.dart';
import 'package:didsa_cad_client/sketch/sketch_screen.dart';
import 'package:didsa_cad_client/storage/file_handle.dart';
import 'package:didsa_cad_client/storage/project_root.dart';
import 'package:didsa_cad_client/storage/storage_service.dart';
import 'package:didsa_cad_client/tool_chooser_screen.dart';
import 'package:didsa_cad_client/viewport3d/part_screen.dart';

/// Multi-part/assembly overhaul, Phase C (`docs/ai-modelling/13-multi-
/// part-assembly-overhaul.md`): a minimal fake exercising only the two
/// methods `ToolChooserScreen`'s "AI Modelling" tile actually calls
/// (`lastUsedProjectRoot`/`pickOrCreateProjectRoot`) - every other method
/// throws if reached, the same "fail loud on an unexpected call" posture
/// `ai_plan_translator_test.dart`'s own `_FakeStorageService` already uses.
class _FakeStorageService implements StorageService {
  _FakeStorageService({this.lastUsed, this.picked});

  final ProjectRoot? lastUsed;
  final ProjectRoot? picked;
  int pickOrCreateCallCount = 0;

  @override
  Future<ProjectRoot?> lastUsedProjectRoot() async => lastUsed;

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

void main() {
  testWidgets('ToolChooserScreen offers both destinations and navigates to PartScreen on tap',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: ToolChooserScreen()));

    expect(find.text('3D Part Design'), findsOneWidget);
    expect(find.text('2D Drawing'), findsOneWidget);

    await tester.tap(find.text('3D Part Design'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300)); // lets the push transition finish
    expect(find.byType(PartScreen), findsOneWidget);
  });

  testWidgets('ToolChooserScreen navigates to a standalone SketchScreen on "2D Drawing" tap',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: ToolChooserScreen()));

    await tester.tap(find.text('2D Drawing'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300)); // lets the push transition finish
    expect(find.byType(SketchScreen), findsOneWidget);
    final sketchScreen = tester.widget<SketchScreen>(find.byType(SketchScreen));
    expect(sketchScreen.standalone, isTrue);
  });

  testWidgets('shows a back button once it can pop (e.g. reached, as in the real app, from '
      'ConnectionScreen via push)', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () =>
                  Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ToolChooserScreen())),
              child: const Text('start'),
            ),
          ),
        ),
      ),
    ));

    // No back affordance yet - this screen is still the Navigator's root.
    expect(find.byType(BackButton), findsNothing);

    await tester.tap(find.text('start'));
    await tester.pumpAndSettle();

    expect(find.byType(ToolChooserScreen), findsOneWidget);
    expect(find.byType(BackButton), findsOneWidget);
  });

  testWidgets(
      'nav cleanup regression: a tile push()es its destination (not pushReplacement()), so the '
      'automatic back button on the pushed screen returns to ToolChooserScreen rather than '
      'skipping past it to whatever was underneath', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () =>
                  Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ToolChooserScreen())),
              child: const Text('start'),
            ),
          ),
        ),
      ),
    ));

    await tester.tap(find.text('start'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('2D Drawing'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(SketchScreen), findsOneWidget);

    // SketchScreen's own AppBar `leading` is a plain logo button (see
    // DidsaLogoButton), not a back arrow - popping directly through the
    // Navigator mirrors how a device's system back gesture would behave,
    // same convention ai_modelling_screen_test.dart already uses for a
    // screen with a custom `leading`.
    Navigator.of(tester.element(find.byType(SketchScreen))).pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // Lands back on ToolChooserScreen, not the 'start' screen underneath it -
    // if the tile had instead used pushReplacement, ToolChooserScreen would
    // already be gone from the stack and this pop would have skipped
    // straight past it.
    expect(find.byType(ToolChooserScreen), findsOneWidget);
    expect(find.text('What would you like to open?'), findsOneWidget);
  });

  // Multi-part/assembly overhaul, Phase C (`docs/ai-modelling/13-multi-
  // part-assembly-overhaul.md`): a project folder is now required up front
  // at the "AI Modelling" entry point too, not just "Continue with AI".
  group('AI Modelling tile project-folder gate', () {
    testWidgets('reuses a known last-used project root without prompting, then navigates', (tester) async {
      const root = DesktopProjectRoot('/tmp/existing-project');
      final storage = _FakeStorageService(lastUsed: root);
      await tester.pumpWidget(MaterialApp(home: ToolChooserScreen(storageServiceFactory: () => storage)));

      await tester.ensureVisible(find.text('AI Modelling'));
      await tester.tap(find.text('AI Modelling'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byType(AiModellingScreen), findsOneWidget);
      expect(storage.pickOrCreateCallCount, 0);
      final screen = tester.widget<AiModellingScreen>(find.byType(AiModellingScreen));
      expect(screen.projectRoot, root);
      expect(screen.storageService, storage);
    });

    testWidgets('falls back to the folder picker when no last-used root is known, then navigates', (tester) async {
      const root = DesktopProjectRoot('/tmp/picked-project');
      final storage = _FakeStorageService(picked: root);
      await tester.pumpWidget(MaterialApp(home: ToolChooserScreen(storageServiceFactory: () => storage)));

      await tester.ensureVisible(find.text('AI Modelling'));
      await tester.tap(find.text('AI Modelling'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byType(AiModellingScreen), findsOneWidget);
      expect(storage.pickOrCreateCallCount, 1);
      final screen = tester.widget<AiModellingScreen>(find.byType(AiModellingScreen));
      expect(screen.projectRoot, root);
    });

    testWidgets('never navigates when the folder picker is cancelled', (tester) async {
      final storage = _FakeStorageService(); // no lastUsed, no picked -> pickOrCreateProjectRoot throws
      await tester.pumpWidget(MaterialApp(home: ToolChooserScreen(storageServiceFactory: () => storage)));

      await tester.ensureVisible(find.text('AI Modelling'));
      await tester.tap(find.text('AI Modelling'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byType(AiModellingScreen), findsNothing);
      expect(find.byType(ToolChooserScreen), findsOneWidget);
    });
  });
}
