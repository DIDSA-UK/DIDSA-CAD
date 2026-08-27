import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:didsa_cad_client/api/document_api_client.dart';
import 'package:didsa_cad_client/viewport3d/body_naming.dart';
import 'package:didsa_cad_client/viewport3d/feature_tree_panel.dart';
import 'package:didsa_cad_client/viewport3d/svg_icon.dart';

FeatureDto _sketch(String id, {bool locked = true}) =>
    FeatureDto(type: 'sketch', id: id, locked: locked, produces: 'sketch');

FeatureDto _extrude(String id, {bool locked = true}) =>
    FeatureDto(type: 'extrude', id: id, locked: locked, produces: 'body');

FeatureDto _gearFamily(String type, String id, {bool locked = true}) =>
    FeatureDto(type: type, id: id, locked: locked, produces: 'body');

FeatureDto _surface(String id, {bool locked = true}) =>
    FeatureDto(type: 'surface', id: id, locked: locked, produces: 'surface');

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
      // Bodies starts collapsed - expand it before its rows are findable.
      await tester.tap(find.text('Bodies'));
      await tester.pumpAndSettle();

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

      await tester.tap(find.text('Bodies'));
      await tester.pumpAndSettle();

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

    await tester.tap(find.text('Bodies'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Body 1'));
    await tester.pump();

    expect(tapped, 'e1');
  });

  testWidgets('Bodies and Planes start collapsed; Features starts expanded', (tester) async {
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

    // Bodies section header is present, but its row is not - collapsed.
    expect(find.text('Bodies'), findsOneWidget);
    expect(find.text('Body 1'), findsNothing);
    // Features starts expanded - both its rows are already visible.
    expect(find.text('Sketch 1'), findsOneWidget);
    expect(find.text('Extrude 1'), findsOneWidget);
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

  group('On-device feedback: hidden Bodies stay listed, long-press toggles them', () {
    testWidgets('a hidden Body still shows its row, dimmed with a visibility-off icon', (
      tester,
    ) async {
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
            onBodyTap: (_) {},
            bodyIds: const ['e1'],
            bodyNames: names,
            hiddenBodyIds: const {'e1'},
          ),
        ),
      );

      await tester.tap(find.text('Bodies'));
      await tester.pumpAndSettle();

      expect(find.text('Body 1'), findsOneWidget);
      expect(find.byIcon(Icons.visibility_off), findsOneWidget);
    });

    testWidgets('a visible Body shows no visibility-off icon', (tester) async {
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
            onBodyTap: (_) {},
            bodyIds: const ['e1'],
            bodyNames: names,
          ),
        ),
      );

      await tester.tap(find.text('Bodies'));
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.visibility_off), findsNothing);
    });

    testWidgets('long-pressing a Body row calls onBodyLongPress with that body_id', (
      tester,
    ) async {
      String? longPressed;
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
            onBodyTap: (_) {},
            onBodyLongPress: (id) => longPressed = id,
            bodyIds: const ['e1'],
            bodyNames: names,
          ),
        ),
      );

      await tester.tap(find.text('Bodies'));
      await tester.pumpAndSettle();
      await tester.longPress(find.text('Body 1'));
      await tester.pump();

      expect(longPressed, 'e1');
    });

    testWidgets('long-pressing a Body row is a no-op when onBodyLongPress is not supplied', (
      tester,
    ) async {
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
            onBodyTap: (_) {},
            bodyIds: const ['e1'],
            bodyNames: names,
          ),
        ),
      );

      await tester.tap(find.text('Bodies'));
      await tester.pumpAndSettle();

      // Must not throw.
      await tester.longPress(find.text('Body 1'));
      await tester.pump();
    });
  });

  group('Pattern/Mirror scoping Phase 6: isFeaturePickerMode', () {
    testWidgets('shows the picker banner with no count when nothing is selected yet', (
      tester,
    ) async {
      final features = [_extrude('e1', locked: false), _extrude('e2', locked: false)];
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
            isFeaturePickerMode: true,
            pickableFeaturePickerIds: const {'e1', 'e2'},
          ),
        ),
      );

      expect(find.text('Select source Features'), findsOneWidget);
    });

    testWidgets('the banner shows the current selection count', (tester) async {
      final features = [_extrude('e1', locked: false), _extrude('e2', locked: false)];
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
            isFeaturePickerMode: true,
            pickableFeaturePickerIds: const {'e1', 'e2'},
            selectedFeaturePickerIds: const {'e1'},
          ),
        ),
      );

      expect(find.text('Select source Features - 1 selected'), findsOneWidget);
    });

    testWidgets('tapping a pickable row calls onFeaturePickerToggle, not onFeatureTap', (
      tester,
    ) async {
      final features = [_extrude('e1', locked: false)];
      var toggled = false;
      var tapped = false;
      await tester.pumpWidget(
        _wrap(
          FeatureTreePanel(
            visible: true,
            features: features,
            selectedFeatureId: null,
            onFeatureTap: (_) => tapped = true,
            onFeatureLongPress: (_) {},
            onClose: () {},
            onBodyTap: (_) {},
            isFeaturePickerMode: true,
            pickableFeaturePickerIds: const {'e1'},
            onFeaturePickerToggle: (_) => toggled = true,
          ),
        ),
      );

      await tester.tap(find.text('Extrude 1'));
      await tester.pump();

      expect(toggled, isTrue);
      expect(tapped, isFalse);
    });

    testWidgets('tapping a non-pickable row is inert - no callback fires', (tester) async {
      final features = [_sketch('s1')];
      var toggled = false;
      var tapped = false;
      await tester.pumpWidget(
        _wrap(
          FeatureTreePanel(
            visible: true,
            features: features,
            selectedFeatureId: null,
            onFeatureTap: (_) => tapped = true,
            onFeatureLongPress: (_) {},
            onClose: () {},
            onBodyTap: (_) {},
            isFeaturePickerMode: true,
            pickableFeaturePickerIds: const {},
            onFeaturePickerToggle: (_) => toggled = true,
          ),
        ),
      );

      await tester.tap(find.text('Sketch 1'));
      await tester.pump();

      expect(toggled, isFalse);
      expect(tapped, isFalse);
    });

    testWidgets('a selected row shows a check-circle trailing icon', (tester) async {
      final features = [_extrude('e1', locked: false)];
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
            isFeaturePickerMode: true,
            pickableFeaturePickerIds: const {'e1'},
            selectedFeaturePickerIds: const {'e1'},
          ),
        ),
      );

      expect(find.byIcon(Icons.check_circle), findsOneWidget);
    });

    testWidgets('long-pressing a row is disabled while picking (no cascade-delete dialog trigger)', (
      tester,
    ) async {
      final features = [_extrude('e1', locked: false)];
      var longPressed = false;
      await tester.pumpWidget(
        _wrap(
          FeatureTreePanel(
            visible: true,
            features: features,
            selectedFeatureId: null,
            onFeatureTap: (_) {},
            onFeatureLongPress: (_) => longPressed = true,
            onClose: () {},
            onBodyTap: (_) {},
            isFeaturePickerMode: true,
            pickableFeaturePickerIds: const {'e1'},
          ),
        ),
      );

      await tester.longPress(find.text('Extrude 1'));
      await tester.pump();

      expect(longPressed, isFalse);
    });
  });

  group('Gear-tree UX: gear-family Feature types get a "Gear" category, not generic "Sketch"', () {
    test('featureDisplayName labels every gear-family type with its own design-screen vocabulary', () {
      final features = [
        _gearFamily('gear', 'f1'),
        _gearFamily('rack', 'f2'),
        _gearFamily('gear_chain', 'f3'),
        _gearFamily('planetary_gear', 'f4'),
        _gearFamily('bevel_gear', 'f5'),
        _gearFamily('bevel_pair', 'f6'),
      ];
      expect(featureDisplayName(features, 0), 'Gear 1');
      expect(featureDisplayName(features, 1), 'Rack 1');
      expect(featureDisplayName(features, 2), 'Gear Chain 1');
      expect(featureDisplayName(features, 3), 'Planetary Gear 1');
      expect(featureDisplayName(features, 4), 'Bevel Gear 1');
      expect(featureDisplayName(features, 5), 'Bevel Pair 1');
    });

    for (final type in ['gear', 'rack', 'gear_chain', 'planetary_gear', 'bevel_gear', 'bevel_pair']) {
      testWidgets('a "$type" Feature row shows the shared gear category icon, not the Sketch fallback', (
        tester,
      ) async {
        await tester.pumpWidget(
          _wrap(
            FeatureTreePanel(
              visible: true,
              features: [_gearFamily(type, 'f1')],
              selectedFeatureId: null,
              onFeatureTap: (_) {},
              onFeatureLongPress: (_) {},
              onClose: () {},
              onBodyTap: (_) {},
            ),
          ),
        );

        expect(
          find.byWidgetPredicate(
            (w) => w is SvgIcon && w.asset == 'assets/icons/feature/feature_gear.svg',
          ),
          findsOneWidget,
        );
        expect(
          find.byWidgetPredicate(
            (w) => w is SvgIcon && w.asset == 'assets/icons/feature/feature_new_sketch.svg',
          ),
          findsNothing,
        );
      });
    }
  });

  group('Boolean family, Subtract/Common: one shared "boolean" type, dispatching on operation', () {
    test('featureDisplayName labels a boolean Feature by its own operation, not a generic name', () {
      final features = [
        FeatureDto(type: 'boolean', id: 'f1', locked: false, produces: 'body', operation: 'subtract'),
        FeatureDto(type: 'boolean', id: 'f2', locked: false, produces: 'body', operation: 'common'),
      ];
      expect(featureDisplayName(features, 0), 'Subtract 1');
      // Shares the same `type` ("boolean") as f1, so the ordinal counts
      // across both operations together - mirrors ExtrudeType's own Boss/Cut
      // precedent (one shared "extrude" type/ordinal counter regardless of
      // mode), not a per-operation counter.
      expect(featureDisplayName(features, 1), 'Common 2');
    });

    testWidgets('a "boolean" Feature row shows the shared Boolean-family (Merge) icon', (tester) async {
      await tester.pumpWidget(
        _wrap(
          FeatureTreePanel(
            visible: true,
            features: [
              FeatureDto(type: 'boolean', id: 'f1', locked: false, produces: 'body', operation: 'subtract'),
            ],
            selectedFeatureId: null,
            onFeatureTap: (_) {},
            onFeatureLongPress: (_) {},
            onClose: () {},
            onBodyTap: (_) {},
          ),
        ),
      );

      expect(
        find.byWidgetPredicate(
          (w) => w is SvgIcon && w.asset == 'assets/icons/feature/feature_merge.svg',
        ),
        findsOneWidget,
      );
    });
  });

  group('Bug fix: Surfaces section lists produced Surface objects, not a second Feature row', () {
    // The Surfaces-section row and the SurfaceFeature's own Features-section
    // row share the exact same display name ("Surface 1" from both
    // `surfaceDisplayNames` and `featureDisplayName`) - unlike Bodies
    // ("Body 1" vs "Extrude 1"), so any test that needs to interact with
    // (tap/long-press) exactly one "Surface 1" row must first collapse the
    // Features section (which starts expanded) to avoid an ambiguous
    // two-widget match. This helper does that, then expands Surfaces.
    Future<void> collapseFeaturesExpandSurfaces(WidgetTester tester) async {
      await tester.tap(find.text('Features'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Surfaces'));
      await tester.pumpAndSettle();
    }

    testWidgets('Surfaces section is hidden entirely when there are no computed Surfaces', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          FeatureTreePanel(
            visible: true,
            features: [_sketch('s1'), _surface('sf1', locked: false)],
            selectedFeatureId: null,
            onFeatureTap: (_) {},
            onFeatureLongPress: (_) {},
            onClose: () {},
            onBodyTap: (_) {},
          ),
        ),
      );

      expect(find.text('Surfaces'), findsNothing);
    });

    testWidgets(
      'a Surface renders one row under "Surfaces", named via surfaceDisplayNames, and still '
      'appears once under Features too',
      (tester) async {
        final features = [_sketch('s1'), _surface('sf1', locked: false)];
        final names = surfaceDisplayNames(features, ['sf1']);
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
              surfaceIds: const ['sf1'],
              surfaceNames: names,
            ),
          ),
        );

        expect(find.text('Surfaces'), findsOneWidget);
        // Surfaces starts collapsed, Features starts expanded - so right now
        // "Surface 1" is exactly the one Features-section row.
        expect(find.text('Surface 1'), findsOneWidget);

        // Expand Surfaces too - its own row is a second, distinct "Surface
        // 1" widget alongside the still-present Features-section one.
        await tester.tap(find.text('Surfaces'));
        await tester.pumpAndSettle();
        expect(find.text('Surface 1'), findsNWidgets(2));
      },
    );

    testWidgets('tapping a Surface row calls onSurfaceTap, not onFeatureTap', (tester) async {
      String? tapped;
      var featureTapped = false;
      final features = [_surface('sf1', locked: false)];
      final names = surfaceDisplayNames(features, ['sf1']);
      await tester.pumpWidget(
        _wrap(
          FeatureTreePanel(
            visible: true,
            features: features,
            selectedFeatureId: null,
            onFeatureTap: (_) => featureTapped = true,
            onFeatureLongPress: (_) {},
            onClose: () {},
            onBodyTap: (_) {},
            onSurfaceTap: (id) => tapped = id,
            surfaceIds: const ['sf1'],
            surfaceNames: names,
          ),
        ),
      );

      await collapseFeaturesExpandSurfaces(tester);
      await tester.tap(find.text('Surface 1'));
      await tester.pump();

      expect(tapped, 'sf1');
      expect(featureTapped, isFalse);
    });

    testWidgets('long-pressing a Surface row calls onSurfaceLongPress with that id', (
      tester,
    ) async {
      String? longPressed;
      final features = [_surface('sf1', locked: false)];
      final names = surfaceDisplayNames(features, ['sf1']);
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
            onSurfaceLongPress: (id) => longPressed = id,
            surfaceIds: const ['sf1'],
            surfaceNames: names,
          ),
        ),
      );

      await collapseFeaturesExpandSurfaces(tester);
      await tester.longPress(find.text('Surface 1'));
      await tester.pump();

      expect(longPressed, 'sf1');
    });

    testWidgets('long-pressing a Surface row is a no-op when onSurfaceLongPress is not supplied', (
      tester,
    ) async {
      final features = [_surface('sf1', locked: false)];
      final names = surfaceDisplayNames(features, ['sf1']);
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
            surfaceIds: const ['sf1'],
            surfaceNames: names,
          ),
        ),
      );

      await collapseFeaturesExpandSurfaces(tester);

      // Must not throw.
      await tester.longPress(find.text('Surface 1'));
      await tester.pump();
    });

    testWidgets('a hidden Surface shows its row dimmed with a visibility-off icon', (
      tester,
    ) async {
      final features = [_surface('sf1', locked: false)];
      final names = surfaceDisplayNames(features, ['sf1']);
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
            surfaceIds: const ['sf1'],
            surfaceNames: names,
            hiddenSurfaceIds: const {'sf1'},
          ),
        ),
      );

      await collapseFeaturesExpandSurfaces(tester);

      expect(find.text('Surface 1'), findsOneWidget);
      expect(find.byIcon(Icons.visibility_off), findsOneWidget);
    });

    testWidgets('a Body and a Surface both present render distinct sections, never mixed', (
      tester,
    ) async {
      final features = [_extrude('e1', locked: true), _surface('sf1', locked: false)];
      final bodyNames = bodyDisplayNames(features, ['e1']);
      final surfNames = surfaceDisplayNames(features, ['sf1']);
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
            bodyNames: bodyNames,
            surfaceIds: const ['sf1'],
            surfaceNames: surfNames,
          ),
        ),
      );

      expect(find.text('Bodies'), findsOneWidget);
      expect(find.text('Surfaces'), findsOneWidget);

      await tester.tap(find.text('Bodies'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Surfaces'));
      await tester.pumpAndSettle();

      // "Body 1" only ever has one row (Bodies section; the owning Feature
      // is named "Extrude 1", no collision there). "Surface 1" has two -
      // one under Surfaces, one under the still-expanded Features section
      // for the same SurfaceFeature - never three, i.e. never duplicated
      // *within* the Surfaces section itself.
      expect(find.text('Body 1'), findsOneWidget);
      expect(find.text('Surface 1'), findsNWidgets(2));
    });
  });

  // --- LOD (docs/lod-strategy/01-design.md SS5 chunk 5): pending-detail
  // badge + pin-to-coarse toggle ------------------------------------------

  testWidgets(
    'a coarse-eligible Feature in pendingDetailFeatureIds shows the hourglass badge and '
    'the "Loading full detail…" subtitle',
    (tester) async {
      await tester.pumpWidget(
        _wrap(
          FeatureTreePanel(
            visible: true,
            features: [_gearFamily('pattern', 'p1')],
            selectedFeatureId: null,
            onFeatureTap: (_) {},
            onFeatureLongPress: (_) {},
            onClose: () {},
            onBodyTap: (_) {},
            pendingDetailFeatureIds: const {'p1'},
          ),
        ),
      );

      expect(find.byIcon(Icons.hourglass_bottom), findsOneWidget);
      expect(find.text('Loading full detail…'), findsOneWidget);
    },
  );

  testWidgets(
    'hasLostReference wins over a pending-detail badge for the same row - no hourglass, no '
    '"Loading full detail…" text',
    (tester) async {
      await tester.pumpWidget(
        _wrap(
          FeatureTreePanel(
            visible: true,
            features: [
              FeatureDto(type: 'pattern', id: 'p1', locked: false, produces: 'body', hasLostReference: true),
            ],
            selectedFeatureId: null,
            onFeatureTap: (_) {},
            onFeatureLongPress: (_) {},
            onClose: () {},
            onBodyTap: (_) {},
            pendingDetailFeatureIds: const {'p1'},
          ),
        ),
      );

      expect(find.byIcon(Icons.warning_rounded), findsOneWidget);
      expect(find.byIcon(Icons.hourglass_bottom), findsNothing);
      expect(find.text('Lost reference'), findsOneWidget);
      expect(find.text('Loading full detail…'), findsNothing);
    },
  );

  testWidgets(
    'the pin-to-coarse control only renders for a coarse-eligible Feature type when '
    'onToggleCoarsePin is supplied',
    (tester) async {
      await tester.pumpWidget(
        _wrap(
          FeatureTreePanel(
            visible: true,
            features: [_gearFamily('pattern', 'p1'), _extrude('e1', locked: false)],
            selectedFeatureId: null,
            onFeatureTap: (_) {},
            onFeatureLongPress: (_) {},
            onClose: () {},
            onBodyTap: (_) {},
            onToggleCoarsePin: (_) {},
          ),
        ),
      );

      // One pin control total - the Pattern row gets one, the plain Extrude
      // row (not coarse-eligible) gets none.
      expect(find.byIcon(Icons.blur_off), findsOneWidget);
    },
  );

  testWidgets(
    'the pin-to-coarse control is absent entirely when onToggleCoarsePin is omitted',
    (tester) async {
      await tester.pumpWidget(
        _wrap(
          FeatureTreePanel(
            visible: true,
            features: [_gearFamily('pattern', 'p1')],
            selectedFeatureId: null,
            onFeatureTap: (_) {},
            onFeatureLongPress: (_) {},
            onClose: () {},
            onBodyTap: (_) {},
          ),
        ),
      );

      expect(find.byIcon(Icons.blur_off), findsNothing);
      expect(find.byIcon(Icons.blur_on), findsNothing);
    },
  );

  testWidgets(
    'tapping the pin-to-coarse control calls onToggleCoarsePin with that row\'s own Feature, '
    'and pinnedCoarseFeatureIds flips the icon to the pinned glyph',
    (tester) async {
      FeatureDto? tapped;
      await tester.pumpWidget(
        _wrap(
          FeatureTreePanel(
            visible: true,
            features: [_gearFamily('loft', 'l1')],
            selectedFeatureId: null,
            onFeatureTap: (_) {},
            onFeatureLongPress: (_) {},
            onClose: () {},
            onBodyTap: (_) {},
            onToggleCoarsePin: (feature) => tapped = feature,
          ),
        ),
      );

      expect(find.byIcon(Icons.blur_off), findsOneWidget);
      await tester.tap(find.byIcon(Icons.blur_off));
      await tester.pumpAndSettle();
      expect(tapped?.id, 'l1');

      await tester.pumpWidget(
        _wrap(
          FeatureTreePanel(
            visible: true,
            features: [_gearFamily('loft', 'l1')],
            selectedFeatureId: null,
            onFeatureTap: (_) {},
            onFeatureLongPress: (_) {},
            onClose: () {},
            onBodyTap: (_) {},
            onToggleCoarsePin: (feature) => tapped = feature,
            pinnedCoarseFeatureIds: const {'l1'},
          ),
        ),
      );

      expect(find.byIcon(Icons.blur_on), findsOneWidget);
      expect(find.byIcon(Icons.blur_off), findsNothing);
    },
  );
}
