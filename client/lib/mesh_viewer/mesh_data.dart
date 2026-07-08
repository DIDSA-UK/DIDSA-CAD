/// On-device, OCCT-free/backend-free mesh decoding for the "View Complex
/// Mesh" viewer (see `mesh_viewer_screen.dart`). This mirrors
/// `backend/app/document/mesh_import.py`'s decoders in spirit - same STL/glTF
/// formats, same "de-index into a flat triangle soup" convention the backend's
/// own `MeshData`/`MeshDto` already use throughout this codebase (see
/// `mesh_geometry.dart`'s doc comments) - but runs entirely in the Flutter
/// client with no server round-trip at all. That's the whole point: a
/// photogrammetry-scale mesh (millions of triangles, hundreds of MB) never
/// needs to survive the 15s HTTP timeout or the base64-JSON transport
/// overhead the real `ImportFeature` pipeline has, because it never leaves
/// the device.
///
/// This file only builds pure, GPU-independent data - no `flutter_scene`/
/// `flutter_gpu` imports - so it can be unit-tested with plain `flutter test`,
/// the same split `mesh_viewer_render.dart` continues on the GPU-touching
/// side (mirroring `mesh_geometry.dart`'s `MeshBuffers` vs `geometryFromMesh`
/// split).
library;

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

class MeshImportError implements Exception {
  final String message;
  MeshImportError(this.message);
  @override
  String toString() => message;
}

/// A fully de-indexed "triangle soup": triangle `i` owns vertices
/// `[3*i, 3*i+1, 3*i+2]` in [positions]/[normals]/[uvs], with no vertex
/// sharing across triangles - same convention `backend/app/document/mesh.py`
/// already uses for `MeshDto`. Chosen deliberately over a real indexed vertex
/// buffer: it makes both decimation (drop whole triangles) and GPU batching
/// (slice into contiguous vertex ranges, see `mesh_viewer_render.dart`)
/// trivial, at the cost of some extra memory for meshes with heavy vertex
/// sharing (a real glTF/GLB indexed buffer is de-indexed once at decode time
/// to get here).
///
/// [uvs] is all-`(0, 0)` for a format/file with no texture coordinates (STL
/// never has them) - matching `mesh_geometry.dart`'s existing convention for
/// a Body with no texture.
class DecodedMesh {
  final Float32List positions;
  final Float32List normals;
  final Float32List uvs;
  final Uint8List? textureBytes;
  final String? textureMimeType;
  final int? _sourceTriangleCountOverride;

  /// Per-material triangle ranges within [positions]/[normals]/[uvs], for a
  /// glTF/GLB file whose mesh has more than one primitive - a real
  /// photogrammetry export routinely has dozens of primitives, one per
  /// material/texture-atlas-chunk (e.g. one per building facet/section), all
  /// of which get concatenated into this single flat triangle soup during
  /// decode (see `decodeGltf`'s own doc comment). `null`/empty for every
  /// other case (STL, OBJ, or a single-primitive glTF) - [textureBytes]/
  /// [textureMimeType] above are that simpler case's own single texture, and
  /// remain populated even when [materialGroups] is also set (as "whichever
  /// group's texture would have been picked before this field existed" -
  /// harmless, unused once a caller actually reads [materialGroups]).
  ///
  /// Each group's `startTriangle`/`triangleCount` is a contiguous range in
  /// the flat triangle-soup arrays (never interleaved with another group's
  /// triangles - a primitive's own kept triangles, after decimation, are
  /// always written as one unbroken run - see `_decodeGltfDocument`'s
  /// assembly loop).
  final List<MeshMaterialGroup>? materialGroups;

  DecodedMesh({
    required this.positions,
    required this.normals,
    required this.uvs,
    this.textureBytes,
    this.textureMimeType,
    this.materialGroups,
    int? sourceTriangleCount,
  }) : _sourceTriangleCountOverride = sourceTriangleCount;

  int get triangleCount => positions.length ~/ 9;
  int get vertexCount => triangleCount * 3;

  /// The file's true triangle count before any in-decode decimation (see
  /// `decodeStl`/`decodeObj`/`decodeGltf`'s `maxTriangles` parameter) - equal
  /// to [triangleCount] unless decimation actually dropped triangles while
  /// building this instance. Drives the mesh viewer's "showing X of Y
  /// triangles" banner without needing a separate, full-size mesh kept
  /// around just to know what Y was.
  int get sourceTriangleCount => _sourceTriangleCountOverride ?? triangleCount;
}

/// One glTF mesh primitive's own contiguous triangle range and material
/// (base-color texture only, matching [DecodedMesh]'s own single-texture-
/// per-material scope cut - see `mesh_viewer_render.dart`'s doc comments on
/// why only base color is modelled) - see [DecodedMesh.materialGroups]'s own
/// doc comment for why this exists.
class MeshMaterialGroup {
  final int startTriangle;
  final int triangleCount;
  final Uint8List? textureBytes;
  final String? textureMimeType;

  const MeshMaterialGroup({
    required this.startTriangle,
    required this.triangleCount,
    this.textureBytes,
    this.textureMimeType,
  });
}

/// Shared by every decoder's in-decode decimation (STL/OBJ/glTF all call
/// this the same way) - `1` (keep everything) when [maxTriangles] is null
/// or [totalTriangles] is already within budget, otherwise the smallest
/// stride that brings the kept count at or under [maxTriangles].
int _decimationStride(int totalTriangles, int? maxTriangles) {
  if (maxTriangles == null || totalTriangles <= maxTriangles) return 1;
  return (totalTriangles / maxTriangles).ceil();
}

// ---------------------------------------------------------------------------
// STL (binary + ASCII)
// ---------------------------------------------------------------------------

/// Binary STL: 80-byte header, uint32 triangle count, then 50 bytes/triangle
/// (3 floats facet normal, 3x3 floats vertices, uint16 attribute byte count -
/// ignored here, see this file's own doc comment on the non-standard color
/// extension some tools stuff into it). A file is only treated as binary if
/// its declared triangle count exactly matches `(length - 84) / 50` -
/// otherwise this falls back to the ASCII parser, mirroring the backend's own
/// `decode_stl` fallback rule (an ASCII STL that happens to start with bytes
/// resembling a binary header is the classic false-positive this guards
/// against).
///
/// [maxTriangles], if given, decimates *during* decode (stride-skip - see
/// `_decimationStride`) rather than fully decoding every triangle and
/// shrinking afterward (the original approach, since replaced - see
/// `decimateToTriangleBudget`'s own doc comment): a photogrammetry-scale
/// file can be large enough that materializing its *full* triangle count as
/// decoded `Float32List`s, even briefly, risks exhausting memory before
/// decimation ever gets a chance to shrink it down - confirmed by a real
/// on-device crash-to-home-screen loading a very large `.glb`. Bounding peak
/// memory to the *target* budget instead of the *source* size is the fix,
/// applied uniformly across all three formats this file decodes.
DecodedMesh decodeStl(Uint8List bytes, {int? maxTriangles}) {
  if (bytes.length >= 84) {
    final byteData = ByteData.sublistView(bytes);
    final declaredCount = byteData.getUint32(80, Endian.little);
    if (bytes.length == 84 + declaredCount * 50) {
      return _decodeBinaryStl(byteData, declaredCount, maxTriangles);
    }
  }
  return _decodeAsciiStl(utf8.decode(bytes, allowMalformed: true), maxTriangles);
}

