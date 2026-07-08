/// GPU-touching half of the "View Complex Mesh" viewer - the counterpart to
/// `mesh_data.dart`'s pure decoders, mirroring the split `mesh_geometry.dart`
/// already uses for the server-backed viewport (`MeshBuffers` vs
/// `geometryFromMesh`). Nothing here can run in a headless `flutter test`.
///
/// A material's constructor (`UnlitMaterial` originally; `PhysicallyBasedMaterial`
/// since the lighting/shading upgrade - see [buildMeshViewerMaterial]) calls
/// `setFragmentShader(...)` immediately, which throws until
/// `Scene.initializeStaticResources()` has completed at least once -
/// confirmed by a real on-device crash the first time a mesh was picked,
/// since the material was built (in `MeshViewerScreen`) before
/// `_MeshViewerViewport` (whose own `initState` is what calls
/// `initializeStaticResources`) had ever been mounted. [ensureSceneResourcesLoaded]
/// fixes this by memoizing the one real call behind a single shared Future,
/// so every caller - `MeshViewerScreen` before building the material, and
/// `_MeshViewerViewport` before building the Scene - can safely await it as
/// often as needed without knowing (or caring) whether `initializeStaticResources`
/// itself tolerates being called twice.
///
/// FLAGGED FOR ON-DEVICE VERIFICATION: `PhysicallyBasedMaterial`'s
/// `doubleSided` field (see [buildMeshViewerMaterial]) is inferred from a
/// real `flutter_scene` changelog line ("Fixed material.doubleSided being
/// ignored by runtime importer") rather than confirmed directly against
/// this file's own installed source the way `baseColorTexture` was after
/// the earlier `colorTexture` mistake - same "no Flutter SDK in this
/// sandbox" caveat as everything else in this upgrade.
library;

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_gpu/gpu.dart' as gpu;
import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart' as vm;

import '../viewport3d/mesh_geometry.dart' show buildMeshEdgesNode, kEdgeStrokeWidth;
import '../viewport3d/view_preferences.dart' show vector4FromHex;
import 'mesh_data.dart';

Future<void>? _staticResourcesFuture;

/// Awaits `Scene.initializeStaticResources()`, calling it for real only once
/// no matter how many times/places this is awaited from - see this file's
/// top-of-file doc comment for why that matters here specifically.
Future<void> ensureSceneResourcesLoaded() =>
    _staticResourcesFuture ??= Scene.initializeStaticResources();

/// `flutter_scene` 0.18.1 only takes 16-bit vertex indices (see
/// `mesh_geometry.dart`'s `MeshBuffers` doc comment) - a photogrammetry-scale
/// mesh will almost always exceed that, so instead of one draw call per
/// [DecodedMesh] this splits it into multiple [MeshPrimitive]s, each a
/// contiguous, independent vertex range no larger than this. A mobile GPU in
/// the Adreno 740 class handles a few hundred draw calls per frame without
/// difficulty - vertex/fragment throughput, not draw-call count, is the real
/// constraint at this triangle scale.
const int _kMaxVerticesPerBatch = 65535;

/// Triangles per batch, given [_kMaxVerticesPerBatch] and 3 unique
/// vertices/triangle (this file's triangle-soup convention - see
/// `mesh_data.dart`'s `DecodedMesh` doc comment).
const int _kMaxTrianglesPerBatch = _kMaxVerticesPerBatch ~/ 3;

