import 'dart:math' as math;

import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart' as vm;

import '../api/sketch_api_client.dart';
import 'mesh_geometry.dart' show kVertexMarkerWidth, vertexMarkerSegments;
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

/// The inverse of [sketchPointToWorld]: drops [point]'s off-plane axis to
/// project it onto [plane]'s local 2D coordinates. Used for Stage 12's
/// ghost wireframe overlay (see [projectMeshEdgesOntoPlane]) - an orthogonal
/// drop-the-normal-axis projection is exact (not an approximation) because
/// every [ReferencePlaneKind] is itself axis-aligned through the origin.
(double, double) worldPointToSketch(ReferencePlaneKind plane, vm.Vector3 point) => switch (plane) {
      ReferencePlaneKind.xy => (point.x, point.y),
      ReferencePlaneKind.xz => (point.x, point.z),
      ReferencePlaneKind.yz => (point.y, point.z),
    };

/// Projects every mesh-edge [segments] pair (see [edgeSegmentsFromMesh] in
/// mesh_geometry.dart) onto [plane] via [worldPointToSketch] - the existing
/// solid's edges, flattened into the active Sketch's own 2D coordinate
/// space, ready for [SketchCanvas]'s ghost-overlay painter (Stage 12 item
/// 9). Plain `(double, double)` tuples rather than a Sketch-package type,
/// so this stays in viewport3d and the 2D sketch package doesn't need to
/// depend on it.
List<((double, double), (double, double))> projectMeshEdgesOntoPlane(
  ReferencePlaneKind plane,
  List<(vm.Vector3, vm.Vector3)> segments,
) =>
    [
      for (final segment in segments)
        (worldPointToSketch(plane, segment.$1), worldPointToSketch(plane, segment.$2)),
    ];

/// Segments approximating a rendered Circle outline - high enough to read as
/// round at [referencePlaneSize]-ish scales without costing much per circle.
const int circleSegments3D = 32;

/// Pure, GPU-independent description of one Sketch's Points/Lines/Circles
/// already projected into 3D world space via [sketchPointToWorld] - the
/// testable counterpart to [buildSketchGeometryNode] below.
///
/// Prompt C1: [points]/[pointIds] and [lineIds] (parallel to [lineSegments])
/// were added so the 3D viewport's hit-testing can resolve a ray hit back to
/// a real backend `Point`/Line id (see `selection_hit_test.dart`'s
/// `hitTestBodies`) - before this prompt, this type only carried enough
/// data to *draw* a Sketch's geometry, never enough to select any of it.
/// Circles are deliberately not given a parallel id array here - C1's scope
/// is Point/Line picking only (see its own doc comment for why Circle
/// picking is flagged as future work, not built now).
class SketchGeometry3D {
  final List<(vm.Vector3, vm.Vector3)> lineSegments;
  final List<String> lineIds;
  final List<vm.Vector3> points;
  final List<String> pointIds;
  final List<List<vm.Vector3>> circlePolygons;

  const SketchGeometry3D({
    required this.lineSegments,
    required this.lineIds,
    required this.points,
    required this.pointIds,
    required this.circlePolygons,
  });

  static const empty =
      SketchGeometry3D(lineSegments: [], lineIds: [], points: [], pointIds: [], circlePolygons: []);

  bool get isEmpty => lineSegments.isEmpty && points.isEmpty && circlePolygons.isEmpty;
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
  final lineIds = <String>[];
  for (final line in lines) {
    final start = pointsById[line.startPointId];
    final end = pointsById[line.endPointId];
    if (start == null || end == null) continue;
    lineSegments.add((
      sketchPointToWorld(plane, start.x, start.y),
      sketchPointToWorld(plane, end.x, end.y),
    ));
    lineIds.add(line.id);
  }

  final worldPoints = [for (final p in points) sketchPointToWorld(plane, p.x, p.y)];
  final pointIds = [for (final p in points) p.id];

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

