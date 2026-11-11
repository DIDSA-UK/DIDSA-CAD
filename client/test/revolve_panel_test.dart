import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:didsa_cad_client/viewport3d/revolve_panel.dart';

/// [RevolvePanel]'s thin-wall option (Flutter-testing feedback 2026-11-11, item 5): a Thin toggle with a thickness field and a direction
/// choice shared with Extrude (`ThinWallControls`); an open profile locks Thin on and labels the direction against the axis.
void main() {
  late List<(RevolveMode, double, double?, ThicknessDirection)> emitted;
  var confirmed = 0;

  Future<void> pump(
    WidgetTester tester, {
    double? initialThickness,
    ThicknessDirection direction = ThicknessDirection.outward,
    bool openProfile = false,
    bool hasAxis = true,
  }) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(900, 1600);
    addTearDown(tester.view.reset);
    emitted = [];
    confirmed = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Stack(children: [
          RevolvePanel(
            initialAngle: 360,
            initialThickness: initialThickness,
            initialThicknessDirection: direction,
            openProfile: openProfile,
            hasAxis: hasAxis,
            targetBodyCount: 0,
            onChanged: (mode, angle, thickness, dir) => emitted.add((mode, angle, thickness, dir)),
            onConfirm: () => confirmed++,
            onCancel: () {},
          ),
        ]),
      ),
    ));
    await tester.pump(); // the initial value is reported after the first frame
  }

  final toggle = find.byKey(const ValueKey('thin-wall-toggle'));
  final thickness = find.byKey(const ValueKey('thin-wall-thickness'));

  testWidgets('a solid revolve shows no thickness field and reports a null thickness', (tester) async {
    await pump(tester);
    expect(thickness, findsNothing);
    expect(emitted.last.$3, isNull);
    expect(find.text('Thin wall'), findsOneWidget);
  });

  testWidgets('the Thin toggle shows the thickness field and direction, and every change reports the values', (tester) async {
    await pump(tester);
    await tester.tap(toggle);
    await tester.pump();
    expect(thickness, findsOneWidget);
    expect(emitted.last, (RevolveMode.boss, 360.0, 2.0, ThicknessDirection.outward), reason: 'the default wall is 2');

    await tester.enterText(thickness, '3.5');
    await tester.pump();
    expect(emitted.last.$3, 3.5);

    await tester.tap(find.text('In'));
    await tester.pump();
    expect(emitted.last.$4, ThicknessDirection.inward);
    await tester.tap(find.text('Middle'));
    await tester.pump();
    expect(emitted.last.$4, ThicknessDirection.symmetric);

    await tester.tap(toggle); // back to solid
    await tester.pump();
    expect(emitted.last.$3, isNull);
    expect(thickness, findsNothing);
  });

  testWidgets('an invalid thickness disables Confirm and sends no preview that would silently turn solid', (tester) async {
    await pump(tester, initialThickness: 2);
    final sent = emitted.length;
    await tester.enterText(thickness, '0');
    await tester.pump();
    expect(emitted.length, sent, reason: 'no update while the wall is invalid');
    await tester.ensureVisible(find.text('Confirm'));
    await tester.tap(find.text('Confirm'));
    expect(confirmed, 0);
    await tester.enterText(thickness, '1.25');
    await tester.pump();
    await tester.tap(find.text('Confirm'));
    expect(confirmed, 1);
  });

  testWidgets('editing a thin revolve opens on its stored thickness and direction', (tester) async {
    await pump(tester, initialThickness: 4, direction: ThicknessDirection.symmetric);
    expect(tester.widget<TextField>(thickness).controller!.text, '4');
    expect(emitted.last, (RevolveMode.boss, 360.0, 4.0, ThicknessDirection.symmetric));
    final control = tester.widget<SegmentedButton<ThicknessDirection>>(find.byKey(const ValueKey('thin-wall-direction')));
    expect(control.selected, {ThicknessDirection.symmetric});
  });

  testWidgets('an open profile has Thin on and locked, a hint, and the axis labels', (tester) async {
    await pump(tester, openProfile: true);
    expect(tester.widget<CheckboxListTile>(toggle).value, isTrue);
    expect(tester.widget<CheckboxListTile>(toggle).onChanged, isNull, reason: 'locked on');
    expect(find.text('An open profile revolves as a thin wall'), findsOneWidget);
    expect(find.text('Away from axis'), findsOneWidget);
    expect(find.text('Toward axis'), findsOneWidget);
    expect(find.text('Both sides'), findsOneWidget);
    expect(find.text('Out'), findsNothing);
    expect(emitted.last.$3, 2.0, reason: 'opens with a valid wall so the preview and Confirm work straight away');
  });
}
