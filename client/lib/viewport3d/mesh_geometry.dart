import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart' as vm;

import '../api/document_api_client.dart';

/// Holds the pure, GPU-independent vertex/index buffers `flutter_scene`
/// expects for an [UnskinnedGeometry] - kept separate from
/// [geometryFromMesh] so this data-layout logic can be unit-tested without a
/// real GPU/Impeller context (see [geometryFromMesh] for why the rest can't
/// be).
///
/// Indices are always 16-bit: this stage's mesh is a small placeholder solid
/// (and flutter_scene 0.18.1 doesn't expose its `IndexType` enum publicly to
/// select 32-bit indices anyway) - revisit if a later stage's tessellation
/// can exceed 65535 vertices.
class MeshBuffers {
  final Float32List vertexData;
  final int vertexCount;
  final ByteData indexData;

  const MeshBuffers({
    required this.vertexData,
    required this.vertexCount,
    required this.indexData,
  });
}

/// Builds the vertex/index buffers for a backend [MeshDto] in the same
/// vertex layout `flutter_scene`'s own geometry types use (position, normal,
/// uv, color - 12 floats/vertex), so it works with `flutter_scene`'s
/// default/built-in materials with no custom shader.
///
/// [mesh.vertices] and [mesh.normals] are already a flat triangle-soup (see
/// backend/app/document/mesh.py - every triangle owns its own 3 vertices, no
/// sharing across triangles), so there is no further de-duplication to do
/// here; uv is unused by [UnlitMaterial] without a texture and is left at
/// (0, 0), and color is left fully opaque white so [UnlitMaterial]'s
/// `baseColorFactor` alone controls the rendered color.
MeshBuffers meshBuffersFromMesh(MeshDto mesh) {
  final vertexCount = mesh.vertices.length;
  final vertexData = Float32List(vertexCount * 12);
  for (var i = 0; i < vertexCount; i++) {
    final position = mesh.vertices[i];
    final normal = mesh.normals[i];
    final base = i * 12;
    vertexData[base] = position[0];
    vertexData[base + 1] = position[1];
    vertexData[base + 2] = position[2];
    vertexData[base + 3] = normal[0];
    vertexData[base + 4] = normal[1];
    vertexData[base + 5] = normal[2];
    vertexData[base + 6] = 0; // u
    vertexData[base + 7] = 0; // v
    vertexData[base + 8] = 1; // r
    vertexData[base + 9] = 1; // g
    vertexData[base + 10] = 1; // b
    vertexData[base + 11] = 1; // a
  }

  final indexCount = mesh.triangleIndices.length * 3;
  final indices = Uint16List(indexCount);
  var i = 0;
  for (final triangle in mesh.triangleIndices) {
    indices[i++] = triangle[0];
    indices[i++] = triangle[1];
    indices[i++] = triangle[2];
  }

  return MeshBuffers(
    vertexData: vertexData,
    vertexCount: vertexCount,
    indexData: ByteData.sublistView(indices),
  );
}

/// Converts a backend [MeshDto] into a `flutter_scene` [UnskinnedGeometry].
///
/// This calls [UnskinnedGeometry.uploadVertexData], which internally calls
/// into `flutter_scene`'s GPU shim to allocate a device buffer - a real
/// GPU/Impeller context is needed for that, so unlike [meshBuffersFromMesh]
/// this function cannot be exercised in a headless `flutter test` run.
UnskinnedGeometry geometryFromMesh(MeshDto mesh) {
  final buffers = meshBuffersFromMesh(mesh);
  final geometry = UnskinnedGeometry();
  geometry.uploadVertexData(
    ByteData.sublistView(buffers.vertexData),
    buffers.vertexCount,
    buffers.indexData,
  );
  return geometry;
}

/// The axis-aligned bounding box centre and bounding-sphere radius of
/// [mesh]'s vertices - used to re-center the orbit camera's target on the
/// actual geometry rather than the world origin (see [OrbitCamera.setTarget])
/// and to scale its zoom bounds to the geometry's actual size (see
/// [OrbitCamera.setZoomBoundsForRadius]). The current placeholder mesh (see
/// backend/app/document/router.py) is a `BRepPrimAPI_MakeBox(10, 10, 10)`,
/// which OCCT spans from (0,0,0) to (10,10,10) rather than centering it at
/// the origin, so this - and any future mesh's bounds - has to be computed
/// from the real vertex data rather than assumed to be centred on (0,0,0).
///
/// The bounding centre (not the vertex-position average) is used so a
/// lopsided triangle distribution (e.g. a fine mesh on one face, coarse on
/// another) doesn't pull the orbit target off the geometry's visual middle.
class MeshBounds {
  final vm.Vector3 center;
  final double boundingSphereRadius;

