import 'dart:math' as math;

import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart' as vm;

import '../api/sketch_api_client.dart';
import 'mesh_geometry.dart' show kVertexMarkerWidth, vertexMarkerSegments;
import 'reference_planes.dart';

/// C3: a Sketch's local-(x, y) -> world embedding basis - either one of the
/// three fixed [ReferencePlaneKind]s ([SketchPlaneBasis.fixed]) or (new in
/// C3) an arbitrary `CreatePlaneFeature`'s own resolved orthonormal basis
/// ([SketchPlaneBasis.custom], built from the backend's `FeatureDto.origin`/
/// `xAxis`/`yAxis`/`normal` - see the backend's `ResolvedPlane`). Generalizes
/// what used to be a bare [ReferencePlaneKind] parameter throughout this
/// file, so a Sketch anchored to a custom plane renders/hit-tests exactly
/// like one on a fixed plane, just with a different (still orthonormal)
/// basis.
class SketchPlaneBasis {
  final vm.Vector3 origin;
  final vm.Vector3 xAxis;
  final vm.Vector3 yAxis;
  final vm.Vector3 normal;

  const SketchPlaneBasis({
    required this.origin,
    required this.xAxis,
    required this.yAxis,
    required this.normal,
  });

  /// The exact basis a fixed [ReferencePlaneKind] already implies - matches
  /// the backend's `app.document.plane_geometry._PLANE_BASIS` table (and so
  /// this class's [fixed] factory reproduces the same world points the old
  /// bare-[ReferencePlaneKind] switch statements below used to, for every
  /// pre-C3 fixed-plane Sketch).
  ///
  /// XZ's `xAxis` is `(-1, 0, 0)`, not `(1, 0, 0)` - confirmed as a real bug,
  /// not a pre-existing convention to preserve: `xAxis cross yAxis` must
  /// equal `normal` for a right-handed basis, and only `(-1,0,0)` satisfies
  /// that given `yAxis=(0,0,1)`/`normal=(0,1,0)` - `(1,0,0)` gave `xAxis
  /// cross yAxis = (0,-1,0) = -normal`, a left-handed basis unique to this
  /// one plane among the three. Every Sketch on the XZ plane was being built
  /// with inverted chirality as a result - see
  /// `backend/app/document/plane_geometry.py`'s own `_PLANE_BASIS` doc
  /// comment for the full derivation and the on-device report that surfaced
  /// it. `yAxis` was kept fixed deliberately: it means a Sketch's own local
  /// +Y ("up" on the 2D sketch canvas) still maps to world +Z on this plane,
  /// so the fix only flips the *horizontal* (local X) direction, not which
  /// way "up" points.
  factory SketchPlaneBasis.fixed(ReferencePlaneKind plane) => switch (plane) {
        ReferencePlaneKind.xy => SketchPlaneBasis(
            origin: vm.Vector3.zero(),
            xAxis: vm.Vector3(1, 0, 0),
            yAxis: vm.Vector3(0, 1, 0),
            normal: vm.Vector3(0, 0, 1),
          ),
        ReferencePlaneKind.xz => SketchPlaneBasis(
            origin: vm.Vector3.zero(),
            xAxis: vm.Vector3(-1, 0, 0),
            yAxis: vm.Vector3(0, 0, 1),
            normal: vm.Vector3(0, 1, 0),
          ),
        ReferencePlaneKind.yz => SketchPlaneBasis(
            origin: vm.Vector3.zero(),
            xAxis: vm.Vector3(0, 1, 0),
            yAxis: vm.Vector3(0, 0, 1),
            normal: vm.Vector3(1, 0, 0),
          ),
      };
}

/// Maps a Sketch-local 2D point onto its [basis] in 3D world space, for
/// rendering a Sketch's Lines/Circles in the 3D viewport - `origin + x *
/// xAxis + y * yAxis`, the same formula the backend's `ResolvedPlane`-based
/// embedding (`app.document.extrude.basis_point_to_world`) uses, so a
/// Sketch's own rendered geometry always lines up with where its Extrude
/// actually builds material.
vm.Vector3 sketchPointToWorld(SketchPlaneBasis basis, double x, double y) =>
    basis.origin + basis.xAxis * x + basis.yAxis * y;

/// The inverse of [sketchPointToWorld]: projects [point] onto [basis]'s
/// local 2D coordinates. Used for Stage 12's ghost wireframe overlay (see
/// [projectMeshEdgesOntoPlane]) - a plain dot-product projection against
/// [basis]'s own axes is exact (not an approximation) because [basis]'s
/// `xAxis`/`yAxis` are always orthonormal (guaranteed by the backend's
/// `ResolvedPlane`, fixed or custom alike).
(double, double) worldPointToSketch(SketchPlaneBasis basis, vm.Vector3 point) {
  final local = point - basis.origin;
  return (local.dot(basis.xAxis), local.dot(basis.yAxis));
}