/// Triangle ceiling for the "Mesh" (wireframe) View toggle - deliberately
/// far below `MeshViewerPreferences.maxTriangles` (the user-adjustable
/// overall decimation target - see that class's own doc comment; this used
/// to be a fixed `kMaxViewerTriangles` constant here before that setting
/// existed). Unlike the real Part viewport's edge overlay (a Body's own,
/// comparatively small, number of true OCCT edge polylines - see
/// `mesh_geometry.dart`'s `buildMeshEdgesNode`), an arbitrary imported mesh
/// has no separate edge data at all: the only way to draw one is every
/// triangle's 3 edges, undeduped (a shared edge between two adjacent
/// triangles is simply drawn twice - harmless overdraw, cheaper than a
/// hash-based dedup pass for a cosmetic toggle). At photogrammetry scale
/// (millions of triangles) that's tens of millions of individual line
/// primitives - not something this viewer's target hardware (tuned for a
/// high-end 2023-class Android flagship - Snapdragon 8 Gen 2 / Adreno 740 -
/// not a lower/generic mobile floor; a starting point for real-device
/// tuning, not a benchmarked result, same as every other tunable in this
/// file) can build or render without stalling, so
/// [buildMeshViewerWireframeNode] simply isn't called above this ceiling
/// (see `mesh_viewer_screen.dart`'s own View menu, which disables the
/// toggle instead of silently doing nothing).
const int kMaxWireframeTriangles = 200000;

/// Builds a wireframe overlay [Node] from [mesh]'s triangle soup - every
/// triangle contributes its own 3 edges (undeduped; see
/// [kMaxWireframeTriangles]'s own doc comment on why that's an accepted
/// trade-off here), reusing `mesh_geometry.dart`'s own
/// [buildMeshEdgesNode]/[PolylineGeometry]-based edge renderer rather than a
/// second implementation of the same "list of segments -> Node" step.
/// Caller is expected to have already checked [mesh]'s triangle count
/// against [kMaxWireframeTriangles].
Node buildMeshViewerWireframeNode(DecodedMesh mesh, {vm.Vector4? color}) {
  final positions = mesh.positions;
  final segments = <(vm.Vector3, vm.Vector3)>[];
  for (var t = 0; t < positions.length; t += 9) {
    final a = vm.Vector3(positions[t], positions[t + 1], positions[t + 2]);
    final b = vm.Vector3(positions[t + 3], positions[t + 4], positions[t + 5]);
    final c = vm.Vector3(positions[t + 6], positions[t + 7], positions[t + 8]);
    segments.add((a, b));
    segments.add((b, c));
    segments.add((c, a));
  }
  return buildMeshEdgesNode(segments, color: color ?? vm.Vector4(0, 0, 0, 1), width: kEdgeStrokeWidth);
}

/// Longest edge (px) a decoded texture is downsampled to before upload -
/// same target-device reasoning as `MeshViewerPreferences.maxTriangles`.
/// Downsampling happens *during* decode (see [decodeTextureImage]'s use of
/// `ui.ImageDescriptor.instantiateCodec`), so the full-resolution source
/// image is never held in memory even momentarily.
const int kMaxTextureDimension = 4096;

/// Decodes [bytes] (JPEG/PNG) to a [ui.Image], downsampled during decode (not
/// decoded at full size and resized after) so a source photogrammetry texture
/// atlas - often 4K-16K - never fully materializes in memory. JPEG's decoder
/// in particular can downscale in the DCT domain at 1/2, 1/4, 1/8 steps
/// essentially for free; PNG has no such fast path, but the target size still
/// bounds the final image's own memory footprint.
Future<ui.Image> decodeTextureImage(Uint8List bytes, {int maxDimension = kMaxTextureDimension}) async {
  final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
  final descriptor = await ui.ImageDescriptor.encoded(buffer);
  final scale = math.min(1.0, math.min(maxDimension / descriptor.width, maxDimension / descriptor.height));
  final targetWidth = (descriptor.width * scale).round().clamp(1, descriptor.width);
  final targetHeight = (descriptor.height * scale).round().clamp(1, descriptor.height);
  final codec = await descriptor.instantiateCodec(targetWidth: targetWidth, targetHeight: targetHeight);
  final frame = await codec.getNextFrame();
  return frame.image;
}

