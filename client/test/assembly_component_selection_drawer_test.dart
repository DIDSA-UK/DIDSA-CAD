import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:didsa_cad_client/api/document_api_client.dart';
import 'package:didsa_cad_client/viewport3d/assembly_component_selection_drawer.dart';

OccurrenceDto _occurrence({bool fixed = false, String? nameOverride, String? externalRef}) => OccurrenceDto(
      id: 'o1',
      externalRef: externalRef,
      nameOverride: nameOverride,
      transform: RigidTransformDto(translation: const [0, 0, 0], rotationAxis: const [0, 0, 1], rotationAngleDegrees: 0),
      fixed: fixed,
    );

void main() {
  Future<void> pumpDrawer(
    WidgetTester tester,
    OccurrenceDto occurrence, {
    VoidCallback? onMove,
    VoidCallback? onFixFloat,
    VoidCallback? onDelete,
  }) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(800, 1000);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Stack(
            children: [
              AssemblyComponentSelectionDrawer(
                selectedComponent: occurrence,
                onMove: onMove ?? () {},
                onFixFloat: onFixFloat ?? () {},
                onDelete: onDelete ?? () {},
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('shows the component name and Move / Fix / Delete actions', (tester) async {
    await pumpDrawer(tester, _occurrence(nameOverride: 'Bracket'));

    expect(find.text('Bracket'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Move'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Fix'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Delete'), findsOneWidget);
  });

  testWidgets('falls back to the external ref basename when there is no name override', (tester) async {
    await pumpDrawer(tester, _occurrence(externalRef: 'parts/bolt.DIDSAprt'));

    expect(find.text('bolt'), findsOneWidget);
  });

  testWidgets('the Fix button reads Float for an already-fixed component', (tester) async {
    await pumpDrawer(tester, _occurrence(fixed: true, nameOverride: 'Base'));

    expect(find.widgetWithText(FilledButton, 'Float'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Fix'), findsNothing);
  });

  testWidgets('each action button fires its own callback', (tester) async {
    var moved = 0, toggled = 0, deleted = 0;
    await pumpDrawer(
      tester,
      _occurrence(nameOverride: 'Bracket'),
      onMove: () => moved++,
      onFixFloat: () => toggled++,
      onDelete: () => deleted++,
    );

    await tester.tap(find.widgetWithText(FilledButton, 'Move'));
    await tester.tap(find.widgetWithText(FilledButton, 'Fix'));
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));

    expect([moved, toggled, deleted], [1, 1, 1]);
  });

  testWidgets('renders as a draggable sheet', (tester) async {
    await pumpDrawer(tester, _occurrence(nameOverride: 'Bracket'));

    expect(find.byType(DraggableScrollableSheet), findsOneWidget);
  });
}
