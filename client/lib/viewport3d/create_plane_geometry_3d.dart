import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart' as vm;

import 'reference_planes.dart' show doubleSidedQuadBuffers, referencePlaneBorderPoints;

/// C2: half-extent of a rendered Create Plane quad - a fixed default rather
/// than one derived from the referencing geometry's bounding box, per this
/// prompt's own "leave exact sizing as an on-device call, don't over-decide
/// blind" instruction. Matches `reference_planes.dart`'s own
/// `referencePlaneSize` for visual consistency between the two kinds of
/// plane the viewport now renders.
const double createPlaneSize = 20.0;
const double _createPlaneHalfSize = createPlaneSize / 2;

const double _createPlaneAlpha = 0.25;
const double _createPlaneSelectedAlpha = 0.5;

/// A warm amber tint - deliberately distinct from the three fixed reference
/// planes' RGB-axis colour coding (`ReferencePlaneKindX._baseColor`:
/// blue/red/green) and from Sketch geometry's neutral grey
/// (`sketch_geometry_3d.dart`'s `sketchLineColor`), so a created Plane
/// always reads as its own, third kind of viewport overlay at a glance.
final vm.Vector3 _createPlaneBaseColor = vm.Vector3(0xF5 / 255, 0xA6 / 255, 0x23 / 255);

const double _createPlaneBorderWidth = 2.0;

/// C2/C3: a CreatePlaneFeature's resolved world-space geometry (see the
/// backend's `ResolvedPlane`/`FeatureDto.origin`/`FeatureDto.normal`/
/// `FeatureDto.xAxis`/`FeatureDto.yAxis`) - the pure data [PartViewport]
/// renders via [buildCreatePlaneNode], and (C3) the same basis a Sketch
/// anchored to this Plane embeds its own local geometry through (see
/// `sketch_geometry_3d.dart`'s `SketchPlaneBasis.custom`).
class ResolvedPlaneGeometry {
  final vm.Vector3 origin;
  final vm.Vector3 normal;
  final vm.Vector3 xAxis;
  final vm.Vector3 yAxis;

  const ResolvedPlaneGeometry({
    required this.origin,
    required this.normal,
    required this.xAxis,
    required this.yAxis,
  });
}

/// C3: the world-space transform placing a local, flat-in-XZ-facing-+Y quad
/// (see `reference_planes.dart`'s `doubleSidedQuadBuffers`) at [origin],
/// with its own local +X/+Z/+Y axes mapped onto [xAxis]/[yAxis]/[normal]
/// respectively - built directly from the backend's own already-resolved
/// orthonormal basis (`ResolvedPlane`) via `Matrix4.columns`, rather than
/// (C2's original approach) deriving *some* valid rotation from [normal]
/// alone via `Quaternion.fromTwoVectors`. That approach worked but left the
/// quad's in-plane (X/Z) orientation arbitrary/unspecified; using the
/// backend's real [xAxis]/[yAxis] instead makes the rendered quad's
/// orientation the *same* one a Sketch anchored to this Plane actually
/// embeds its local (x, y) geometry through - not just visually consistent
/// with it by coincidence.
vm.Matrix4 createPlaneTransform(
  vm.Vector3 origin,
  vm.Vector3 xAxis,
  vm.Vector3 yAxis,
  vm.Vector3 normal,
) =>
    vm.Matrix4.columns(
      vm.Vector4(xAxis.x, xAxis.y, xAxis.z, 0),
      vm.Vector4(normal.x, normal.y, normal.z, 0),
      vm.Vector4(yAxis.x, yAxis.y, yAxis.z, 0),
      vm.Vector4(origin.x, origin.y, origin.z, 1),
    );

