import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:didsa_cad_client/viewport3d/multi_select_action_bar.dart';

/// Bug report 2026-10-14, item 4: the bar now lives in the tree panel's
/// header, which on a portrait phone is 66% of the screen wide by default and
/// can be dragged much narrower. It must scale down, not overflow.
void main() {
  for (final width in [260.0, 160.0, 120.0]) {
    testWidgets('fits a ${width.toInt()}px-wide header with every action, no overflow', (tester) async {
      var cancelled = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: width,
                child: MultiSelectActionBar(
                  count: 1,
                  allHidden: false,
                  onToggleVisibility: () {},
                  onDelete: () {},
                  onCancel: () => cancelled++,
                  onMore: () {},
                ),
              ),
            ),
          ),
        ),
      );

      expect(tester.takeException(), isNull);
      expect(find.text('Hide'), findsOneWidget);
      expect(find.text('Delete'), findsOneWidget);
      expect(find.byTooltip('More actions'), findsOneWidget);
      final cancel = find.widgetWithIcon(IconButton, Icons.close);
      expect(cancel, findsOneWidget);
      await tester.tap(cancel);
      expect(cancelled, 1);
    });
  }
}
