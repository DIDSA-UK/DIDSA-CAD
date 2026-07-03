import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:didsa_cad_client/api/document_api_client.dart';
import 'package:didsa_cad_client/viewport3d/feature_tree_panel.dart';

FeatureDto _sketch(String id, {bool locked = true}) =>
    FeatureDto(type: 'sketch', id: id, locked: locked, produces: 'sketch');

FeatureDto _extrude(String id, {bool locked = true}) =>
    FeatureDto(type: 'extrude', id: id, locked: locked, produces: 'body');

Widget _wrap(FeatureTreePanel panel) => MaterialApp(home: Scaffold(body: panel));

void main() {
  testWidgets('Boss/Cut Features render under a "Bodies" section header', (tester) async {
    await tester.pumpWidget(
      _wrap(
        FeatureTreePanel(
          visible: true,
          features: [_sketch('s1'), _extrude('e1', locked: false)],
          selectedFeatureId: null,
          onFeatureTap: (_) {},
          onFeatureLongPress: (_) {},
          onClose: () {},
        ),
      ),
    );

    expect(find.text('Bodies'), findsOneWidget);
    expect(find.text('Extrude 1'), findsOneWidget);
    expect(find.text('Sketch 1'), findsOneWidget);
  });

  testWidgets('empty Planes/Surfaces groups render as nothing, not an empty section', (tester) async {
    await tester.pumpWidget(
      _wrap(
        FeatureTreePanel(
          visible: true,
          features: [_sketch('s1'), _extrude('e1', locked: false)],
          selectedFeatureId: null,
          onFeatureTap: (_) {},
          onFeatureLongPress: (_) {},
          onClose: () {},
        ),
      ),
    );

    expect(find.text('Planes'), findsNothing);
    expect(find.text('Surfaces'), findsNothing);
  });

  testWidgets('a Part with only Sketches shows no group headers at all', (tester) async {
    await tester.pumpWidget(
      _wrap(
        FeatureTreePanel(
          visible: true,
          features: [_sketch('s1'), _sketch('s2', locked: false)],
          selectedFeatureId: null,
          onFeatureTap: (_) {},
          onFeatureLongPress: (_) {},
          onClose: () {},
        ),
      ),
    );

    expect(find.text('Bodies'), findsNothing);
    expect(find.text('Planes'), findsNothing);
    expect(find.text('Surfaces'), findsNothing);
    expect(find.text('Sketch 1'), findsOneWidget);
    expect(find.text('Sketch 2'), findsOneWidget);
  });

  testWidgets('tapping a grouped Body row still calls onFeatureTap', (tester) async {
    FeatureDto? tapped;
    final extrude = _extrude('e1', locked: false);
    await tester.pumpWidget(
      _wrap(
        FeatureTreePanel(
          visible: true,
          features: [_sketch('s1'), extrude],
          selectedFeatureId: null,
          onFeatureTap: (f) => tapped = f,
          onFeatureLongPress: (_) {},
          onClose: () {},
        ),
      ),
    );

    await tester.tap(find.text('Extrude 1'));
    await tester.pump();

    expect(tapped, extrude);
  });

  testWidgets(
    'multiple Extrude Features (each possibly producing several Bodies server-side) still '
    'render as exactly one row each under Bodies, not duplicated',
    (tester) async {
      await tester.pumpWidget(
        _wrap(
          FeatureTreePanel(
            visible: true,
            features: [_sketch('s1'), _extrude('e1'), _extrude('e2', locked: false)],
            selectedFeatureId: null,
            onFeatureTap: (_) {},
            onFeatureLongPress: (_) {},
            onClose: () {},
          ),
        ),
      );

      expect(find.text('Extrude 1'), findsOneWidget);
      expect(find.text('Extrude 2'), findsOneWidget);
    },
  );
}
