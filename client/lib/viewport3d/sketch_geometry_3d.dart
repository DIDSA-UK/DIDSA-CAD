import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show listEquals, setEquals;
import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart' as vm;

import '../api/document_api_client.dart' show MeshDto;
import '../api/sketch_api_client.dart';
import 'mesh_geometry.dart' show vertexMarkerSegments;
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

  /// Sketcher-roadmap Phase 5: [fixed]'s own xAxis/yAxis, with a Sketch's
  /// own `flip`/`rotationQuarterTurns` (see [SketchDto.flip]/
  /// [SketchDto.rotationQuarterTurns]) applied on top - mirrors the
  /// backend's `app.document.plane_geometry.oriented_basis_for_plane`
  /// exactly (same flip-then-rotate order, same "a 90-degree CCW turn maps
  /// xAxis -> yAxis, yAxis -> -xAxis" formula), so a Sketch's rendered
  /// geometry always lines up with where its Extrude actually builds
  /// material once the orientation is anything other than the default.
  factory SketchPlaneBasis.oriented(
    ReferencePlaneKind plane, {
    required bool flip,
    required int rotationQuarterTurns,
  }) =>
      SketchPlaneBasis.fixed(plane).withOrientation(flip: flip, rotationQuarterTurns: rotationQuarterTurns);

  /// [oriented]'s own flip-then-rotate transform, generalized to start from
  /// any orthonormal basis rather than only [fixed]'s three fixed planes -
  /// a custom (`create_plane`) plane's own resolved basis is exactly as
  /// valid a starting point (still just `origin`/`xAxis`/`yAxis`/`normal`),
  /// so a Sketch anchored to one can support the same flip/rotate
  /// orientation controls a fixed-plane Sketch already does. Bug fix: the
  /// orientation confirm step never triggered for a custom-plane Sketch at
  /// all - see `part_screen.dart`'s `_addSketchFeature`.
  SketchPlaneBasis withOrientation({required bool flip, required int rotationQuarterTurns}) {
    var xAxis = flip ? -this.xAxis : this.xAxis;
    var yAxis = this.yAxis;
    for (var i = 0; i < rotationQuarterTurns % 4; i++) {
      final nextX = yAxis;
      final nextY = -xAxis;
      xAxis = nextX;
      yAxis = nextY;
    }
    return SketchPlaneBasis(origin: origin, xAxis: xAxis, yAxis: yAxis, normal: normal);
  }
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

/// Sketcher-roadmap Phase 4.3 v1: the per-point analogue of
/// [projectMeshEdgesOntoPlane] - projects a Body's real B-rep vertices
/// (`MeshDto.topologyVertices`/`topologyVertexIds`, already computed
/// server-side independently of the triangle mesh - see
/// `backend/app/document/mesh.py`'s `_extract_topology_vertices`) onto
/// [basis], ready for [SketchCanvas]'s ghost-overlay pick targets. [bodyId]
/// is threaded through unchanged (not itself projected) so a picked ghost
/// vertex round-trips into a real `SubShapeRef`/materialize-a-Point call -
/// see [SketchController.pickReferenceGhostVertex].
List<(String, int, double, double)> projectMeshVerticesOntoPlane(
  SketchPlaneBasis basis,
  String bodyId,
  MeshDto mesh,
) {
  final result = <(String, int, double, double)>[];
  for (var i = 0; i < mesh.topologyVertices.length; i++) {
    final v = mesh.topologyVertices[i];
    final (x, y) = worldPointToSketch(basis, vm.Vector3(v[0], v[1], v[2]));
    result.add((bodyId, mesh.topologyVertexIds[i], x, y));
  }
  return result;
}

/// Sketcher-roadmap Phase 4.3 v2: the per-edge analogue of
/// [projectMeshVerticesOntoPlane] - projects a Body's real edge polylines
/// (`MeshDto.edges`/`edgeIds`, the same dense per-segment id
/// `SelectionEntityRef`'s own edge picking in the 3D viewport already
/// trusts as a `SubShapeRef.index` for Fillet/Chamfer - see
/// `selection_hit_test.dart`) onto [basis], ready for [SketchCanvas]'s
/// ghost-overlay pick targets. [bodyId]/edge id are threaded through
/// unchanged (not projected) so a picked ghost edge round-trips into a
/// real `SubShapeRef`/materialize-an-edge call - see
/// [SketchController.pickReferenceGhostEdge]. A curved edge's several
/// consecutive mesh segments all carry that edge's *same* id, exactly
/// like [edgeSegmentsFromMesh] (mesh_geometry.dart) already assumes for
/// rendering - deliberately a separate list from that one rather than
/// adding ids onto it, since [edgeSegmentsFromMesh]'s own id-less
/// segments still drive the unrelated Phase 4.1 ghost wireframe render
/// unchanged.
List<(String, int, (double, double), (double, double))> projectMeshEdgesOntoPlaneWithIds(
  SketchPlaneBasis basis,
  String bodyId,
  MeshDto mesh,
) {
  final result = <(String, int, (double, double), (double, double))>[];
  var segmentIndex = 0;
  for (var i = 0; i + 5 < mesh.edges.length; i += 6) {
    final start = worldPointToSketch(basis, vm.Vector3(mesh.edges[i], mesh.edges[i + 1], mesh.edges[i + 2]));
    final end =
        worldPointToSketch(basis, vm.Vector3(mesh.edges[i + 3], mesh.edges[i + 4], mesh.edges[i + 5]));
    result.add((bodyId, mesh.edgeIds[segmentIndex], start, end));
    segmentIndex++;
  }
  return result;
}

/// Segments approximating a rendered Circle/Ellipse outline - high enough to
/// read as round at [referencePlaneSize]-ish scales without costing much per
/// circle.
const int circleSegments3D = 32;

/// Segments approximating a rendered Arc outline - fewer than a full circle
/// since an Arc is only ever a partial sweep, not a full turn.
const int arcSegments3D = 24;

/// Segments approximating one cubic-Bezier Spline segment's curve.
const int splineSegmentSteps3D = 16;

/// Pure, GPU-independent description of one Sketch's Points/Lines/Circles/
/// Arcs/Ellipses/Splines already projected into 3D world space via
/// [sketchPointToWorld] - the testable counterpart to
/// [buildSketchGeometryNode] below.
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
///
/// Bug fix (on-device feedback): Arc/Ellipse/Spline never had any 3D
/// representation at all - [sketchGeometry3DFrom] only ever converted
/// Points/Lines/Circles, so a Sketch containing any of the three (or a
/// Slot/Text, both built from them - see that function's own doc comment)
/// silently drew nothing for those entities in the main 3D Part viewport,
/// even though the same Sketch rendered correctly on its own 2D canvas.
/// [arcPolylines]/[ellipsePolygons]/[splinePolylines] (each with a parallel
/// id array, mirroring [circlePolygons]/[circleIds]) close that gap -
/// hit-testing/selection for these three isn't wired up here (out of scope
/// for this fix, matching how Circle's own [circleIds] long predates any
/// Arc/Ellipse/Spline selection support), only rendering.
class SketchGeometry3D {
  final List<(vm.Vector3, vm.Vector3)> lineSegments;
  final List<String> lineIds;
  final List<vm.Vector3> points;
  final List<String> pointIds;
  final List<List<vm.Vector3>> circlePolygons;
  final List<String> circleIds;
  final List<List<vm.Vector3>> arcPolylines;
  final List<String> arcIds;
  final List<List<vm.Vector3>> ellipsePolygons;
  final List<String> ellipseIds;
  final List<List<vm.Vector3>> splinePolylines;
  final List<String> splineIds;

  /// P26 (2D-sketcher feature parity): the subset of [lineIds]/[circleIds]/
  /// [arcIds]/[ellipseIds]/[splineIds] flagged `construction` on their own
  /// DTO - [buildSketchGeometryNode] dashes exactly these, mirroring
  /// `sketch_canvas.dart`'s own dashed-stroke look for construction
  /// geometry. Points have no construction flag of their own (a Point is
  /// never itself "construction", only the Line/Circle/etc. built from it
  /// can be), so this only ever contains entries from those five id lists.
  final Set<String> constructionIds;