  const MeshBounds({required this.center, required this.boundingSphereRadius});
}

/// Returns `null` for an empty mesh (no vertices) - callers fall back to the
/// origin/fixed zoom bounds in that case, per [OrbitCamera].
MeshBounds? boundsOfMesh(MeshDto mesh) {
  if (mesh.vertices.isEmpty) return null;
  final first = mesh.vertices.first;
  var min = vm.Vector3(first[0], first[1], first[2]);
  var max = min.clone();
  for (final vertex in mesh.vertices) {
    final p = vm.Vector3(vertex[0], vertex[1], vertex[2]);
    min = vm.Vector3(math.min(min.x, p.x), math.min(min.y, p.y), math.min(min.z, p.z));
    max = vm.Vector3(math.max(max.x, p.x), math.max(max.y, p.y), math.max(max.z, p.z));
  }
  return MeshBounds(
    center: (min + max) * 0.5,
    boundingSphereRadius: (max - min).length * 0.5,
  );
}

/// Line width (screen pixels, per [PolylineGeometry]'s default
/// `widthMode`) for both edge-rendering modes - Stage 19a Item 3 narrowed
/// this from the original `2.0` towards a more typical CAD wireframe weight.
const double kEdgeStrokeWidth = 1.1;

/// C3: how far (world units) [biasSegmentsTowardCamera] pushes each edge
/// point towards the camera - the closest available substitute for a real
/// GPU depth bias in `shadedWithEdges` mode, used to stop edges
/// z-fighting/flickering against the filled faces underneath them at
/// glancing viewing angles.
///
/// Three fixes for this were evaluated, in the order the project brief
/// prefers:
///  1. Render edges in a separate always-on-top pass with depth test/write
///     disabled - the standard, fully robust CAD technique. Not
///     achievable: flutter_scene 0.18.1's public API is just
///     `Scene.add(Node)` into one implicitly depth-tested pass - no
///     per-material depth-test/depth-write toggle and no way to declare a
///     second, later render pass. (This was already established by this
///     file's previous fix - see the removed `nudgeSegmentsOutward`/
///     `meshEdgeNudgeAmount`, written when this was first confirmed
///     against the real package - so it was not re-investigated here.)
///  2. **Chosen**: push each edge vertex a small amount towards the
///     camera, approximating a per-pixel NDC/clip-space depth bias in
///     world space. Implemented as [biasSegmentsTowardCamera] below.
///  3. Enlarge the offset only on segments nearly parallel to their
///     face's normal - needs a per-edge-segment "which face(s) is this
///     edge part of" lookup, which the client doesn't have (`MeshDto`
///     carries `faceIds`/`edgeIds` as two independent dense id lists with
///     no adjacency between them) - would require backend changes to
///     `mesh.py`, out of C3's client-only scope, so not attempted.
///
/// The fix that shipped first pushed every point directly away from the
/// mesh's bounding-sphere **center** - at a glancing angle, "away from
/// center" and "towards the camera" can be nearly perpendicular, so that
/// push barely increased depth-buffer separation for exactly the edges
/// the bug report was about. [biasSegmentsTowardCamera] fixes the
/// direction: it pushes towards the *camera position* instead, recomputed
/// per vertex (see its own doc comment) and re-run whenever the camera
/// moves (see `PartViewport`'s `_onPointerEnd`/`_onPointerSignal`/
/// `_doRecentre`/`animateToPlane`).
///
/// This constant's *magnitude* went through one more on-device-tested
/// iteration: it was briefly expressed as a fraction of the mesh's own
/// bounding-sphere radius (0.1%, reasoning that a fixed world-space value
/// would be imperceptible on a metre-scale part and heavy-handed on a
/// small one). That scaling caused a real regression, confirmed on a
/// non-convex (stepped/notched) part: a big part's overall bounding
/// radius says nothing about the depth of its *smaller local features* -
/// scaling off it pushed edges on a shallow step/notch by more than the
/// step's own depth, so a far wall's edges ended up biased in *front of*
/// a nearer wall and rendered through it. Edges are opaque and
/// depth-write (see [buildMeshEdgesNode]/[kEdgeStrokeWidth]'s material),
/// so an oversized bias does not just misplace the edge itself - it also
/// corrupts the depth buffer for anything else tested against it
/// afterwards (e.g. a translucent face-highlight overlay depth-tested in
/// the same frame). This constant is back to a fixed world-space amount -
/// the same value (`0.02`) the pre-existing, already-shipped
/// `meshEdgeNudgeAmount` used, so it inherits whatever on-device tuning
/// that had - with only the *direction* changed, not the magnitude.
const double kEdgeDepthBias = 0.02;

