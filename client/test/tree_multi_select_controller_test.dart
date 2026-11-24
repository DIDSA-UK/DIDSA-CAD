import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:didsa_cad_client/api/document_api_client.dart';
import 'package:didsa_cad_client/assembly/assembly_tree_model.dart';
import 'package:didsa_cad_client/viewport3d/assembly_tree_view.dart';
import 'package:didsa_cad_client/viewport3d/tree_multi_select_controller.dart';

void main() {
  group('TreeMultiSelectController', () {
    test('enter selects exactly the given id and activates the session', () {
      final controller = TreeMultiSelectController(TreeMultiSelectScope.buildTree);
      expect(controller.active, isFalse);
      controller.enter('a');
      expect(controller.active, isTrue);
      expect(controller.selectedIds, {'a'});
    });

    test('toggle adds/removes, and emptying the selection ends the session', () {
      final controller = TreeMultiSelectController(TreeMultiSelectScope.assemblyTree)..enter('a');
      controller.toggle('b');
      expect(controller.selectedIds, {'a', 'b'});
      controller.toggle('a');
      expect(controller.selectedIds, {'b'});
      expect(controller.active, isTrue);
      controller.toggle('b');
      expect(controller.selectedIds, isEmpty);
      expect(controller.active, isFalse);
    });

    test('toggle is a no-op outside a session; exit clears everything', () {
      final controller = TreeMultiSelectController(TreeMultiSelectScope.buildTree);
      controller.toggle('a');
      expect(controller.selectedIds, isEmpty);
      controller
        ..enter('a')
        ..toggle('b')
        ..exit();
      expect(controller.active, isFalse);
      expect(controller.selectedIds, isEmpty);
    });

    test('keys round-trip and never collide between row kinds', () {
      expect(TreeMultiSelectKeys.featureIdOf(TreeMultiSelectKeys.feature('x')), 'x');
      expect(TreeMultiSelectKeys.bodyIdOf(TreeMultiSelectKeys.body('x#1')), 'x#1');
      expect(TreeMultiSelectKeys.surfaceIdOf(TreeMultiSelectKeys.surface('x')), 'x');
      expect(TreeMultiSelectKeys.feature('x'), isNot(TreeMultiSelectKeys.body('x')));
      expect(TreeMultiSelectKeys.bodyIdOf(TreeMultiSelectKeys.feature('x')), isNull);
    });
  });

  testWidgets('build tree multi-select mode: row taps toggle instead of selecting, ticked by the key mapping', (tester) async {
    // P3: the one tree draws the build tree; the Part screen's multi-select keeps [TreeMultiSelectKeys] and maps them to row keys.
    final model = AssemblyTreeModel(
      tree: AssemblyTreeResponseDto(partId: 'root', partName: 'Bracket', featureCount: 2, statusIncluded: true),
    )..setLivePart(AssemblyLivePart(
        '',
        features: const [
          AssemblyLiveFeature(id: 's1', label: 'Sketch 1', type: 'sketch'),
          AssemblyLiveFeature(id: 'e1', label: 'Extrude 1', type: 'extrude'),
        ],
      ));
    final toggled = <String>[];
    final tapped = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AssemblyTreeView(
            model: model,
            isMultiSelectMode: true,
            selectedKeys: {...model.rowKeysOfMultiSelect(TreeMultiSelectKeys.feature('s1'))},
            onRowTap: (r) => tapped.add(r.key),
            onMultiSelectToggle: (r) => toggled.add(model.multiSelectKeyOfRow(r.key)!),
          ),
        ),
      ),
    );

    expect(find.byIcon(Icons.check_circle), findsOneWidget);

    await tester.tap(find.text('Extrude 1'));
    await tester.pump();

    expect(toggled, [TreeMultiSelectKeys.feature('e1')]);
    expect(tapped, isEmpty);
  });
}