  /// On-device feedback (bug fix: a Circle's own outline vanishing
  /// entirely - fill still showing - whenever its centre Point was hidden
  /// by the hover-reveal feature): [points]/[pointIds] must stay the
  /// *complete* set every entity here resolves its own defining Points
  /// against (`sketchGeometry3DFrom`'s own `pointsById` lookups silently
  /// `continue`, dropping the whole entity, the moment one of its Points
  /// is missing) - so "hide this Point's marker until hover-revealed" can
  /// never be implemented by omitting it from that list, unlike
  /// `sketch_canvas.dart`'s own equivalent (which only ever gates its
  /// *drawing* loop, never touches the underlying Point map other
  /// entities resolve against). This is the 3D-embedded counterpart of
  /// that same gate instead: [buildSketchGeometryNode] skips creating a
  /// marker primitive for any id in here, while every entity referencing
  /// it still resolves normally.
  final Set<String> hiddenPointIds;

  const SketchGeometry3D({
    required this.lineSegments,
    required this.lineIds,
    required this.points,
    required this.pointIds,
    required this.circlePolygons,
    required this.circleIds,
    this.arcPolylines = const [],
    this.arcIds = const [],
    this.ellipsePolygons = const [],
    this.ellipseIds = const [],
    this.splinePolylines = const [],
    this.splineIds = const [],
    this.constructionIds = const <String>{},
    this.hiddenPointIds = const <String>{},
  });

  static const empty = SketchGeometry3D(
    lineSegments: [],
    lineIds: [],
    points: [],
    pointIds: [],
    circlePolygons: [],
    circleIds: [],
  );

  bool get isEmpty =>
      lineSegments.isEmpty &&
      points.isEmpty &&
      circlePolygons.isEmpty &&
      arcPolylines.isEmpty &&
      ellipsePolygons.isEmpty &&
      splinePolylines.isEmpty;
}

/// P27 bug fix (on-device feedback: Rectangle placement still froze/ANR'd
/// after the P23 colour-map caching fix): deep content equality for two
/// [SketchGeometry3D] instances - `sketch_screen.dart` builds a fresh
/// [SketchGeometry3D] (via [sketchGeometry3DFrom]) on every single
/// `SketchController` notification and needs this to decide whether the
/// result actually differs from what it built last time, exactly the same
/// "only build a new instance when content genuinely changed" contract
/// [PartViewport.sketchGeometries] itself already documents - a fresh
/// instance every rebuild, even with byte-for-byte identical content, was
/// forcing `PartViewport._syncSketchNodes()` (a full GPU teardown-and-
/// rebuild of every entity's `Node`/`MeshPrimitive`/`PolylineGeometry` in
/// the whole Sketch) on every rebuild - the other half of the same class of
/// bug the P23 colour-map fix addressed for `sketchEntityColors`, still
/// present here and apparently still enough on its own to explain the
/// continued freeze. [listEquals]/[setEquals] handle the flat `List`/`Set`
/// fields directly (a record like `(vm.Vector3, vm.Vector3)` and
/// `vm.Vector3`/`vm.Vector4` themselves already have proper structural
/// `==`); the four `List<List<vm.Vector3>>` fields need one extra level of
/// [listEquals] per element, since a plain `List`'s own `==` is identity-
/// based, not deep.
bool sketchGeometry3DEquals(SketchGeometry3D a, SketchGeometry3D b) {
  if (identical(a, b)) return true;
  bool nestedListEquals(List<List<vm.Vector3>> x, List<List<vm.Vector3>> y) {
    if (x.length != y.length) return false;
    for (var i = 0; i < x.length; i++) {
      if (!listEquals(x[i], y[i])) return false;
    }
    return true;
  }

  return listEquals(a.lineSegments, b.lineSegments) &&
      listEquals(a.lineIds, b.lineIds) &&
      listEquals(a.points, b.points) &&
      listEquals(a.pointIds, b.pointIds) &&
      nestedListEquals(a.circlePolygons, b.circlePolygons) &&
      listEquals(a.circleIds, b.circleIds) &&
      nestedListEquals(a.arcPolylines, b.arcPolylines) &&
      listEquals(a.arcIds, b.arcIds) &&
      nestedListEquals(a.ellipsePolygons, b.ellipsePolygons) &&
      listEquals(a.ellipseIds, b.ellipseIds) &&
      nestedListEquals(a.splinePolylines, b.splinePolylines) &&
      listEquals(a.splineIds, b.splineIds) &&
      setEquals(a.constructionIds, b.constructionIds) &&
      setEquals(a.hiddenPointIds, b.hiddenPointIds);
}

/// Builds [SketchGeometry3D] from a Sketch's raw DTOs - resolving each
/// Line's/Circle's/Arc's/Ellipse's/Spline's point references against
/// [points] and silently skipping any that reference a missing point id
/// (rather than throwing), since a transient inconsistency here should
/// degrade to "one entity missing", not break the whole 3D viewport.
///
/// [arcs]/[ellipses]/[splines] default to empty so every existing call site
/// (and every existing test constructing this) keeps compiling unchanged -
/// callers that actually want these rendered (currently only
/// `part_screen.dart`'s `_refreshSketchGeometries`) opt in explicitly. Slot
/// (two Arcs + two tangent Lines) and Polygon (only Lines) need no entry of
/// their own here - they're already covered once their component
/// Arc/Line entities are. Text is *not* covered (its own glyph outlines
/// come from a dedicated preview endpoint, not a Point/Line/Circle/Arc/
/// Ellipse/Spline entity) - a separate, larger piece of work, out of scope
/// for this fix.
SketchGeometry3D sketchGeometry3DFrom({
  required SketchPlaneBasis basis,
  required List<PointDto> points,
  required List<LineDto> lines,
  required List<CircleDto> circles,
  List<ArcDto> arcs = const [],
  List<EllipseDto> ellipses = const [],
  List<SplineDto> splines = const [],
  Set<String> hiddenPointIds = const <String>{},
}) {
  final pointsById = {for (final p in points) p.id: p};
  final constructionIds = <String>{};

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
    if (line.construction) constructionIds.add(line.id);
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
    if (circle.construction) constructionIds.add(circle.id);
  }

  // Bug fix: Arc/Ellipse/Spline previously had no 3D representation at all
  // - see this function's own doc comment.
  final arcPolylines = <List<vm.Vector3>>[];
  final arcIds = <String>[];
  for (final arc in arcs) {
    final center = pointsById[arc.centerPointId];
    final start = pointsById[arc.startPointId];
    final end = pointsById[arc.endPointId];
    if (center == null || start == null || end == null) continue;
    // Same CCW-from-start-to-end convention as `sketch_canvas.dart`'s own
    // `_arcScreenAngles`/`angleWithinArcSweep` (see the latter's own doc
    // comment) - the only difference is this operates in local sketch (x,
    // y) coordinates directly, with no screen-space Y-flip to undo.
    final startAngle = math.atan2(start.y - center.y, start.x - center.x);
    final endAngle = math.atan2(end.y - center.y, end.x - center.x);
    final sweep = _normalizeAngle(endAngle - startAngle);
    final polyline = <vm.Vector3>[];
    for (var i = 0; i <= arcSegments3D; i++) {
      final angle = startAngle + sweep * i / arcSegments3D;
      final x = center.x + arc.radius * math.cos(angle);
      final y = center.y + arc.radius * math.sin(angle);
      polyline.add(sketchPointToWorld(basis, x, y));
    }
    arcPolylines.add(polyline);
    arcIds.add(arc.id);
    if (arc.construction) constructionIds.add(arc.id);
  }

  final ellipsePolygons = <List<vm.Vector3>>[];
  final ellipseIds = <String>[];
  for (final ellipse in ellipses) {
    final center = pointsById[ellipse.centerPointId];
    if (center == null) continue;
    final majorRadius = ellipse.majorRadius;
    final minorRadius = ellipse.minorRadius;
    final cosR = math.cos(ellipse.rotation);
    final sinR = math.sin(ellipse.rotation);
    final polygon = <vm.Vector3>[];
    for (var i = 0; i <= circleSegments3D; i++) {
      final t = 2 * math.pi * i / circleSegments3D;
      final localX = majorRadius * math.cos(t);
      final localY = minorRadius * math.sin(t);
      final x = center.x + localX * cosR - localY * sinR;
      final y = center.y + localX * sinR + localY * cosR;
      polygon.add(sketchPointToWorld(basis, x, y));
    }
    ellipsePolygons.add(polygon);
    ellipseIds.add(ellipse.id);
    if (ellipse.construction) constructionIds.add(ellipse.id);
  }

  final splinePolylines = <List<vm.Vector3>>[];
  final splineIds = <String>[];
  for (final spline in splines) {
    final polyline = <vm.Vector3>[];
    var complete = true;
    for (var i = 0; i < spline.throughPointIds.length - 1; i++) {
      final p0 = pointsById[spline.throughPointIds[i]];
      final p1 = pointsById[spline.controlPointIds[2 * i]];
      final p2 = pointsById[spline.controlPointIds[2 * i + 1]];
      final p3 = pointsById[spline.throughPointIds[i + 1]];
      if (p0 == null || p1 == null || p2 == null || p3 == null) {
        complete = false;
        break;
      }
      final startStep = i == 0 ? 0 : 1; // Shares its start point with the previous segment's end.
      for (var step = startStep; step <= splineSegmentSteps3D; step++) {
        final t = step / splineSegmentSteps3D;
        final mt = 1 - t;
        final x = mt * mt * mt * p0.x +
            3 * mt * mt * t * p1.x +
            3 * mt * t * t * p2.x +
            t * t * t * p3.x;
        final y = mt * mt * mt * p0.y +
            3 * mt * mt * t * p1.y +
            3 * mt * t * t * p2.y +
            t * t * t * p3.y;
        polyline.add(sketchPointToWorld(basis, x, y));
      }
    }
    if (!complete || polyline.isEmpty) continue;
    splinePolylines.add(polyline);
    splineIds.add(spline.id);
    if (spline.construction) constructionIds.add(spline.id);
  }

  return SketchGeometry3D(
    lineSegments: lineSegments,
    lineIds: lineIds,
    points: worldPoints,
    pointIds: pointIds,
    circlePolygons: circlePolygons,
    circleIds: circleIds,
    arcPolylines: arcPolylines,
    arcIds: arcIds,
    ellipsePolygons: ellipsePolygons,
    ellipseIds: ellipseIds,
    splinePolylines: splinePolylines,
    splineIds: splineIds,
    constructionIds: constructionIds,
    hiddenPointIds: hiddenPointIds,
  );
}