DecodedMesh _decodeBinaryStl(ByteData byteData, int triangleCount, int? maxTriangles) {
  final stride = _decimationStride(triangleCount, maxTriangles);
  final keptCount = (triangleCount / stride).ceil();
  final positions = Float32List(keptCount * 9);
  final normals = Float32List(keptCount * 9);
  var outTriangle = 0;
  var offset = 84;
  for (var t = 0; t < triangleCount; t++) {
    if (t % stride != 0) {
      offset += 50; // skip this record entirely - no float decode, no storage
      continue;
    }
    var nx = byteData.getFloat32(offset, Endian.little);
    var ny = byteData.getFloat32(offset + 4, Endian.little);
    var nz = byteData.getFloat32(offset + 8, Endian.little);
    offset += 12;
    final verts = List.generate(3, (_) {
      final v = (
        byteData.getFloat32(offset, Endian.little),
        byteData.getFloat32(offset + 4, Endian.little),
        byteData.getFloat32(offset + 8, Endian.little),
      );
      offset += 12;
      return v;
    });
    offset += 2; // attribute byte count, unused
    if (nx == 0 && ny == 0 && nz == 0) {
      final computed = _faceNormal(verts[0], verts[1], verts[2]);
      nx = computed.$1;
      ny = computed.$2;
      nz = computed.$3;
    }
    final base = outTriangle * 9;
    for (var i = 0; i < 3; i++) {
      positions[base + i * 3] = verts[i].$1;
      positions[base + i * 3 + 1] = verts[i].$2;
      positions[base + i * 3 + 2] = verts[i].$3;
      normals[base + i * 3] = nx;
      normals[base + i * 3 + 1] = ny;
      normals[base + i * 3 + 2] = nz;
    }
    outTriangle++;
  }
  return DecodedMesh(
    positions: Float32List.sublistView(positions, 0, outTriangle * 9),
    normals: Float32List.sublistView(normals, 0, outTriangle * 9),
    uvs: Float32List(outTriangle * 6),
    sourceTriangleCount: triangleCount,
  );
}

DecodedMesh _decodeAsciiStl(String text, int? maxTriangles) {
  final lines = const LineSplitter().convert(text);

  // Cheap pre-count so the decimation stride is known before any vertex
  // data is parsed/stored - see decodeStl's own doc comment for why this
  // matters at photogrammetry scale.
  var totalFacets = 0;
  for (final rawLine in lines) {
    if (rawLine.trim().startsWith('endfacet')) totalFacets++;
  }
  final stride = _decimationStride(totalFacets, maxTriangles);

  final positions = <double>[];
  final normals = <double>[];
  double nx = 0, ny = 0, nz = 0;
  final verts = <(double, double, double)>[];
  var facetIndex = 0;
  final normalRegex = RegExp(r'facet\s+normal\s+(\S+)\s+(\S+)\s+(\S+)');
  final vertexRegex = RegExp(r'vertex\s+(\S+)\s+(\S+)\s+(\S+)');

  void flushFacet() {
    if (verts.length != 3) return;
    final keep = facetIndex % stride == 0;
    facetIndex++;
    if (!keep) {
      verts.clear();
      return;
    }
    var (fnx, fny, fnz) = (nx, ny, nz);
    if (fnx == 0 && fny == 0 && fnz == 0) {
      final computed = _faceNormal(verts[0], verts[1], verts[2]);
      fnx = computed.$1;
      fny = computed.$2;
      fnz = computed.$3;
    }
    for (final v in verts) {
      positions.addAll([v.$1, v.$2, v.$3]);
      normals.addAll([fnx, fny, fnz]);
    }
    verts.clear();
  }

  for (final rawLine in lines) {
    final line = rawLine.trim();
    final normalMatch = normalRegex.firstMatch(line);
    if (normalMatch != null) {
      nx = double.parse(normalMatch.group(1)!);
      ny = double.parse(normalMatch.group(2)!);
      nz = double.parse(normalMatch.group(3)!);
      continue;
    }
    final vertexMatch = vertexRegex.firstMatch(line);
    if (vertexMatch != null) {
      verts.add((
        double.parse(vertexMatch.group(1)!),
        double.parse(vertexMatch.group(2)!),
        double.parse(vertexMatch.group(3)!),
      ));
      continue;
    }
    if (line.startsWith('endfacet')) flushFacet();
  }
  if (positions.isEmpty) {
    throw MeshImportError('Could not parse ASCII STL - no facets found');
  }
  return DecodedMesh(
    positions: Float32List.fromList(positions),
    normals: Float32List.fromList(normals),
    uvs: Float32List(positions.length ~/ 3 * 2),
    sourceTriangleCount: totalFacets,
  );
}

(double, double, double) _faceNormal(
  (double, double, double) a,
  (double, double, double) b,
  (double, double, double) c,
) {
  final ux = b.$1 - a.$1, uy = b.$2 - a.$2, uz = b.$3 - a.$3;
  final vx = c.$1 - a.$1, vy = c.$2 - a.$2, vz = c.$3 - a.$3;
  final cx = uy * vz - uz * vy;
  final cy = uz * vx - ux * vz;
  final cz = ux * vy - uy * vx;
  final len = math.sqrt(cx * cx + cy * cy + cz * cz);
  if (len < 1e-12) return (0, 0, 1);
  return (cx / len, cy / len, cz / len);
}

// ---------------------------------------------------------------------------
// OBJ
// ---------------------------------------------------------------------------