/// Parses [mesh]'s flat `[x1,y1,z1, x2,y2,z2, ...]` edge polyline data (see
/// backend/app/document/mesh.py's `_extract_edges`) into segment pairs -
/// the pure, testable counterpart to [buildMeshEdgesNode] below. Each
/// 6-float run is one polyline segment; a curved OCCT edge contributes
/// several consecutive segments, a straight one exactly one.
List<(vm.Vector3, vm.Vector3)> edgeSegmentsFromMesh(MeshDto mesh) {
  final segments = <(vm.Vector3, vm.Vector3)>[];
  for (var i = 0; i + 5 < mesh.edges.length; i += 6) {
    segments.add((
      vm.Vector3(mesh.edges[i], mesh.edges[i + 1], mesh.edges[i + 2]),
      vm.Vector3(mesh.edges[i + 3], mesh.edges[i + 4], mesh.edges[i + 5]),
    ));
  }
  return segments;
}

/// Pushes every point in [segments] towards [cameraPosition] by [amount]
/// world units - see [kEdgeDepthBias]'s doc comment for why towards-camera
/// rather than away-from-mesh-center. The towards-camera direction is
/// recomputed independently for each point (rather than one shared
/// direction for the whole mesh) so it stays reasonably accurate across a
/// mesh whose extent is a significant fraction of its distance to the
/// camera, at the same per-point cost the previous center-based version
/// already paid. A point exactly at [cameraPosition] (zero-length
/// direction - never happens in practice) is left unchanged rather than
/// divided by zero.
List<(vm.Vector3, vm.Vector3)> biasSegmentsTowardCamera(
  List<(vm.Vector3, vm.Vector3)> segments,
  vm.Vector3 cameraPosition,
  double amount,
) {
  vm.Vector3 biased(vm.Vector3 point) {
    final direction = cameraPosition - point;
    if (direction.length2 < 1e-12) return point.clone();
    return point + direction.normalized() * amount;
  }

  return [for (final segment in segments) (biased(segment.$1), biased(segment.$2))];
}

/// Builds the [Node] rendering [segments] as [color]d polylines - one
/// [MeshPrimitive] per segment, combined into a single [Mesh]/[Node] so
/// they share one per-frame `updateForCamera` scan (see `PartViewport`'s
/// `_ScenePainter`), the same pattern [buildSketchGeometryNode] uses.
///
/// GPU-bound (`PolylineGeometry`'s underlying updatable `MeshGeometry`), so
/// - like [geometryFromMesh] - this cannot be exercised in a headless
/// `flutter test` run; [edgeSegmentsFromMesh]/[biasSegmentsTowardCamera]
/// above are the pure, testable counterparts for this data's actual content.
Node buildMeshEdgesNode(
  List<(vm.Vector3, vm.Vector3)> segments, {
  required vm.Vector4 color,
  double width = kEdgeStrokeWidth,
  PolylineCap cap = PolylineCap.butt,
}) {
  final material = UnlitMaterial()
    ..alphaMode = AlphaMode.opaque
    ..baseColorFactor = color;

  final primitives = <MeshPrimitive>[
    for (final segment in segments)
      MeshPrimitive(
        PolylineGeometry([segment.$1, segment.$2], width: width, cap: cap),
        material,
      ),
  ];

  return Node(name: 'mesh-edges', mesh: Mesh.primitives(primitives: primitives));
}

/// Stage 23 Item 3: thicker than [kEdgeStrokeWidth] for both hover and
/// selected edge highlights - "colour change + thickness increase" per the
/// brief - the two states are told apart by colour alone, not by a further
/// width difference between them.
const double kHighlightEdgeStrokeWidth = kEdgeStrokeWidth * 3;

/// Stage 23 Item 3: width (screen pixels, same [PolylineGeometry] convention
/// as [kEdgeStrokeWidth]) of the "small filled circle" vertex highlight
/// marker [buildVertexMarkersNode] renders.
const double kVertexMarkerWidth = 8.0;

/// Turns each of [positions] into a near-zero-length segment - the pure,
/// testable step behind [buildVertexMarkersNode]'s "fake dot" trick: a
/// [PolylineGeometry] segment too short to see as a line, given a large
/// [kVertexMarkerWidth], renders as a constant on-screen-size dot regardless
/// of camera distance (since that width is in screen pixels, not world
/// units - see [kEdgeStrokeWidth]'s doc comment), with no dedicated
/// point-sprite primitive needed.
List<(vm.Vector3, vm.Vector3)> vertexMarkerSegments(List<vm.Vector3> positions) => [
      for (final p in positions) (p, p + vm.Vector3(1e-5, 1e-5, 1e-5)),
    ];