/// Normalizes [angle] (radians) into `[0, 2*pi)` - a local copy of
/// `sketch_controller.dart`'s `normalizeSketchAngle` (that file isn't
/// importable here without pulling the whole 2D sketch controller into the
/// 3D viewport's dependency graph, and this is a two-line pure function).
double _normalizeAngle(double angle) {
  const twoPi = 2 * math.pi;
  final wrapped = angle % twoPi;
  return wrapped < 0 ? wrapped + twoPi : wrapped;
}

/// Neutral (non-axis-tinted) color for rendered Sketch geometry, fully
/// opaque - deliberately distinct from the reference planes' tints so a
/// Sketch's real Lines/Circles always read clearly against its plane.
final vm.Vector4 sketchLineColor = vm.Vector4(0.85, 0.85, 0.85, 1.0);
// P19 on-device feedback: thinner than the original 2.0/8.0 - both read as
// too thick once real geometry (not just the grid/plane backdrop) was
// visible to compare against. Later on-device feedback ("make sketch
// lines more visible, increase the thickness slightly") nudged this back
// up a bit from that pass's `1.2`.
const double sketchLineWidth = 1.5;

/// P19 on-device feedback: deliberately its own constant, not
/// [kVertexMarkerWidth] (`mesh_geometry.dart`'s shared default) - that
/// constant also sizes Selection mode's own selected-vertex highlight
/// markers ([buildVertexMarkersNode] call sites in `part_viewport.dart`),
/// which weren't part of this feedback and shouldn't shrink alongside a
/// Sketch's own drawn points. On-device feedback ("Points should be
/// visible with a diameter slightly larger than the sketch line width"):
/// derived from [sketchLineWidth] - earlier passes (1.3x, then 2.2x, then a
/// bare 9.0 while root-causing a real *invisibility* bug, see
/// [buildSketchGeometryNode]'s own doc comment on the round-cap culling fix)
/// kept getting bumped chasing what turned out to be a separate,
/// now-fixed rendering bug, not an actual sizing problem - once markers
/// were genuinely rendering again, on-device feedback was that 9.0 read as
/// oversized. Back to a line-width-derived ratio now that size is the only
/// remaining variable.
const double sketchPointMarkerWidth = sketchLineWidth * 1.5;

/// P23 (2D-sketcher feature parity): green, mirrors `sketch_canvas.dart`'s
/// own `_fullyConstrainedColor` (`0xFF2E7D32`) - an entity whose defining
/// Points are all fully constrained (see [SketchController.isFullyConstrained]/
/// `rigidity`).
final vm.Vector4 sketchFullyConstrainedColor = vm.Vector4(0.180, 0.490, 0.196, 1.0);

/// P23: red, mirrors `sketch_canvas.dart`'s own `_overConstrainedColor`
/// (`0xFFB71C1C`) - an entity implicated by an over-constrained (redundant/
/// conflicting) Constraint cluster or solver failure (see
/// [SketchController.isPointForcedOverConstrained]).
final vm.Vector4 sketchOverConstrainedColor = vm.Vector4(0.718, 0.109, 0.109, 1.0);

/// P23: blue, mirrors `sketch_canvas.dart`'s own `_constructionColor`
/// (`0xFF4A90D9`) - a Line/Circle/Arc/Ellipse/Spline flagged `construction`
/// (reference geometry only, never sent to Extrude/other Features).
final vm.Vector4 sketchConstructionColor = vm.Vector4(0.290, 0.565, 0.851, 1.0);

/// P24 (2D-sketcher feature parity): orangeAccent, mirrors
/// `sketch_canvas.dart`'s own `_grabbedColor` - the Point/Line currently
/// grabbed by [SketchController.draggingPointId]/[draggingLineId]. Highest
/// priority in `sketch_screen.dart`'s own `_embeddedSketchEntityColors`
/// (same as 2D's own priority chain), since a grabbed entity is actively
/// being manipulated right now.
final vm.Vector4 sketchGrabbedColor = vm.Vector4(1.0, 0.671, 0.251, 1.0);

/// P26 (on-device feedback: "make construction lines dashed"): world-space
/// dash/gap length for construction geometry - mirrors `sketch_canvas.dart`'s
/// own dashed-stroke look, but at a fixed *sketch-unit* cadence rather than
/// that painter's fixed *screen-pixel* one (`_drawDashedLine`/
/// `_drawDashedCircle`/etc.) - committed 3D geometry has no meaningful
/// "screen pixel" scale of its own (camera distance varies continuously),
/// so a world-space dash length is the only cadence that stays a genuine
/// dash regardless of zoom.
const double sketchConstructionDashLength = 0.6;
const double sketchConstructionGapLength = 0.4;

/// P27 safety net: a hard ceiling on how many dash primitives a single
/// entity's [dashedSegments] call ever produces, regardless of its actual
/// world-space length - guards against an unexpectedly large piece of
/// construction geometry (or any future change to this cadence) turning
/// into hundreds of tiny [PolylineGeometry] primitives created
/// synchronously on the main isolate, which - independent of whatever
/// else was involved in the on-device "Rectangle placement froze/crashed"
/// report - is exactly the shape of thing worth bounding defensively.
const int sketchConstructionMaxDashes = 120;