/// Uploads [image]'s pixels to a new `flutter_gpu` [gpu.Texture] -
/// `Texture.overwrite` takes the `ByteData` from `toByteData` directly (not
/// a `Uint8List` view of it) and returns `void`, not a success flag - both
/// corrected here after a real on-device build caught them (see this file's
/// git history for the earlier, wrong assumptions). Requires
/// `StorageMode.hostVisible` and exactly `width * height * 4` bytes for an
/// RGBA8 texture (`createTexture`'s default `PixelFormat`), matching
/// `toByteData(format: rawRgba)`'s layout.
Future<gpu.Texture> uploadTexture(ui.Image image) async {
  final byteData = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  if (byteData == null) {
    throw StateError('Could not extract RGBA pixels from decoded texture image');
  }
  final texture = gpu.gpuContext.createTexture(gpu.StorageMode.hostVisible, image.width, image.height);
  texture.overwrite(byteData);
  return texture;
}

/// Sets up this viewer's Scene-wide lighting - a procedural, no-asset ambient
/// fill (so the unlit side of the mesh isn't pure black) plus the single
/// directional "sun" light driven by [lightIntensity] (the "mid lighting"
/// control - see `ScenePreferences`). Mirrors `PartViewport`'s own
/// `_applyLighting`/`EnvironmentMap.studio()` setup exactly, so both
/// viewers in this app look lit the same way.
void applySceneLighting(Scene scene, double lightIntensity) {
  scene.environment = EnvironmentMap.studio();
  scene.directionalLight = DirectionalLight(
    direction: vm.Vector3(-0.3, -1.0, -0.2),
    color: vm.Vector3(1, 1, 1),
    intensity: lightIntensity,
  );
}

/// Confirmed against the real installed `flutter_scene` 0.18.1 source
/// (`UnlitMaterial`'s own `set baseColorTexture` - see
/// `package:flutter_scene/src/material/unlit_material.dart`) after the
/// original unverified guess (`colorTexture`) failed a real on-device build.
/// `PhysicallyBasedMaterial` (adopted for the lighting/shading upgrade, see
/// [buildMeshViewerMaterial]) exposes the identically-named
/// `baseColorTexture` setter - both materials share the same base-color
/// texture-slot convention.
void _bindBaseColorTexture(PhysicallyBasedMaterial material, gpu.Texture texture) {
  material.baseColorTexture = texture;
}

/// Builds the batch [Node]s for one contiguous triangle range of [mesh]
/// (starting at [startTriangle], [triangleCount] long), all sharing the one
/// [material] - split further to stay under `flutter_scene`'s 16-bit index
/// limit (see [_kMaxVerticesPerBatch]). Shared by [buildMeshViewerNodes]'s
/// no-[DecodedMesh.materialGroups] case (the whole mesh is one "range") and
/// its per-[MeshMaterialGroup] case (one call per group).
List<Node> _buildMeshViewerBatches(
  DecodedMesh mesh,
  PhysicallyBasedMaterial material, {
  required int startTriangle,
  required int triangleCount,
}) {
  final nodes = <Node>[];
  for (var start = 0; start < triangleCount; start += _kMaxTrianglesPerBatch) {
    final end = (start + _kMaxTrianglesPerBatch).clamp(0, triangleCount);
    final batchTriangles = end - start;
    final vertexCount = batchTriangles * 3;
    final vertexData = Float32List(vertexCount * 12);
    for (var v = 0; v < vertexCount; v++) {
      final srcBase = ((startTriangle + start) * 3 + v) * 3;
      final srcUvBase = ((startTriangle + start) * 3 + v) * 2;
      final dstBase = v * 12;
      vertexData[dstBase] = mesh.positions[srcBase];
      vertexData[dstBase + 1] = mesh.positions[srcBase + 1];
      vertexData[dstBase + 2] = mesh.positions[srcBase + 2];
      vertexData[dstBase + 3] = mesh.normals[srcBase];
      vertexData[dstBase + 4] = mesh.normals[srcBase + 1];
      vertexData[dstBase + 5] = mesh.normals[srcBase + 2];
      vertexData[dstBase + 6] = mesh.uvs[srcUvBase];
      vertexData[dstBase + 7] = mesh.uvs[srcUvBase + 1];
      vertexData[dstBase + 8] = 1;
      vertexData[dstBase + 9] = 1;
      vertexData[dstBase + 10] = 1;
      vertexData[dstBase + 11] = 1;
    }
    final indices = Uint16List(vertexCount);
    for (var i = 0; i < vertexCount; i++) {
      indices[i] = i;
    }
    final geometry = UnskinnedGeometry();
    geometry.uploadVertexData(
      ByteData.sublistView(vertexData),
      vertexCount,
      ByteData.sublistView(indices),
    );
    nodes.add(Node(name: 'mesh-viewer-batch-${startTriangle + start}', mesh: Mesh(geometry, material)));
  }
  return nodes;
}

