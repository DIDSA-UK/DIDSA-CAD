import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:didsa_cad_client/viewport3d/curve_panel.dart';

/// [CurvePanel]'s Helix form: diameter, a taper (none / end diameter / angle, the other shown read-only)
/// and a list of pitch + turns segments. No `flutter_scene` in this file's import chain.
void main() {
  late List<Map<String, Object?>> emitted;
  var confirmed = 0;

  Future<void> pumpHelix(WidgetTester tester, {HelixInitialValues? initial, double keyboardHeight = 0}) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(900, 2000);
    addTearDown(tester.view.reset);
    emitted = [];
    confirmed = 0;
    await tester.pumpWidget(MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(
          size: const Size(900, 2000),
          viewInsets: EdgeInsets.only(bottom: keyboardHeight),
        ),
        child: Scaffold(
          resizeToAvoidBottomInset: false,
          body: Stack(children: [
            CurvePanel(
              initialHelix: initial,
              onHelixChanged: ({
                required String axisPlane,
                required double radius,
                double? endRadius,
                double? taperAngleDegrees,
                required List<HelixSegmentValue> segments,
                required List<HelixPitchPointValue> pitchPoints,
                required bool rightHanded,
              }) =>
                  emitted.add({
                'points': [for (final p in pitchPoints) (p.at, p.pitch)],
                'radius': radius,
                'endRadius': endRadius,
                'angle': taperAngleDegrees,
                'segments': [for (final s in segments) (s.pitch, s.turns)],
                'rightHanded': rightHanded,
              }),
              onConfirm: () => confirmed++,
              onCancel: () {},
            ),
          ]),
        ),
      ),
    ));
  }

  testWidgets('starts as a constant helix with one segment and can be confirmed', (tester) async {
    await pumpHelix(tester);
    expect(find.byKey(const ValueKey('helix-segment-0')), findsOneWidget);
    expect(find.byKey(const ValueKey('helix-taper-field')), findsNothing);
    await tester.tap(find.text('Confirm'));
    expect(confirmed, 1);
  });

  testWidgets('segments can be added, edited and removed; each edit reports the whole list', (tester) async {
    await pumpHelix(tester);
    await tester.tap(find.byKey(const ValueKey('helix-add-segment')));
    await tester.pump();
    expect(find.byKey(const ValueKey('helix-segment-1')), findsOneWidget);
    // The new row repeats the pitch of the one above and starts at one turn.
    expect(emitted.last['segments'], [(2.0, 3.0), (2.0, 1.0)]);

    await tester.enterText(find.byKey(const ValueKey('helix-segment-1-pitch')), '6');
    await tester.enterText(find.byKey(const ValueKey('helix-segment-1-turns')), '2.5');
    expect(emitted.last['segments'], [(2.0, 3.0), (6.0, 2.5)]);
    await tester.pump();
    expect(find.textContaining('Height'), findsOneWidget);
    expect(find.text('Height 21.00'), findsOneWidget); // 2 x 3 + 6 x 2.5

    await tester.tap(find.byKey(const ValueKey('helix-segment-0-remove')));
    await tester.pump();
    expect(find.byKey(const ValueKey('helix-segment-1')), findsNothing);
    expect(emitted.last['segments'], [(6.0, 2.5)]);
    // The last remaining segment cannot be removed.
    expect(tester.widget<IconButton>(find.byKey(const ValueKey('helix-segment-0-remove'))).onPressed, isNull);
  });

  testWidgets('an invalid segment stops the reports and disables Confirm', (tester) async {
    await pumpHelix(tester);
    final before = emitted.length;
    await tester.enterText(find.byKey(const ValueKey('helix-segment-0-turns')), '0');
    await tester.pump();
    expect(emitted.length, before);
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Confirm')).onPressed, isNull);
    expect(find.textContaining('non-zero pitch and positive turns'), findsOneWidget);
  });

  testWidgets('segments that advance opposite ways along the axis are rejected', (tester) async {
    await pumpHelix(tester);
    await tester.tap(find.byKey(const ValueKey('helix-add-segment')));
    await tester.pump();
    await tester.enterText(find.byKey(const ValueKey('helix-segment-1-pitch')), '-1');
    await tester.pump();
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Confirm')).onPressed, isNull);
  });

  testWidgets('the diameter is typed and half of it is sent as the radius', (tester) async {
    await pumpHelix(tester);
    expect(find.text('Diameter (at the start)'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('helix-diameter-field')), '12');
    await tester.pump();
    expect(emitted.last['radius'], 6.0);
  });

  testWidgets('an end diameter is sent as an end radius and shows the angle read-only', (tester) async {
    await pumpHelix(tester);
    await tester.tap(find.text('End diameter'));
    await tester.pump();
    expect(
        tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Confirm')).onPressed, isNull); // needs a value
    await tester.enterText(find.byKey(const ValueKey('helix-taper-field')), '16');
    await tester.pump();
    expect(emitted.last['endRadius'], 8.0);
    expect(emitted.last['angle'], isNull);
    // Radius 5 to 8 over a height of 6.
    // Height 6 (pitch 2 x 3 turns), widening 3: atan(0.5) = 26.57 degrees.
    expect(find.text('Taper angle: 26.57°'), findsOneWidget);
  });

  testWidgets('a taper angle is sent as such and shows the end diameter read-only', (tester) async {
    await pumpHelix(tester);
    await tester.tap(find.text('Taper angle'));
    await tester.pump();
    await tester.enterText(find.byKey(const ValueKey('helix-taper-field')), '45');
    await tester.pump();
    expect(emitted.last['angle'], 45.0);
    expect(emitted.last['endRadius'], isNull);
    expect(find.text('End diameter: 22.000'), findsOneWidget); // 10 + 2 x 6 x tan(45 degrees)
  });

  testWidgets('going back to Constant clears the taper', (tester) async {
    await pumpHelix(tester);
    await tester.tap(find.text('End diameter'));
    await tester.pump();
    await tester.enterText(find.byKey(const ValueKey('helix-taper-field')), '16');
    await tester.tap(find.text('Constant'));
    await tester.pump();
    expect(emitted.last['endRadius'], isNull);
    expect(emitted.last['angle'], isNull);
    expect(find.byKey(const ValueKey('helix-taper-field')), findsNothing);
  });

  testWidgets('the handedness switch is reported', (tester) async {
    await pumpHelix(tester);
    await tester.tap(find.byType(SwitchListTile));
    await tester.pump();
    expect(emitted.last['rightHanded'], isFalse);
  });

  testWidgets('editing opens on the stored values, as diameters, without the Helix / Intersection toggle',
      (tester) async {
    await pumpHelix(
      tester,
      initial: const HelixInitialValues(
        radius: 2.5,
        endRadius: 4,
        segments: [HelixSegmentValue(pitch: 1.5, turns: 4), HelixSegmentValue(pitch: 3, turns: 2)],
        rightHanded: false,
      ),
    );
    expect(find.text('Intersection'), findsNothing);
    expect(tester.widget<TextField>(find.byKey(const ValueKey('helix-diameter-field'))).controller!.text, '5');
    expect(tester.widget<TextField>(find.byKey(const ValueKey('helix-taper-field'))).controller!.text, '8');
    expect(tester.widget<TextField>(find.byKey(const ValueKey('helix-segment-1-pitch'))).controller!.text, '3');
    expect(tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value, isFalse);
    await tester.tap(find.text('Confirm'));
    expect(confirmed, 1);
  });

  testWidgets('bug report: the keyboard lifts the panel instead of covering its fields', (tester) async {
    await pumpHelix(tester, keyboardHeight: 900);
    final panelBottom = tester.getBottomLeft(find.byType(Material).last).dy;
    expect(panelBottom, lessThanOrEqualTo(2000 - 900 + 0.5));
    expect(tester.takeException(), isNull);
  });

  testWidgets('pitch varying along the length: starts from the segments, sends pitch points only', (tester) async {
    await pumpHelix(tester);
    await tester.tap(find.text('Varies along length'));
    await tester.pump();
    // One segment of pitch 2 x 3 turns: points at 0 and at the height 6, both pitch 2.
    expect(emitted.last['segments'], isEmpty);
    expect(emitted.last['points'], [(0.0, 2.0), (6.0, 2.0)]);
    expect(tester.widget<TextField>(find.byKey(const ValueKey('helix-point-0-at'))).enabled, isFalse);
    await tester.enterText(find.byKey(const ValueKey('helix-point-1-pitch')), '4');
    await tester.tap(find.byKey(const ValueKey('helix-add-point')));
    await tester.pump();
    await tester.enterText(find.byKey(const ValueKey('helix-point-2-at')), '20');
    await tester.pump();
    expect(emitted.last['points'], [(0.0, 2.0), (6.0, 4.0), (20.0, 4.0)]);
    expect(find.text('Height 20.00'), findsOneWidget);
    // Back to segments sends segments again.
    await tester.tap(find.text('Segments').first);
    await tester.pump();
    expect(emitted.last['points'], isEmpty);
    expect(emitted.last['segments'], [(2.0, 3.0)]);
  });

  testWidgets('pitch points must increase from the start and advance one way', (tester) async {
    await pumpHelix(tester);
    await tester.tap(find.text('Varies along length'));
    await tester.pump();
    final before = emitted.length;
    await tester.enterText(find.byKey(const ValueKey('helix-point-1-at')), '0');
    await tester.pump();
    expect(emitted.length, before);
    expect(find.textContaining('start at 0 and increase'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Confirm')).onPressed, isNull);
    await tester.enterText(find.byKey(const ValueKey('helix-point-1-at')), '5');
    await tester.enterText(find.byKey(const ValueKey('helix-point-1-pitch')), '-2');
    await tester.pump();
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Confirm')).onPressed, isNull);
  });

  testWidgets('editing a variable-pitch helix opens on its points', (tester) async {
    await pumpHelix(
      tester,
      initial: const HelixInitialValues(
        radius: 5,
        segments: [],
        pitchPoints: [HelixPitchPointValue(at: 0, pitch: 1), HelixPitchPointValue(at: 10, pitch: 3)],
      ),
    );
    expect(tester.widget<TextField>(find.byKey(const ValueKey('helix-point-1-at'))).controller!.text, '10');
    expect(find.text('Height 10.00'), findsOneWidget);
    await tester.tap(find.text('Confirm'));
    expect(confirmed, 1);
  });
}