/// Geometry-only OBJ decoder: `v`/`vt`/`vn`/`f` lines, fan-triangulating any
/// face with more than 3 vertices (matches the backend's own `decode_obj`
/// behaviour - see `test_decode_obj_fan_triangulates_a_quad_face`), computing
/// a face normal when a referenced vertex has no `vn` at all.
///
/// Deliberately does not resolve `mtllib`/`usemtl`/a `.mtl`'s `map_Kd`
/// texture image - unlike GLB, OBJ's texture is normally a *separate* file
/// next to the `.obj`/`.mtl`, and a single file picked on a mobile SAF-style
/// picker has no reliable path back to a sibling file (the same constraint
/// `backend/app/document/mesh_import.py`'s `decode_gltf` already documents
/// for a JSON `.gltf`'s external buffer references). Geometry (and UVs, if
/// present, passed straight through unused until a texture-wiring follow-up
/// resolves this) still decodes and renders untextured.
///
/// [maxTriangles], if given, decimates during decode - see `decodeStl`'s
/// own doc comment for why. Unlike STL/glTF, OBJ has no upfront triangle
/// count declared anywhere in the format, so this does a cheap first pass
/// over just the `f` lines' own fan-triangulated counts (`vertsInFace - 2`
/// each) to compute the stride *before* the real parse - which still has to
/// fully populate the `vertices`/`normals`/`uvs` *pools* below regardless of
/// decimation (a face can reference any earlier-or-later `v`/`vn`/`vt` line
/// by index, so which ones end up used isn't known until every face is
/// read) - what decimation actually bounds here is the triangle-soup
/// *output* arrays, which is where the real 3x-per-triangle expansion (and
/// so the real memory cost) lives.
DecodedMesh decodeObj(String text, {int? maxTriangles}) {
  final lines = const LineSplitter().convert(text);

  var totalTriangles = 0;
  for (final rawLine in lines) {
    final line = rawLine.trim();
    if (!line.startsWith('f')) continue;
    final tokens = line.split(RegExp(r'\s+'));
    if (tokens[0] != 'f') continue;
    final vertCount = tokens.length - 1;
    if (vertCount >= 3) totalTriangles += vertCount - 2;
  }
  final stride = _decimationStride(totalTriangles, maxTriangles);

  final vertices = <(double, double, double)>[];
  final normals = <(double, double, double)>[];
  final uvs = <(double, double)>[];
  final positions = <double>[];
  final outNormals = <double>[];
  final outUvs = <double>[];
  var triangleIndex = 0;

  (int, int?, int?) parseFaceVertex(String token) {
    final parts = token.split('/');
    final vi = int.parse(parts[0]);
    final ti = parts.length > 1 && parts[1].isNotEmpty ? int.parse(parts[1]) : null;
    final ni = parts.length > 2 && parts[2].isNotEmpty ? int.parse(parts[2]) : null;
    return (vi, ti, ni);
  }

  int resolveIndex(int rawIndex, int count) => rawIndex > 0 ? rawIndex - 1 : count + rawIndex;

  for (final rawLine in lines) {
    final line = rawLine.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    final tokens = line.split(RegExp(r'\s+'));
    switch (tokens[0]) {
      case 'v':
        vertices.add((double.parse(tokens[1]), double.parse(tokens[2]), double.parse(tokens[3])));
      case 'vn':
        normals.add((double.parse(tokens[1]), double.parse(tokens[2]), double.parse(tokens[3])));
      case 'vt':
        uvs.add((double.parse(tokens[1]), double.parse(tokens[2])));
      case 'f':
        final faceTokens = tokens.sublist(1);
        if (faceTokens.length < 3) continue;
        final faceVerts = faceTokens.map(parseFaceVertex).toList();
        for (final (vi, _, _) in faceVerts) {
          if (resolveIndex(vi, vertices.length) < 0 || resolveIndex(vi, vertices.length) >= vertices.length) {
            throw MeshImportError('OBJ face references unknown vertex index $vi');
          }
        }
        for (var i = 1; i + 1 < faceVerts.length; i++) {
          final keep = triangleIndex % stride == 0;
          triangleIndex++;
          if (!keep) continue;
          final triangleVerts = [faceVerts[0], faceVerts[i], faceVerts[i + 1]];
          var needsNormal = false;
          for (final (vi, ti, ni) in triangleVerts) {
            final v = vertices[resolveIndex(vi, vertices.length)];
            positions.addAll([v.$1, v.$2, v.$3]);
            if (ti != null) {
              final uv = uvs[resolveIndex(ti, uvs.length)];
              outUvs.addAll([uv.$1, uv.$2]);
            } else {
              outUvs.addAll([0, 0]);
            }
            if (ni != null) {
              final n = normals[resolveIndex(ni, normals.length)];
              outNormals.addAll([n.$1, n.$2, n.$3]);
            } else {
              needsNormal = true;
              outNormals.addAll([0, 0, 0]); // filled in below once the triangle is complete
            }
          }
          final t = positions.length ~/ 3;
          if (needsNormal) {
            final a = (positions[(t - 3) * 3], positions[(t - 3) * 3 + 1], positions[(t - 3) * 3 + 2]);
            final b = (positions[(t - 2) * 3], positions[(t - 2) * 3 + 1], positions[(t - 2) * 3 + 2]);
            final c = (positions[(t - 1) * 3], positions[(t - 1) * 3 + 1], positions[(t - 1) * 3 + 2]);
            final n = _faceNormal(a, b, c);
            for (var i = 0; i < 3; i++) {
              outNormals[(t - 3 + i) * 3] = n.$1;
              outNormals[(t - 3 + i) * 3 + 1] = n.$2;
              outNormals[(t - 3 + i) * 3 + 2] = n.$3;
            }
          }
        }
    }
  }

  if (vertices.isEmpty) throw MeshImportError('OBJ file has no vertices');

  return DecodedMesh(
    positions: Float32List.fromList(positions),
    normals: Float32List.fromList(outNormals),
    uvs: Float32List.fromList(outUvs),
    sourceTriangleCount: totalTriangles,
  );
}

// ---------------------------------------------------------------------------
// glTF / GLB
// ---------------------------------------------------------------------------

const int _kComponentByte = 5120;
const int _kComponentUnsignedByte = 5121;
const int _kComponentShort = 5122;
const int _kComponentUnsignedShort = 5123;
const int _kComponentUnsignedInt = 5125;
const int _kComponentFloat = 5126;

