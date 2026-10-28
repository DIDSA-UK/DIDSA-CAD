import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:didsa_cad_client/api/document_api_client.dart';
import 'package:didsa_cad_client/viewport3d/action_sheet.dart';
import 'package:didsa_cad_client/viewport3d/assembly_tree_panel.dart';
import 'package:didsa_cad_client/viewport3d/body_naming.dart';
import 'package:didsa_cad_client/viewport3d/feature_tree_panel.dart';

/// Desktop input D4 (`docs/desktop-input-scope.md` section 4): a mouse right
/// click on a tree row asks for that row's menu at the cursor; a touch
/// long-press keeps doing what it did (here: the panel's own long-press
/// callback), and nothing is offered while a multi-select is open.

Future<void> _rightClick(WidgetTester tester, Finder target) async {
  final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse, buttons: kSecondaryMouseButton);
  await gesture.down(tester.getCenter(target));
  await gesture.up();
  await tester.pump();
}

FeatureDto _sketch(String id) => FeatureDto(type: 'sketch', id: id, locked: true, produces: 'sketch');
FeatureDto _extrude(String id) => FeatureDto(type: 'extrude', id: id, locked: false, produces: 'body');

RigidTransformDto _identity() =>
    RigidTransformDto(translation: const [0, 0, 0], rotationAxis: const [0, 0, 1], rotationAngleDegrees: 0);

void main() {
  group('Build Tree', () {
    Widget panel({
      List<(String, Offset)>? features,
      List<(String, Offset)>? bodies,
      List<String>? longPresses,
      bool multiSelect = false,
    }) {
      final all = [_sketch('s1'), _extrude('e1')];
      return MaterialApp(
        home: Scaffold(
          body: FeatureTreePanel(
            visible: true,
            features: all,
            selectedFeatureId: null,
            onFeatureTap: (_) {},
            onFeatureLongPress: (feature) => longPresses?.add(feature.id),
            onClose: () {},
            onBodyTap: (_) {},
            bodyIds: const ['e1'],
            bodyNames: bodyDisplayNames(all, ['e1']),
            isMultiSelectMode: multiSelect,
            onFeatureContextMenu: (feature, at) => features?.add((feature.id, at)),
            onBodyContextMenu: (bodyId, at) => bodies?.add((bodyId, at)),
          ),
        ),
      );
    }

    testWidgets('a right click on a Feature row reports it and the cursor position', (tester) async {
      final features = <(String, Offset)>[];
      await tester.pumpWidget(panel(features: features));
      await _rightClick(tester, find.text('Sketch 1'));
      expect(features, [('s1', tester.getCenter(find.text('Sketch 1')))]);
    });

    testWidgets('a right click on a Body row reports the body', (tester) async {
      final bodies = <(String, Offset)>[];
      await tester.pumpWidget(panel(bodies: bodies));
      await tester.tap(find.text('Bodies'));
      await tester.pumpAndSettle();
      await _rightClick(tester, find.text('Body 1'));
      expect(bodies.map((b) => b.$1), ['e1']);
    });

    testWidgets('a touch long-press still calls onFeatureLongPress and opens no context menu', (tester) async {
      final features = <(String, Offset)>[];
      final longPresses = <String>[];
      await tester.pumpWidget(panel(features: features, longPresses: longPresses));
      await tester.longPress(find.text('Sketch 1'));
      await tester.pump();
      expect(longPresses, ['s1']);
      expect(features, isEmpty);
    });

    testWidgets('nothing is offered while a multi-select is open', (tester) async {
      final features = <(String, Offset)>[];
      await tester.pumpWidget(panel(features: features, multiSelect: true));
      await _rightClick(tester, find.text('Sketch 1'));
      expect(features, isEmpty);
    });
  });

  group('Assembly Tree', () {
    final occurrence = OccurrenceDto(id: 'o1', externalRef: 'parts/bolt.didsa', nameOverride: 'My Bolt', transform: _identity());
    final mate = MateDto(id: 'm1', type: 'coincident', references: const [], suppressed: false);
    final pattern = ComponentPatternDto(
      id: 'p1',
      sourceOccurrenceIds: const ['o1'],
      patternType: 'linear',
      direction: const [1.0, 0.0, 0.0],
      count: 3,
      angleTotal: 360,
      countAngular: 1,
      suppressed: false,
    );

    Widget panel({required List<String> opened, bool multiSelect = false, List<String>? longPresses}) {
      return MaterialApp(
        home: Scaffold(
          body: AssemblyTreePanel(
            visible: true,
            occurrences: [occurrence],
            mates: [mate],
            patterns: [pattern],
            selectedOccurrenceId: null,
            onOccurrenceTap: (_) {},
            onOccurrenceLongPress: (o) => longPresses?.add(o.id),
            onMateTap: (_) {},
            onMateLongPress: (m) => longPresses?.add(m.id),
            onPatternTap: (_) {},
            onPatternLongPress: (p) => longPresses?.add(p.id),
            isMultiSelectMode: multiSelect,
            onClose: () {},
            onOccurrenceContextMenu: (o, at) => opened.add('occurrence ${o.id}'),
            onMateContextMenu: (m, at) => opened.add('mate ${m.id}'),
            onPatternContextMenu: (p, at) => opened.add('pattern ${p.id}'),
          ),
        ),
      );
    }

    testWidgets('a right click on an occurrence, a mate and a pattern row reports each', (tester) async {
      final opened = <String>[];
      await tester.pumpWidget(panel(opened: opened));
      final regions = find.byType(MouseContextMenuRegion);
      expect(regions, findsNWidgets(3));
      for (var i = 0; i < 3; i++) {
        await _rightClick(tester, regions.at(i));
      }
      expect(opened, ['occurrence o1', 'mate m1', 'pattern p1']);
    });

    testWidgets('a touch long-press keeps its own callbacks and opens no context menu', (tester) async {
      final opened = <String>[];
      final longPresses = <String>[];
      await tester.pumpWidget(panel(opened: opened, longPresses: longPresses));
      final regions = find.byType(MouseContextMenuRegion);
      for (var i = 0; i < 3; i++) {
        await tester.longPress(regions.at(i));
        await tester.pump();
      }
      expect(longPresses, ['o1', 'm1', 'p1']);
      expect(opened, isEmpty);
    });

    testWidgets('nothing is offered while a multi-select is open', (tester) async {
      final opened = <String>[];
      await tester.pumpWidget(panel(opened: opened, multiSelect: true));
      for (var i = 0; i < 3; i++) {
        await _rightClick(tester, find.byType(ListTile).at(i));
      }
      expect(opened, isEmpty);
    });
  });
}
