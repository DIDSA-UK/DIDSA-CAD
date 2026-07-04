import 'dart:math' as math;
import 'dart:ui' show Size;

import 'package:vector_math/vector_math.dart' as vm;

import '../api/document_api_client.dart';
import 'mesh_geometry.dart' show edgeSegmentsFromMesh;
import 'selection_filter.dart';
import 'sketch_geometry_3d.dart' show SketchGeometry3D;

/// flutter_scene's `PerspectiveCamera` only exposes `fovNear`/`fovFar` (the
/// near/far *clip* distances, see `OrbitCamera.cameraFor`) - there's no
/// getter for the actual field-of-view angle it renders with. [OrbitCamera]
/// already documents the same fixed assumption ("flutter_scene's 45-degree
/// default vertical FOV") for its own zoom-distance tuning, so this reuses
/// that exact assumption rather than inventing a second one.
const double kCameraVerticalFovRadians = math.pi / 4;

/// Hit-test radius (screen dp) for edges in selection mode (Item 3 of the
/// Stage 23 brief; see [kVertexSelectionHitRadiusPixels] for vertices) -
/// deliberately smaller than, and independent of, the sketcher's own
/// `SketchController.minTapHitRadiusPixels` (22.0): that is a 2D sketch's
/// primary tap-to-select radius, this is a 3D hover/pick radius that always
/// has a face fallback when nothing edge/vertex-like is near enough.
///
/// Bug-fix round: this used to be smaller than [kVertexSelectionHitRadiusPixels]
/// (9px vs. 16px) so a vertex - a single point target vs. an edge's full
/// line segment - had extra forgiveness. On-device testing found the gap
/// between the two made hit-testing feel inconsistent (generous near a
/// corner, tight along an edge) and, worse, meant the actual selectable
/// area no longer matched the hover highlight it's driven from (both read
/// off the same [HoverHit] - see [hitTestMeshEntities] - so hover and
/// selection were never actually different targets, just an oversized one
/// for vertices specifically). Both constants are now equal, at the
/// midpoint of the old 9px/16px values.
const double kSelectionHitRadiusPixels = 12.5;

/// See [kSelectionHitRadiusPixels]'s doc comment - equal to it as of the
/// bug-fix round (previously wider, at 16px, to give a vertex - a single
/// point target - extra forgiveness over an edge's full line segment).
const double kVertexSelectionHitRadiusPixels = kSelectionHitRadiusPixels;

/// Prompt A3 added `body` - a whole Body (Prompt A1), selected as a unit
/// rather than one of its individual faces/edges/vertices. Prompt C1 added
/// `sketchPoint`/`sketchLine` - a Sketch's own Point/Line entities, rendered
/// and pickable in the 3D viewport alongside Body geometry (see
/// `sketch_geometry_3d.dart`).
enum SelectionEntityKind { face, edge, vertex, body, sketchPoint, sketchLine }

/// Identifies one selectable mesh entity - a [SelectionEntityKind] plus the
/// stable id `MeshDto.faceIds`/`edgeIds`/`topologyVertexIds` assigns it.
/// Equality/hashCode are value-based so this can be used as a `Set` element
/// (the selection set) or a `Map` key.
///
/// Prompt A3: [bodyId] identifies which Body this entity belongs to -
/// required because those `MeshDto` ids are only unique *within* one
/// Body's own tessellation (Prompt A1), not globally across a Part's whole
/// `/mesh` response. Defaults to `''` for the single-mesh-scoped functions
/// below ([hitTestVertices]/[hitTestEdges]/[hitTestFaces]/
/// [hitTestMeshEntities]), which predate A3 and have no Body concept of
/// their own - only [hitTestBodies] (the real multi-body entry point
/// [PartViewport] uses) ever produces a meaningful, non-empty [bodyId].
/// For a [SelectionEntityKind.body] entity, [bodyId] alone is the whole
/// identity - [id] is always `0` and carries no meaning.
///
/// Prompt C1: [sketchFeatureId]/[sketchEntityId] identify a
/// [SelectionEntityKind.sketchPoint]/[SelectionEntityKind.sketchLine] entity
/// instead - [bodyId]/[id] carry no meaning for those two kinds, the same
/// way [bodyId] carries no meaning for mesh kinds and vice versa. A separate
/// pair (rather than reusing [bodyId]/[id]) because Sketch Point/Line ids
/// are real backend UUID strings (`Point.id`/`SketchEntity.id`), not the
/// small dense ints `MeshDto` assigns its own entities - [sketchFeatureId]
/// is the owning Feature's id (matching `PartViewport.sketchGeometries`'
/// own keying), not the Sketch's own id, so this stays resolvable the same
/// way `_bodyFor`/`PartViewport.sketchGeometries` already key by Feature id.
class SelectionEntityRef {
  final SelectionEntityKind kind;
  final String bodyId;
  final int id;
  final String sketchFeatureId;
  final String sketchEntityId;

