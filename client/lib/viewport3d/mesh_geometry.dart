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

/// How far [nudgeSegmentsOutward] pushes each edge point away from the
/// mesh's bounding-sphere center, in world units - flutter_scene 0.18.1 has
/// no GPU depth-bias control, so this is the closest available substitute
/// for preventing z-fighting between the filled mesh and its edge overlay
/// in `shadedWithEdges` mode: a small static geometric offset rather than a
/// per-pixel depth adjustment.
const double meshEdgeNudgeAmount = 0.02;

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

/// Pushes every point in [segments] away from [center] by [amount] world
/// units - see [meshEdgeNudgeAmount]'s doc comment for why. A point
/// exactly at [center] (zero-length direction) is left unchanged rather
/// than divided by zero.
List<(vm.Vector3, vm.Vector3)> nudgeSegmentsOutward(
  List<(vm.Vector3, vm.Vector3)> segments,
  vm.Vector3 center,
  double amount,
) {
  vm.Vector3 nudged(vm.Vector3 point) {
    final direction = point - center;
    if (direction.length2 < 1e-12) return point.clone();
    return point + direction.normalized() * amount;
  }

  return [for (final segment in segments) (nudged(segment.$1), nudged(segment.$2))];
}

/// Builds the [Node] rendering [segments] as [color]d polylines - one
/// [MeshPrimitive] per segment, combined into a single [Mesh]/[Node] so
/// they share one per-frame `updateForCamera` scan (see `PartViewport`'s
/// `_ScenePainter`), the same pattern [buildSketchGeometryNode] uses.
///
/// GPU-bound (`PolylineGeometry`'s underlying updatable `MeshGeometry`), so
/// - like [geometryFromMesh] - this cannot be exercised in a headless
/// `flutter test` run; [edgeSegmentsFromMesh]/[nudgeSegmentsOutward] above
/// are the pure, testable counterparts for this data's actual content.
Node buildMeshEdgesNode(
  List<(vm.Vector3, vm.Vector3)> segments, {
  required vm.Vector4 color,
  double width = kEdgeStrokeWidth,
}) {
  final material = UnlitMaterial()
    ..alphaMode = AlphaMode.opaque
    ..baseColorFactor = color;

  final primitives = <MeshPrimitive>[
    for (final segment in segments)
      MeshPrimitive(PolylineGeometry([segment.$1, segment.$2], width: width), material),
  ];

  return Node(name: 'mesh-edges', mesh: Mesh.primitives(primitives: primitives));
}