/// Decodes either binary `.glb` (magic-byte sniffed) or a plain-JSON `.gltf`
/// with embedded `data:` URI buffers/images - mirrors the backend's own
/// `decode_gltf` dual-path rule exactly (see
/// `backend/app/document/mesh_import.py`), including the same restriction: a
/// JSON `.gltf` referencing an external buffer/image *file* is rejected with
/// a clear error, since a single picked file on a mobile SAF-style picker
/// can't reliably resolve a sibling file next to it.
///
/// Scope cut (documented, not silently assumed away): does not apply node
/// transforms or walk the scene graph - every mesh primitive in the asset is
/// concatenated into one [DecodedMesh] as if it sat untransformed at the
/// origin. True for the common case this viewer targets (a single
/// photogrammetry mesh exported as one node), false for a GLB with a real
/// multi-node hierarchy. Only the first material's `baseColorTexture` (if
/// any) is used, applied to the whole concatenated mesh - a multi-material
/// GLB would need per-primitive materials, not attempted here.
///
/// [maxTriangles], if given, decimates during decode - see `decodeStl`'s own
/// doc comment for why. glTF accessors declare their `count` upfront, so
/// (unlike OBJ) the total triangle count - and so the decimation stride -
/// is known before any vertex-attribute bytes are ever decoded into floats.
DecodedMesh decodeGltf(Uint8List bytes, {int? maxTriangles}) {
  if (bytes.length >= 4 &&
      bytes[0] == 0x67 &&
      bytes[1] == 0x6c &&
      bytes[2] == 0x54 &&
      bytes[3] == 0x46) {
    return _decodeGlb(bytes, maxTriangles);
  }
  return _decodeGltfJson(bytes, maxTriangles);
}

DecodedMesh _decodeGlb(Uint8List bytes, int? maxTriangles) {
  final byteData = ByteData.sublistView(bytes);
  if (bytes.length < 12) throw MeshImportError('GLB file is too short to contain a header');
  final totalLength = byteData.getUint32(8, Endian.little);
  if (totalLength != bytes.length) {
    throw MeshImportError(
      'GLB declared length ($totalLength) does not match actual file length (${bytes.length})',
    );
  }
  Map<String, dynamic>? gltf;
  final buffers = <Uint8List>[];
  var offset = 12;
  while (offset + 8 <= bytes.length) {
    final chunkLength = byteData.getUint32(offset, Endian.little);
    final chunkType = byteData.getUint32(offset + 4, Endian.little);
    final chunkStart = offset + 8;
    final chunkData = bytes.sublist(chunkStart, chunkStart + chunkLength);
    if (chunkType == 0x4e4f534a) {
      gltf = jsonDecode(utf8.decode(chunkData)) as Map<String, dynamic>;
    } else if (chunkType == 0x004e4942) {
      buffers.add(chunkData);
    }
    offset = chunkStart + chunkLength;
  }
  if (gltf == null) throw MeshImportError('GLB file has no JSON chunk');
  return _decodeGltfDocument(gltf, buffers, maxTriangles);
}

DecodedMesh _decodeGltfJson(Uint8List bytes, int? maxTriangles) {
  final Map<String, dynamic> gltf;
  try {
    gltf = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
  } on FormatException catch (e) {
    throw MeshImportError('Could not parse .gltf JSON: $e');
  }
  final rawBuffers = (gltf['buffers'] as List?) ?? const [];
  final buffers = <Uint8List>[
    for (final buffer in rawBuffers) _resolveDataUri((buffer as Map<String, dynamic>)['uri'] as String?, 'buffer'),
  ];
  return _decodeGltfDocument(gltf, buffers, maxTriangles);
}

Uint8List _resolveDataUri(String? uri, String what) {
  if (uri == null || !uri.startsWith('data:')) {
    throw MeshImportError(
      'This .gltf references an external $what file ("$uri") rather than an embedded data: URI - '
      'pick a self-contained file (most authoring tools offer an "embed" export option) instead.',
    );
  }
  final commaIndex = uri.indexOf(',');
  if (commaIndex == -1 || !uri.substring(0, commaIndex).contains('base64')) {
    throw MeshImportError('Unsupported data: URI encoding for $what');
  }
  return base64.decode(uri.substring(commaIndex + 1));
}

/// A glTF node's *world-composed* transform, accumulated by walking the
/// scene graph from a root node down through every ancestor - not just a
/// single node's own TRS. A mesh several levels deep under a chain of
/// parent nodes (an "Empty"/collection wrapper, an armature, a Blender
/// axis-correction node, etc. - all common in real exports) needs every
/// ancestor's transform composed together, not just its own; a
/// root-nodes-only, non-recursive walk misses this entirely, which is why
/// an earlier version of this fix (root-node-only, no recursion into
/// `node.children`) still left real-world Blender exports mirrored.
///
/// [m]/[n] are row-major 3x3 matrices (9 values: row0, row1, row2) - [m] for
/// positions (composed rotation+scale), [n] for normals (composed
/// inverse-transpose, so non-uniform scale at any ancestor level still
/// shades correctly - see `_localTransform`'s own doc comment on why a
/// position matrix can't just be reused for normals). [t] is the composed
/// translation. A node using a raw `matrix` instead of separate
/// translation/rotation/scale fields is rejected with a clear error rather
/// than decomposed (real complexity - handling non-uniform scale/reflection
/// correctly - not attempted here).
class _NodeTransform {
  const _NodeTransform({required this.m, required this.n, required this.t});

  final List<double> m;
  final List<double> n;
  final (double, double, double) t;

  static const identity = _NodeTransform(
    m: [1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0],
    n: [1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0],
    t: (0.0, 0.0, 0.0),
  );
}

List<double> _mat3Mul(List<double> a, List<double> b) {
  final out = List<double>.filled(9, 0.0);
  for (var row = 0; row < 3; row++) {
    for (var col = 0; col < 3; col++) {
      out[row * 3 + col] =
          a[row * 3 + 0] * b[0 * 3 + col] + a[row * 3 + 1] * b[1 * 3 + col] + a[row * 3 + 2] * b[2 * 3 + col];
    }
  }
  return out;
}

(double, double, double) _mat3MulVec(List<double> m, (double, double, double) v) {
  final (x, y, z) = v;
  return (
    m[0] * x + m[1] * y + m[2] * z,
    m[3] * x + m[4] * y + m[5] * z,
    m[6] * x + m[7] * y + m[8] * z,
  );
}

/// Standard right-handed quaternion-to-rotation-matrix formula (glTF spec
/// convention), row-major.
List<double> _quatToMat3((double, double, double, double) q) {
  final (x, y, z, w) = q;
  final xx = x * x, yy = y * y, zz = z * z;
  final xy = x * y, xz = x * z, yz = y * z;
  final wx = w * x, wy = w * y, wz = w * z;
  return [
    1 - 2 * (yy + zz), 2 * (xy - wz), 2 * (xz + wy),
    2 * (xy + wz), 1 - 2 * (xx + zz), 2 * (yz - wx),
    2 * (xz - wy), 2 * (yz + wx), 1 - 2 * (xx + yy),
  ];
}