  const SelectionEntityRef({
    required this.kind,
    this.bodyId = '',
    this.id = 0,
    this.sketchFeatureId = '',
    this.sketchEntityId = '',
  });

  @override
  bool operator ==(Object other) =>
      other is SelectionEntityRef &&
      other.kind == kind &&
      other.bodyId == bodyId &&
      other.id == id &&
      other.sketchFeatureId == sketchFeatureId &&
      other.sketchEntityId == sketchEntityId;

  @override
  int get hashCode => Object.hash(kind, bodyId, id, sketchFeatureId, sketchEntityId);

  @override
  String toString() => kind == SelectionEntityKind.sketchPoint || kind == SelectionEntityKind.sketchLine
      ? 'SelectionEntityRef($kind, sketchFeatureId: $sketchFeatureId, $sketchEntityId)'
      : 'SelectionEntityRef($kind, bodyId: $bodyId, $id)';
}

/// A hit-test result: which entity, how far along the ray it was found (for
/// depth-based reasoning), and - for edge/vertex hits only - how many
/// screen pixels away from the ray it actually was (used to pick the
/// nearer of a vertex/edge tie; always null for a face hit, since faces
/// have no hit-radius concept - see [hitTestFaces]).
class HoverHit {
  final SelectionEntityRef entity;
  final double rayT;
  final double? pixelDistance;

  const HoverHit({required this.entity, required this.rayT, this.pixelDistance});
}

/// World-space size of one screen pixel at [depth] (distance along the
/// camera's forward ray) - lets a 3D world-space distance be compared
/// against a screen-space pixel radius without needing the full
/// view/projection matrix `flutter_scene`'s `PerspectiveCamera` builds
/// internally (mirrors `hitTestReferencePlanes`'s choice to stay off
/// `flutter_scene`'s own `raycast.dart`, for the same "stay pure and
/// unit-testable" reason).
double _worldUnitsPerPixelAtDepth(double depth, Size viewportSize) {
  if (viewportSize.height <= 0) return double.infinity;
  final worldHeightAtDepth = 2 * depth * math.tan(kCameraVerticalFovRadians / 2);
  return worldHeightAtDepth / viewportSize.height;
}

/// Nearest of [vertices] (ids parallel in [ids]) to [ray], in screen space,
/// within [radiusPixels] - or null if none are that close. A vertex behind
/// the camera (`t <= 0`) is never considered.
HoverHit? hitTestVertices(
  vm.Ray ray,
  Size viewportSize,
  List<vm.Vector3> vertices,
  List<int> ids, {
  double radiusPixels = kSelectionHitRadiusPixels,
}) {
  final direction = ray.direction.normalized();
  HoverHit? best;
  for (var i = 0; i < vertices.length; i++) {
    final toPoint = vertices[i] - ray.origin;
    final t = toPoint.dot(direction);
    if (t <= 0) continue;
    final closestOnRay = ray.origin + direction * t;
    final worldDistance = (vertices[i] - closestOnRay).length;
    final pixelDistance = worldDistance / _worldUnitsPerPixelAtDepth(t, viewportSize);
    if (pixelDistance > radiusPixels) continue;
    if (best == null || pixelDistance < best.pixelDistance!) {
      best = HoverHit(
        entity: SelectionEntityRef(kind: SelectionEntityKind.vertex, id: ids[i]),
        rayT: t,
        pixelDistance: pixelDistance,
      );
    }
  }
  return best;
}

