import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:didsa_cad_client/sketch/plane_indicator.dart';

void main() {
  testWidgets('renders nothing while the plane is still unknown', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: PlaneIndicator(plane: null)));

    expect(find.byType(PlaneIndicator), findsOneWidget);
    expect(find.text('XY'), findsNothing);
    expect(find.text('XZ'), findsNothing);
    expect(find.text('YZ'), findsNothing);
  });

  for (final plane in ['XY', 'XZ', 'YZ']) {
    testWidgets('shows the "$plane" label once the active plane is known', (tester) async {
      await tester.pumpWidget(MaterialApp(home: PlaneIndicator(plane: plane)));

      expect(find.text(plane), findsOneWidget);
    });
  }
}
