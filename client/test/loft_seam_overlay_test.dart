import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart' as vm;

import 'package:didsa_cad_client/api/document_api_client.dart';
import 'package:didsa_cad_client/viewport3d/loft_seam_overlay.dart';
import 'package:didsa_cad_client/viewport3d/orthographic_camera.dart';

void main() {
  const viewportSize = Size(800, 600);
  // Straight-on orthographic view of the XY plane: world (x, y) maps to a predictable screen spot
  // (halfHeight 5 -> 60 px per unit, y up, centre at (400, 300)).
  final camera = OrthographicCamera(
    position: vm.Vector3(0, 0, 10),
    target: vm.Vector3.zero(),
    up: vm.Vector3(0, 1, 0),
    halfHeight: 5,
  );

  // A 4x4 square sampled at 16 points from its first corner (-2, -2), counter-clockwise.
  List<vm.Vector3> squareSamples() {
    final corners = [(-2.0, -2.0), (2.0, -2.0), (2.0, 2.0), (-2.0, 2.0)];
    final points = <vm.Vector3>[];
    for (var i = 0; i < 16; i++) {
      final side = i ~/ 4;
      final t = (i % 4) / 4;
      final a = corners[side];
      final b = corners[(side + 1) % 4];
      points.add(vm.Vector3(a.$1 + t * (b.$1 - a.$1), a.$2 + t * (b.$2 - a.$2), 0));
    }
    return points;
  }

  final polyline = loftSeamScreenPolyline(camera, viewportSize, null, squareSamples());

  group('profile projection', () {
    test('a marker position follows the profile, and wraps past the last sample', () {
      final start = loftSeamScreenPosition(polyline, 0)!;
      expect(start.dx, closeTo(400 - 120, 1e-3));
      expect(start.dy, closeTo(300 + 120, 1e-3)); // sketch y up = screen y down
      final nextCorner = loftSeamScreenPosition(polyline, 0.25)!;
      expect(nextCorner.dx, closeTo(400 + 120, 1e-3));
      expect(loftSeamScreenPosition(polyline, 1.0)!.dx, closeTo(start.dx, 1e-3));
    });

    test('the fraction for a screen point is that of the nearest point on the profile', () {
      // Beside the middle of the first (bottom) edge, a little below it.
      final fraction = loftSeamFractionForScreenPoint(polyline, const Offset(400, 300 + 120 + 30))!;
      expect(fraction, closeTo(0.125, 1e-3));
      // Near the top-right corner.
      expect(loftSeamFractionForScreenPoint(polyline, const Offset(400 + 130, 300 - 130))!, closeTo(0.5, 1e-3));
    });

    test('returns null when nothing is visible', () {
      expect(loftSeamFractionForScreenPoint(const [null, null, null], Offset.zero), isNull);
      expect(loftSeamScreenPosition(const [], 0.3), isNull);
    });
  });

  testWidgets('dragging a marker along the profile reports the new seam fraction', (tester) async {
    final reported = <(int, double)>[];
    final handles = <LoftSeamHandleDto?>[
      null, // a section without a seam is skipped
      LoftSeamHandleDto(points: squareSamples(), seamParam: 0, reverse: false, auto: true),
    ];
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = viewportSize;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: LoftSeamOverlay(
          camera: camera,
          viewportSize: viewportSize,
          handles: handles,
          onSeamChanged: (index, fraction) => reported.add((index, fraction)),
        ),
      ),
    ));

    // The marker for section 1 starts on the first corner, at screen (280, 420).
    final handle = find.byKey(const ValueKey('loft-seam-handle-1'));
    expect(handle, findsOneWidget);
    expect(find.byKey(const ValueKey('loft-seam-handle-0')), findsNothing);

    // Drag it along the bottom edge to its middle.
    await tester.dragFrom(const Offset(280, 420), const Offset(120, 0));
    await tester.pump();

    expect(reported, isNotEmpty);
    expect(reported.every((entry) => entry.$1 == 1), isTrue);
    expect(reported.last.$2, closeTo(0.125, 0.02));
  });

  testWidgets('a press on a marker is claimed by it; a press anywhere else still reaches the viewport below',
      (tester) async {
    final underneath = <Offset>[];
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = viewportSize;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Stack(
          children: [
            // Stands in for PartViewport's own camera-orbit Listener.
            Listener(
              behavior: HitTestBehavior.opaque,
              onPointerDown: (event) => underneath.add(event.position),
              child: const SizedBox.expand(),
            ),
            LoftSeamOverlay(
              camera: camera,
              viewportSize: viewportSize,
              handles: [LoftSeamHandleDto(points: squareSamples(), seamParam: 0, reverse: false, auto: true)],
              onSeamChanged: (_, __) {},
            ),
          ],
        ),
      ),
    ));

    await tester.tapAt(const Offset(280, 420)); // on the marker
    await tester.tapAt(const Offset(700, 100)); // empty space
    expect(underneath, [const Offset(700, 100)]);
  });
}
