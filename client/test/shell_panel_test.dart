import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:didsa_cad_client/viewport3d/extrude_panel.dart' show ThicknessDirection;
import 'package:didsa_cad_client/viewport3d/shell_panel.dart';

/// Unit-level coverage for [ShellPanel] - mirrors `chamfer_panel_test.dart`'s
/// Confirm-enablement coverage, plus the face-count gate and the
/// [ThicknessDirection] segmented control.
void main() {
  Widget host({
    double initialThickness = 1.0,
    int faceCount = 1,
    void Function(double, ThicknessDirection)? onChanged,
  }) =>
      MaterialApp(
        home: Scaffold(
          body: ShellPanel(
            initialThickness: initialThickness,
            faceCount: faceCount,
            onChanged: onChanged,
            onConfirm: () {},
            onCancel: () {},
          ),
        ),
      );

  bool confirmEnabled(WidgetTester tester) =>
      tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Confirm')).onPressed != null;

  testWidgets('a valid thickness with a picked face is enabled', (tester) async {
    await tester.pumpWidget(host());
    expect(confirmEnabled(tester), isTrue);
    expect(find.text('Opening 1 face'), findsOneWidget);
  });

  testWidgets(
      'body-first session: opens with zero faces (Confirm disabled, pick hint shown), then the '
      'live count follows faces picked in the viewport', (tester) async {
    await tester.pumpWidget(host(faceCount: 0));
    expect(confirmEnabled(tester), isFalse);
    expect(find.text('Tap faces of the body to open them'), findsOneWidget);

    await tester.pumpWidget(host(faceCount: 2));
    expect(confirmEnabled(tester), isTrue);
    expect(find.text('Opening 2 faces'), findsOneWidget);

    await tester.pumpWidget(host(faceCount: 0));
    expect(confirmEnabled(tester), isFalse);
  });

  testWidgets('a zero thickness disables Confirm', (tester) async {
    await tester.pumpWidget(host(initialThickness: 0.0));
    expect(confirmEnabled(tester), isFalse);
  });

  testWidgets('emits the initial values, then direction changes', (tester) async {
    final calls = <(double, ThicknessDirection)>[];
    await tester.pumpWidget(host(initialThickness: 2.0, onChanged: (t, d) => calls.add((t, d))));
    await tester.pump();
    expect(calls, [(2.0, ThicknessDirection.outward)]);

    await tester.tap(find.text('In'));
    await tester.pump();
    expect(calls.last, (2.0, ThicknessDirection.inward));
  });
}
