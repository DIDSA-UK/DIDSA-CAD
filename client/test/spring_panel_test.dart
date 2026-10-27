import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:didsa_cad_client/api/document_api_client.dart';
import 'package:didsa_cad_client/viewport3d/spring_panel.dart';

/// [SpringPanel]: a compression spring's numbers, each end open / closed / closed & ground, the hand;
/// it reports only numbers that can make a spring. No `flutter_scene` in this file's import chain.
void main() {
  late List<(SpringDto, String)> emitted;
  var confirmed = 0;

  Future<void> pumpPanel(WidgetTester tester, {SpringDto? initial, double keyboardHeight = 0}) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(900, 2000);
    addTearDown(tester.view.reset);
    emitted = [];
    confirmed = 0;
    await tester.pumpWidget(MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(size: const Size(900, 2000), viewInsets: EdgeInsets.only(bottom: keyboardHeight)),
        child: Scaffold(
          resizeToAvoidBottomInset: false,
          body: Stack(children: [
            SpringPanel(
              initial: initial,
              onChanged: (spring, plane) => emitted.add((spring, plane)),
              onConfirm: () => confirmed++,
              onCancel: () {},
            ),
          ]),
        ),
      ),
    ));
  }

  testWidgets('starts as a closed-and-ground right-handed spring that can be confirmed', (tester) async {
    await pumpPanel(tester);
    expect(find.text('Closed & ground'), findsNWidgets(2));
    expect(find.text('Outside 11.00, inside 9.00'), findsOneWidget);
    await tester.tap(find.text('Confirm'));
    expect(confirmed, 1);
  });

  testWidgets('every edit reports the whole spring', (tester) async {
    await pumpPanel(tester);
    await tester.enterText(find.byKey(const ValueKey('spring-wire')), '0.3');
    await tester.enterText(find.byKey(const ValueKey('spring-coils')), '10');
    await tester.pump();
    final (spring, plane) = emitted.last;
    expect(spring.wireDiameter, 0.3);
    expect(spring.activeCoils, 10.0);
    expect(spring.meanDiameter, 10.0);
    expect(plane, 'XY');
    expect(spring.toJson()['start_end'], 'closed_ground');
  });

  testWidgets('an end can be set open', (tester) async {
    await pumpPanel(tester);
    await tester.tap(find.byKey(const ValueKey('spring-finish-end')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open').last);
    await tester.pumpAndSettle();
    expect(emitted.last.$1.finishEnd, 'open');
    expect(emitted.last.$1.startEnd, 'closed_ground');
  });

  testWidgets('a wire as thick as the spring is refused before Confirm', (tester) async {
    await pumpPanel(tester);
    final before = emitted.length;
    await tester.enterText(find.byKey(const ValueKey('spring-wire')), '10');
    await tester.pump();
    expect(emitted.length, before);
    expect(find.text('The mean diameter must be bigger than the wire diameter'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Confirm')).onPressed, isNull);
  });

  testWidgets('editing opens on the stored spring and shows what it works out to', (tester) async {
    await pumpPanel(
      tester,
      initial: const SpringDto(
        meanDiameter: 8,
        wireDiameter: 0.8,
        freeLength: 30,
        activeCoils: 9,
        startEnd: 'closed',
        finishEnd: 'open',
        rightHanded: false,
        activePitch: 3.1,
        totalCoils: 10,
        solidLength: 8.4,
      ),
    );
    expect(tester.widget<TextField>(find.byKey(const ValueKey('spring-length'))).controller!.text, '30');
    expect(find.text('Closed'), findsOneWidget);
    expect(find.text('Open'), findsOneWidget);
    expect(tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value, isFalse);
    expect(find.text('Working pitch 3.100, 10.00 coils in all, solid at 8.40'), findsOneWidget);
  });

  testWidgets('the keyboard lifts the panel', (tester) async {
    await pumpPanel(tester, keyboardHeight: 900);
    expect(tester.getBottomLeft(find.byType(Material).last).dy, lessThanOrEqualTo(2000 - 900 + 0.5));
    expect(tester.takeException(), isNull);
  });
}
