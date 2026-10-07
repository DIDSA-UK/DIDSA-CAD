import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:didsa_cad_client/viewport3d/loft_panel.dart';

void main() {
  Future<void> pumpPanel(
    WidgetTester tester, {
    List<double?> seams = const [null, 0.25],
    List<bool> reverse = const [false, true],
    List<bool> profilePicked = const [false, true],
    int? pickingProfile,
    void Function(int, double?)? onSeam,
    void Function(int, bool)? onReverse,
    void Function(int)? onPick,
    void Function(int)? onClear,
  }) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(900, 1600);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Stack(children: [
          LoftPanel(
            sectionCount: 2,
            targetBodyCount: 0,
            alignmentPointsSet: const [false, false],
            guideCurveSet: false,
            pickingAlignmentPointIndex: null,
            pickingGuideCurve: false,
            onPickAlignmentPoint: (_) {},
            onClearAlignmentPoint: (_) {},
            onCancelAlignmentPointPick: () {},
            onPickGuideCurve: () {},
            onClearGuideCurve: () {},
            onCancelGuideCurvePick: () {},
            onChanged: (_, __, ___, ____) {},
            onConfirm: () {},
            onCancel: () {},
            seamParams: seams,
            reverseFlags: reverse,
            profilePicked: profilePicked,
            pickingProfileIndex: pickingProfile,
            onSeamChanged: onSeam ?? (_, __) {},
            onReverseChanged: onReverse ?? (_, __) {},
            onPickProfile: onPick ?? (_) {},
            onClearProfile: onClear ?? (_) {},
          ),
        ]),
      ),
    ));
    await tester.tap(find.text('Connection point & direction'));
    await tester.pumpAndSettle();
  }

  testWidgets('shows each section\'s start as auto or a percentage', (tester) async {
    await pumpPanel(tester);
    expect(find.text('Section 1 start: auto'), findsOneWidget);
    expect(find.text('Section 2 start: 25%'), findsOneWidget);
  });

  testWidgets('the reverse switch and Auto button report per-section changes', (tester) async {
    final reversed = <(int, bool)>[];
    final seams = <(int, double?)>[];
    await pumpPanel(tester, onReverse: (i, v) => reversed.add((i, v)), onSeam: (i, v) => seams.add((i, v)));

    await tester.tap(find.byKey(const ValueKey('loft-reverse-switch-0')));
    await tester.pump();
    expect(reversed, [(0, true)]);

    await tester.tap(find.text('Auto')); // only section 2 has an explicit seam
    await tester.pump();
    expect(seams, [(1, null)]);
  });

  testWidgets('the profile row offers Pick when default and Change/clear when picked', (tester) async {
    final picked = <int>[];
    final cleared = <int>[];
    await pumpPanel(tester, onPick: picked.add, onClear: cleared.add);

    expect(find.text('Default (only loop)'), findsOneWidget);
    expect(find.text('Picked'), findsOneWidget);

    await tester.tap(find.text('Pick'));
    await tester.tap(find.text('Change'));
    await tester.tap(find.byTooltip('Use the default profile'));
    expect(picked, [0, 1]);
    expect(cleared, [1]);
  });

  testWidgets('while picking a profile the row asks for a tap in the viewport', (tester) async {
    await pumpPanel(tester, pickingProfile: 0);
    expect(find.text('Tap one of its lines or curves in the viewport…'), findsOneWidget);
  });
}