/// Closest approach between [ray] (treated as starting at [rayOrigin],
/// unit-length [rayDirection], extending only forward) and the finite
/// segment [segStart]-[segEnd] - the standard closest-point-between-two-
/// lines formula, with the segment parameter clamped to `[0, 1]` so the
/// result respects the segment's actual endpoints rather than its infinite
/// extension. Returns `(t along the ray, world-space distance)`, or null if
/// the segment's closest point would be behind the camera (`t <= 0`).
(double, double)? _closestRaySegmentDistance(
  vm.Vector3 rayOrigin,
  vm.Vector3 rayDirection,
  vm.Vector3 segStart,
  vm.Vector3 segEnd,
) {
  final d1 = rayDirection;
  final d2 = segEnd - segStart;
  final r = rayOrigin - segStart;

  final b = d1.dot(d2);
  final c = d2.dot(d2);
  final d = d1.dot(r);
  final e = d2.dot(r);

  // a = d1.dot(d1) == 1 since d1 is unit-length.
  final denom = c - b * b;
  var segT = denom.abs() < 1e-9 ? 0.0 : (e - b * d) / denom;
  segT = segT.clamp(0.0, 1.0);

  final segPoint = segStart + d2 * segT;
  final rayT = d1.dot(segPoint - rayOrigin);
  if (rayT <= 0) return null;

  final closestOnRay = rayOrigin + d1 * rayT;
  return (rayT, (segPoint - closestOnRay).length);
}

/// Nearest of [segments] (ids parallel in [ids], one id per segment - see
/// `MeshDto.edgeIds`) to [ray], in screen space, within [radiusPixels] - or
/// null if none are that close.
HoverHit? hitTestEdges(
  vm.Ray ray,
  Size viewportSize,
  List<(vm.Vector3, vm.Vector3)> segments,
  List<int> ids, {
  double radiusPixels = kSelectionHitRadiusPixels,
}) {
  final direction = ray.direction.normalized();
  HoverHit? best;
  for (var i = 0; i < segments.length; i++) {
    final closest =
        _closestRaySegmentDistance(ray.origin, direction, segments[i].$1, segments[i].$2);
    if (closest == null) continue;
    final (t, worldDistance) = closest;
    final pixelDistance = worldDistance / _worldUnitsPerPixelAtDepth(t, viewportSize);
    if (pixelDistance > radiusPixels) continue;
    if (best == null || pixelDistance < best.pixelDistance!) {
      best = HoverHit(
        entity: SelectionEntityRef(kind: SelectionEntityKind.edge, id: ids[i]),
        rayT: t,
        pixelDistance: pixelDistance,
      );
    }
  }
  return best;
}

/// Prompt C1: [hitTestVertices]' counterpart for a Sketch's own Points -
/// same nearest-in-range-wins logic, just producing
/// [SelectionEntityKind.sketchPoint] entities tagged with [sketchFeatureId]/
/// a String [SketchEntityRef]-style id (see [SelectionEntityRef]'s own doc
/// comment for why that's a separate field pair from [bodyId]/`id`) instead
/// of a Body-scoped int id.
HoverHit? hitTestSketchPoints(
  vm.Ray ray,
  Size viewportSize,
  String sketchFeatureId,
  List<vm.Vector3> points,
  List<String> ids, {
  double radiusPixels = kVertexSelectionHitRadiusPixels,
}) {
  final direction = ray.direction.normalized();
  HoverHit? best;
  for (var i = 0; i < points.length; i++) {
    final toPoint = points[i] - ray.origin;
    final t = toPoint.dot(direction);
    if (t <= 0) continue;
    final closestOnRay = ray.origin + direction * t;
    final worldDistance = (points[i] - closestOnRay).length;
    final pixelDistance = worldDistance / _worldUnitsPerPixelAtDepth(t, viewportSize);
    if (pixelDistance > radiusPixels) continue;
    if (best == null || pixelDistance < best.pixelDistance!) {
      best = HoverHit(
        entity: SelectionEntityRef(
          kind: SelectionEntityKind.sketchPoint,
          sketchFeatureId: sketchFeatureId,
          sketchEntityId: ids[i],
        ),
        rayT: t,
        pixelDistance: pixelDistance,
      );
    }
  }
  return best;
}