/// Walks [polyline] (a connected chain of straight segments - two points
/// for a Line, many for a tessellated Circle/Arc/Ellipse/Spline) and
/// returns only the "on" pieces of a dash pattern along its own cumulative
/// arc length, each as its own `(start, end)` segment ready for its own
/// [PolylineGeometry] primitive - there's no dashed-stroke primitive here,
/// so each dash is its own tiny polyline, the same "just build more,
/// shorter primitives" approach [buildSketchGridNode]'s own fade already
/// uses. Pure/testable - [buildSketchGeometryNode] is its GPU-facing
/// caller. Scales [dashLength]/[gapLength] up together (preserving their
/// ratio, so the dash-to-gap look stays the same, just coarser) whenever
/// the naive dash count would exceed [sketchConstructionMaxDashes].
///
/// Bug fix (on-device: "crashing when trying to create a construction
/// line" - confirmed via ANR trace as a genuine main-thread hang, right
/// where this function was introduced): an earlier version of this walked
/// each segment with a `while (traveled < segmentLength)` loop advancing by
/// `step = min(remainingInPhase, segmentLength - traveled)`, where
/// `remainingInPhase` came from `distanceIntoPattern % period`. Floating-
/// point rounding in that repeated modulo can, for some inputs, land
/// `phase` exactly on a dash/gap boundary such that `remainingInPhase`
/// rounds to precisely `0.0` - `step` then stays `0.0` forever (neither
/// `traveled` nor `distanceIntoPattern` ever advances, so the *next*
/// iteration recomputes the exact same `phase`/`step` again), an infinite
/// loop with no escape once triggered. Rewritten to walk dash boundaries by
/// integer index instead (`dashIndex * period`, `dashIndex` incrementing by
/// exactly `1` every iteration) - provably terminates after a bounded
/// number of iterations regardless of floating-point rounding, since
/// nothing here depends on a computed remainder ever being nonzero.
List<(vm.Vector3, vm.Vector3)> dashedSegments(
  List<vm.Vector3> polyline, {
  double dashLength = sketchConstructionDashLength,
  double gapLength = sketchConstructionGapLength,
}) {
  var totalLength = 0.0;
  for (var i = 0; i < polyline.length - 1; i++) {
    totalLength += (polyline[i + 1] - polyline[i]).length;
  }
  final naivePeriod = dashLength + gapLength;
  if (naivePeriod > 1e-9 && totalLength / naivePeriod > sketchConstructionMaxDashes) {
    final scale = (totalLength / naivePeriod) / sketchConstructionMaxDashes;
    dashLength *= scale;
    gapLength *= scale;
  }

  final period = dashLength + gapLength;
  if (period < 1e-9) return const [];

  final result = <(vm.Vector3, vm.Vector3)>[];
  var distanceIntoPattern = 0.0;
  for (var i = 0; i < polyline.length - 1; i++) {
    final segmentStart = polyline[i];
    final segmentEnd = polyline[i + 1];
    final segmentLength = (segmentEnd - segmentStart).length;
    if (segmentLength < 1e-9) continue;
    final direction = (segmentEnd - segmentStart) / segmentLength;
    final segmentEndDistance = distanceIntoPattern + segmentLength;

    var dashIndex = (distanceIntoPattern / period).floor();
    while (dashIndex * period < segmentEndDistance) {
      final dashStart = math.max(distanceIntoPattern, dashIndex * period);
      final dashEnd = math.min(segmentEndDistance, dashIndex * period + dashLength);
      if (dashEnd > dashStart) {
        result.add((
          segmentStart + direction * (dashStart - distanceIntoPattern),
          segmentStart + direction * (dashEnd - distanceIntoPattern),
        ));
      }
      dashIndex++;
    }
    distanceIntoPattern = segmentEndDistance;
  }
  return result;
}

/// Builds the [Node] rendering one Feature's [geometry] - one
/// [MeshPrimitive] per Line segment, Circle/Arc/Ellipse/Spline outline, and
/// Point marker, combined into a single [Mesh] so they share one
/// [Node]/transform and so a
/// single per-frame primitive scan (see `PartViewport`'s `_ScenePainter`)
/// reaches every `PolylineGeometry` needing `updateForCamera`.
///
/// Point markers reuse [vertexMarkerSegments]' "near-zero segment + round
/// cap" trick (see `mesh_geometry.dart`) rather than calling
/// [buildVertexMarkersNode] directly, so they stay [MeshPrimitive]s of this
/// same [Node]/[Mesh] instead of a second Node.
///
/// P23 (2D-sketcher feature parity): [entityColors], keyed by
/// [SketchGeometry3D]'s own id arrays (`lineIds`/`circleIds`/`arcIds`/
/// `ellipseIds`/`splineIds`/`pointIds`), overrides [sketchLineColor] per
/// entity - the constraint-status colour coding `sketch_canvas.dart` has
/// always had (green/red/blue/grey by solve state), ported here as data the
/// caller (`sketch_screen.dart`, which alone has `SketchController` access)
/// computes ahead of time, same "inject as data, keep this file
/// controller-agnostic" pattern every other callback/map in `viewport3d`
/// already uses. Null (the default) keeps every entity at the flat
/// [sketchLineColor] this function always used before P23 - `part_screen.dart`'s
/// own call site (rendering a Part's Sketches as fixed, non-editing
/// context) deliberately leaves this unset, since constraint-status colour
/// coding is only meaningful while a Sketch is the thing actively being
/// edited.
///
/// GPU-bound (`PolylineGeometry`'s own underlying updatable `MeshGeometry`),
/// so - like [buildReferencePlaneNode] - this cannot be exercised in a
/// headless `flutter test` run. [sketchGeometry3DFrom] above is the pure,
/// testable counterpart for the coordinate-mapping/geometry-layout logic.
Node buildSketchGeometryNode(
  String featureId,
  SketchGeometry3D geometry, {
  Map<String, vm.Vector4>? entityColors,
}) {
  vm.Vector4 colorFor(String id) => entityColors?[id] ?? sketchLineColor;
  // On-device feedback ("points are not visible"): a Point marker's own
  // round-cap disk (see vertexMarkerSegments' doc comment for why a Point
  // renders as one) comes from PolylineGeometry's fan-triangulated cap,
  // whose winding - unlike the ordinary line-strip triangles every other
  // primitive here uses - reads as back-facing under this renderer's
  // default counter-clockwise-front convention (Material.bind's own doc
  // comment) and was being silently culled regardless of marker width, no
  // matter how many times that width got bumped. `doubleSided` is only
  // honored for opaque materials (also that same doc comment) - true here
  // for all of them, so this fixes the Point markers without needing to
  // reverse-engineer/patch the third-party disk-winding math itself, at no
  // cost to the Line/Circle/etc. outlines also built from this material
  // (thin geometry with no real "back" to hide either way).
  UnlitMaterial materialFor(String id) => UnlitMaterial()
    ..alphaMode = AlphaMode.opaque
    ..baseColorFactor = colorFor(id)
    ..doubleSided = true;

  // P26: [id]'s outline as one or more [MeshPrimitive]s - a single solid
  // polyline normally, or a run of short dash primitives (all sharing the
  // same material) when [id] is in [SketchGeometry3D.constructionIds].
  Iterable<MeshPrimitive> outlinePrimitivesFor(String id, List<vm.Vector3> polyline) sync* {
    final material = materialFor(id);
    if (!geometry.constructionIds.contains(id)) {
      yield MeshPrimitive(PolylineGeometry(polyline, width: sketchLineWidth), material);
      return;
    }
    for (final dash in dashedSegments(polyline)) {
      yield MeshPrimitive(PolylineGeometry([dash.$1, dash.$2], width: sketchLineWidth), material);
    }
  }

  final primitives = <MeshPrimitive>[
    for (var i = 0; i < geometry.lineSegments.length; i++)
      ...outlinePrimitivesFor(
        geometry.lineIds[i],
        [geometry.lineSegments[i].$1, geometry.lineSegments[i].$2],
      ),
    for (var i = 0; i < geometry.circlePolygons.length; i++)
      ...outlinePrimitivesFor(geometry.circleIds[i], geometry.circlePolygons[i]),
    for (var i = 0; i < geometry.arcPolylines.length; i++)
      ...outlinePrimitivesFor(geometry.arcIds[i], geometry.arcPolylines[i]),
    for (var i = 0; i < geometry.ellipsePolygons.length; i++)
      ...outlinePrimitivesFor(geometry.ellipseIds[i], geometry.ellipsePolygons[i]),
    for (var i = 0; i < geometry.splinePolylines.length; i++)
      ...outlinePrimitivesFor(geometry.splineIds[i], geometry.splinePolylines[i]),
    for (var i = 0; i < geometry.points.length; i++)
      if (!geometry.hiddenPointIds.contains(geometry.pointIds[i]))
        for (final segment in vertexMarkerSegments([geometry.points[i]]))
          MeshPrimitive(
            PolylineGeometry(
              [segment.$1, segment.$2],
              width: sketchPointMarkerWidth,
              cap: PolylineCap.round,
            ),
            materialFor(geometry.pointIds[i]),
          ),
  ];

  return Node(name: 'sketch-$featureId', mesh: Mesh.primitives(primitives: primitives));
}

