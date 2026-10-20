/// What an appearance looks like in the flat app's viewport: a resolved appearance (`appearance_rule.dart`, only the fields
/// something sets) turned into material values over the viewport's own default look, the same mapping the backend's
/// `material_for_appearance` uses for the glb (glow is `emission`, or the base colour when only a strength is set; a strength
/// of 0 turns it off), and a body mesh split into one piece per look when its faces differ.
library;

import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart' as vm;

import '../api/document_api_client.dart';
import '../viewport3d/mesh_geometry.dart';
import 'appearance_rule.dart';

/// The look of one instance in the viewport: its [whole] appearance and, when its faces don't all look the same,
/// one appearance per face (`'$bodyId|$faceIndex'` keys, `appearance_rule.resolveFaces`).
class InstanceLook {
  final Json whole;
  final Map<String, Json>? faces;

  const InstanceLook({this.whole = const {}, this.faces});

  bool get isEmpty => whole.isEmpty && (faces == null || faces!.values.every((f) => f.isEmpty));
}

/// Material values for one appearance.
class LookParams {
  final vm.Vector3 colour;
  final double opacity;
  final double metallic;
  final double roughness;
  final vm.Vector3 emissive;

  const LookParams({
    required this.colour,
    required this.opacity,
    required this.metallic,
    required this.roughness,
    required this.emissive,
  });

  /// [appearance]'s fields over the defaults (the viewport's own look for a placed part).
  factory LookParams.of(
    Json appearance, {
    vm.Vector3? defaultColour,
    double defaultRoughness = 0.6,
    double defaultMetallic = 0.1,
  }) {
    final colour = isHexColour(appearance['colour']) ? rgbOfHex(appearance['colour'] as String) : (defaultColour ?? vm.Vector3(0.68, 0.72, 0.78));
    final strength = (appearance['emission_strength'] as num?)?.toDouble();
    var emissive = vm.Vector3.zero();
    if (appearance['emission'] != null || strength != null) {
      final s = strength ?? 1.0;
      if (s > 0) {
        final glow = isHexColour(appearance['emission']) ? rgbOfHex(appearance['emission'] as String) : colour;
        emissive = glow * s;
      }
    }
    return LookParams(
      colour: colour,
      opacity: ((appearance['opacity'] as num?) ?? 1.0).toDouble(),
      metallic: ((appearance['metallic'] as num?) ?? defaultMetallic).toDouble(),
      roughness: ((appearance['roughness'] as num?) ?? defaultRoughness).toDouble(),
      emissive: emissive,
    );
  }
}

vm.Vector3 rgbOfHex(String hex) {
  final value = int.parse(hex.substring(1), radix: 16);
  return vm.Vector3(((value >> 16) & 0xFF) / 255.0, ((value >> 8) & 0xFF) / 255.0, (value & 0xFF) / 255.0);
}

/// A lit material for [look], at [opacity] times the look's own (a focus fade or a dimmed preview). [baseEmissive] is the
/// viewport's own fill glow (Scene settings), added under the look's.
PhysicallyBasedMaterial materialForLook(LookParams look, {double opacity = 1.0, double baseEmissive = 0.0}) {
  final alpha = look.opacity * opacity;
  final glow = look.emissive + vm.Vector3.all(baseEmissive);
  return NormalDepthPhysicallyBasedMaterial()
    ..alphaMode = alpha < 1.0 ? AlphaMode.blend : AlphaMode.opaque
    ..baseColorFactor = vm.Vector4(look.colour.x, look.colour.y, look.colour.z, alpha)
    ..roughnessFactor = look.roughness
    ..metallicFactor = look.metallic
    ..emissiveFactor = vm.Vector4(glow.x, glow.y, glow.z, 1.0)
    ..doubleSided = true;
}

String _key(Json appearance) {
  final keys = appearance.keys.toList()..sort();
  return [for (final k in keys) '$k=${appearance[k]}'].join(';');
}

/// [mesh] (one body, [bodyId]) split into one piece per distinct look of its faces ([faces] keyed `'$bodyId|$faceIndex'`;
/// a face not listed takes [whole]). One piece (the mesh itself) when every face looks the same or the mesh has no face
/// ids. Vertices and normals are shared; only the triangles differ.
List<(MeshDto, Json)> splitMeshByLook(MeshDto mesh, String bodyId, Json whole, Map<String, Json>? faces) {
  if (faces == null || mesh.faceIds.length != mesh.triangleIndices.length || mesh.triangleIndices.isEmpty) {
    return [(mesh, whole)];
  }
  final groups = <String, (Json, List<List<int>>, List<int>)>{};
  for (var i = 0; i < mesh.triangleIndices.length; i++) {
    final faceId = mesh.faceIds[i];
    final look = faces['$bodyId|$faceId'] ?? whole;
    final group = groups.putIfAbsent(_key(look), () => (look, <List<int>>[], <int>[]));
    group.$2.add(mesh.triangleIndices[i]);
    group.$3.add(faceId);
  }
  if (groups.length == 1) return [(mesh, groups.values.first.$1)];
  return [
    for (final g in groups.values)
      (
        MeshDto(
          vertices: mesh.vertices,
          normals: mesh.normals,
          triangleIndices: g.$2,
          edges: mesh.edges,
          faceIds: g.$3,
          edgeIds: mesh.edgeIds,
          topologyVertices: mesh.topologyVertices,
          topologyVertexIds: mesh.topologyVertexIds,
          faceEdgeIds: mesh.faceEdgeIds,
          faceIsPlanar: mesh.faceIsPlanar,
        ),
        g.$1,
      ),
  ];
}

/// One node for a body of a placed instance wearing its look: one primitive per look ([splitMeshByLook]).
Node buildLookedInstanceNode(
  MeshDto mesh, {
  required String bodyId,
  required InstanceLook look,
  required vm.Matrix4 localTransform,
  required double opacity,
  vm.Vector3? defaultColour,
}) {
  final pieces = splitMeshByLook(mesh, bodyId, look.whole, look.faces);
  final primitives = <MeshPrimitive>[];
  for (final (piece, appearance) in pieces) {
    final params = LookParams.of(appearance, defaultColour: defaultColour);
    final translucent = params.opacity * opacity < 1.0;
    primitives.add(MeshPrimitive(geometryFromMesh(piece, doubleSidedWinding: translucent), materialForLook(params, opacity: opacity)));
  }
  return Node(name: 'assembly-instance', localTransform: localTransform, mesh: Mesh.primitives(primitives: primitives));
}