/// Builds a [Node] rendering [positions] as small constant-screen-size dot
/// markers - Stage 23 Item 3's vertex highlight. GPU-bound (delegates to
/// [buildMeshEdgesNode]), so cannot be exercised in a headless `flutter
/// test` run; [vertexMarkerSegments] above is the pure, testable
/// counterpart for this data's actual content.
///
/// Passes [PolylineCap.round] explicitly - [PolylineGeometry]'s own default
/// is [PolylineCap.butt], which on a near-zero-length segment (as
/// [vertexMarkerSegments] builds) draws a flat-capped sliver with virtually
/// no extent along the line's direction rather than a filled circle, since
/// nothing then extends the geometry past each endpoint. Round caps add a
/// camera-facing disk at each endpoint, which is what actually makes this
/// "fake dot" trick render as a dot instead of being invisible.
Node buildVertexMarkersNode(
  List<vm.Vector3> positions, {
  required vm.Vector4 color,
  double width = kVertexMarkerWidth,
}) =>
    buildMeshEdgesNode(
      vertexMarkerSegments(positions),
      color: color,
      width: width,
      cap: PolylineCap.round,
    );

/// Pure vertex/index buffer builder for an ad-hoc triangle list (not a full
/// [MeshDto]) - the testable counterpart to [buildHighlightFacesNode], the
/// same split [meshBuffersFromMesh]/[geometryFromMesh] use above. Each
/// triangle's face normal is computed via cross product, since these ad-hoc
/// highlight triangles (unlike a [MeshDto]'s real ones) carry no separate
/// per-vertex normal data of their own; a degenerate (zero-area) triangle's
/// normal is left as the zero vector rather than dividing by zero.
///
/// Each input triangle is emitted twice — once with original winding (front
/// face) and once with reversed winding (back face) — so highlights are
/// visible from either side of a surface, working around flutter_scene/
/// Impeller's back-face culling.
MeshBuffers triangleHighlightBuffers(List<(vm.Vector3, vm.Vector3, vm.Vector3)> triangles) {
  // Two passes per input triangle: front-face then back-face.
  final totalTriCount = triangles.length * 2;
  final vertexCount = totalTriCount * 3;
  final vertexData = Float32List(vertexCount * 12);

  void writeTriangle(int triIdx, vm.Vector3 a, vm.Vector3 b, vm.Vector3 c) {
    final corners = [a, b, c];
    final cross = (b - a).cross(c - a);
    final normal = cross.length2 < 1e-12 ? vm.Vector3.zero() : cross.normalized();
    for (var i = 0; i < 3; i++) {
      final position = corners[i];
      final base = (triIdx * 3 + i) * 12;
      vertexData[base] = position.x;
      vertexData[base + 1] = position.y;
      vertexData[base + 2] = position.z;
      vertexData[base + 3] = normal.x;
      vertexData[base + 4] = normal.y;
      vertexData[base + 5] = normal.z;
      vertexData[base + 6] = 0; // u
      vertexData[base + 7] = 0; // v
      vertexData[base + 8] = 1; // r
      vertexData[base + 9] = 1; // g
      vertexData[base + 10] = 1; // b
      vertexData[base + 11] = 1; // a
    }
  }

  for (var t = 0; t < triangles.length; t++) {
    final (a, b, c) = triangles[t];
    writeTriangle(t, a, b, c);                      // front face
    writeTriangle(t + triangles.length, a, c, b);   // back face (reversed winding)
  }

  final indices = Uint16List(vertexCount);
  for (var i = 0; i < vertexCount; i++) {
    indices[i] = i;
  }
  return MeshBuffers(
    vertexData: vertexData,
    vertexCount: vertexCount,
    indexData: ByteData.sublistView(indices),
  );
}

/// Builds a [Node] rendering [triangles] as a translucent flat tint - Stage
/// 23 Item 3's face highlight ("subtle tint"). GPU-bound
/// (`UnskinnedGeometry.uploadVertexData`, same as [geometryFromMesh]), so
/// cannot be exercised in a headless `flutter test` run;
/// [triangleHighlightBuffers] above is the pure, testable counterpart for
/// this data's actual content.
Node buildHighlightFacesNode(
  List<(vm.Vector3, vm.Vector3, vm.Vector3)> triangles, {
  required vm.Vector4 color,
}) {
  final buffers = triangleHighlightBuffers(triangles);
  final geometry = UnskinnedGeometry();
  geometry.uploadVertexData(
    ByteData.sublistView(buffers.vertexData),
    buffers.vertexCount,
    buffers.indexData,
  );
  final material = UnlitMaterial()
    ..alphaMode = AlphaMode.blend
    ..baseColorFactor = color;
  return Node(name: 'highlight-faces', mesh: Mesh(geometry, material));
}
