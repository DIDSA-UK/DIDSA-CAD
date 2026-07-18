import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart' as vm;

import 'package:didsa_cad_client/viewport3d/sketch_geometry_3d.dart';

void main() {
  final xyBasis = SketchPlaneBasis(
    origin: vm.Vector3.zero(),
    xAxis: vm.Vector3(1, 0, 0),
    yAxis: vm.Vector3(0, 1, 0),
    normal: vm.Vector3(0, 0, 1),
  );

  test('spans [-extent, extent] at the given spacing, both directions', () {
    final segments = sketchGridLinesFrom(xyBasis, spacing: 1, extent: 2);

    // 5 offsets (-2, -1, 0, 1, 2) each producing one "horizontal" and one
    // "vertical" line.
    expect(segments.length, 10);

    // The centre horizontal line (y = 0) spans the full extent in x.
    final centreHorizontal = segments.firstWhere((s) => s.$1.y == 0 && s.$1.x == -2);
    expect(centreHorizontal.$1, vm.Vector3(-2, 0, 0));
    expect(centreHorizontal.$2, vm.Vector3(2, 0, 0));

    // The centre vertical line (x = 0) spans the full extent in y.
    final centreVertical = segments.firstWhere((s) => s.$1.x == 0 && s.$1.y == -2);
    expect(centreVertical.$1, vm.Vector3(0, -2, 0));
    expect(centreVertical.$2, vm.Vector3(0, 2, 0));

    // Every point stays exactly on the basis's own plane (z = 0) - the
    // small render-only offset used for on-screen z-fighting avoidance
    // lives in the GPU-facing builder's own Node transform now, not here
    // (see sketch_geometry_3d.dart's own doc comment on why).
    for (final segment in segments) {
      expect(segment.$1.z, 0);
      expect(segment.$2.z, 0);
    }
  });

  test('an arbitrary tilted/offset custom plane places every segment endpoint exactly on the basis', () {
    final normal = vm.Vector3(1, 1, 1).normalized();
    final xAxis = (vm.Vector3(1, -1, 0)).normalized();
    final yAxis = normal.cross(xAxis).normalized();
    final basis = SketchPlaneBasis(origin: vm.Vector3(5, 5, 5), xAxis: xAxis, yAxis: yAxis, normal: normal);

    final segments = sketchGridLinesFrom(basis, spacing: 2, extent: 4);

    expect(segments, isNotEmpty);
    for (final segment in segments) {
      final (localX1, localY1) = worldPointToSketch(basis, segment.$1);
      final (localX2, localY2) = worldPointToSketch(basis, segment.$2);
      // Every endpoint's own local coordinates should be within [-extent,
      // extent] - i.e. the segment genuinely lies within the grid's bounds
      // once mapped back through the same basis.
      expect(localX1.abs(), lessThanOrEqualTo(4.0001));
      expect(localY1.abs(), lessThanOrEqualTo(4.0001));
      expect(localX2.abs(), lessThanOrEqualTo(4.0001));
      expect(localY2.abs(), lessThanOrEqualTo(4.0001));
    }
  });
}