/// Prompt C1: [hitTestEdges]' counterpart for a Sketch's own Lines - see
/// [hitTestSketchPoints]'s doc comment for why this produces
/// [SelectionEntityRef.sketchFeatureId]/[SelectionEntityRef.sketchEntityId]
/// rather than [SelectionEntityRef.bodyId]/`id`.
HoverHit? hitTestSketchLines(
  vm.Ray ray,
  Size viewportSize,
  String sketchFeatureId,
  List<(vm.Vector3, vm.Vector3)> segments,
  List<String> ids, {
  double radiusPixels = kSelectionHitRadiusPixels,
}) {
  final direction = ray.direction.normalized();
  HoverHit? best;
  for (var i = 0; i < segments.length; i++) {
    final closest =
        _closestRaySegmentDistance(ray.origin, direction, segments[i].$1, segments[i].$2);
    if (closest == null) continue;
    final (t, worldDistance) = closest;
    final pixelDistance = worldDistance / _worldUnitsPerPixelAtDepth(t, viewportSize);
    if (pixelDistance > radiusPixels) continue;
    if (best == null || pixelDistance < best.pixelDistance!) {
      best = HoverHit(
        entity: SelectionEntityRef(
          kind: SelectionEntityKind.sketchLine,
          sketchFeatureId: sketchFeatureId,
          sketchEntityId: ids[i],
        ),
        rayT: t,
        pixelDistance: pixelDistance,
      );
    }
  }
  return best;
}

/// Möller-Trumbore ray-triangle intersection - returns the ray parameter
/// `t` of the intersection, or null if [ray] misses the triangle (or hits
/// only behind the camera/at the camera itself).
double? _rayTriangleIntersectionT(
  vm.Vector3 origin,
  vm.Vector3 direction,
  vm.Vector3 v0,
  vm.Vector3 v1,
  vm.Vector3 v2,
) {
  const epsilon = 1e-9;
  final edge1 = v1 - v0;
  final edge2 = v2 - v0;
  final h = direction.cross(edge2);
  final a = edge1.dot(h);
  if (a.abs() < epsilon) return null; // Ray parallel to the triangle's plane.
  final f = 1.0 / a;
  final s = origin - v0;
  final u = f * s.dot(h);
  if (u < 0.0 || u > 1.0) return null;
  final q = s.cross(edge1);
  final v = f * direction.dot(q);
  if (v < 0.0 || u + v > 1.0) return null;
  final t = f * edge2.dot(q);
  if (t <= epsilon) return null;
  return t;
}

