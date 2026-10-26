import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:didsa_cad_client/viewport3d/curve_panel.dart';

/// [CurvePanel]'s Helix form: radius, a taper (none / end radius / angle, the other shown read-only)
/// and a list of pitch + turns segments. No `flutter_scene` in this file's import chain.
void main() {
  late List<Map<String, Object?>> emitted;
  var confirmed = 0;

  Future<void> pumpHelix(WidgetTester tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(900, 2000);
    addTearDown(tester.view.reset);
    emitted = [];
    confirmed = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Stack(children: [
          CurvePanel(
            onHelixChanged: ({
              required String axisPlane,
              required double radius,
              double? endRadius,
              double? taperAngleDegrees,
              required List<HelixSegmentValue> segments,
              required bool rightHanded,
            }) =>
                emitted.add({
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

  testWidgets('an end radius is sent as such and shows the angle read-only', (tester) async {
    await pumpHelix(tester);
    await tester.tap(find.text('End radius'));
    await tester.pump();
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Confirm')).onPressed, isNull); // needs a value
    await tester.enterText(find.byKey(const ValueKey('helix-taper-field')), '8');
    await tester.pump();
    expect(emitted.last['endRadius'], 8.0);
    expect(emitted.last['angle'], isNull);
    // Height 6 (pitch 2 x 3 turns), widening 3: atan(0.5) = 26.57 degrees.
    expect(find.text('Taper angle: 26.57°'), findsOneWidget);
  });

  testWidgets('a taper angle is sent as such and shows the end radius read-only', (tester) async {
    await pumpHelix(tester);
    await tester.tap(find.text('Taper angle'));
    await tester.pump();
    await tester.enterText(find.byKey(const ValueKey('helix-taper-field')), '45');
    await tester.pump();
    expect(emitted.last['angle'], 45.0);
    expect(emitted.last['endRadius'], isNull);
    expect(find.text('End radius: 11.000'), findsOneWidget); // 5 + 6 x tan(45 degrees)
  });

  testWidgets('going back to Constant clears the taper', (tester) async {
    await pumpHelix(tester);
    await tester.tap(find.text('End radius'));
    await tester.pump();
    await tester.enterText(find.byKey(const ValueKey('helix-taper-field')), '8');
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
}