/// Computes [node]'s own *local* (not yet composed with any ancestor)
/// position matrix, normal matrix, and translation from its
/// translation/rotation/scale fields (each defaults per spec when absent).
/// The normal matrix is `R * diag(1/scale)` rather than reusing the
/// position matrix `R * diag(scale)` as-is: a normal transforms by a
/// surface's inverse-transpose, not the same matrix as a position - under
/// non-uniform scale those two diverge (using the position matrix for
/// normals too would leave shading subtly wrong on any non-uniformly-scaled
/// node), and glTF's separate T/R/S fields can't express shear, so
/// `R * diag(1/scale)` (equivalent to the true inverse-transpose here) is
/// exact rather than an approximation.
_NodeTransform _localTransform(Map<String, dynamic> node) {
  if (node['matrix'] != null) {
    throw MeshImportError(
      'This glTF node uses a raw matrix transform, which this viewer cannot decompose - '
      're-export using separate translation/rotation/scale (most tools default to this).',
    );
  }
  (double, double, double) vec3(String key, (double, double, double) fallback) {
    final raw = node[key] as List?;
    if (raw == null) return fallback;
    return ((raw[0] as num).toDouble(), (raw[1] as num).toDouble(), (raw[2] as num).toDouble());
  }

  final rotationRaw = node['rotation'] as List?;
  final rotation = rotationRaw == null
      ? (0.0, 0.0, 0.0, 1.0)
      : (
          (rotationRaw[0] as num).toDouble(),
          (rotationRaw[1] as num).toDouble(),
          (rotationRaw[2] as num).toDouble(),
          (rotationRaw[3] as num).toDouble(),
        );
  final translation = vec3('translation', (0.0, 0.0, 0.0));
  final (sx, sy, sz) = vec3('scale', (1.0, 1.0, 1.0));
  final r = _quatToMat3(rotation);
  final m = [
    r[0] * sx, r[1] * sy, r[2] * sz,
    r[3] * sx, r[4] * sy, r[5] * sz,
    r[6] * sx, r[7] * sy, r[8] * sz,
  ];
  final n = [
    r[0] / sx, r[1] / sy, r[2] / sz,
    r[3] / sx, r[4] / sy, r[5] / sz,
    r[6] / sx, r[7] / sy, r[8] / sz,
  ];
  return _NodeTransform(m: m, n: n, t: translation);
}

/// Composes [node]'s own local transform onto [parent]'s already-composed
/// one - `parent.m * local.m` for the position matrix and translation
/// (`parent.m * local.t + parent.t`, i.e. the parent's rotation+scale
/// applies to the child's local translation before the parent's own
/// translation is added - the standard scene-graph transform-composition
/// rule), and `parent.n * local.n` for the normal matrix (inverse-transpose
/// of a matrix product reverses to a product of inverse-transposes in the
/// *same* order as the original product, not reversed, so this mirrors the
/// position-matrix composition exactly).
_NodeTransform _composeTransform(_NodeTransform parent, Map<String, dynamic> node) {
  final local = _localTransform(node);
  return _NodeTransform(
    m: _mat3Mul(parent.m, local.m),
    n: _mat3Mul(parent.n, local.n),
    t: _addVec3(_mat3MulVec(parent.m, local.t), parent.t),
  );
}

(double, double, double) _addVec3((double, double, double) a, (double, double, double) b) =>
    (a.$1 + b.$1, a.$2 + b.$2, a.$3 + b.$3);

(double, double, double) _applyPosition(_NodeTransform transform, (double, double, double) p) {
  final (x, y, z) = _mat3MulVec(transform.m, p);
  final (tx, ty, tz) = transform.t;
  return (x + tx, y + ty, z + tz);
}

(double, double, double) _applyNormal(_NodeTransform transform, (double, double, double) v) {
  var (x, y, z) = _mat3MulVec(transform.n, v);
  final len = math.sqrt(x * x + y * y + z * z);
  if (len > 1e-12) {
    x /= len;
    y /= len;
    z /= len;
  }
  return (x, y, z);
}

/// Extensions this decoder cannot read the real geometry of - if any of
/// these appear in the document's spec-mandated `extensionsUsed` list, every
/// accessor lacking a `bufferView` is almost certainly *compressed* data
/// this decoder doesn't understand, not a legitimate spec-legal "all zero"
/// accessor (see `readAccessor`'s own doc comment on that legal case). A
/// real ODM/OpenDroneMap `.glb` export hit exactly this on-device - Draco
/// mesh compression is a common way photogrammetry tools shrink large
/// exports. Checked once, up front, rather than discovered accessor-by-
/// accessor: a Draco file's POSITION/NORMAL/TEXCOORD_0 accessors still
/// declare their real (potentially huge) vertex `count` even though the
/// actual bytes are compressed elsewhere, so blindly zero-filling each one
/// as "legitimately all zero" risks a multi-gigabyte allocation attempt
/// before ever reaching an indices accessor that would otherwise fail
/// cleanly - the likely explanation for a separate, real on-device
/// crash-to-home-screen report on a larger file from the same export
/// pipeline.
const _kUnsupportedGltfExtensions = {
  'KHR_draco_mesh_compression',
  'EXT_meshopt_compression',
};