  return SketchGeometry3D(
    lineSegments: lineSegments,
    lineIds: lineIds,
    points: worldPoints,
    pointIds: pointIds,
    circlePolygons: circlePolygons,
  );
}

/// Neutral (non-axis-tinted) color for rendered Sketch geometry, fully
/// opaque - deliberately distinct from the reference planes' tints so a
/// Sketch's real Lines/Circles always read clearly against its plane.
final vm.Vector4 sketchLineColor = vm.Vector4(0.85, 0.85, 0.85, 1.0);
const double sketchLineWidth = 2.0;

/// Prompt C1: alpha for a Sketch whose Feature is only rendered/pickable
/// because of the auto-hidden-when-consumed exception (see `PartScreen`'s
/// `_autoHiddenSketchFeatureIds`) rather than genuinely visible - dimmer
/// than [sketchLineColor]'s fully-opaque look so a consumed Sketch's profile
/// still reads visually as "not the active/driving one" while remaining
/// exactly as pickable. Uses [AlphaMode.blend] rather than a darker opaque
/// color: this geometry is thin polylines with no fill to occlude, so this
/// doesn't risk the translucent-pass occlusion bug documented on
/// `buildHighlightFacesNode`/`buildMeshEdgesNode` (that bug is about solid
/// geometry being wrongly seen *through*, not about a polyline's own alpha).
final vm.Vector4 sketchLineDimmedColor = vm.Vector4(0.85, 0.85, 0.85, 0.35);

/// Builds the [Node] rendering one Feature's [geometry] - one
/// [MeshPrimitive] per Line segment, Circle outline, and Point marker,
/// combined into a single [Mesh] so they share one [Node]/transform and so a
/// single per-frame primitive scan (see `PartViewport`'s `_ScenePainter`)
/// reaches every `PolylineGeometry` needing `updateForCamera`.
///
/// Prompt C1: [dimmed] switches to [sketchLineDimmedColor]/[AlphaMode.blend]
/// for a Sketch that's only shown because it's consumed (see
/// [sketchLineDimmedColor]'s own doc comment) - `PartScreen` decides which
/// Features qualify.
///
/// Point markers reuse [vertexMarkerSegments]' "near-zero segment + round
/// cap" trick (see `mesh_geometry.dart`) rather than calling
/// [buildVertexMarkersNode] directly, so they stay [MeshPrimitive]s of this
/// same [Node]/[Mesh] instead of a second Node.
///
/// GPU-bound (`PolylineGeometry`'s own underlying updatable `MeshGeometry`),
/// so - like [buildReferencePlaneNode] - this cannot be exercised in a
/// headless `flutter test` run. [sketchGeometry3DFrom] above is the pure,
/// testable counterpart for the coordinate-mapping/geometry-layout logic.
Node buildSketchGeometryNode(String featureId, SketchGeometry3D geometry, {bool dimmed = false}) {
  final material = UnlitMaterial()
    ..alphaMode = dimmed ? AlphaMode.blend : AlphaMode.opaque
    ..baseColorFactor = dimmed ? sketchLineDimmedColor : sketchLineColor;

  final primitives = <MeshPrimitive>[
    for (final segment in geometry.lineSegments)
      MeshPrimitive(
        PolylineGeometry([segment.$1, segment.$2], width: sketchLineWidth),
        material,
      ),
    for (final polygon in geometry.circlePolygons)
      MeshPrimitive(PolylineGeometry(polygon, width: sketchLineWidth), material),
    for (final segment in vertexMarkerSegments(geometry.points))
      MeshPrimitive(
        PolylineGeometry(
          [segment.$1, segment.$2],
          width: kVertexMarkerWidth,
          cap: PolylineCap.round,
        ),
        material,
      ),
  ];

  return Node(name: 'sketch-$featureId', mesh: Mesh.primitives(primitives: primitives));
}
