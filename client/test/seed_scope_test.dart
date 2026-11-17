import 'dart:async';

import 'package:didsa_cad_client/api/document_api_client.dart';
import 'package:didsa_cad_client/viewport3d/seed_scope.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

/// Bug report 2026-11-17 items 2B / M.3 / M.4: the one scope controller and section both Pattern and Mirror use.
FeatureDto _f(String id, {required bool tool}) =>
    FeatureDto(type: 'extrude', id: id, locked: false, produces: 'body', extrudeType: tool ? 'cut' : 'boss');
bool _isTool(FeatureDto f) => f.extrudeType == 'cut';
final _features = [_f('block', tool: false), _f('hole', tool: true), _f('pocket', tool: true)];

void main() {
  group('SeedScopeController', () {
    test('opens on the Feature tab with the scope field active', () {
      final scope = SeedScopeController()..reset();
      expect(scope.tab, SeedScopeTab.feature);
      expect(scope.scopeActive, isTrue);
      expect(scope.isEmpty, isTrue);
    });

    test('Feature tab: a face gives the feature that made it (one request per tap); the same face again removes it', () async {
      final scope = SeedScopeController()..reset();
      var requests = 0;
      Future<String> owner() async {
        requests++;
        return 'hole';
      }

      await scope.pickFace(bodyId: 'block', featureOwner: owner);
      expect(scope.featureIds, ['hole']);
      final seed = scope.seed(features: _features, isToolFeature: _isTool);
      expect(seed.toolFeatureIds, ['hole']);
      expect(seed.bodyIds, isEmpty);
      await scope.pickFace(bodyId: 'block', featureOwner: owner);
      expect(scope.featureIds, isEmpty);
      expect(requests, 2);
    });

    test('Body tab: a face puts its body in scope straight away, no request', () async {
      final scope = SeedScopeController()..reset(tab: SeedScopeTab.body);
      await scope.pickFace(bodyId: 'block', featureOwner: () async => fail('no request on the Body tab'));
      expect(scope.bodyIds, ['block']);
      expect(scope.seed(features: _features, isToolFeature: _isTool).bodyIds, ['block']);
    });

    test('switching tabs keeps each tab\'s scope; the request uses the active tab only', () async {
      final scope = SeedScopeController()..reset(features: ['hole']);
      scope.setTab(SeedScopeTab.body);
      scope.toggleBody('block');
      expect(scope.seed(features: _features, isToolFeature: _isTool).toolFeatureIds, isEmpty);
      scope.setTab(SeedScopeTab.feature);
      expect(scope.featureIds, ['hole']);
      expect(scope.bodyIds, ['block']);
      expect(scope.seed(features: _features, isToolFeature: _isTool).toolFeatureIds, ['hole']);
      expect(scope.seed(features: _features, isToolFeature: _isTool).bodyIds, isEmpty);
    });

    test('a cut and a body-making feature together are refused, nothing removed', () {
      final scope = SeedScopeController()..reset(features: ['hole', 'block']);
      final seed = scope.seed(features: _features, isToolFeature: _isTool);
      expect(seed.error, isNotNull);
      expect(scope.featureIds, ['hole', 'block']);
      scope.remove('block');
      expect(scope.seed(features: _features, isToolFeature: _isTool).error, isNull);
    });

    test('an answer that comes back after the tool was reset is dropped', () async {
      final scope = SeedScopeController()..reset();
      final answer = Completer<String>();
      final pick = scope.pickFace(bodyId: 'block', featureOwner: () => answer.future);
      scope.reset();
      answer.complete('hole');
      await pick;
      expect(scope.featureIds, isEmpty);
    });

    test('a failed answer is said, and changes nothing', () async {
      final scope = SeedScopeController()..reset(features: ['hole']);
      await scope.pickFace(bodyId: 'block', featureOwner: () async => throw StateError('422'));
      expect(scope.featureIds, ['hole']);
      expect(scope.pickError, contains('422'));
    });
  });

  group('SeedScopeSection', () {
    Widget section({
      SeedScopeTab tab = SeedScopeTab.feature,
      List<SeedScopeChip> chips = const [],
      void Function(SeedScopeTab)? onTabChanged,
      void Function(String)? onRemove,
      VoidCallback? onActivate,
      String? error,
      VoidCallback? onAddFromTree,
    }) =>
        MaterialApp(
          home: Scaffold(
            body: SeedScopeSection(
              keyPrefix: 'pattern',
              tab: tab,
              onTabChanged: onTabChanged ?? (_) {},
              chips: chips,
              onRemove: onRemove ?? (_) {},
              active: true,
              onActivate: onActivate ?? () {},
              error: error,
              onAddFromTree: onAddFromTree,
            ),
          ),
        );

    testWidgets('tabs, "Pick faces" while empty, chips with a remove, the error, Add from Tree on the Feature tab only', (tester) async {
      SeedScopeTab? tab;
      String? removed;
      var activated = false;
      await tester.pumpWidget(section(onTabChanged: (t) => tab = t, onActivate: () => activated = true, onAddFromTree: () {}));
      expect(find.byKey(const ValueKey('pattern-tab-feature')), findsOneWidget);
      expect(find.text('Pick faces'), findsOneWidget);
      expect(find.text('Add from Tree'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('pattern-tab-body')));
      expect(tab, SeedScopeTab.body);
      await tester.tap(find.byKey(const ValueKey('pattern-scope-field')));
      expect(activated, isTrue);

      await tester.pumpWidget(section(
        chips: const [(id: 'hole', label: 'Extrude 2')],
        onRemove: (id) => removed = id,
        error: 'mixed',
        onAddFromTree: () {},
      ));
      expect(find.text('Extrude 2'), findsOneWidget);
      expect(find.text('mixed'), findsOneWidget);
      tester.widget<InputChip>(find.byKey(const ValueKey('pattern-scope-chip-hole'))).onDeleted!();
      expect(removed, 'hole');

      await tester.pumpWidget(section(tab: SeedScopeTab.body, onAddFromTree: () {}));
      expect(find.text('Add from Tree'), findsNothing);
    });
  });
}
