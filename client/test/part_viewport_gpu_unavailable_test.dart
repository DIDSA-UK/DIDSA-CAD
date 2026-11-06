import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:didsa_cad_client/api/document_api_client.dart';
import 'package:didsa_cad_client/viewport3d/gpu_unavailable.dart';
import 'package:didsa_cad_client/viewport3d/part_viewport.dart';

final _body = BodyMeshDto(
  bodyId: 'body-1',
  source: 'computed',
  mesh: MeshDto(
    vertices: [
      [0, 0, 0],
      [10, 0, 0],
      [0, 10, 0],
    ],
    normals: [
      [0, 0, 1],
      [0, 0, 1],
      [0, 0, 1],
    ],
    triangleIndices: [
      [0, 1, 2],
    ],
  ),
);

void main() {
  // flutter_scene 0.24 completes Scene.initializeStaticResources() with its
  // error when Flutter GPU is missing (every `flutter test` run). The viewport
  // must say so instead of showing an endless spinner or throwing.
  testWidgets('with no GPU the viewport shows the unavailable message and nothing throws', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            height: 400,
            child: PartViewport(
              bodies: [_body],
              selectedPlane: null,
              onPlaneTap: (_) {},
              onBackgroundTap: () {},
            ),
          ),
        ),
      ),
    );
    for (var i = 0; i < 100; i++) {
      if (find.byType(CircularProgressIndicator).evaluate().isEmpty) break;
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pump();

    // A machine with a working GPU would show the real viewport instead.
    if (find.byKey(gpuUnavailableKey).evaluate().isEmpty) {
      markTestSkipped('this machine has a working Flutter GPU, so there is no failure to show');
      return;
    }
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.textContaining('3D view unavailable on this device'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
