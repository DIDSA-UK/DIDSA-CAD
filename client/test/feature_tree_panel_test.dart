import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:didsa_cad_client/api/document_api_client.dart';
import 'package:didsa_cad_client/viewport3d/body_naming.dart';
import 'package:didsa_cad_client/viewport3d/feature_tree_panel.dart';

FeatureDto _sketch(String id, {bool locked = true}) =>
    FeatureDto(type: 'sketch', id: id, locked: locked, produces: 'sketch');

FeatureDto _extrude(String id, {bool locked = true}) =>
    FeatureDto(type: 'extrude', id: id, locked: locked, produces: 'body');

Widget _wrap(FeatureTreePanel panel) => MaterialApp(home: Scaffold(body: panel));

void main() {
  testWidgets('"Build Tree" is the panel title, not "Features"', (tester) async {
    await tester.pumpWidget(
      _wrap(
        FeatureTreePanel(
          visible: true,
          features: [_sketch('s1')],
          selectedFeatureId: null,
          onFeatureTap: (_) {},
          onFeatureLongPress: (_) {},
          onClose: () {},
          onBodyTap: (_) {},
        ),
      ),
    );

    expect(find.text('Build Tree'), findsOneWidget);
    expect(find.text('Features'), findsOneWidget);
  });

  testWidgets('Bodies section is hidden entirely when there are no computed Bodies', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        FeatureTreePanel(
          visible: true,
          features: [_sketch('s1'), _extrude('e1', locked: false)],
          selectedFeatureId: null,
          onFeatureTap: (_) {},
          onFeatureLongPress: (_) {},
          onClose: () {},
          onBodyTap: (_) {},
        ),
      ),
    );

    expect(find.text('Bodies'), findsNothing);
  });

  testWidgets(
    'a single-Body Extrude renders one Body row under "Bodies", named via bodyDisplayNames',
    (tester) async {
      final features = [_sketch('s1'), _extrude('e1', locked: false)];
      final names = bodyDisplayNames(features, ['e1']);
      await tester.pumpWidget(
        _wrap(
          FeatureTreePanel(
            visible: true,
            features: features,
            selectedFeatureId: null,
            onFeatureTap: (_) {},
            onFeatureLongPress: (_) {},
            onClose: () {},
            onBodyTap: (_) {},
            bodyIds: const ['e1'],
            bodyNames: names,
          ),
        ),
      );

      expect(find.text('Bodies'), findsOneWidget);
      expect(find.text('Body 1'), findsOneWidget);
      // The Extrude Feature itself still appears too, under Features.
      expect(find.text('Extrude 1'), findsOneWidget);
    },
  );

  testWidgets(
    'a single Extrude that split into two Bodies (A1 multi-solid amendment) renders two '
    'distinct Body rows, not one duplicated/fabricated node',
    (tester) async {
      final features = [_sketch('s1'), _extrude('e1', locked: false)];
      final bodyIds = ['e1#0', 'e1#1'];
      final names = bodyDisplayNames(features, bodyIds);
      await tester.pumpWidget(
        _wrap(
          FeatureTreePanel(
            visible: true,
            features: features,
            selectedFeatureId: null,
            onFeatureTap: (_) {},
            onFeatureLongPress: (_) {},
            onClose: () {},
            onBodyTap: (_) {},
            bodyIds: bodyIds,
            bodyNames: names,
          ),
        ),
      );

      expect(find.text('Body 1'), findsOneWidget);
      expect(find.text('Body 2'), findsOneWidget);
      // Still exactly one Feature row for the one Extrude that produced them.
      expect(find.text('Extrude 1'), findsOneWidget);
    },
  );

  testWidgets('tapping a Body row calls onBodyTap with that body_id', (tester) async {
    String? tapped;
    final features = [_extrude('e1', locked: false)];
    final names = bodyDisplayNames(features, ['e1']);
    await tester.pumpWidget(
      _wrap(
        FeatureTreePanel(
          visible: true,
          features: features,
          selectedFeatureId: null,
          onFeatureTap: (_) {},
          onFeatureLongPress: (_) {},
          onClose: () {},
          onBodyTap: (id) => tapped = id,
          bodyIds: const ['e1'],
          bodyNames: names,
        ),
      ),
    );

    await tester.tap(find.text('Body 1'));
    await tester.pump();

    expect(tapped, 'e1');
  });

  testWidgets('tapping a Feature row still calls onFeatureTap, not onBodyTap', (tester) async {
    FeatureDto? tapped;
    var bodyTapped = false;
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
          onBodyTap: (_) => bodyTapped = true,
        ),
      ),
    );

    await tester.tap(find.text('Extrude 1'));
    await tester.pump();

    expect(tapped, extrude);
    expect(bodyTapped, isFalse);
  });

  testWidgets('a Sketch-only Part with no Bodies shows Features but no Bodies section', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        FeatureTreePanel(
          visible: true,
          features: [_sketch('s1'), _sketch('s2', locked: false)],
          selectedFeatureId: null,
          onFeatureTap: (_) {},
          onFeatureLongPress: (_) {},
          onClose: () {},
          onBodyTap: (_) {},
        ),
      ),
    );

    expect(find.text('Bodies'), findsNothing);
    expect(find.text('Features'), findsOneWidget);
    expect(find.text('Sketch 1'), findsOneWidget);
    expect(find.text('Sketch 2'), findsOneWidget);
  });
}
