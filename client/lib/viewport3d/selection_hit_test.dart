import 'dart:math' as math;
import 'dart:ui' show Size;

import 'package:vector_math/vector_math.dart' as vm;

import '../api/document_api_client.dart';
import 'mesh_geometry.dart' show edgeSegmentsFromMesh;

/// flutter_scene's `PerspectiveCamera` only exposes `fovNear`/`fovFar` (the
/// near/far *clip* distances, see `OrbitCamera.cameraFor`) - there's no
/// getter for the actual field-of-view angle it renders with. [OrbitCamera]
/// already documents the same fixed assumption ("flutter_scene's 45-degree
/// default vertical FOV") for its own zoom-distance tuning, so this reuses
/// that exact assumption rather than inventing a second one.
const double kCameraVerticalFovRadians = math.pi / 4;

/// Hit-test radius (screen dp) for edges/vertices in selection mode (Item 3
/// of the Stage 23 brief) - deliberately smaller than, and independent of,
/// the sketcher's own `SketchController.minTapHitRadiusPixels` (22.0): that
/// is a 2D sketch's primary tap-to-select radius, this is a 3D hover/pick
/// radius that always has a face fallback when nothing edge/vertex-like is
/// near enough.
const double kSelectionHitRadiusPixels = 9.0;

enum SelectionEntityKind { face, edge, vertex }

/// Identifies one selectable mesh entity - a [SelectionEntityKind] plus the
/// stable id `MeshDto.faceIds`/`edgeIds`/`topologyVertexIds` assigns it.
/// Equality/hashCode are value-based so this can be used as a `Set` element
/// (the selection set) or a `Map` key.
class SelectionEntityRef {
  final SelectionEntityKind kind;
  final int id;

  const SelectionEntityRef({required this.kind, required this.id});

  @override
  bool operator ==(Object other) =>
      other is SelectionEntityRef && other.kind == kind && other.id == id;

  @override
  int get hashCode => Object.hash(kind, id);

  @override
  String toString() => 'SelectionEntityRef($kind, $id)';
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
  return HoverHit(entity: SelectionEntityRef(kind: SelectionEntityKind.face, id: bestId));
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

/// The combined Item 3 hit-test: nearest topology vertex or edge to [ray]
/// within [radiusPixels] wins (a vertex exactly tied with an edge - e.g. the
/// cursor sitting right on a corner - resolves to the vertex, since a tie
/// only happens when the vertex *is* the edge's own closest point); only
/// when neither is within radius does this fall back to the nearest face
/// [ray] actually intersects. Returns null if nothing in [mesh] is hit at
/// all (empty mesh, or cursor over open background).
HoverHit? hitTestMeshEntities({
  required vm.Ray ray,
  required Size viewportSize,
  required MeshDto mesh,
  double radiusPixels = kSelectionHitRadiusPixels,
}) {
  final vertexHit = hitTestVertices(
    ray,
    viewportSize,
    topologyVerticesFromMesh(mesh),
    mesh.topologyVertexIds,
    radiusPixels: radiusPixels,
  );
  final edgeHit = hitTestEdges(
    ray,
    viewportSize,
    edgeSegmentsFromMesh(mesh),
    mesh.edgeIds,
    radiusPixels: radiusPixels,
  );

  if (vertexHit != null && (edgeHit == null || vertexHit.pixelDistance! <= edgeHit.pixelDistance!)) {
    return vertexHit;
  }
  if (edgeHit != null) return edgeHit;

  return hitTestFaces(ray, trianglesFromMesh(mesh), mesh.faceIds);
}