DecodedMesh _decodeGltfDocument(Map<String, dynamic> gltf, List<Uint8List> buffers, int? maxTriangles) {
  final extensionsUsed = ((gltf['extensionsUsed'] as List?) ?? const []).cast<String>();
  final unsupported = extensionsUsed.where(_kUnsupportedGltfExtensions.contains);
  if (unsupported.isNotEmpty) {
    throw MeshImportError(
      'This glTF/GLB uses ${unsupported.join(', ')}, which this viewer cannot decode - '
      're-export without mesh compression (most tools that use it offer an uncompressed option).',
    );
  }

  final accessors = (gltf['accessors'] as List?) ?? const [];
  final bufferViews = (gltf['bufferViews'] as List?) ?? const [];
  final meshes = (gltf['meshes'] as List?) ?? const [];
  if (meshes.isEmpty) throw MeshImportError('glTF file has no meshes');

  // Every (meshIndex, transform) instance to actually process - one entry
  // per mesh-referencing node reached by recursively walking the active
  // scene's node hierarchy from its root nodes down through every
  // `children` list, composing each ancestor's transform along the way (see
  // `_NodeTransform`'s own doc comment on why composition, not just a
  // root node's own TRS, is needed - a real Blender export's axis-correction
  // and/or object transform is often several levels deep, not on a scene
  // root node directly). Falls back to one identity-transform entry per
  // mesh when the document has no scene graph at all (true of every fixture
  // in this file's own test suite, and of any minimal/synthetic glTF),
  // matching this decoder's pre-node-transform behaviour exactly.
  final meshInstances = <(int, _NodeTransform)>[];
  final nodes = (gltf['nodes'] as List?) ?? const [];
  final scenes = (gltf['scenes'] as List?) ?? const [];
  final sceneIndex = (gltf['scene'] as int?) ?? 0;
  final rootNodeIndices = (scenes.isNotEmpty && nodes.isNotEmpty)
      ? ((scenes[sceneIndex] as Map<String, dynamic>)['nodes'] as List?)?.cast<int>() ?? const []
      : const <int>[];
  if (rootNodeIndices.isEmpty) {
    for (var i = 0; i < meshes.length; i++) {
      meshInstances.add((i, _NodeTransform.identity));
    }
  } else {
    void walk(int nodeIndex, _NodeTransform parentTransform) {
      final node = nodes[nodeIndex] as Map<String, dynamic>;
      final transform = _composeTransform(parentTransform, node);
      final meshIndex = node['mesh'] as int?;
      if (meshIndex != null) meshInstances.add((meshIndex, transform));
      final children = (node['children'] as List?)?.cast<int>() ?? const [];
      for (final childIndex in children) {
        walk(childIndex, transform);
      }
    }

    for (final rootIndex in rootNodeIndices) {
      walk(rootIndex, _NodeTransform.identity);
    }
  }

  // Pre-count the total triangle count from each instance's own accessor
  // `count` field - no vertex-attribute bytes decoded yet - so the
  // decimation stride is known before the real assembly loop below ever
  // runs. Mirrors decodeStl's binary-header pre-count; see decodeGltf's own
  // doc comment for why this matters at photogrammetry scale.
  var totalTriangles = 0;
  for (final (meshIndex, _) in meshInstances) {
    final mesh = meshes[meshIndex] as Map<String, dynamic>;
    for (final primitiveRaw in mesh['primitives'] as List) {
      final primitive = primitiveRaw as Map<String, dynamic>;
      final attributes = primitive['attributes'] as Map<String, dynamic>;
      final positionAccessor = attributes['POSITION'] as int?;
      if (positionAccessor == null) continue;
      final indicesAccessor = primitive['indices'] as int?;
      final elementCount = indicesAccessor != null
          ? (accessors[indicesAccessor] as Map<String, dynamic>)['count'] as int
          : (accessors[positionAccessor] as Map<String, dynamic>)['count'] as int;
      totalTriangles += elementCount ~/ 3;
    }
  }
  final stride = _decimationStride(totalTriangles, maxTriangles);

  /// Reads a POSITION/NORMAL/TEXCOORD_0-style vertex accessor. Does not
  /// apply glTF's "normalized integer" rescaling (dividing an
  /// UNSIGNED_BYTE/UNSIGNED_SHORT component by 255/65535) - POSITION/NORMAL
  /// are FLOAT-only per spec, and the overwhelming majority of real-world
  /// exporters (including every photogrammetry tool this was written for)
  /// use FLOAT for TEXCOORD_0 too, so this is a real but low-probability gap
  /// rather than a silently-assumed-correct one: a normalized-integer
  /// TEXCOORD_0 would read as raw 0-255/0-65535 values instead of 0-1.
  ///
  /// An accessor's `bufferView` is legally optional per spec (means
  /// "all-zero data" unless a `sparse` accessor is also given, which this
  /// decoder doesn't support) - a real ODM/OpenDroneMap `.glb` export hit
  /// this on-device, previously crashing with a raw, unhelpful "type 'Null'
  /// is not a subtype of type 'int'" the moment `bufferView` was force-cast.
  /// Handled here by returning the spec-correct zero-filled data instead.
  List<double> readAccessor(int accessorIndex, int expectedComponents) {
    final accessor = accessors[accessorIndex] as Map<String, dynamic>;
    final count = accessor['count'] as int;
    final bufferViewIndex = accessor['bufferView'] as int?;
    if (bufferViewIndex == null) {
      return List.filled(count * expectedComponents, 0.0);
    }
    final componentType = accessor['componentType'] as int;
    final accessorByteOffset = (accessor['byteOffset'] as int?) ?? 0;
    final bufferView = bufferViews[bufferViewIndex] as Map<String, dynamic>;
    final bufferIndex = bufferView['buffer'] as int;
    final bufferViewByteOffset = (bufferView['byteOffset'] as int?) ?? 0;
    final byteStride = bufferView['byteStride'] as int?;
    final buffer = buffers[bufferIndex];
    final byteData = ByteData.sublistView(buffer);
    final componentSize = switch (componentType) {
      _kComponentByte || _kComponentUnsignedByte => 1,
      _kComponentShort || _kComponentUnsignedShort => 2,
      _kComponentUnsignedInt || _kComponentFloat => 4,
      _ => throw MeshImportError('Unsupported accessor componentType $componentType'),
    };
    final elementSize = componentSize * expectedComponents;
    final stride = byteStride ?? elementSize;
    final base = bufferViewByteOffset + accessorByteOffset;
    final out = <double>[];
    for (var i = 0; i < count; i++) {
      final elementStart = base + i * stride;
      for (var c = 0; c < expectedComponents; c++) {
        final componentStart = elementStart + c * componentSize;
        out.add(switch (componentType) {
          _kComponentFloat => byteData.getFloat32(componentStart, Endian.little),
          _kComponentUnsignedByte => byteData.getUint8(componentStart).toDouble(),
          _kComponentUnsignedShort => byteData.getUint16(componentStart, Endian.little).toDouble(),
          _ => throw MeshImportError('Unsupported vertex componentType $componentType'),
        });
      }
    }
    return out;
  }

  /// See [readAccessor]'s own doc comment on `bufferView` being legally
  /// optional - unlike a vertex accessor, there's no useful "all zeros"
  /// interpretation for an *index* accessor (every triangle would collapse
  /// onto vertex 0), so this rejects that case with a clear error instead
  /// of either crashing or silently producing a degenerate mesh.
  List<int> readIndices(int accessorIndex) {
    final accessor = accessors[accessorIndex] as Map<String, dynamic>;
    final count = accessor['count'] as int;
    final bufferViewIndex = accessor['bufferView'] as int?;
    if (bufferViewIndex == null) {
      throw MeshImportError('glTF index accessor has no bufferView (sparse/all-zero indices are not supported)');
    }
    final componentType = accessor['componentType'] as int;
    final accessorByteOffset = (accessor['byteOffset'] as int?) ?? 0;
    final bufferView = bufferViews[bufferViewIndex] as Map<String, dynamic>;
    final bufferIndex = bufferView['buffer'] as int;
    final bufferViewByteOffset = (bufferView['byteOffset'] as int?) ?? 0;
    final buffer = buffers[bufferIndex];
    final byteData = ByteData.sublistView(buffer);
    final base = bufferViewByteOffset + accessorByteOffset;
    final componentSize = switch (componentType) {
      _kComponentUnsignedByte => 1,
      _kComponentUnsignedShort => 2,
      _kComponentUnsignedInt => 4,
      _ => throw MeshImportError('Unsupported index componentType $componentType'),
    };
    return [
      for (var i = 0; i < count; i++)
        switch (componentType) {
          _kComponentUnsignedByte => byteData.getUint8(base + i),
          _kComponentUnsignedShort => byteData.getUint16(base + i * 2, Endian.little),
          _kComponentUnsignedInt => byteData.getUint32(base + i * 4, Endian.little),
          _ => throw MeshImportError('Unreachable'),
        },
    ];
  }

  final positions = <double>[];
  final normals = <double>[];
  final uvs = <double>[];
  var triangleIndex = 0;

  // One entry per mesh primitive that actually contributed a triangle -
  // real photogrammetry exports routinely have one primitive/material per
  // building facet or texture-atlas chunk (a real ODM/Blender export this
  // was tested against has 39) - see [DecodedMesh.materialGroups]'s own doc
  // comment. Cached per material index so a texture referenced by more than
  // one primitive is only extracted (byte-sliced, not yet image-decoded -
  // that's `mesh_viewer_render.dart`'s job) once.
  final materialGroups = <MeshMaterialGroup>[];
  final textureCache = <int, (Uint8List, String)?>{};
  (Uint8List, String)? textureForMaterial(int materialIndex) =>
      textureCache.putIfAbsent(materialIndex, () => _extractBaseColorTexture(gltf, buffers, materialIndex));

  for (final (meshIndex, transform) in meshInstances) {
    final mesh = meshes[meshIndex] as Map<String, dynamic>;
    final isIdentity = identical(transform, _NodeTransform.identity);
    for (final primitiveRaw in mesh['primitives'] as List) {
      final primitive = primitiveRaw as Map<String, dynamic>;
      final attributes = primitive['attributes'] as Map<String, dynamic>;
      final positionAccessor = attributes['POSITION'] as int?;
      if (positionAccessor == null) continue;
      final rawPositions = readAccessor(positionAccessor, 3);
      final vertexCount = rawPositions.length ~/ 3;
      final rawNormals = attributes['NORMAL'] != null
          ? readAccessor(attributes['NORMAL'] as int, 3)
          : null;
      final rawUvs = attributes['TEXCOORD_0'] != null
          ? readAccessor(attributes['TEXCOORD_0'] as int, 2)
          : null;
      final indicesAccessor = primitive['indices'] as int?;
      final indices = indicesAccessor != null
          ? readIndices(indicesAccessor)
          : List.generate(vertexCount, (i) => i);

      final groupStartTriangle = positions.length ~/ 9;
      for (var i = 0; i + 2 < indices.length; i += 3) {
        final keep = triangleIndex % stride == 0;
        triangleIndex++;
        if (!keep) continue;
        for (final vi in [indices[i], indices[i + 1], indices[i + 2]]) {
          var p = (rawPositions[vi * 3], rawPositions[vi * 3 + 1], rawPositions[vi * 3 + 2]);
          if (!isIdentity) p = _applyPosition(transform, p);
          positions.addAll([p.$1, p.$2, p.$3]);
          if (rawNormals != null) {
            var n = (rawNormals[vi * 3], rawNormals[vi * 3 + 1], rawNormals[vi * 3 + 2]);
            if (!isIdentity) n = _applyNormal(transform, n);
            normals.addAll([n.$1, n.$2, n.$3]);
          }
          if (rawUvs != null) {
            uvs.addAll([rawUvs[vi * 2], rawUvs[vi * 2 + 1]]);
          } else {
            uvs.addAll([0, 0]);
          }
        }
        if (rawNormals == null) {
          final t = positions.length ~/ 3;
          final a = (positions[(t - 3) * 3], positions[(t - 3) * 3 + 1], positions[(t - 3) * 3 + 2]);
          final b = (positions[(t - 2) * 3], positions[(t - 2) * 3 + 1], positions[(t - 2) * 3 + 2]);
          final c = (positions[(t - 1) * 3], positions[(t - 1) * 3 + 1], positions[(t - 1) * 3 + 2]);
          final n = _faceNormal(a, b, c);
          normals.addAll([n.$1, n.$2, n.$3, n.$1, n.$2, n.$3, n.$1, n.$2, n.$3]);
        }
      }
      final groupTriangleCount = (positions.length ~/ 9) - groupStartTriangle;
      if (groupTriangleCount > 0) {
        final materialIndex = (primitive['material'] as int?) ?? 0;
        final texture = textureForMaterial(materialIndex);
        materialGroups.add(MeshMaterialGroup(
          startTriangle: groupStartTriangle,
          triangleCount: groupTriangleCount,
          textureBytes: texture?.$1,
          textureMimeType: texture?.$2,
        ));
      }
    }
  }

  if (positions.isEmpty) throw MeshImportError('glTF file has no usable geometry');

  final firstTexture = materialGroups.isEmpty ? null : (materialGroups.first.textureBytes, materialGroups.first.textureMimeType);

  return DecodedMesh(
    positions: Float32List.fromList(positions),
    normals: Float32List.fromList(normals),
    uvs: Float32List.fromList(uvs),
    textureBytes: firstTexture?.$1,
    textureMimeType: firstTexture?.$2,
    materialGroups: materialGroups,
    sourceTriangleCount: totalTriangles,
  );
}

