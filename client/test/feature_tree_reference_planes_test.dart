import 'package:didsa_cad_client/api/document_api_client.dart';
import 'package:didsa_cad_client/viewport3d/feature_tree_panel.dart';
import 'package:didsa_cad_client/viewport3d/reference_planes.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

/// The XY / XZ / YZ rows under Planes (`docs/flutter-testing-feedback-2026-11-05-plan.md` item 4).
void main() {
  Future<void> pump(
    WidgetTester tester, {
    Set<ReferencePlaneKind> hidden = const {},
    bool multiSelect = false,
    List<ReferencePlaneKind>? taps,
    List<(ReferencePlaneKind, bool)>? visibility,
    List<FeatureDto> features = const [],
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            height: 700,
            child: FeatureTreePanel(
              visible: true,
              docked: true,
              features: features,
              selectedFeatureId: null,
              onFeatureTap: (_) {},
              onFeatureLongPress: (_) {},
              onClose: () {},
              onBodyTap: (_) {},
              hiddenReferencePlanes: hidden,
              onReferencePlaneTap: taps?.add,
              onReferencePlaneVisibility: (plane, h) => visibility?.add((plane, h)),
              isMultiSelectMode: multiSelect,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('Planes'));
    await tester.pumpAndSettle();
  }

  testWidgets('with no created planes there is still a Planes section with three rows in order', (tester) async {
    await pump(tester);
    final ys = [
      for (final name in ['XY Plane', 'XZ Plane', 'YZ Plane']) tester.getTopLeft(find.text(name)).dy,
    ];
    expect(ys, [...ys]..sort());
    expect(find.byKey(const ValueKey('ref-plane-eye-XZ')), findsOneWidget);
  });

  testWidgets('the eye on XZ asks to hide it; on a hidden plane it asks to show it', (tester) async {
    final calls = <(ReferencePlaneKind, bool)>[];
    await pump(tester, visibility: calls, hidden: {ReferencePlaneKind.yz});
    await tester.tap(find.byKey(const ValueKey('ref-plane-eye-XZ')));
    await tester.tap(find.byKey(const ValueKey('ref-plane-eye-YZ')));
    expect(calls, [(ReferencePlaneKind.xz, true), (ReferencePlaneKind.yz, false)]);
  });

  testWidgets('a hidden row is dimmed', (tester) async {
    await pump(tester, hidden: {ReferencePlaneKind.xy});
    double opacityOf(String key) => tester
        .widget<Opacity>(find.ancestor(of: find.byKey(ValueKey(key)), matching: find.byType(Opacity)).first)
        .opacity;
    expect(opacityOf('ref-plane-row-XY'), lessThan(1));
    expect(opacityOf('ref-plane-row-XZ'), 1);
  });

  testWidgets('tap opens the plane (same as the viewport tap)', (tester) async {
    final taps = <ReferencePlaneKind>[];
    await pump(tester, taps: taps);
    await tester.tap(find.text('YZ Plane'));
    expect(taps, [ReferencePlaneKind.yz]);
  });

  testWidgets('long-press offers Hide / Show and no Delete', (tester) async {
    final calls = <(ReferencePlaneKind, bool)>[];
    await pump(tester, visibility: calls);
    await tester.longPress(find.text('XZ Plane'));
    await tester.pumpAndSettle();
    expect(find.text('Hide'), findsOneWidget);
    expect(find.textContaining('Delete'), findsNothing);
    await tester.tap(find.text('Hide'));
    await tester.pumpAndSettle();
    expect(calls, [(ReferencePlaneKind.xz, true)]);
  });

  testWidgets('in multi-select the rows are not selectable: no eye, no tap, no long-press menu', (tester) async {
    final taps = <ReferencePlaneKind>[];
    final calls = <(ReferencePlaneKind, bool)>[];
    await pump(tester, multiSelect: true, taps: taps, visibility: calls);
    expect(find.byKey(const ValueKey('ref-plane-eye-XY')), findsNothing);
    await tester.tap(find.text('XY Plane'), warnIfMissed: false);
    await tester.longPress(find.text('XY Plane'), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(taps, isEmpty);
    expect(calls, isEmpty);
    expect(find.text('Hide'), findsNothing);
    expect(find.byIcon(Icons.check_circle), findsNothing);
  });
}
