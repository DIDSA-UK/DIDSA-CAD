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

/// C2: a CreatePlaneFeature's resolved world-space geometry (see the
/// backend's `ResolvedPlane`/`FeatureDto.origin`/`FeatureDto.normal`) -
/// the pure data [PartViewport] renders via [buildCreatePlaneNode].
class ResolvedPlaneGeometry {
  final vm.Vector3 origin;
  final vm.Vector3 normal;

  const ResolvedPlaneGeometry({required this.origin, required this.normal});
}

/// C2: the world-space transform placing a local, flat-in-XZ-facing-+Y quad
/// (see `reference_planes.dart`'s `doubleSidedQuadBuffers`) at [origin],
/// oriented so its own local +Y axis points along [normal]. Reused rather
/// than reinventing a second quad-orientation scheme - `doubleSidedQuadBuffers`/
/// `referencePlaneBorderPoints` already build exactly that local shape for
/// the three fixed reference planes; a created Plane just needs a different
/// (arbitrary, not axis-aligned) `Node.localTransform` instead of one of
/// `ReferencePlaneKind`'s three fixed ones.
///
/// `Quaternion.fromTwoVectors` degrades gracefully for [normal] exactly
/// anti-parallel to local +Y (a face/line pointing straight down) - see its
/// own implementation, which picks an arbitrary valid perpendicular axis
/// for that 180-degree case rather than producing a degenerate rotation.
vm.Matrix4 createPlaneTransform(vm.Vector3 origin, vm.Vector3 normal) {
  final rotation = vm.Quaternion.fromTwoVectors(vm.Vector3(0, 1, 0), normal.normalized());
  return vm.Matrix4.compose(origin, rotation, vm.Vector3(1, 1, 1));
}

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
    localTransform: createPlaneTransform(origin, normal),
    mesh: Mesh.primitives(primitives: [
      MeshPrimitive(fillGeometry, fillMaterial),
      MeshPrimitive(borderGeometry, borderMaterial),
    ]),
  );
}