/// Sketcher restructure Phase 2 follow-up (P8/P9): side length of the active
/// Sketch's own rendered plane surface and grid while embedded-sketching -
/// matches [referencePlaneSize] so both line up visually with each other and
/// with the (hidden, while embedded-sketching) fixed reference planes'
/// established sizing.
const double sketchPlaneSurfaceSize = referencePlaneSize;
const double _sketchPlaneSurfaceHalfSize = sketchPlaneSurfaceSize / 2;

/// P8/P9: the actual Sketch's own drawn Points/Lines (see
/// [sketchGeometry3DFrom]) sit exactly on [basis]'s own plane, at zero
/// offset - so does [hitTestSketchPlane]'s own ray target. Rendering the new
/// surface/grid at that same exact depth risks z-fighting against them (two
/// coplanar surfaces with no defined draw-order winner), and against each
/// other. Both push back a hair along `-basis.normal` - the surface further
/// back than the grid.
///
/// On-device feedback: the grid rendered *behind* the surface despite this.
/// Root cause, confirmed by reading `flutter_scene`'s own
/// `SceneEncoder._depthOf` (not assumed): the translucent pass depth-sorts
/// by `worldTransform.getTranslation()` - a [Node]'s own transform origin,
/// not its actual mesh vertices. The previous version left every [Node]
/// here at the identity transform and baked world-space (including the
/// epsilon) straight into vertex positions - so every primitive's sort key
/// was `(0,0,0).distanceTo(camera)`, tied with each other and with real
/// Sketch geometry (`buildSketchGeometryNode` has the same identity-Node
/// shape), regardless of where the geometry actually was. Fixed by moving
/// *all* of a Node's position (both `basis.origin` and the small render
/// epsilon) into its own `localTransform`, and building vertex positions
/// relative to that origin instead (see [_sketchPlaneNodeTransform] and its
/// callers) - the depth-sort key now genuinely reflects each Node's real
/// position, camera-side-independent (a true "back to front from the
/// camera" distance, not a fixed-axis offset).
const double _sketchPlaneSurfaceRenderEpsilon = 0.03;
const double _sketchPlaneGridRenderEpsilon = 0.015;

vm.Matrix4 _sketchPlaneNodeTransform(SketchPlaneBasis basis, double epsilon) =>
    vm.Matrix4.translation(basis.origin - basis.normal * epsilon);

/// The four corners of a [halfSize]-radius square in [basis]'s own plane,
/// *relative to* [basis]'s own origin (no `+basis.origin` term) - the
/// origin itself is applied via the consuming [Node]'s own `localTransform`
/// instead (see [_sketchPlaneNodeTransform]'s own doc comment for why).
List<vm.Vector3> _sketchPlaneLocalQuadCorners(SketchPlaneBasis basis, double halfSize) => [
      basis.xAxis * -halfSize + basis.yAxis * -halfSize,
      basis.xAxis * halfSize + basis.yAxis * -halfSize,
      basis.xAxis * halfSize + basis.yAxis * halfSize,
      basis.xAxis * -halfSize + basis.yAxis * halfSize,
    ];

/// A fade profile that stays fully opaque through [solidUntil] of the
/// normalized radius (`0` at centre, `1` at the boundary), then ramps
/// linearly to `0` over the remaining band - on-device feedback: the fade
/// should read as flat/solid through the interior, gradual only in the
/// outer ~20%, not a fade starting from the centre.
double _edgeFadeAlpha(double normalizedDistance, {double solidUntil = 0.8}) {
  if (normalizedDistance <= solidUntil) return 1.0;
  final t = (normalizedDistance - solidUntil) / (1 - solidUntil);
  return 1 - t.clamp(0.0, 1.0);
}

/// P8: [doubleSidedQuadBuffers]'s own double-sided-translucency fix (see its
/// doc comment - `flutter_scene` back-face-culls any translucent material
/// regardless of `doubleSided`), generalized to an arbitrary [basis] instead
/// of one of the three fixed, axis-aligned reference planes - built relative
/// to the basis's own axes (see [_sketchPlaneLocalQuadCorners]) rather than
/// a fixed local-space quad plus a rotation matrix, since a custom plane's
/// basis has no fixed rotation table to key off.
DoubleSidedQuadBuffers doubleSidedSketchPlaneQuadBuffers(SketchPlaneBasis basis, double halfSize) {
  final corners = _sketchPlaneLocalQuadCorners(basis, halfSize);
  final positions = Float32List(8 * 3);
  final normals = Float32List(8 * 3);
  for (var i = 0; i < 4; i++) {
    final p = corners[i];
    final frontBase = i * 3;
    positions[frontBase] = p.x;
    positions[frontBase + 1] = p.y;
    positions[frontBase + 2] = p.z;
    normals[frontBase] = basis.normal.x;
    normals[frontBase + 1] = basis.normal.y;
    normals[frontBase + 2] = basis.normal.z;

    final backBase = (i + 4) * 3;
    positions[backBase] = p.x;
    positions[backBase + 1] = p.y;
    positions[backBase + 2] = p.z;
    normals[backBase] = -basis.normal.x;
    normals[backBase + 1] = -basis.normal.y;
    normals[backBase + 2] = -basis.normal.z;
  }
  return DoubleSidedQuadBuffers(
    positions: positions,
    normals: normals,
    indices: const [0, 2, 1, 0, 3, 2, 4, 5, 6, 4, 6, 7],
  );
}

/// P8: how many concentric squares [buildSketchPlaneSurfaceNode] layers to
/// approximate an edge fade - see that function's own doc comment for why.
const int _sketchPlaneSurfaceFadeSteps = 8;

/// P8: the active Sketch's own plane, rendered as a translucent fill so real
/// Bodies - visible for the first time behind the embedded sketch view - read
/// through it rather than being hidden by an opaque backdrop. On-device
/// feedback: no border (the fixed reference planes' own hard-edged look
/// doesn't suit a surface meant to be seen *through*), and the fill should
/// stay solid through the interior and only fade in the outer ~20% (see
/// [_edgeFadeAlpha]), not fade starting from the centre.
/// `UnlitMaterial.baseColorFactor` has no per-vertex gradient, so this
/// approximates the fade the same way a paper-craft technique would: every
/// layer is sized between 80% and 100% of the full extent (so *every* layer
/// already covers the full `[0, 80%]` interior - that band composites to a
/// constant, near-full alpha - while progressively fewer layers still cover
/// a point as its radius grows past 80%, tapering only that outer band).
Node buildSketchPlaneSurfaceNode(SketchPlaneBasis basis, {required vm.Vector4 color}) {
  final layerAlpha = color.w / _sketchPlaneSurfaceFadeSteps;
  final primitives = <MeshPrimitive>[
    for (var step = 0; step < _sketchPlaneSurfaceFadeSteps; step++)
      () {
        final t = step / (_sketchPlaneSurfaceFadeSteps - 1);
        final halfSize = _sketchPlaneSurfaceHalfSize * (0.8 + 0.2 * t);
        final material = UnlitMaterial()
          ..alphaMode = AlphaMode.blend
          ..baseColorFactor = vm.Vector4(color.x, color.y, color.z, layerAlpha);
        final buffers = doubleSidedSketchPlaneQuadBuffers(basis, halfSize);
        final geometry = MeshGeometry.fromArrays(
          positions: buffers.positions,
          normals: buffers.normals,
          indices: buffers.indices,
        );
        return MeshPrimitive(geometry, material);
      }(),
  ];

  return Node(
    name: 'sketch-plane-surface',
    localTransform: _sketchPlaneNodeTransform(basis, _sketchPlaneSurfaceRenderEpsilon),
    mesh: Mesh.primitives(primitives: primitives),
  );
}

