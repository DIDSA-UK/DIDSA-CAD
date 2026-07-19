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
///
/// [doubleSidedWinding]: face-culling bug fix - `flutter_scene`'s
/// `Material.bind()` always back-face-culls a translucent (`AlphaMode.blend`)
/// material's geometry regardless of `Material.doubleSided` (the same
/// `cullBackFace = !doubleSided || !isOpaque()` quirk documented on
/// `reference_planes.dart`'s `doubleSidedQuadBuffers`, and worked around for
/// ad-hoc highlight triangles by [triangleHighlightBuffers] below) - a body
/// rendered at `bodyOpacity < 1.0` (e.g. the sketcher's Orbit View, or the
/// main viewport's own Body Transparency slider) hit this for real: whole
/// back-facing triangles of the solid vanished instead of just fading, since
/// `doubleSided: true` alone is not enough once the material is translucent.
/// Set true to emit a second, reverse-wound copy of every triangle (with
/// flipped normals, so lighting/shading still reads correctly from either
/// side) - the same fix, applied to real mesh geometry instead of a simple
/// quad or ad-hoc triangle list. Doubles [MeshBuffers.vertexCount], so it
/// halves this file's existing 65535-vertex 16-bit-index ceiling (see
/// [MeshBuffers]'s own doc comment) for any mesh rendered translucent.
MeshBuffers meshBuffersFromMesh(MeshDto mesh, {bool doubleSidedWinding = false}) {
  final vertexCount = mesh.vertices.length;
  final copies = doubleSidedWinding ? 2 : 1;
  final vertexData = Float32List(vertexCount * 12 * copies);

  void writeVertexCopy(int copyIndex, double normalSign) {
    final vertexOffset = copyIndex * vertexCount;
    for (var i = 0; i < vertexCount; i++) {
      final position = mesh.vertices[i];
      final normal = mesh.normals[i];
      final base = (vertexOffset + i) * 12;
      vertexData[base] = position[0];
      vertexData[base + 1] = position[1];
      vertexData[base + 2] = position[2];
      vertexData[base + 3] = normal[0] * normalSign;
      vertexData[base + 4] = normal[1] * normalSign;
      vertexData[base + 5] = normal[2] * normalSign;
      vertexData[base + 6] = 0; // u
      vertexData[base + 7] = 0; // v
      vertexData[base + 8] = 1; // r
      vertexData[base + 9] = 1; // g
      vertexData[base + 10] = 1; // b
      vertexData[base + 11] = 1; // a
    }
  }

  writeVertexCopy(0, 1.0);
  if (doubleSidedWinding) writeVertexCopy(1, -1.0);

  final triangleCount = mesh.triangleIndices.length;
  final indexCount = triangleCount * 3 * copies;
  final indices = Uint16List(indexCount);
  var i = 0;
  for (final triangle in mesh.triangleIndices) {
    indices[i++] = triangle[0];
    indices[i++] = triangle[1];
    indices[i++] = triangle[2];
  }
  if (doubleSidedWinding) {
    for (final triangle in mesh.triangleIndices) {
      // Reversed winding (so it's front-facing when viewed from the
      // opposite side), referencing the second, normal-flipped vertex copy.
      indices[i++] = vertexCount + triangle[0];
      indices[i++] = vertexCount + triangle[2];
      indices[i++] = vertexCount + triangle[1];
    }
  }

  return MeshBuffers(
    vertexData: vertexData,
    vertexCount: vertexCount * copies,
    indexData: ByteData.sublistView(indices),
  );
}

