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
library;

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_gpu/gpu.dart' as gpu;
import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart' as vm;

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

/// Target triangle ceiling for the decimated view - tuned for a high-end
/// 2023-class Android flagship (Snapdragon 8 Gen 2 / Adreno 740, the
/// originally-specified target device), not a lower/generic mobile floor.
/// This project has no on-device Flutter test capability in its current
/// sandbox, so this number is a starting point for real-device tuning, not a
/// benchmarked result - raise or lower it once someone can actually watch
/// frame time on the target hardware.
const int kMaxViewerTriangles = 3000000;

/// Longest edge (px) a decoded texture is downsampled to before upload -
/// same target-device reasoning as [kMaxViewerTriangles]. Downsampling
/// happens *during* decode (see [decodeTextureImage]'s use of
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

/// Splits [mesh] into `flutter_scene` [Node]s, batched to stay under
/// `flutter_scene`'s 16-bit index limit (see [_kMaxVerticesPerBatch]) - all
/// batches share the one [material] (and so the one texture, if any), since
/// [DecodedMesh] only ever carries a single base-color texture (see its own
/// doc comment on the single-material scope cut).
List<Node> buildMeshViewerNodes(DecodedMesh mesh, PhysicallyBasedMaterial material) {
  final nodes = <Node>[];
  final triangleCount = mesh.triangleCount;
  for (var start = 0; start < triangleCount; start += _kMaxTrianglesPerBatch) {
    final end = (start + _kMaxTrianglesPerBatch).clamp(0, triangleCount);
    final batchTriangles = end - start;
    final vertexCount = batchTriangles * 3;
    final vertexData = Float32List(vertexCount * 12);
    for (var v = 0; v < vertexCount; v++) {
      final srcBase = (start * 3 + v) * 3;
      final srcUvBase = (start * 3 + v) * 2;
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
    nodes.add(Node(name: 'mesh-viewer-batch-$start', mesh: Mesh(geometry, material)));
  }
  return nodes;
}

/// Builds the shared [PhysicallyBasedMaterial] for [mesh] - textured if
/// [mesh] carries a base-color texture, a flat tint from [baseColourHex]
/// otherwise (so geometry is always visible even before/without a texture,
/// matching this viewer's "grey geometry is an acceptable fallback" scope
/// decision). When a texture *is* present, [baseColourHex] is deliberately
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
Future<PhysicallyBasedMaterial> buildMeshViewerMaterial(
  DecodedMesh mesh, {
  required String baseColourHex,
  required double roughness,
  required double emissiveIntensity,
  required double fixedMetallic,
}) async {
  await ensureSceneResourcesLoaded();
  final hasTexture = mesh.textureBytes != null;
  final material = PhysicallyBasedMaterial()
    ..baseColorFactor = hasTexture ? vm.Vector4(1, 1, 1, 1) : vector4FromHex(baseColourHex)
    ..roughnessFactor = roughness
    ..metallicFactor = fixedMetallic
    ..emissiveFactor = vm.Vector4(emissiveIntensity, emissiveIntensity, emissiveIntensity, 1);
  final textureBytes = mesh.textureBytes;
  if (textureBytes != null) {
    final image = await decodeTextureImage(textureBytes);
    final texture = await uploadTexture(image);
    _bindBaseColorTexture(material, texture);
  }
  return material;
}