/// P9: a fixed, finite grid of lines across [basis]'s own plane - purely a
/// visual aid (not a hit-test target), centred on [basis.origin], spanning
/// `[-extent, extent]` along both local axes at [spacing] intervals.
/// Deliberately fixed/finite rather than camera-following or fading with
/// distance-from-camera - an "infinite grid" look needs either dynamic
/// per-frame regeneration or a shader approach, neither of which exists in
/// this codebase, and is out of scope for this landing (this fades with
/// distance-from-*centre* instead, a fixed property of the geometry itself -
/// see [buildSketchGridNode]). Pure and unit-testable, mirroring
/// [sketchGeometry3DFrom]'s own "pure geometry, no GPU types" split from its
/// GPU-facing counterpart.
List<(vm.Vector3, vm.Vector3)> sketchGridLinesFrom(
  SketchPlaneBasis basis, {
  double spacing = 2.5,
  double extent = _sketchPlaneSurfaceHalfSize,
}) {
  final segments = <(vm.Vector3, vm.Vector3)>[];
  final steps = (extent / spacing).floor();
  for (var i = -steps; i <= steps; i++) {
    final offset = i * spacing;
    segments.add((
      sketchPointToWorld(basis, -extent, offset),
      sketchPointToWorld(basis, extent, offset),
    ));
    segments.add((
      sketchPointToWorld(basis, offset, -extent),
      sketchPointToWorld(basis, offset, extent),
    ));
  }
  return segments;
}

/// P9: neutral, subdued grid-line colour and width - deliberately distinct
/// from [sketchLineColor]/[sketchLineWidth] so grid lines read as backdrop
/// structure, never mistaken for actually-drawn Sketch geometry. [sketchGridLineColor]'s
/// own alpha is the *centre* alpha [buildSketchGridNode] fades from.
final vm.Vector4 sketchGridLineColor = vm.Vector4(0.6, 0.6, 0.6, 0.5);
const double sketchGridLineWidth = 1.0;

/// P9: how many pieces [buildSketchGridNode] splits each full grid line
/// into, purely so each piece can carry its own fade alpha (a single
/// [PolylineGeometry] segment has one constant-alpha material, no per-vertex
/// gradient) - see [buildSketchGridNode]'s own doc comment.
const int _sketchGridFadeSteps = 6;

/// P9: [sketchGridLinesFrom]'s GPU-facing counterpart - on-device feedback:
/// the grid (like P8's surface) should stay solid through the interior and
/// only fade in the outer ~20% (see [_edgeFadeAlpha]). Splits each full line
/// (from [sketchGridLinesFrom], called against a *local* - zero-origin -
/// copy of [basis] so its segments come back relative to the origin, per
/// [_sketchPlaneNodeTransform]'s own doc comment) into [_sketchGridFadeSteps]
/// short pieces, each given its own alpha from [sketchGridLineColor]'s own
/// alpha, tapered by that piece's own distance from the centre relative to
/// [extent].
Node buildSketchGridNode(
  SketchPlaneBasis basis, {
  double spacing = 2.5,
  double extent = _sketchPlaneSurfaceHalfSize,
}) {
  final localBasis = SketchPlaneBasis(
    origin: vm.Vector3.zero(),
    xAxis: basis.xAxis,
    yAxis: basis.yAxis,
    normal: basis.normal,
  );
  final segments = sketchGridLinesFrom(localBasis, spacing: spacing, extent: extent);
  final primitives = <MeshPrimitive>[];
  for (final segment in segments) {
    final delta = segment.$2 - segment.$1;
    for (var i = 0; i < _sketchGridFadeSteps; i++) {
      final t0 = i / _sketchGridFadeSteps;
      final t1 = (i + 1) / _sketchGridFadeSteps;
      final p1 = segment.$1 + delta * t0;
      final p2 = segment.$1 + delta * t1;
      final mid = segment.$1 + delta * ((t0 + t1) / 2);
      // On-device feedback: fading by Euclidean distance from the centre
      // faded the corners too early (they're `extent * sqrt(2)` from
      // centre) while the edge midpoints (only `extent` away) stayed
      // solid - a mismatch with the square's own actual boundary. Chebyshev
      // distance (the larger of the two local-axis coordinates) reaches
      // `extent` everywhere exactly on the boundary, fading the whole
      // square edge - corners included - uniformly instead.
      final localX = mid.dot(basis.xAxis);
      final localY = mid.dot(basis.yAxis);
      final normalizedDist = math.max(localX.abs(), localY.abs()) / extent;
      final alpha = _edgeFadeAlpha(normalizedDist) * sketchGridLineColor.w;
      if (alpha < 0.01) continue;
      final material = UnlitMaterial()
        ..alphaMode = AlphaMode.blend
        ..baseColorFactor = vm.Vector4(sketchGridLineColor.x, sketchGridLineColor.y, sketchGridLineColor.z, alpha);
      primitives.add(MeshPrimitive(PolylineGeometry([p1, p2], width: sketchGridLineWidth), material));
    }
  }
  return Node(
    name: 'sketch-plane-grid',
    localTransform: _sketchPlaneNodeTransform(basis, _sketchPlaneGridRenderEpsilon),
    mesh: Mesh.primitives(primitives: primitives),
  );
}

/// P17: the live draw-cursor ghost preview's colour - translucent and
/// distinct from both [sketchLineColor] (real, committed geometry) and
/// [sketchGridLineColor] (backdrop structure), so a ghost never reads as
/// already-committed geometry while a draw tool is active. Fully opaque
/// alpha would risk exactly that misreading; translucency is the signal.
final vm.Vector4 sketchGhostLineColor = vm.Vector4(0.3, 0.65, 1.0, 0.65);
// P19 on-device feedback: matches sketchLineWidth's own thinning, so the
// ghost previews at the same thickness the real committed Line will render.
const double sketchGhostLineWidth = sketchLineWidth;

/// P17: the live draw-cursor ghost preview's GPU-facing [Node] - one
/// [PolylineGeometry] primitive per polyline in [polylines] (already
/// resolved to world space; the caller - `sketch_screen.dart` - is
/// responsible for tessellating a `DrawGhost` via `ghostPolylines` and
/// mapping each point through [sketchPointToWorld], mirroring exactly how
/// [buildSketchGeometryNode] takes pre-resolved [SketchGeometry3D] rather
/// than raw DTOs). Deliberately takes plain `List<List<vm.Vector3>>` rather
/// than a `DrawGhost` itself, so this file (like the rest of `viewport3d`)
/// stays free of any dependency on the `sketch` package's own controller
/// types - see [PartViewport]'s own doc comments for why that boundary is
/// kept. Returns null for an empty [polylines] list (no ghost active right
/// now), so callers can pass it straight through to a nullable Node field
/// the same way [PartViewport] already handles [sketchPlaneBasis]-gated
/// nodes elsewhere.
Node? buildSketchGhostNode(List<List<vm.Vector3>> polylines, {vm.Vector4? color}) {
  if (polylines.isEmpty) return null;
  final material = UnlitMaterial()
    ..alphaMode = AlphaMode.blend
    ..baseColorFactor = color ?? sketchGhostLineColor;
  final primitives = <MeshPrimitive>[
    for (final polyline in polylines)
      if (polyline.length >= 2) MeshPrimitive(PolylineGeometry(polyline, width: sketchGhostLineWidth), material),
  ];
  if (primitives.isEmpty) return null;
  return Node(name: 'sketch-draw-ghost', mesh: Mesh.primitives(primitives: primitives));
}