/// Builds the [Node] rendering one CreatePlaneFeature's resolved plane - a
/// double-sided translucent fill plus an opaque border outline, the same
/// two-[MeshPrimitive] structure `reference_planes.dart`'s
/// `buildReferencePlaneNode` uses, just with an arbitrary
/// [createPlaneTransform] instead of a fixed [ReferencePlaneKind] one.
///
/// GPU-bound (`MeshGeometry.fromArrays`'s vertex upload, `PolylineGeometry`'s
/// own underlying updatable `MeshGeometry`), so - like
/// `buildReferencePlaneNode`/`buildSketchGeometryNode` - this cannot be
/// exercised in a headless `flutter test` run; [createPlaneTransform] above
/// is the pure, testable counterpart for the orientation math.
Node buildCreatePlaneNode(
  String featureId,
  vm.Vector3 origin,
  vm.Vector3 xAxis,
  vm.Vector3 yAxis,
  vm.Vector3 normal, {
  bool selected = false,
}) {
  final alpha = selected ? _createPlaneSelectedAlpha : _createPlaneAlpha;
  final fillMaterial = UnlitMaterial()
    ..alphaMode = AlphaMode.blend
    ..baseColorFactor = vm.Vector4(
      _createPlaneBaseColor.x,
      _createPlaneBaseColor.y,
      _createPlaneBaseColor.z,
      alpha,
    );
  final fillBuffers = doubleSidedQuadBuffers(_createPlaneHalfSize);
  final fillGeometry = MeshGeometry.fromArrays(
    positions: fillBuffers.positions,
    normals: fillBuffers.normals,
    indices: fillBuffers.indices,
  );

  final borderMaterial = UnlitMaterial()
    ..alphaMode = AlphaMode.opaque
    ..baseColorFactor = vm.Vector4(
      _createPlaneBaseColor.x,
      _createPlaneBaseColor.y,
      _createPlaneBaseColor.z,
      1.0,
    );
  final borderGeometry = PolylineGeometry(
    referencePlaneBorderPoints(_createPlaneHalfSize),
    width: _createPlaneBorderWidth,
  );

  return Node(
    name: 'create-plane-$featureId',
    localTransform: createPlaneTransform(origin, xAxis, yAxis, normal),
    mesh: Mesh.primitives(primitives: [
      MeshPrimitive(fillGeometry, fillMaterial),
      MeshPrimitive(borderGeometry, borderMaterial),
    ]),
  );
}

/// C3: a tap that intersected a created Plane's rendered quad - mirrors
/// [ReferencePlaneHit], just keyed by Feature id (a created Plane's identity)
/// rather than a fixed [ReferencePlaneKind].
class CreatePlaneHit {
  final String featureId;
  final vm.Vector3 point;

  const CreatePlaneHit({required this.featureId, required this.point});
}

/// C3: pure ray-vs-created-planes intersection, the arbitrary-orientation
/// counterpart to `reference_planes.dart`'s [hitTestReferencePlanes] (which
/// only ever tests the three fixed, axis-aligned planes). Each plane in
/// [planes] is tested via plain plane-ray algebra (`dot(origin - ray.origin,
/// normal) / dot(ray.direction, normal)` for `t`, then projecting the hit
/// point onto the plane's own [ResolvedPlaneGeometry.xAxis]/[yAxis] via dot
/// products - exact, not an approximation, since those axes are always
/// orthonormal per the backend's `ResolvedPlane`) rather than
/// [ReferencePlaneKind]'s zeroed-world-axis shortcut, since a created
/// Plane's orientation is arbitrary. Returns the closest hit (smallest
/// non-negative `t`) that falls within the rendered [halfSize] square, or
/// null if the ray misses every one.
CreatePlaneHit? hitTestCreatePlanes(
  vm.Ray ray,
  Map<String, ResolvedPlaneGeometry> planes, {
  double halfSize = _createPlaneHalfSize,
}) {
  CreatePlaneHit? best;
  double? bestT;

  for (final entry in planes.entries) {
    final plane = entry.value;
    final denom = ray.direction.dot(plane.normal);
    if (denom.abs() < 1e-9) continue; // Parallel to (or lying within) this plane.

    final t = (plane.origin - ray.origin).dot(plane.normal) / denom;
    if (t < 0) continue; // Behind the ray's origin.

    final point = ray.at(t);
    final local = point - plane.origin;
    final u = local.dot(plane.xAxis);
    final v = local.dot(plane.yAxis);
    if (u.abs() > halfSize || v.abs() > halfSize) {
      continue; // Inside the infinite plane but outside the rendered square.
    }

    if (bestT == null || t < bestT) {
      bestT = t;
      best = CreatePlaneHit(featureId: entry.key, point: point);
    }
  }

  return best;
}
