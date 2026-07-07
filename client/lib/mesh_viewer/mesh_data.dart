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

  DecodedMesh({
    required this.positions,
    required this.normals,
    required this.uvs,
    this.textureBytes,
    this.textureMimeType,
  });

  int get triangleCount => positions.length ~/ 9;
  int get vertexCount => triangleCount * 3;
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
DecodedMesh decodeStl(Uint8List bytes) {
  if (bytes.length >= 84) {
    final byteData = ByteData.sublistView(bytes);
    final declaredCount = byteData.getUint32(80, Endian.little);
    if (bytes.length == 84 + declaredCount * 50) {
      return _decodeBinaryStl(byteData, declaredCount);
    }
  }
  return _decodeAsciiStl(utf8.decode(bytes, allowMalformed: true));
}

DecodedMesh _decodeBinaryStl(ByteData byteData, int triangleCount) {
  final positions = Float32List(triangleCount * 9);
  final normals = Float32List(triangleCount * 9);
  var offset = 84;
  for (var t = 0; t < triangleCount; t++) {
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
    final base = t * 9;
    for (var i = 0; i < 3; i++) {
      positions[base + i * 3] = verts[i].$1;
      positions[base + i * 3 + 1] = verts[i].$2;
      positions[base + i * 3 + 2] = verts[i].$3;
      normals[base + i * 3] = nx;
      normals[base + i * 3 + 1] = ny;
      normals[base + i * 3 + 2] = nz;
    }
  }
  return DecodedMesh(positions: positions, normals: normals, uvs: Float32List(triangleCount * 6));
}

DecodedMesh _decodeAsciiStl(String text) {
  final positions = <double>[];
  final normals = <double>[];
  double nx = 0, ny = 0, nz = 0;
  final verts = <(double, double, double)>[];
  final normalRegex = RegExp(r'facet\s+normal\s+(\S+)\s+(\S+)\s+(\S+)');
  final vertexRegex = RegExp(r'vertex\s+(\S+)\s+(\S+)\s+(\S+)');

  void flushFacet() {
    if (verts.length != 3) return;
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

  for (final rawLine in const LineSplitter().convert(text)) {
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
DecodedMesh decodeObj(String text) {
  final vertices = <(double, double, double)>[];
  final normals = <(double, double, double)>[];
  final uvs = <(double, double)>[];
  final positions = <double>[];
  final outNormals = <double>[];
  final outUvs = <double>[];

  (int, int?, int?) parseFaceVertex(String token) {
    final parts = token.split('/');
    final vi = int.parse(parts[0]);
    final ti = parts.length > 1 && parts[1].isNotEmpty ? int.parse(parts[1]) : null;
    final ni = parts.length > 2 && parts[2].isNotEmpty ? int.parse(parts[2]) : null;
    return (vi, ti, ni);
  }

  int resolveIndex(int rawIndex, int count) => rawIndex > 0 ? rawIndex - 1 : count + rawIndex;

  for (final rawLine in const LineSplitter().convert(text)) {
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
DecodedMesh decodeGltf(Uint8List bytes) {
  if (bytes.length >= 4 &&
      bytes[0] == 0x67 &&
      bytes[1] == 0x6c &&
      bytes[2] == 0x54 &&
      bytes[3] == 0x46) {
    return _decodeGlb(bytes);
  }
  return _decodeGltfJson(bytes);
}

DecodedMesh _decodeGlb(Uint8List bytes) {
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
  return _decodeGltfDocument(gltf, buffers);
}

DecodedMesh _decodeGltfJson(Uint8List bytes) {
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
  return _decodeGltfDocument(gltf, buffers);
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

DecodedMesh _decodeGltfDocument(Map<String, dynamic> gltf, List<Uint8List> buffers) {
  final accessors = (gltf['accessors'] as List?) ?? const [];
  final bufferViews = (gltf['bufferViews'] as List?) ?? const [];
  final meshes = (gltf['meshes'] as List?) ?? const [];
  if (meshes.isEmpty) throw MeshImportError('glTF file has no meshes');

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

  for (final meshRaw in meshes) {
    final mesh = meshRaw as Map<String, dynamic>;
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

      for (var i = 0; i + 2 < indices.length; i += 3) {
        for (final vi in [indices[i], indices[i + 1], indices[i + 2]]) {
          positions.addAll([rawPositions[vi * 3], rawPositions[vi * 3 + 1], rawPositions[vi * 3 + 2]]);
          if (rawNormals != null) {
            normals.addAll([rawNormals[vi * 3], rawNormals[vi * 3 + 1], rawNormals[vi * 3 + 2]]);
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
    }
  }

  if (positions.isEmpty) throw MeshImportError('glTF file has no usable geometry');

  final texture = _extractBaseColorTexture(gltf, buffers);

  return DecodedMesh(
    positions: Float32List.fromList(positions),
    normals: Float32List.fromList(normals),
    uvs: Float32List.fromList(uvs),
    textureBytes: texture?.$1,
    textureMimeType: texture?.$2,
  );
}

(Uint8List, String)? _extractBaseColorTexture(Map<String, dynamic> gltf, List<Uint8List> buffers) {
  final materials = (gltf['materials'] as List?) ?? const [];
  if (materials.isEmpty) return null;
  final material = materials.first as Map<String, dynamic>;
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
  );
}