/// P31 (2D-sketcher feature parity): a simple (non-self-intersecting) flat
/// polygon's own ear-clipping triangulation, returning triangle
/// vertex-index triples (length a multiple of 3) into [polygon] itself.
/// Pure and controller-agnostic on purpose (plain `(double, double)` tuples
/// in, plain `int` indices out) - [SketchController.profileLoopOutline]
/// produces [polygon] from live sketch data; this file only ever turns
/// already-tessellated outlines into GPU-facing meshes, never touches
/// `SketchController` itself, per this package's own data-flow boundary.
///
/// Degrades to an empty list (renders nothing) rather than throwing on
/// input this can't triangulate (fewer than 3 points, or every remaining
/// ear candidate rejected - self-intersecting/degenerate input), matching
/// [profileLoopOutline]'s own "null/empty on bad input" contract.
///
/// Hard-capped by a fixed iteration bound tied to [polygon]'s own length,
/// so pathological input can never spin forever regardless of how it's
/// degenerate - the same discipline [dashedSegments] now follows after its
/// own real, on-device infinite-loop bug (see that function's doc comment);
/// this one was written test-first specifically because of that lesson.
List<int> earClipTriangleIndices(List<(double, double)> polygon) {
  final n = polygon.length;
  if (n < 3) return const [];

  var signedArea = 0.0;
  for (var i = 0; i < n; i++) {
    final (x1, y1) = polygon[i];
    final (x2, y2) = polygon[(i + 1) % n];
    signedArea += x1 * y2 - x2 * y1;
  }
  final ccw = signedArea >= 0;

  final remaining = List<int>.generate(n, (i) => i);
  final triangles = <int>[];
  final maxIterations = n * n + 16;
  var iterations = 0;
  while (remaining.length > 3 && iterations < maxIterations) {
    iterations++;
    var clippedAnEar = false;
    for (var i = 0; i < remaining.length; i++) {
      final m = remaining.length;
      final iPrev = remaining[(i - 1 + m) % m];
      final iCur = remaining[i];
      final iNext = remaining[(i + 1) % m];
      final a = polygon[iPrev];
      final b = polygon[iCur];
      final c = polygon[iNext];
      if (!_isConvexEarVertex(a, b, c, ccw)) continue;
      var anyOtherVertexInside = false;
      for (final idx in remaining) {
        if (idx == iPrev || idx == iCur || idx == iNext) continue;
        final candidate = polygon[idx];
        // A hole "bridged" into the outer boundary (see
        // SketchController.profileLoopOutlineWithHoles) deliberately
        // revisits the same (x, y) at two different indices (the zero-
        // width slit connecting the two) - a coordinate-duplicate of one
        // of *this* candidate ear's own three corners is the same point in
        // space as that corner, not a genuinely separate vertex sitting
        // inside the ear, so it must never block it the way a real
        // interior point would.
        if (_pointsCoincide(candidate, a) || _pointsCoincide(candidate, b) || _pointsCoincide(candidate, c)) {
          continue;
        }
        if (_pointInTriangle(candidate, a, b, c)) {
          anyOtherVertexInside = true;
          break;
        }
      }
      if (anyOtherVertexInside) continue;
      triangles.addAll([iPrev, iCur, iNext]);
      remaining.removeAt(i);
      clippedAnEar = true;
      break;
    }
    if (!clippedAnEar) break;
  }
  if (remaining.length == 3) triangles.addAll(remaining);
  return triangles;
}

bool _pointsCoincide((double, double) p, (double, double) q) {
  const epsilon = 1e-9;
  return (p.$1 - q.$1).abs() < epsilon && (p.$2 - q.$2).abs() < epsilon;
}

bool _isConvexEarVertex((double, double) a, (double, double) b, (double, double) c, bool ccw) {
  final cross = (b.$1 - a.$1) * (c.$2 - a.$2) - (b.$2 - a.$2) * (c.$1 - a.$1);
  return ccw ? cross > 1e-12 : cross < -1e-12;
}

bool _pointInTriangle(
  (double, double) p,
  (double, double) a,
  (double, double) b,
  (double, double) c,
) {
  double sign((double, double) p1, (double, double) p2, (double, double) p3) =>
      (p1.$1 - p3.$1) * (p2.$2 - p3.$2) - (p2.$1 - p3.$1) * (p1.$2 - p3.$2);
  final d1 = sign(p, a, b);
  final d2 = sign(p, b, c);
  final d3 = sign(p, c, a);
  final hasNeg = d1 < 0 || d2 < 0 || d3 < 0;
  final hasPos = d1 > 0 || d2 > 0 || d3 > 0;
  return !(hasNeg && hasPos);
}

/// P31 (2D-sketcher feature parity): translucent green fill, mirrors
/// `sketch_canvas.dart`'s own `_paintClosedProfileFill` colour - live
/// "your sketch is closed" feedback while editing, distinct from every
/// other translucent overlay this file draws ([sketchGhostLineColor]'s
/// blue, [buildSketchPlaneSurfaceNode]'s neutral backdrop).
final vm.Vector4 sketchProfileFillColor = vm.Vector4(0.298, 0.686, 0.314, 0.35);

/// P31: red, mirrors `sketch_canvas.dart`'s own branch-point marker colour -
/// a real T-junction breaking closed-loop detection (see
/// [SketchController.profileBranchPointIds]'s own doc comment), rendered via
/// the existing [buildDrawIndicatorsNode]/[DrawIndicatorMarker] machinery
/// (no dedicated builder needed - it's just another marker kind).
final vm.Vector4 sketchProfileBranchMarkerColor = vm.Vector4(0.898, 0.224, 0.208, 1.0);
const double sketchProfileBranchMarkerWidth = 8.0;

/// P31: [outlines]' own live closed-profile fill(s) - one [MeshPrimitive]
/// per outer loop (V1 scope: [SketchController.profileLoopOutline]'s own
/// return value per [ProfileLoopDto], holes not yet punched - see that
/// method's doc comment), built double-sided (front+back vertex sets, back
/// face reverse-wound) for the same reason [doubleSidedSketchPlaneQuadBuffers]
/// already is: `flutter_scene` back-face-culls translucent materials
/// regardless of `doubleSided`, so a fill viewed from "behind" the sketch
/// plane would otherwise vanish. Skips any outline [earClipTriangleIndices]
/// can't triangulate rather than dropping the whole node. Returns null for
/// an empty/all-degenerate [outlines] list.
Node? buildProfileFillNode(
  SketchPlaneBasis basis,
  List<List<(double, double)>> outlines, {
  vm.Vector4? color,
}) {
  final fillColor = color ?? sketchProfileFillColor;
  final material = UnlitMaterial()
    ..alphaMode = AlphaMode.blend
    ..baseColorFactor = fillColor;
  final primitives = <MeshPrimitive>[];
  for (final outline in outlines) {
    final triangleIndices = earClipTriangleIndices(outline);
    if (triangleIndices.isEmpty) continue;
    final n = outline.length;
    final positions = Float32List(n * 2 * 3);
    final normals = Float32List(n * 2 * 3);
    for (var i = 0; i < n; i++) {
      final (x, y) = outline[i];
      final world = sketchPointToWorld(basis, x, y);
      final frontBase = i * 3;
      positions[frontBase] = world.x;
      positions[frontBase + 1] = world.y;
      positions[frontBase + 2] = world.z;
      normals[frontBase] = basis.normal.x;
      normals[frontBase + 1] = basis.normal.y;
      normals[frontBase + 2] = basis.normal.z;

      final backBase = (i + n) * 3;
      positions[backBase] = world.x;
      positions[backBase + 1] = world.y;
      positions[backBase + 2] = world.z;
      normals[backBase] = -basis.normal.x;
      normals[backBase + 1] = -basis.normal.y;
      normals[backBase + 2] = -basis.normal.z;
    }
    final indices = <int>[];
    for (var t = 0; t + 2 < triangleIndices.length; t += 3) {
      final a = triangleIndices[t];
      final b = triangleIndices[t + 1];
      final c = triangleIndices[t + 2];
      indices.addAll([a, b, c]);
      indices.addAll([c + n, b + n, a + n]);
    }
    final geometry = MeshGeometry.fromArrays(positions: positions, normals: normals, indices: indices);
    primitives.add(MeshPrimitive(geometry, material));
  }
  if (primitives.isEmpty) return null;
  return Node(name: 'sketch-profile-fill', mesh: Mesh.primitives(primitives: primitives));
}