/// Splits [mesh] into `flutter_scene` [Node]s. When [mesh] has no
/// [DecodedMesh.materialGroups] (STL/OBJ, or a single-primitive/single-
/// material glTF), every batch shares [materials]' one entry, same as
/// before per-primitive material support existed. When it does (a real
/// multi-material glTF - see [DecodedMesh.materialGroups]'s own doc
/// comment), each group gets its own batches built against its own
/// `materials[i]`, so a triangle range that used material 5 in the source
/// file is drawn with material 5's own (already-built, already-textured)
/// [PhysicallyBasedMaterial], not whichever one happened to be built for
/// material 0. [materials] must have one entry per [DecodedMesh.materialGroups]
/// entry, in the same order (or exactly one entry when there are no groups) -
/// see [buildMeshViewerMaterials].
List<Node> buildMeshViewerNodes(DecodedMesh mesh, List<PhysicallyBasedMaterial> materials) {
  final groups = mesh.materialGroups;
  if (groups == null || groups.isEmpty) {
    return _buildMeshViewerBatches(mesh, materials.first, startTriangle: 0, triangleCount: mesh.triangleCount);
  }
  final nodes = <Node>[];
  for (var g = 0; g < groups.length; g++) {
    nodes.addAll(_buildMeshViewerBatches(
      mesh,
      materials[g],
      startTriangle: groups[g].startTriangle,
      triangleCount: groups[g].triangleCount,
    ));
  }
  return nodes;
}

/// Builds a [PhysicallyBasedMaterial] for [mesh]'s own top-level texture
/// (see [buildMeshViewerMaterials] for the real multi-material case) -
/// textured if [mesh] carries a base-color texture, a flat tint from
/// [baseColourHex] otherwise (so geometry is always visible even before/
/// without a texture, matching this viewer's "grey geometry is an
/// acceptable fallback" scope decision). When a texture *is* present,
/// [baseColourHex] is deliberately
/// ignored (left at white) - a PBR base color factor multiplies the texture,
/// so tinting it by the user's chosen swatch would just darken/recolor a
/// real captured photogrammetry texture for no good reason; the swatch is
/// meant for the untextured (plain geometry) case. Caller awaits this once,
/// then passes the result into [buildMeshViewerNodes]; [roughness]/
/// [emissiveIntensity] map directly to [PhysicallyBasedMaterial]'s own
/// `roughnessFactor`/`emissiveFactor` (see `ScenePreferences` for what these
/// controls mean and their defaults) - `metallicFactor` is fixed at
/// `ScenePreferences.fixedMetallic`, not a caller-supplied parameter, same
/// as the main Part viewport's identical choice.
///
/// Awaits [ensureSceneResourcesLoaded] first - `PhysicallyBasedMaterial`'s
/// constructor touches the base shader library immediately, which throws
/// until that's done at least once (see this file's top-of-file doc
/// comment - originally documented for `UnlitMaterial`, applies identically
/// here).
///
/// Sets `doubleSided = true` - real on-device testing showed some meshes
/// rendering with one side opaque and the other see-through (internal
/// faces visible where an external one should be, flipping depending on
/// view angle): the textbook symptom of backface culling combined with
/// inconsistent triangle winding, which `mesh_geometry.dart`'s own
/// `triangleHighlightBuffers` doc comment already confirms is real in this
/// engine ("flutter_scene/Impeller's back-face culling", worked around
/// there by emitting every highlight triangle with both windings). A real
/// OCCT-tessellated Body's winding is reliably consistent (`geometryFromMesh`
/// has never needed this workaround), but an arbitrary external STL/OBJ/glTF
/// file - especially photogrammetry output - has no such guarantee, and
/// this viewer has no way to detect or repair bad winding in someone else's
/// file. Disabling culling entirely is the robust fix: every triangle
/// renders from both sides regardless of the source file's own winding
/// correctness, at a modest fill-rate cost this viewer's target hardware
/// (see `MeshViewerPreferences.maxTriangles`'s own doc comment) can afford.
Future<PhysicallyBasedMaterial> buildMeshViewerMaterial(
  DecodedMesh mesh, {
  required String baseColourHex,
  required double roughness,
  required double emissiveIntensity,
  required double fixedMetallic,
}) =>
    _buildMaterialForTexture(
      mesh.textureBytes,
      baseColourHex: baseColourHex,
      roughness: roughness,
      emissiveIntensity: emissiveIntensity,
      fixedMetallic: fixedMetallic,
    );

