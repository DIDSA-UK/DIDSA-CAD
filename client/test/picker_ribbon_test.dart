import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:didsa_cad_client/viewport3d/picker_ribbon.dart';

/// On-device feedback ("the tooltip at the top of the screen blocks the
/// FABs"): [PickerRibbon] replaces the separate full-width `top: 8` banner
/// (plus, for some modes, a separate floating checkmark FAB) that the five
/// pure viewport-picking modes with no panel of their own (Sweep's path
/// picker, the Profile picker, plane-selection-for-new-Sketch, Mirror's/
/// Pattern's body-picking steps) used to show.
void main() {
  testWidgets('shows the title, a divider, and the tooltip', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PickerRibbon(title: 'Path', tooltip: 'Tap a line to start the path', onCancel: () {}),
        ),
      ),
    );

    expect(find.text('Path'), findsOneWidget);
    expect(find.text('Tap a line to start the path'), findsOneWidget);
    expect(find.byType(VerticalDivider), findsOneWidget);
  });

  testWidgets('tapping Cancel fires onCancel', (tester) async {
    var cancelled = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PickerRibbon(title: 'Path', tooltip: 'tooltip', onCancel: () => cancelled = true),
        ),
      ),
    );

    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    expect(cancelled, isTrue);
  });

  testWidgets('showConfirm false (auto-advance modes) shows no confirm button at all', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PickerRibbon(title: 'Pattern', tooltip: 'Select Body to Pattern', onCancel: () {}),
        ),
      ),
    );

    expect(find.byIcon(Icons.check), findsNothing);
  });

  testWidgets('showConfirm true with null onConfirm shows a disabled confirm button, not a hidden one', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PickerRibbon(title: 'Path', tooltip: 'tooltip', onCancel: () {}, showConfirm: true),
        ),
      ),
    );

    final button = tester.widget<IconButton>(find.widgetWithIcon(IconButton, Icons.check));
    expect(button.onPressed, isNull);
  });

  testWidgets('showConfirm true with a non-null onConfirm shows an enabled confirm button that fires it', (
    tester,
  ) async {
    var confirmed = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PickerRibbon(
            title: 'Path',
            tooltip: 'tooltip',
            onCancel: () {},
            showConfirm: true,
            onConfirm: () => confirmed = true,
          ),
        ),
      ),
    );

    await tester.tap(find.widgetWithIcon(IconButton, Icons.check));
    expect(confirmed, isTrue);
  });

  group('Pattern/Mirror scoping Phase 6: extraActionLabel/onExtraAction', () {
    testWidgets('null extraActionLabel (the default) shows no extra button', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PickerRibbon(title: 'Pattern', tooltip: 'Select Body to Pattern', onCancel: () {}),
          ),
        ),
      );

      expect(find.text('Select Feature'), findsNothing);
    });

    testWidgets('a non-null extraActionLabel shows the extra button, and tapping it fires onExtraAction', (
      tester,
    ) async {
      var tapped = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PickerRibbon(
              title: 'Pattern',
              tooltip: 'Select Body to Pattern',
              onCancel: () {},
              extraActionLabel: 'Select Feature',
              onExtraAction: () => tapped = true,
            ),
          ),
        ),
      );

      expect(find.text('Select Feature'), findsOneWidget);
      await tester.tap(find.text('Select Feature'));
      expect(tapped, isTrue);
    });

    testWidgets(
        'title/tooltip row and the button row (extraAction + Cancel + Confirm) do not overflow on a '
        'narrow phone-width screen', (tester) async {
      // On-device feedback: title + divider + tooltip + "Select Feature" +
      // Cancel + Confirm used to all share one Row, which overflowed
      // ("RIGHT OVERFLOWED BY 2.6 PIXELS") on a real phone-width screen the
      // moment extraActionLabel was set. Buttons now live on their own row
      // below the title/tooltip row, so this must render with zero
      // overflow even at a narrow width.
      await tester.binding.setSurfaceSize(const Size(320, 640));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PickerRibbon(
              title: 'Pattern',
              tooltip: 'Select Body to Pattern',
              onCancel: () {},
              showConfirm: true,
              onConfirm: () {},
              extraActionLabel: 'Select Feature',
              onExtraAction: () {},
            ),
          ),
        ),
      );

      expect(tester.takeException(), isNull);
      expect(find.text('Select Feature'), findsOneWidget);
      expect(find.text('Cancel'), findsOneWidget);
      expect(find.byIcon(Icons.check), findsOneWidget);
    });
  });
}