/// Extracts [materialIndex]'s own base-color texture bytes (if it has one) -
/// `null` for a document with no materials, an out-of-range index, or a
/// material with no `baseColorTexture` at all (untextured/flat-colour).
/// Caller passes each primitive's own `material` index (falling back to `0`
/// when unset, matching a primitive with no `material` field using the
/// document's first material per spec) rather than always reading
/// `materials.first` - a real photogrammetry export routinely has one
/// material (and so one texture) per mesh primitive, not one for the whole
/// file (see `_decodeGltfDocument`'s own doc comment on `materialGroups`).
(Uint8List, String)? _extractBaseColorTexture(Map<String, dynamic> gltf, List<Uint8List> buffers, int materialIndex) {
  final materials = (gltf['materials'] as List?) ?? const [];
  if (materialIndex < 0 || materialIndex >= materials.length) return null;
  final material = materials[materialIndex] as Map<String, dynamic>;
  final pbr = material['pbrMetallicRoughness'] as Map<String, dynamic>?;
  final baseColorTexture = pbr?['baseColorTexture'] as Map<String, dynamic>?;
  if (baseColorTexture == null) return null;
  final textureIndex = baseColorTexture['index'] as int;
  final textures = (gltf['textures'] as List?) ?? const [];
  if (textureIndex >= textures.length) return null;
  final texture = textures[textureIndex] as Map<String, dynamic>;
  final imageIndex = texture['source'] as int?;
  if (imageIndex == null) return null;
  final images = (gltf['images'] as List?) ?? const [];
  if (imageIndex >= images.length) return null;
  final image = images[imageIndex] as Map<String, dynamic>;

  if (image['uri'] != null) {
    final uri = image['uri'] as String;
    if (!uri.startsWith('data:')) return null; // external file - skip, geometry still renders untextured
    final commaIndex = uri.indexOf(',');
    final mimeType = uri.substring(5, uri.indexOf(';'));
    return (base64.decode(uri.substring(commaIndex + 1)), mimeType);
  }

  final bufferViewIndex = image['bufferView'] as int?;
  if (bufferViewIndex == null) return null;
  final bufferViews = (gltf['bufferViews'] as List?) ?? const [];
  final bufferView = bufferViews[bufferViewIndex] as Map<String, dynamic>;
  final bufferIndex = bufferView['buffer'] as int;
  final byteOffset = (bufferView['byteOffset'] as int?) ?? 0;
  final byteLength = bufferView['byteLength'] as int;
  final mimeType = (image['mimeType'] as String?) ?? 'image/jpeg';
  final bytes = buffers[bufferIndex].sublist(byteOffset, byteOffset + byteLength);
  return (Uint8List.fromList(bytes), mimeType);
}