/// Nearest of [triangles] (ids parallel in [ids], one id per triangle - see
/// `MeshDto.faceIds`) actually intersected by [ray] - or null if [ray]
/// misses every triangle. Unlike [hitTestVertices]/[hitTestEdges], there is
/// no pixel-radius check: a face is only ever the fallback once no
/// edge/vertex is close enough (see [hitTestMeshEntities]), at which point
/// "the cursor ray actually passes through this triangle" is itself the
/// hit-test - no separate proximity radius is meaningful for a filled face.
HoverHit? hitTestFaces(
  vm.Ray ray,
  List<(vm.Vector3, vm.Vector3, vm.Vector3)> triangles,
  List<int> ids,
) {
  final direction = ray.direction.normalized();
  double? bestT;
  int? bestId;
  for (var i = 0; i < triangles.length; i++) {
    final triangle = triangles[i];
    final t = _rayTriangleIntersectionT(
      ray.origin,
      direction,
      triangle.$1,
      triangle.$2,
      triangle.$3,
    );
    if (t == null) continue;
    if (bestT == null || t < bestT) {
      bestT = t;
      bestId = ids[i];
    }
  }
  if (bestT == null || bestId == null) return null;
  return HoverHit(entity: SelectionEntityRef(kind: SelectionEntityKind.face, id: bestId), rayT: bestT);
}

/// [mesh.topologyVertices] as [vm.Vector3]s, parallel to
/// [MeshDto.topologyVertexIds] - the pure parsing step [hitTestMeshEntities]
/// needs before calling [hitTestVertices].
List<vm.Vector3> topologyVerticesFromMesh(MeshDto mesh) =>
    [for (final v in mesh.topologyVertices) vm.Vector3(v[0], v[1], v[2])];

/// [mesh.vertices]/[mesh.triangleIndices] resolved into actual triangle
/// corner positions, parallel to [MeshDto.faceIds] - the pure parsing step
/// [hitTestMeshEntities] needs before calling [hitTestFaces].
List<(vm.Vector3, vm.Vector3, vm.Vector3)> trianglesFromMesh(MeshDto mesh) => [
      for (final triangle in mesh.triangleIndices)
        (
          _vector3At(mesh, triangle[0]),
          _vector3At(mesh, triangle[1]),
          _vector3At(mesh, triangle[2]),
        ),
    ];

vm.Vector3 _vector3At(MeshDto mesh, int index) {
  final p = mesh.vertices[index];
  return vm.Vector3(p[0], p[1], p[2]);
}

/// World position of the topology vertex with the given [id], or null if no
/// such id exists in [mesh] - the lookup [PartViewport]'s highlight
/// rendering needs to turn a hovered/selected [SelectionEntityRef] (vertex
/// kind) back into a world-space point for [buildVertexMarkersNode]-style
/// rendering. A vertex id is always unique per [MeshDto.topologyVertexIds],
/// so this returns at most one position (contrast [edgeSegmentsForId]/
/// [faceTrianglesForId] below, which can each return several).
vm.Vector3? vertexPositionForId(MeshDto mesh, int id) {
  final index = mesh.topologyVertexIds.indexOf(id);
  if (index == -1) return null;
  final v = mesh.topologyVertices[index];
  return vm.Vector3(v[0], v[1], v[2]);
}

/// World-space segments making up the edge with the given [id] - a straight
/// OCCT edge contributes exactly one segment to `mesh.edges`, but a curved
/// one is sampled into several consecutive segments that all share the same
/// id (see backend/app/document/mesh.py's `_extract_edges`:
/// `edge_ids.extend([next_edge_id] * segment_count)`), so this must return a
/// list rather than a single segment. Empty if [id] is not present.
List<(vm.Vector3, vm.Vector3)> edgeSegmentsForId(MeshDto mesh, int id) {
  final allSegments = edgeSegmentsFromMesh(mesh);
  return [
    for (var i = 0; i < mesh.edgeIds.length; i++)
      if (mesh.edgeIds[i] == id) allSegments[i],
  ];
}

/// World-space triangles making up the face with the given [id] - an OCCT
/// face tessellates into one or more triangles that all share the same face
/// id (see backend/app/document/mesh.py's tessellation loop), so this must
/// return a list rather than a single triangle. Empty if [id] is not
/// present.
List<(vm.Vector3, vm.Vector3, vm.Vector3)> faceTrianglesForId(MeshDto mesh, int id) {
  final allTriangles = trianglesFromMesh(mesh);
  return [
    for (var i = 0; i < mesh.faceIds.length; i++)
      if (mesh.faceIds[i] == id) allTriangles[i],
  ];
}