/// Converts a backend [MeshDto] into a `flutter_scene` [UnskinnedGeometry].
///
/// This calls [UnskinnedGeometry.uploadVertexData], which internally calls
/// into `flutter_scene`'s GPU shim to allocate a device buffer - a real
/// GPU/Impeller context is needed for that, so unlike [meshBuffersFromMesh]
/// this function cannot be exercised in a headless `flutter test` run.
UnskinnedGeometry geometryFromMesh(MeshDto mesh, {bool doubleSidedWinding = false}) {
  final buffers = meshBuffersFromMesh(mesh, doubleSidedWinding: doubleSidedWinding);
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

/// Prompt A3: [boundsOfMesh] extended across every Body (Prompt A1's
/// `/mesh` array) - the true AABB of every Body's vertices combined, not an
/// approximation from unioning each Body's own bounding sphere. Returns
/// `null` only when every Body is empty (or [bodies] itself is), same
/// null-when-empty contract as [boundsOfMesh].
MeshBounds? boundsOfBodies(List<BodyMeshDto> bodies) {
  vm.Vector3? min;
  vm.Vector3? max;
  for (final body in bodies) {
    for (final vertex in body.mesh.vertices) {
      final p = vm.Vector3(vertex[0], vertex[1], vertex[2]);
      min = min == null
          ? p
          : vm.Vector3(math.min(min.x, p.x), math.min(min.y, p.y), math.min(min.z, p.z));
      max = max == null
          ? p
          : vm.Vector3(math.max(max.x, p.x), math.max(max.y, p.y), math.max(max.z, p.z));
    }
  }
  if (min == null || max == null) return null;
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
/// the same frame). This constant was reset to a fixed world-space amount -
/// the same value (`0.02`) the pre-existing, already-shipped
/// `meshEdgeNudgeAmount` used, so it inherited whatever on-device tuning
/// that had - with only the *direction* changed, not the magnitude.
///
/// Bumped from `0.02` to `0.1` after a real, much bigger occlusion bug (an
/// Android MSAA offscreen-depth-resolve issue - see `PartViewport`'s
/// `antiAliasingMode = AntiAliasingMode.none`) was found and fixed
/// separately: with that fixed, the only remaining on-device symptom was
/// specific edges rendering as broken/dashed lines (not solid overlays) at
/// full body opacity - the textbook signature of borderline z-fighting,
/// not a wholesale occlusion failure. `0.02` was tuned against a scene
/// that (unknown at the time) also had the MSAA bug active, so it may
/// simply have been too small once that confound is removed.
///
/// `0.1` still wasn't enough for a curved surface's far-side silhouette
/// (a cylindrical disc's back rim, viewed at a glancing angle), which
/// prompted bumping it to `0.3` - but `0.3` turned out to be a real
/// regression of the *other* kind, caught by on-device testing against a
/// part with several thin, closely-spaced features (a serrated/comb
/// shape, and a part with a thin wall between an inner and outer
/// boundary): edges hidden behind one or two of those thin layers were
/// still incorrectly visible, only becoming correctly hidden once three
/// layers stacked up - a graduated "N layers needed" pattern that a
/// working depth test should never produce (a truly occluded edge is
/// binary: hidden or not, regardless of how many surfaces are in front of
/// it). That pattern is the signature of the bias itself being *larger
/// than the gap between layers* - biasing an edge 0.3 units towards the
/// camera happily pushes it in front of one or two thin walls/teeth
/// whose combined thickness is under 0.3, and only fails once enough of
/// them stack up to exceed it. This is the same class of regression as
/// the original stepped-part bias bug from several rounds earlier (a
/// bias too large for the *local* feature it's near, independent of the
/// object's overall size) - `0.3` was simply large enough to trigger it
/// again against different, thinner geometry.
///
/// Reverted to `0.05` - a compromise nearer the low end, since incorrectly
/// reordering real, nearby geometry (this regression) is worse than
/// residual dashing at a glancing curved silhouette (the problem `0.1`/
/// `0.3` were chasing). No single fixed bias can fully solve both: a
/// value large enough to always beat glancing-silhouette z-fighting will
/// always risk exceeding *some* real feature's thickness, however small.
/// Approach 3 from this file's evaluation above `biasSegmentsTowardCamera`
/// (scale the offset to the local geometry - e.g. only enlarging it on
/// segments nearly parallel to their own face's normal - rather than one
/// global constant) is the actual fix for wanting both at once, at the
/// cost of the backend edge/face adjacency data it needs, which does not
/// currently exist (see that evaluation's item 3).
const double kEdgeDepthBias = 0.05;

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
/// Uses [AlphaMode.opaque] - reverted back from a brief [AlphaMode.blend]
/// experiment (see git history) that turned out to make things worse, not
/// better: on-device testing after that switch showed edges rendering
/// through solid bodies *completely* (not the glancing-angle flicker this
/// file's other fixes target) - the same "renders through the body
/// regardless of what's in front of it" signature independently confirmed
/// for [buildHighlightFacesNode]'s face highlights, which have used
/// `AlphaMode.blend` (the translucent pass) unchanged since Stage 23. The
/// working theory, backed by both of these independently reproducing the
/// same failure mode the moment something moved onto the translucent pass:
/// `flutter_scene` 0.18.1's translucent pass is *supposed to* (per its own
/// source - see `buildHighlightFacesNode`'s doc comment) depth-test against
/// the same buffer the opaque pass writes, but does not reliably do so on
/// at least the on-device hardware this was tested against. The opaque
/// pass, in contrast, has only ever shown the smaller, separate
/// glancing-angle flicker these edges already have other fixes for -
/// never a wholesale occlusion failure - so it's the one worth trusting
/// for anything that actually needs to be hidden behind other geometry.
///
/// `AlphaMode.opaque` "ignores alpha" per [UnlitMaterial]'s own doc
/// comment, so a partial-alpha edge color (e.g. a selected-edge highlight)
/// renders fully solid rather than translucent - an accepted, temporary
/// trade-off for correct occlusion, same as [buildHighlightFacesNode]'s.
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

/// Builds a [Node] rendering [triangles] as a flat tint - Stage 23 Item 3's
/// face highlight. GPU-bound (`UnskinnedGeometry.uploadVertexData`, same as
/// [geometryFromMesh]), so cannot be exercised in a headless `flutter test`
/// run; [triangleHighlightBuffers] above is the pure, testable counterpart
/// for this data's actual content.
///
/// Forced to [AlphaMode.opaque] instead of the originally-intended
/// [AlphaMode.blend] "subtle translucent tint" look, in response to a real
/// on-device report that a highlighted face on the far side of a body
/// renders through it (i.e. isn't occluded), reproduced with *no* edges
/// involved at all. This should not have been necessary per
/// `flutter_scene` 0.18.1's own source (its translucent pass is documented
/// to depth-test against the same buffer the opaque pass writes), but
/// switching this from `AlphaMode.blend` to `AlphaMode.opaque` is
/// corroborated by an independent, matching on-device regression: routing
/// [buildMeshEdgesNode]'s edges through the same translucent pass (an
/// intermediate fix, since reverted - see its own doc comment) made edges
/// go from "mostly correct, occasional glancing-angle flicker" to
/// "renders through the body with total disregard for what's in front of
/// it" - the same failure signature this face-highlight bug has. Working
/// theory: the translucent pass's depth test is not reliably functioning
/// on at least the on-device hardware this was tested against, so nothing
/// that needs real occlusion should use it, regardless of what the engine's
/// own source says it ought to do.
///
/// `AlphaMode.opaque` "ignores alpha" (per [UnlitMaterial]'s own doc
/// comment), so [color]'s partial alpha no longer has any visual effect -
/// the highlight renders as a fully solid/saturated tint rather than a
/// translucent one, an accepted trade-off for correct occlusion.
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
    ..alphaMode = AlphaMode.opaque
    ..baseColorFactor = color;
  return Node(name: 'highlight-faces', mesh: Mesh(geometry, material));
}

/// On-device feedback ("the selected face colour was very similar to the
/// body colour I had selected"): [PartViewport]'s selected-face highlight
/// used to be one fixed color, which is guaranteed to eventually collide
/// with *some* user-chosen Body Colour. Picks whichever entry in
/// [palette] is furthest (by squared RGB distance - cheap, and monotonic
/// with true distance so it picks the same winner) from [referenceColor],
/// so the highlight stays visually distinct regardless of what the body
/// itself is colored. [palette] must be non-empty.
vm.Vector4 highContrastColorFrom(List<vm.Vector4> palette, vm.Vector4 referenceColor) {
  double distanceSquared(vm.Vector4 a, vm.Vector4 b) {
    final dr = a.x - b.x, dg = a.y - b.y, db = a.z - b.z;
    return dr * dr + dg * dg + db * db;
  }

  return palette.reduce(
    (best, candidate) =>
        distanceSquared(candidate, referenceColor) > distanceSquared(best, referenceColor) ? candidate : best,
  );
}