// ---------------------------------------------------------------------------
// Decimation
// ---------------------------------------------------------------------------

/// Drops whole triangles at a fixed stride until [mesh] is at or under
/// [maxTriangles] - chosen over vertex clustering deliberately: clustering
/// merges vertices that may carry different UV coordinates (different parts
/// of a texture atlas), which distorts or seams the texture; dropping whole
/// triangles never merges anything; each surviving triangle keeps its
/// original, unmodified vertices/UVs. Trades a smoother-looking simplification
/// for texture correctness - an accepted trade-off for a viewer, not a
/// numerically-optimal decimation.
///
/// No longer the mesh viewer's primary decimation mechanism - `decodeStl`/
/// `decodeObj`/`decodeGltf` all now decimate *during* decode via their own
/// `maxTriangles` parameter, so peak memory is bounded by the target budget
/// rather than the full source mesh (a real on-device crash-to-home-screen
/// on a very large `.glb` motivated that change - operating on an
/// *already-fully-decoded* [mesh] here can't help with that, since the
/// expensive part already happened by the time this runs). Kept as a
/// standalone utility for a caller that already has a full [DecodedMesh]
/// from somewhere else and wants it shrunk further.
///
/// Returns [mesh] unchanged (same instance) if it's already within budget.
DecodedMesh decimateToTriangleBudget(DecodedMesh mesh, int maxTriangles) {
  final triangleCount = mesh.triangleCount;
  if (triangleCount <= maxTriangles) return mesh;
  final stride = (triangleCount / maxTriangles).ceil();
  final keptCount = (triangleCount / stride).ceil();
  final positions = Float32List(keptCount * 9);
  final normals = Float32List(keptCount * 9);
  final uvs = Float32List(keptCount * 6);
  var outTriangle = 0;
  for (var t = 0; t < triangleCount; t += stride) {
    positions.setRange(outTriangle * 9, outTriangle * 9 + 9, mesh.positions, t * 9);
    normals.setRange(outTriangle * 9, outTriangle * 9 + 9, mesh.normals, t * 9);
    uvs.setRange(outTriangle * 6, outTriangle * 6 + 6, mesh.uvs, t * 6);
    outTriangle++;
  }
  return DecodedMesh(
    positions: Float32List.sublistView(positions, 0, outTriangle * 9),
    normals: Float32List.sublistView(normals, 0, outTriangle * 9),
    uvs: Float32List.sublistView(uvs, 0, outTriangle * 6),
    textureBytes: mesh.textureBytes,
    textureMimeType: mesh.textureMimeType,
    sourceTriangleCount: mesh.sourceTriangleCount,
  );
}

// ---------------------------------------------------------------------------
// Up-axis correction
// ---------------------------------------------------------------------------

/// Which axis this decoder should treat as "up" when building a mesh for
/// display - see [applyUpAxis]'s own doc comment for why this needs to be a
/// user choice rather than something auto-detected.
enum MeshUpAxis { y, z }

/// A real Blender-exported glTF was found rendering "on its side"/"inside
/// out" (a wide, thin property scan appeared thin in *depth* rather than
/// *height*) despite this decoder correctly following the glTF spec (Y-up) -
/// this decoder's node-transform and decimation logic were independently
/// re-checked and ruled out (see `docs/status.md`'s own investigation).
/// The real cause: the file's own data is not actually Y-up, most likely
/// because Blender's "+Y Up" export conversion was skipped (a real,
/// user-facing option in Blender's glTF exporter, off meaning "export raw
/// Blender-native Z-up coordinates as-is") - Blender's own viewport still
/// shows such a file "correctly" only because it's a self-consistent round
/// trip through the same tool, not because the file is actually spec-
/// compliant. There is no reliable way to detect this from the file alone
/// (a correctly Y-up file and a mislabeled Z-up file are structurally
/// identical glTF), so this is a manual, user-facing choice instead.
///
/// [MeshUpAxis.y] is a no-op (returns [mesh] unchanged) - this decoder
/// already assumes Y-up per spec, so "the file's data is already correct"
/// needs no correction. [MeshUpAxis.z] applies `(x, y, z) -> (x, z, -y)` -
/// the same axis permutation Blender's own exporter uses to convert its
/// native Z-up scene into glTF's Y-up convention, applied here a second
/// time for a file that skipped it once. Deliberately a proper rotation
/// (determinant +1: this is a 90-degree rotation about the X axis), not a
/// bare axis swap (`(x, y, z) -> (x, z, y)`, determinant -1) - a bare swap
/// would "fix" the up-axis at the cost of introducing a genuine mirror
/// reflection, reproducing a different version of the exact bug this
/// exists to correct.
DecodedMesh applyUpAxis(DecodedMesh mesh, MeshUpAxis axis) {
  if (axis == MeshUpAxis.y) return mesh;

  Float32List rotate(Float32List src) {
    final out = Float32List(src.length);
    for (var i = 0; i + 2 < src.length; i += 3) {
      out[i] = src[i];
      out[i + 1] = src[i + 2];
      out[i + 2] = -src[i + 1];
    }
    return out;
  }

  return DecodedMesh(
    positions: rotate(mesh.positions),
    normals: rotate(mesh.normals),
    uvs: mesh.uvs,
    textureBytes: mesh.textureBytes,
    textureMimeType: mesh.textureMimeType,
    materialGroups: mesh.materialGroups,
    sourceTriangleCount: mesh.sourceTriangleCount,
  );
}
