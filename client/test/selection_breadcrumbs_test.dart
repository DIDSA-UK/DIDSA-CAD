import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:didsa_cad_client/viewport3d/selection_breadcrumbs.dart';
import 'package:didsa_cad_client/viewport3d/selection_hit_test.dart';

/// Phase 6b (`docs/assembly-scope.md` §3, "selection breadcrumbs" - the
/// follow-on this same section documents as blocked on Phase 6a's own
/// occurrence-attributed selection, now landed): real, runnable coverage
/// for [breadcrumbTiersFor]'s own pure containment-chain logic and
/// [SelectionBreadcrumbBar]'s interaction grammar. No `flutter_scene`
/// dependency in `selection_breadcrumbs.dart`'s own import chain (same
/// precedent `fillet_panel_test.dart`/`mate_panel_test.dart` already rely
/// on), so this is a real widget test in this sandbox.
void main() {
  group('breadcrumbTiersFor', () {
    test('a root-Part face chains to itself and its Body, no component tier', () {
      const entity = SelectionEntityRef(kind: SelectionEntityKind.face, bodyId: 'b1', id: 3);
      final tiers = breadcrumbTiersFor(entity);
      expect(tiers.map((t) => t.tier), [BreadcrumbTier.entity, BreadcrumbTier.body]);
      expect(tiers[0].target, entity);
      expect(tiers[1].target, const SelectionEntityRef(kind: SelectionEntityKind.body, bodyId: 'b1'));
    });

    test('an edge on a placed Occurrence chains to itself, its Body, and its Component', () {
      const entity = SelectionEntityRef(
        kind: SelectionEntityKind.edge,
        bodyId: 'b1',
        id: 5,
        occurrenceId: 'occ-1',
      );
      final tiers = breadcrumbTiersFor(entity);
      expect(tiers.map((t) => t.tier), [BreadcrumbTier.entity, BreadcrumbTier.body, BreadcrumbTier.component]);
      expect(tiers[0].target, entity);
      expect(
        tiers[1].target,
        const SelectionEntityRef(kind: SelectionEntityKind.body, bodyId: 'b1', occurrenceId: 'occ-1'),
      );
      expect(tiers[2].target, const SelectionEntityRef(kind: SelectionEntityKind.component, occurrenceId: 'occ-1'));
    });

    test('a vertex on a placed Occurrence includes the component tier too', () {
      const entity = SelectionEntityRef(
        kind: SelectionEntityKind.vertex,
        bodyId: 'b2',
        id: 0,
        occurrenceId: 'occ-2',
      );
      final tiers = breadcrumbTiersFor(entity);
      expect(tiers.map((t) => t.tier), [BreadcrumbTier.entity, BreadcrumbTier.body, BreadcrumbTier.component]);
    });

    test('a whole-Body selection on the root Part chains to just itself', () {
      const entity = SelectionEntityRef(kind: SelectionEntityKind.body, bodyId: 'b1');
      final tiers = breadcrumbTiersFor(entity);
      expect(tiers.map((t) => t.tier), [BreadcrumbTier.body]);
      expect(tiers.single.target, entity);
    });

    test('a whole-Body selection on a placed Occurrence chains to itself plus a component tier', () {
      const entity = SelectionEntityRef(kind: SelectionEntityKind.body, bodyId: 'b1', occurrenceId: 'occ-1');
      final tiers = breadcrumbTiersFor(entity);
      expect(tiers.map((t) => t.tier), [BreadcrumbTier.body, BreadcrumbTier.component]);
      expect(tiers[0].target, entity);
      expect(tiers[1].target, const SelectionEntityRef(kind: SelectionEntityKind.component, occurrenceId: 'occ-1'));
    });

    test('a whole-component selection chains to just itself - nothing coarser or finer to name', () {
      const entity = SelectionEntityRef(kind: SelectionEntityKind.component, occurrenceId: 'occ-1');
      final tiers = breadcrumbTiersFor(entity);
      expect(tiers.map((t) => t.tier), [BreadcrumbTier.component]);
      expect(tiers.single.target, entity);
    });

    test('a sketch entity has no breadcrumb chain at all - deliberately empty, not an error', () {
      const entity = SelectionEntityRef(kind: SelectionEntityKind.sketchLine, sketchFeatureId: 'f1', sketchEntityId: 'l1');
      expect(breadcrumbTiersFor(entity), isEmpty);
    });

    test('a reference plane has no breadcrumb chain either', () {
      const entity = SelectionEntityRef(kind: SelectionEntityKind.referencePlane);
      expect(breadcrumbTiersFor(entity), isEmpty);
    });
  });

  group('SelectionBreadcrumbBar', () {
    Widget wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

    testWidgets('renders nothing for a single-tier chain (a bare component)', (tester) async {
      await tester.pumpWidget(wrap(SelectionBreadcrumbBar(
        entity: const SelectionEntityRef(kind: SelectionEntityKind.component, occurrenceId: 'occ-1'),
        onSelect: (_) {},
      )));
      expect(find.byType(SelectionBreadcrumbBar), findsOneWidget);
      // SizedBox.shrink() is the entire render - no icons, no Material bar.
      expect(find.byTooltip('Body'), findsNothing);
    });

    testWidgets('renders nothing for a kind with no breadcrumb chain', (tester) async {
      await tester.pumpWidget(wrap(SelectionBreadcrumbBar(
        entity: const SelectionEntityRef(kind: SelectionEntityKind.referencePlane),
        onSelect: (_) {},
      )));
      expect(find.byTooltip('Body'), findsNothing);
    });

    testWidgets('renders one tappable icon per tier for a placed-Occurrence face', (tester) async {
      await tester.pumpWidget(wrap(SelectionBreadcrumbBar(
        entity: const SelectionEntityRef(kind: SelectionEntityKind.face, bodyId: 'b1', id: 2, occurrenceId: 'occ-1'),
        onSelect: (_) {},
      )));
      expect(find.byTooltip('Face'), findsOneWidget);
      expect(find.byTooltip('Body'), findsOneWidget);
      expect(find.byTooltip('Component'), findsOneWidget);
    });

    testWidgets('tapping the Body tier fires onSelect with the body-kind target', (tester) async {
      SelectionEntityRef? selected;
      await tester.pumpWidget(wrap(SelectionBreadcrumbBar(
        entity: const SelectionEntityRef(kind: SelectionEntityKind.face, bodyId: 'b1', id: 2),
        onSelect: (target) => selected = target,
      )));
      await tester.tap(find.byTooltip('Body'));
      expect(selected, const SelectionEntityRef(kind: SelectionEntityKind.body, bodyId: 'b1'));
    });

    testWidgets('tapping the Component tier fires onSelect with the component-kind target', (tester) async {
      SelectionEntityRef? selected;
      await tester.pumpWidget(wrap(SelectionBreadcrumbBar(
        entity: const SelectionEntityRef(kind: SelectionEntityKind.vertex, bodyId: 'b1', id: 0, occurrenceId: 'occ-9'),
        onSelect: (target) => selected = target,
      )));
      await tester.tap(find.byTooltip('Component'));
      expect(selected, const SelectionEntityRef(kind: SelectionEntityKind.component, occurrenceId: 'occ-9'));
    });

    testWidgets('hovering a tier fires onPreview with its target, and null on exit', (tester) async {
      final previewed = <SelectionEntityRef?>[];
      await tester.pumpWidget(wrap(SelectionBreadcrumbBar(
        entity: const SelectionEntityRef(kind: SelectionEntityKind.face, bodyId: 'b1', id: 2),
        onSelect: (_) {},
        onPreview: previewed.add,
      )));

      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      addTearDown(gesture.removePointer);
      await tester.pump();
      await gesture.moveTo(tester.getCenter(find.byTooltip('Body')));
      await tester.pump();
      await gesture.moveTo(const Offset(-100, -100));
      await tester.pump();

      expect(previewed, [const SelectionEntityRef(kind: SelectionEntityKind.body, bodyId: 'b1'), null]);
    });
  });
}