/// The combined Item 3 hit-test: any topology vertex within
/// [vertexRadiusPixels] wins outright over edges/faces - not just when it's
/// the *closer* of the two. A vertex sits at the shared endpoint of one or
/// more edges, so comparing raw distance (as this used to) meant an edge's
/// closest point - which slides along the segment toward wherever the
/// cursor actually is - would beat the fixed vertex point for almost any
/// cursor position off its exact projected pixel, defeating the whole point
/// of giving vertices a wider radius. [vertexRadiusPixels] is wider than
/// [radiusPixels] (the latter applies to edges) precisely so a corner is a
/// realistically reachable target - see [kVertexSelectionHitRadiusPixels]'s
/// doc comment - so being inside it is itself the priority signal; only
/// when no vertex is in range does the nearer of edge/face apply.
///
/// Prompt A2: [filter] gates which kinds are considered at all - a kind
/// whose [SelectionFilterState] flag is off is skipped entirely (as if it
/// weren't in the mesh), not merely deprioritized, so e.g. turning vertices
/// off lets a hover land on an edge/face that a nearby vertex would
/// otherwise have won outright. [SelectionFilterState.body] has no effect
/// here - this function has no Body concept at all (it only ever sees one
/// mesh at a time); see [hitTestBodies] for the real multi-body entry
/// point (Prompt A3) that does honor it.
HoverHit? hitTestMeshEntities({
  required vm.Ray ray,
  required Size viewportSize,
  required MeshDto mesh,
  double radiusPixels = kSelectionHitRadiusPixels,
  double vertexRadiusPixels = kVertexSelectionHitRadiusPixels,
  SelectionFilterState filter = SelectionFilterState.defaults,
}) {
  final vertexHit = filter.vertex
      ? hitTestVertices(
          ray,
          viewportSize,
          topologyVerticesFromMesh(mesh),
          mesh.topologyVertexIds,
          radiusPixels: vertexRadiusPixels,
        )
      : null;
  final edgeHit = filter.edge
      ? hitTestEdges(
          ray,
          viewportSize,
          edgeSegmentsFromMesh(mesh),
          mesh.edgeIds,
          radiusPixels: radiusPixels,
        )
      : null;

  if (vertexHit != null) return vertexHit;
  if (edgeHit != null) return edgeHit;

  if (!filter.face) return null;
  return hitTestFaces(ray, trianglesFromMesh(mesh), mesh.faceIds);
}