/// Projects every mesh-edge [segments] pair (see [edgeSegmentsFromMesh] in
/// mesh_geometry.dart) onto [basis] via [worldPointToSketch] - the existing
/// solid's edges, flattened into the active Sketch's own 2D coordinate
/// space, ready for [SketchCanvas]'s ghost-overlay painter (Stage 12 item
/// 9). Plain `(double, double)` tuples rather than a Sketch-package type,
/// so this stays in viewport3d and the 2D sketch package doesn't need to
/// depend on it.
List<((double, double), (double, double))> projectMeshEdgesOntoPlane(
  SketchPlaneBasis basis,
  List<(vm.Vector3, vm.Vector3)> segments,
) =>
    [
      for (final segment in segments)
        (worldPointToSketch(basis, segment.$1), worldPointToSketch(basis, segment.$2)),
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
/// On-device feedback: Circles originally had no parallel id array (C1's
/// scope was Point/Line picking only), but a Circle can be its own closed
/// Profile (see `app.sketch.profile._circle_profile`) just as much as a
/// Line-chain loop can, and Prompt G's profile picker needs to let a user
/// tap one to pick it - [circleIds] (parallel to [circlePolygons]) closes
/// that gap, mirroring [lineIds] exactly.
class SketchGeometry3D {
  final List<(vm.Vector3, vm.Vector3)> lineSegments;
  final List<String> lineIds;
  final List<vm.Vector3> points;
  final List<String> pointIds;
  final List<List<vm.Vector3>> circlePolygons;
  final List<String> circleIds;

  const SketchGeometry3D({
    required this.lineSegments,
    required this.lineIds,
    required this.points,
    required this.pointIds,
    required this.circlePolygons,
    required this.circleIds,
  });

  static const empty = SketchGeometry3D(
    lineSegments: [],
    lineIds: [],
    points: [],
    pointIds: [],
    circlePolygons: [],
    circleIds: [],
  );

  bool get isEmpty => lineSegments.isEmpty && points.isEmpty && circlePolygons.isEmpty;
}

/// Builds [SketchGeometry3D] from a Sketch's raw DTOs - resolving each
/// Line's/Circle's point references against [points] and silently skipping
/// any that reference a missing point id (rather than throwing), since a
/// transient inconsistency here should degrade to "one segment missing", not
/// break the whole 3D viewport.
SketchGeometry3D sketchGeometry3DFrom({
  required SketchPlaneBasis basis,
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
      sketchPointToWorld(basis, start.x, start.y),
      sketchPointToWorld(basis, end.x, end.y),
    ));
    lineIds.add(line.id);
  }

  final worldPoints = [for (final p in points) sketchPointToWorld(basis, p.x, p.y)];
  final pointIds = [for (final p in points) p.id];

  final circlePolygons = <List<vm.Vector3>>[];
  final circleIds = <String>[];
  for (final circle in circles) {
    final center = pointsById[circle.centerPointId];
    if (center == null) continue;
    final polygon = <vm.Vector3>[];
    for (var i = 0; i <= circleSegments3D; i++) {
      final angle = 2 * math.pi * i / circleSegments3D;
      final x = center.x + circle.radius * math.cos(angle);
      final y = center.y + circle.radius * math.sin(angle);
      polygon.add(sketchPointToWorld(basis, x, y));
    }
    circlePolygons.add(polygon);
    circleIds.add(circle.id);
  }

  return SketchGeometry3D(
    lineSegments: lineSegments,
    lineIds: lineIds,
    points: worldPoints,
    pointIds: pointIds,
    circlePolygons: circlePolygons,
    circleIds: circleIds,
  );
}

/// Neutral (non-axis-tinted) color for rendered Sketch geometry, fully
/// opaque - deliberately distinct from the reference planes' tints so a
/// Sketch's real Lines/Circles always read clearly against its plane.
final vm.Vector4 sketchLineColor = vm.Vector4(0.85, 0.85, 0.85, 1.0);
const double sketchLineWidth = 2.0;

/// Builds the [Node] rendering one Feature's [geometry] - one
/// [MeshPrimitive] per Line segment, Circle outline, and Point marker,
/// combined into a single [Mesh] so they share one [Node]/transform and so a
/// single per-frame primitive scan (see `PartViewport`'s `_ScenePainter`)
/// reaches every `PolylineGeometry` needing `updateForCamera`.
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
