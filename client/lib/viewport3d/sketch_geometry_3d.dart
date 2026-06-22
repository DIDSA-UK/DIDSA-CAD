import 'dart:math' as math;

import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart' as vm;

import '../api/sketch_api_client.dart';
import 'reference_planes.dart';

/// Maps a Sketch-local 2D point onto its [plane] in 3D world space, for
/// rendering a Sketch's Lines/Circles in the 3D viewport.
///
/// Sketch-local coordinates had no pre-existing 3D convention to conflict
/// with (Sketch content was only ever rendered in the flat 2D canvas before
/// this stage), so this adopts the brief's own suggested mapping verbatim:
/// XY: `(x, y) -> (x, y, 0)`; XZ: `(x, y) -> (x, 0, y)` (local y becomes
/// world Z); YZ: `(x, y) -> (0, x, y)` (local x becomes world Y). Each of
/// these places the sketch flush on its own [ReferencePlaneKind] plane
/// (matching [ReferencePlaneKindX.localTransform]'s zeroed axis).
vm.Vector3 sketchPointToWorld(ReferencePlaneKind plane, double x, double y) => switch (plane) {
      ReferencePlaneKind.xy => vm.Vector3(x, y, 0),
      ReferencePlaneKind.xz => vm.Vector3(x, 0, y),
      ReferencePlaneKind.yz => vm.Vector3(0, x, y),
    };

/// Segments approximating a rendered Circle outline - high enough to read as
/// round at [referencePlaneSize]-ish scales without costing much per circle.
const int circleSegments3D = 32;

/// Pure, GPU-independent description of one Sketch's Lines/Circles already
/// projected into 3D world space via [sketchPointToWorld] - the testable
/// counterpart to [buildSketchGeometryNode] below.
class SketchGeometry3D {
  final List<(vm.Vector3, vm.Vector3)> lineSegments;
  final List<List<vm.Vector3>> circlePolygons;

  const SketchGeometry3D({required this.lineSegments, required this.circlePolygons});

  static const empty = SketchGeometry3D(lineSegments: [], circlePolygons: []);

  bool get isEmpty => lineSegments.isEmpty && circlePolygons.isEmpty;
}

/// Builds [SketchGeometry3D] from a Sketch's raw DTOs - resolving each
/// Line's/Circle's point references against [points] and silently skipping
/// any that reference a missing point id (rather than throwing), since a
/// transient inconsistency here should degrade to "one segment missing", not
/// break the whole 3D viewport.
SketchGeometry3D sketchGeometry3DFrom({
  required ReferencePlaneKind plane,
  required List<PointDto> points,
  required List<LineDto> lines,
  required List<CircleDto> circles,
}) {
  final pointsById = {for (final p in points) p.id: p};

  final lineSegments = <(vm.Vector3, vm.Vector3)>[];
  for (final line in lines) {
    final start = pointsById[line.startPointId];
    final end = pointsById[line.endPointId];
    if (start == null || end == null) continue;
    lineSegments.add((
      sketchPointToWorld(plane, start.x, start.y),
      sketchPointToWorld(plane, end.x, end.y),
    ));
  }

  final circlePolygons = <List<vm.Vector3>>[];
  for (final circle in circles) {
    final center = pointsById[circle.centerPointId];
    if (center == null) continue;
    final polygon = <vm.Vector3>[];
    for (var i = 0; i <= circleSegments3D; i++) {
      final angle = 2 * math.pi * i / circleSegments3D;
      final x = center.x + circle.radius * math.cos(angle);
      final y = center.y + circle.radius * math.sin(angle);
      polygon.add(sketchPointToWorld(plane, x, y));
    }
    circlePolygons.add(polygon);
  }

  return SketchGeometry3D(lineSegments: lineSegments, circlePolygons: circlePolygons);
}

/// Neutral (non-axis-tinted) color for rendered Sketch geometry, fully
/// opaque - deliberately distinct from the reference planes' tints so a
/// Sketch's real Lines/Circles always read clearly against its plane.
final vm.Vector4 sketchLineColor = vm.Vector4(0.85, 0.85, 0.85, 1.0);
const double sketchLineWidth = 2.0;

/// Builds the [Node] rendering one Feature's [geometry] - one
/// [MeshPrimitive] per Line segment and per Circle outline, combined into a
/// single [Mesh] so they share one [Node]/transform and so a single
/// per-frame primitive scan (see `PartViewport`'s `_ScenePainter`) reaches
/// every `PolylineGeometry` needing `updateForCamera`.
///
/// GPU-bound (`PolylineGeometry`'s own underlying updatable `MeshGeometry`),
/// so - like [buildReferencePlaneNode] - this cannot be exercised in a
/// headless `flutter test` run. [sketchGeometry3DFrom] above is the pure,
/// testable counterpart for the coordinate-mapping/geometry-layout logic.
Node buildSketchGeometryNode(String featureId, SketchGeometry3D geometry) {
  final material = UnlitMaterial()
    ..alphaMode = AlphaMode.opaque
    ..baseColorFactor = sketchLineColor;

  final primitives = <MeshPrimitive>[
    for (final segment in geometry.lineSegments)
      MeshPrimitive(
        PolylineGeometry([segment.$1, segment.$2], width: sketchLineWidth),
        material,
      ),
    for (final polygon in geometry.circlePolygons)
      MeshPrimitive(PolylineGeometry(polygon, width: sketchLineWidth), material),
  ];

  return Node(name: 'sketch-$featureId', mesh: Mesh.primitives(primitives: primitives));
}
