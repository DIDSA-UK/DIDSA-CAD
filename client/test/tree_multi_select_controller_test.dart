import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:didsa_cad_client/api/document_api_client.dart';
import 'package:didsa_cad_client/viewport3d/feature_tree_panel.dart';
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

  testWidgets('FeatureTreePanel multi-select mode: row taps toggle instead of opening the Feature', (tester) async {
    final toggled = <String>[];
    final tapped = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FeatureTreePanel(
            visible: true,
            features: [
              FeatureDto(type: 'sketch', id: 's1', locked: true, produces: 'sketch'),
              FeatureDto(type: 'extrude', id: 'e1', locked: false, produces: 'body'),
            ],
            selectedFeatureId: null,
            onFeatureTap: (f) => tapped.add(f.id),
            onFeatureLongPress: (_) {},
            onClose: () {},
            onBodyTap: (_) {},
            isMultiSelectMode: true,
            selectedMultiSelectIds: {TreeMultiSelectKeys.feature('s1')},
            onMultiSelectToggle: toggled.add,
          ),
        ),
      ),
    );

    expect(find.text('Tap rows to select - 1 selected'), findsOneWidget);
    expect(find.byIcon(Icons.check_circle), findsOneWidget);

    await tester.tap(find.text('Extrude 1'));
    await tester.pump();

    expect(toggled, [TreeMultiSelectKeys.feature('e1')]);
    expect(tapped, isEmpty);
  });
}