/// One [PhysicallyBasedMaterial] per [DecodedMesh.materialGroups] entry (in
/// the same order, so `materials[i]` is always group `i`'s own material) -
/// or, when [mesh] has no groups at all (STL/OBJ, or a single-primitive
/// glTF), a single-entry list built from [mesh]'s own top-level
/// [DecodedMesh.textureBytes], identical to a bare [buildMeshViewerMaterial]
/// call. See [buildMeshViewerNodes]'s own doc comment for why a real
/// multi-material photogrammetry export needs this instead of the one-
/// texture-for-the-whole-file assumption [buildMeshViewerMaterial] alone
/// makes.
Future<List<PhysicallyBasedMaterial>> buildMeshViewerMaterials(
  DecodedMesh mesh, {
  required String baseColourHex,
  required double roughness,
  required double emissiveIntensity,
  required double fixedMetallic,
}) async {
  final groups = mesh.materialGroups;
  if (groups == null || groups.isEmpty) {
    return [
      await buildMeshViewerMaterial(
        mesh,
        baseColourHex: baseColourHex,
        roughness: roughness,
        emissiveIntensity: emissiveIntensity,
        fixedMetallic: fixedMetallic,
      ),
    ];
  }
  return [
    for (final group in groups)
      await _buildMaterialForTexture(
        group.textureBytes,
        baseColourHex: baseColourHex,
        roughness: roughness,
        emissiveIntensity: emissiveIntensity,
        fixedMetallic: fixedMetallic,
      ),
  ];
}

Future<PhysicallyBasedMaterial> _buildMaterialForTexture(
  Uint8List? textureBytes, {
  required String baseColourHex,
  required double roughness,
  required double emissiveIntensity,
  required double fixedMetallic,
}) async {
  await ensureSceneResourcesLoaded();
  final hasTexture = textureBytes != null;
  final material = PhysicallyBasedMaterial()
    ..baseColorFactor = hasTexture ? vm.Vector4(1, 1, 1, 1) : vector4FromHex(baseColourHex)
    ..roughnessFactor = roughness
    ..metallicFactor = fixedMetallic
    ..emissiveFactor = vm.Vector4(emissiveIntensity, emissiveIntensity, emissiveIntensity, 1)
    ..doubleSided = true;
  if (textureBytes != null) {
    final image = await decodeTextureImage(textureBytes);
    final texture = await uploadTexture(image);
    _bindBaseColorTexture(material, texture);
  }
  return material;
}