/// Prompt A3: the real multi-body hit-test entry point [PartViewport]
/// uses - generalizes [hitTestMeshEntities] across every currently-visible
/// Body (Prompt A1's `/mesh` array), tagging the winning entity with which
/// Body it came from (see [SelectionEntityRef.bodyId]) since ids are only
/// body-local.
///
/// Vertex/edge priority is unchanged (nearest in-range vertex always wins;
/// then nearest in-range edge) - just extended from "nearest within one
/// mesh" to "nearest across every Body". Face-vs-Body resolution is new:
/// [SelectionFilterState.body] is not an independent fourth hit-test tier
/// alongside vertex/edge/face - toggling it on changes what a face
/// intersection *means*, rather than adding a competing kind of its own. A
/// face-ray-intersection test runs whenever either [SelectionFilterState.face]
/// or [SelectionFilterState.body] is on (so a future picking mode that
/// forces "bodies only, everything else off" - see Prompt A4 - still gets
/// a working ray-vs-geometry test even with `face` itself off), and if
/// [SelectionFilterState.body] is on, the winning triangle's owning Body is
/// resolved and returned as a [SelectionEntityKind.body] entity instead of
/// the tapped [SelectionEntityKind.face] - Body deliberately takes
/// precedence over a plain face pick whenever both are enabled, since
/// toggling Body on is specifically a request for the coarser granularity.
///
/// Prompt C1: [sketchGeometries] (same map [PartViewport.sketchGeometries]
/// carries, keyed by Feature id) is folded into the same two tiers rather
/// than tested as a separate third pass - a Sketch Point ties with a Body
/// Vertex at the top priority tier, a Sketch Line ties with a Body Edge at
/// the next one, per this prompt's own confirmed design (the recommended
/// "kind-based tie" over "all Sketch entities outrank all Body entities" -
/// see the prompt's own scope doc). Reuses [hitTestSketchPoints]/
/// [hitTestSketchLines] rather than a second hit-test path, per this
/// project's standing "extend the existing projection/hit-test logic"
/// principle.
HoverHit? hitTestBodies({
  required vm.Ray ray,
  required Size viewportSize,
  required List<BodyMeshDto> bodies,
  Map<String, SketchGeometry3D> sketchGeometries = const {},
  double radiusPixels = kSelectionHitRadiusPixels,
  double vertexRadiusPixels = kVertexSelectionHitRadiusPixels,
  SelectionFilterState filter = SelectionFilterState.defaults,
}) {
  HoverHit taggedWithBody(HoverHit hit, String bodyId) => HoverHit(
        entity: SelectionEntityRef(kind: hit.entity.kind, bodyId: bodyId, id: hit.entity.id),
        rayT: hit.rayT,
        pixelDistance: hit.pixelDistance,
      );

  HoverHit? bestVertex;
  HoverHit? bestEdge;
  HoverHit? bestFace;
  String? bestFaceBodyId;

  for (final body in bodies) {
    final mesh = body.mesh;
    if (filter.vertex) {
      final hit = hitTestVertices(
        ray,
        viewportSize,
        topologyVerticesFromMesh(mesh),
        mesh.topologyVertexIds,
        radiusPixels: vertexRadiusPixels,
      );
      if (hit != null && (bestVertex == null || hit.pixelDistance! < bestVertex.pixelDistance!)) {
        bestVertex = taggedWithBody(hit, body.bodyId);
      }
    }
    if (filter.edge) {
      final hit = hitTestEdges(
        ray,
        viewportSize,
        edgeSegmentsFromMesh(mesh),
        mesh.edgeIds,
        radiusPixels: radiusPixels,
      );
      if (hit != null && (bestEdge == null || hit.pixelDistance! < bestEdge.pixelDistance!)) {
        bestEdge = taggedWithBody(hit, body.bodyId);
      }
    }
    if (filter.face || filter.body) {
      final hit = hitTestFaces(ray, trianglesFromMesh(mesh), mesh.faceIds);
      if (hit != null && (bestFace == null || hit.rayT < bestFace.rayT)) {
        bestFace = hit;
        bestFaceBodyId = body.bodyId;
      }
    }
  }

  for (final entry in sketchGeometries.entries) {
    final geometry = entry.value;
    if (filter.sketchPoint) {
      final hit = hitTestSketchPoints(
        ray,
        viewportSize,
        entry.key,
        geometry.points,
        geometry.pointIds,
        radiusPixels: vertexRadiusPixels,
      );
      if (hit != null && (bestVertex == null || hit.pixelDistance! < bestVertex.pixelDistance!)) {
        bestVertex = hit;
      }
    }
    if (filter.sketchLine) {
      final hit = hitTestSketchLines(
        ray,
        viewportSize,
        entry.key,
        geometry.lineSegments,
        geometry.lineIds,
        radiusPixels: radiusPixels,
      );
      if (hit != null && (bestEdge == null || hit.pixelDistance! < bestEdge.pixelDistance!)) {
        bestEdge = hit;
      }
    }
  }

  if (bestVertex != null) return bestVertex;
  if (bestEdge != null) return bestEdge;
  if (bestFace == null) return null;

  if (filter.body) {
    return HoverHit(
      entity: SelectionEntityRef(kind: SelectionEntityKind.body, bodyId: bestFaceBodyId!),
      rayT: bestFace.rayT,
    );
  }
  if (!filter.face) return null;
  return taggedWithBody(bestFace, bestFaceBodyId!);
}