/// P20 follow-up (2D-sketcher feature parity): the colour a Line ghost
/// switches to when [SketchController.activeLineSnapAxis] is non-null -
/// mirrors `sketch_canvas.dart`'s own `Colors.green` recolor exactly (same
/// "the next tap lands exactly horizontal/vertical" signal), passed as
/// [buildSketchGhostNode]'s `color` override rather than a second constant
/// baked into that function, since only `sketch_screen.dart` (which reads
/// [SketchController.activeLineSnapAxis]) knows when it applies.
final vm.Vector4 sketchGhostSnapColor = vm.Vector4(0.298, 0.686, 0.314, 0.85);

/// P20 follow-up: Polygon's circumscribed/inscribed guide circles (see
/// `ghostGuidePolylines` in `sketch_controller.dart`) - a fainter twin of
/// [sketchGhostLineColor] (mirrors `sketch_canvas.dart`'s own
/// `guidePaint = paint.color.withValues(alpha: 0.35)`), rendered via a
/// second [buildSketchGhostNode] call so the guide circles never compete
/// visually with the polygon's own outline.
final vm.Vector4 sketchGhostGuideColor = vm.Vector4(0.3, 0.65, 1.0, 0.28);

/// P20 follow-up: the live draw-cursor's "in-progress anchor" and snap
/// indicator markers - the 3D-embedded counterpart to `sketch_canvas.dart`'s
/// deepOrange/green/cyan point emphasis while placing a multi-tap shape
/// (Circle/Arc/Polygon/Slot/Ellipse/Spline anchors, Line's chain-start,
/// the origin, a snap-candidate/auto-coincident point, a Line's midpoint).
/// Deliberately a single, generic (colour + width)-per-point type rather
/// than one class per indicator kind - every one of 2D's variants is
/// "a point, emphasised, in some colour", the same shape [buildVertexMarkersNode]
/// already draws for committed points; only the (world) position/colour/
/// width differ, all decided by the caller (`sketch_screen.dart`, which
/// alone knows which `SketchController` getters are active right now).
/// Rendered as filled dots (not 2D's hollow rings for some variants) -
/// [PolylineGeometry]'s screen-space "near-zero segment + round cap" trick
/// (see [vertexMarkerSegments]'s own doc comment) only draws solid disks, no
/// literal ring primitive exists here - an accepted simplification, not a
/// missing feature: same information (position + colour + emphasis size),
/// slightly less ornate render.
class DrawIndicatorMarker {
  final vm.Vector3 point;
  final vm.Vector4 color;
  final double width;

  const DrawIndicatorMarker({required this.point, required this.color, required this.width});
}

/// P20 follow-up: deepOrange, mirrors `sketch_canvas.dart`'s
/// `_pointRadiusEmphasis`/`Colors.deepOrange` - the in-progress anchor
/// Points driving whichever multi-tap shape is currently being placed
/// (Circle centre, Arc centre/start, Polygon centre, Slot's two centres,
/// Ellipse centre/major-point, Spline's through-points so far).
final vm.Vector4 sketchIndicatorAnchorColor = vm.Vector4(1.0, 0.341, 0.133, 1.0);
const double sketchIndicatorAnchorWidth = 7.0;

/// P20 follow-up: green, mirrors `sketch_canvas.dart`'s `_pointRadiusSnapping`/
/// `Colors.green` - "the next tap lands exactly here instead of creating a
/// new Point": a Line chain about to close its loop onto its own start
/// Point ([SketchController.isHoveringChainStart]), or the cursor about to
/// snap onto the Sketch's origin ([SketchController.isHoveringOrigin]).
/// Bigger than [sketchIndicatorAnchorWidth] - same "more emphasis than a
/// plain anchor" relationship 2D's own radius values have.
final vm.Vector4 sketchIndicatorSnapColor = vm.Vector4(0.298, 0.686, 0.314, 1.0);
const double sketchIndicatorSnapWidth = 9.0;

/// P20 follow-up: cyan, mirrors `sketch_canvas.dart`'s `_snapCandidateColor`
/// - a real existing Point the cursor is hovering near
/// ([SketchController.snapCandidatePointId], pre-tap) or that the most
/// recent tap just auto-linked onto via a CoincidentConstraint
/// ([SketchController.autoCoincidentIndicatorPointId], post-tap) - same
/// visual for both, since 2D's own painter reuses one look for both triggers.
final vm.Vector4 sketchIndicatorCandidateColor = vm.Vector4(0.0, 0.737, 0.831, 0.9);
const double sketchIndicatorCandidateWidth = 8.0;

/// P20 follow-up: a fainter green than [sketchIndicatorSnapColor] - a
/// Line's own (otherwise invisible) midpoint, while the cursor hovers near
/// enough that a tap would snap onto it
/// ([SketchController.hoveredLineMidpoint]) - mirrors `sketch_canvas.dart`'s
/// own `_midpointSnapIndicatorRadius`/hollow green ring (see
/// [DrawIndicatorMarker]'s own doc comment for why this renders solid
/// instead of hollow).
final vm.Vector4 sketchIndicatorMidpointColor = vm.Vector4(0.298, 0.686, 0.314, 0.7);
const double sketchIndicatorMidpointWidth = 7.0;

/// P20 follow-up: [DrawIndicatorMarker]'s GPU-facing [Node] - one
/// near-zero-length, round-capped [PolylineGeometry] "fake dot" primitive
/// per marker (the same trick [buildVertexMarkersNode] uses for committed
/// points), each with its own colour/width so different indicator kinds can
/// render simultaneously (e.g. an Arc's centre AND start anchor, both
/// deepOrange, alongside a cyan snap-candidate) in one [Node]. Returns null
/// for an empty [markers] list, matching every other optional-node
/// convention in this file.
Node? buildDrawIndicatorsNode(List<DrawIndicatorMarker> markers) {
  if (markers.isEmpty) return null;
  final primitives = <MeshPrimitive>[
    for (final marker in markers)
      for (final segment in vertexMarkerSegments([marker.point]))
        MeshPrimitive(
          PolylineGeometry([segment.$1, segment.$2], width: marker.width, cap: PolylineCap.round),
          UnlitMaterial()
            // On-device feedback ("the invisible cursor being naughty in the
            // background" - the in-progress draw anchor/snap/candidate dots
            // this Node renders): same round-cap culling bug as
            // [buildSketchGeometryNode]'s own Point markers (see that
            // function's own doc comment) - `doubleSided` is only honored
            // for opaque materials, so switching out of AlphaMode.blend is
            // required here too, same trade-off `buildMeshEdgesNode`'s own
            // doc comment already accepted (a partial-alpha colour, e.g.
            // [sketchIndicatorCandidateColor]'s 0.9, renders fully solid
            // instead of its intended slight translucency) - an actually-
            // visible solid dot beats a correctly-translucent invisible one.
            ..alphaMode = AlphaMode.opaque
            ..baseColorFactor = marker.color
            ..doubleSided = true,
        ),
  ];
  return Node(name: 'sketch-draw-indicators', mesh: Mesh.primitives(primitives: primitives));
}
