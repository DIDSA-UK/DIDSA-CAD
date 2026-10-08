import 'package:didsa_cad_client/sketch/sketch_controller.dart';
import 'package:didsa_cad_client/viewport3d/orthographic_camera.dart';
import 'package:didsa_cad_client/viewport3d/sketch_constraint_overlay.dart';
import 'package:didsa_cad_client/viewport3d/sketch_geometry_3d.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart' as vm;

/// DIDSA-VR plan, phase 3: a persistent reference (driven) dimension in the 3D overlay: drawn as a bracketed value between what it measures, and never a tap
/// target (it is removed from the Dimension bar, not by tapping it on the canvas). The 2D canvas draws the same from `SketchController.referenceDimensionLabels`.
void main() {
  final basis = SketchPlaneBasis(
    origin: vm.Vector3.zero(),
    xAxis: vm.Vector3(1, 0, 0),
    yAxis: vm.Vector3(0, 1, 0),
    normal: vm.Vector3(0, 0, 1),
  );
  const viewportSize = Size(400, 300);
  final camera = OrthographicCamera(
    position: vm.Vector3(0, 0, 10),
    target: vm.Vector3.zero(),
    up: vm.Vector3(0, 1, 0),
    halfHeight: 5,
  );
  const item = ReferenceDimensionItem(
    constraintId: 'reference:r1',
    selected: false,
    anchorA: (-2.0, 0.0),
    anchorB: (2.0, 0.0),
    text: '(12.5)',
  );

  test('a reference dimension takes no taps: it has no label centre to hit-test', () {
    expect(constraintOverlayItemLabelCenter(camera, viewportSize, basis, item), isNull);
  });

  test('two equal reference dimension items compare equal, so the overlay does not repaint for nothing', () {
    const same = ReferenceDimensionItem(
      constraintId: 'reference:r1',
      selected: false,
      anchorA: (-2.0, 0.0),
      anchorB: (2.0, 0.0),
      text: '(12.5)',
    );
    expect(same, item);
    expect(same.hashCode, item.hashCode);
    expect(
      const ReferenceDimensionItem(constraintId: 'reference:r1', selected: false, anchorA: (-2.0, 0.0), anchorB: (2.0, 0.0), text: '(13)'),
      isNot(item),
    );
  });

  testWidgets('the overlay paints a reference dimension without error and without catching taps', (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => taps++,
            child: SizedBox(
              width: 400,
              height: 300,
              child: ConstraintOverlay(camera: camera, viewportSize: viewportSize, basis: basis, items: const [item]),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.byType(ConstraintOverlay), findsOneWidget);
    await tester.tapAt(const Offset(200, 150));
    expect(taps, 1); // the overlay is IgnorePointer: the tap reached what is under it
  });
}
