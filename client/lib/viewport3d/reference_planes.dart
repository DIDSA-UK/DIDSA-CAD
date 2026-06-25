import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart' as vm;

/// One of the three fixed, origin-centered axis-aligned reference planes -
/// XY (z=0), XZ (y=0), YZ (x=0). There are no arbitrary/custom user-defined
/// planes in this stage; a later Extrude-capable stage may add them, but
/// every plane this stage ever renders or hit-tests is one of these three.
enum ReferencePlaneKind { xy, xz, yz }

/// The inverse of [ReferencePlaneKindX.apiValue] - parses a `SketchDto.plane`
/// string (always one of `"XY"`/`"XZ"`/`"YZ"`, per the backend's `Plane`
/// enum) back into a [ReferencePlaneKind], e.g. to resolve which plane an
/// existing Feature's Sketch lives on for the camera-animation-on-open flow.
/// Returns null on anything unrecognized rather than throwing, since this
/// only ever feeds a "skip the animation" fallback, not a hard requirement.
ReferencePlaneKind? referencePlaneKindFromApiValue(String value) => switch (value) {
      'XY' => ReferencePlaneKind.xy,
      'XZ' => ReferencePlaneKind.xz,
      'YZ' => ReferencePlaneKind.yz,
      _ => null,
    };

/// Side length of each rendered reference-plane rectangle, centered on the
/// origin. Named so it stays easy to tune: large enough to be clearly
/// visible/tappable at [OrbitCamera]'s default distance (30) without
/// dominating the view next to the placeholder 10x10x10 box mesh.
const double referencePlaneSize = 20.0;
const double _referencePlaneHalfSize = referencePlaneSize / 2;

const double _referencePlaneAlpha = 0.20;
const double _referencePlaneSelectedAlpha = 0.45;

/// Screen-pixel width of each plane's border line (Fix 3).
const double _referencePlaneBorderWidth = 2.0;

extension ReferencePlaneKindX on ReferencePlaneKind {
  /// The exact `plane` string the backend already accepts (see
  /// `backend/.../sketch/models.py`'s `Plane` enum and
  /// `DocumentApiClient.createSketchFeature`/`SketchApiClient.createSketch`)
  /// - tapping a plane in the 3D viewport can pass this straight through
  /// with no translation layer.
  String get apiValue => switch (this) {
        ReferencePlaneKind.xy => 'XY',
        ReferencePlaneKind.xz => 'XZ',
        ReferencePlaneKind.yz => 'YZ',
      };

  /// The world axis (0=x, 1=y, 2=z) held at zero everywhere on this plane -
  /// e.g. the XY plane (z=0) zeroes the Z axis.
  int get _zeroAxis => switch (this) {
        ReferencePlaneKind.xy => 2,
        ReferencePlaneKind.xz => 1,
        ReferencePlaneKind.yz => 0,
      };

  /// The other two axes this plane spans, used to bound a ray hit to the
  /// finite rendered rectangle rather than the infinite mathematical plane.
  List<int> get _spanAxes => switch (this) {
        ReferencePlaneKind.xy => const [0, 1],
        ReferencePlaneKind.xz => const [0, 2],
        ReferencePlaneKind.yz => const [1, 2],
      };

  /// Stage 18's fixed per-plane tint, matching the conventional RGB-axis
  /// colour coding used by Fusion 360/Blender/most CAD tools (XY="Top"=blue,
  /// XZ="Front"=red, YZ="Right"=green) - a per-`ReferencePlaneKind` constant
  /// rather than derived from [_zeroAxis], since that derivation would put
  /// XZ/YZ on the opposite colors from the brief's explicit table.
  vm.Vector3 get _baseColor => switch (this) {
        ReferencePlaneKind.xy => vm.Vector3(0x3A / 255, 0x7B / 255, 0xD5 / 255),
        ReferencePlaneKind.xz => vm.Vector3(0xE8 / 255, 0x36 / 255, 0x4A / 255),
        ReferencePlaneKind.yz => vm.Vector3(0x27 / 255, 0xAE / 255, 0x60 / 255),
      };

  /// The translucent fill color for this plane's rectangle. [selected]
  /// brightens the alpha (in place of a separate outline) when this is the
  /// current tap selection.
  vm.Vector4 tintColor({bool selected = false}) {
    final alpha = selected ? _referencePlaneSelectedAlpha : _referencePlaneAlpha;
    final c = _baseColor;
    return vm.Vector4(c.x, c.y, c.z, alpha);
  }

  /// The fully-opaque border color (Fix 3) - the same hue as [tintColor],
  /// just without the transparency.
  vm.Vector4 get borderColor {
    final c = _baseColor;
    return vm.Vector4(c.x, c.y, c.z, 1.0);
  }

  /// Reorients the plane's local geometry - built flat in local XZ, surface
  /// facing +Y - onto this plane: XZ needs no rotation; XY rotates 90
  /// degrees about the X axis; YZ rotates 90 degrees about the Z axis.
  /// (Derivation: `Matrix4.rotationX(pi/2)` maps a local `(x, 0, z)` point
  /// to `(x, -z, 0)` - on the z=0/XY plane; `Matrix4.rotationZ(pi/2)` maps
  /// it to `(0, x, z)` - on the x=0/YZ plane. See `reference_planes_test.dart`.)
  vm.Matrix4 get localTransform => switch (this) {
        ReferencePlaneKind.xy => vm.Matrix4.rotationX(math.pi / 2),
        ReferencePlaneKind.xz => vm.Matrix4.identity(),
        ReferencePlaneKind.yz => vm.Matrix4.rotationZ(math.pi / 2),
      };
}

/// The four corners of a [halfSize]-radius square centered on the origin,
/// flat in the local XZ plane (matching [ReferencePlaneKindX.localTransform]'s
/// frame), in winding order, with the first corner repeated at the end to
/// close the loop - ready to hand straight to `PolylineGeometry` for the
/// border (Fix 3). Pure and shared with [doubleSidedQuadBuffers] below so
/// the border and fill always outline the same rectangle.
List<vm.Vector3> referencePlaneBorderPoints(double halfSize) => [
      vm.Vector3(-halfSize, 0, -halfSize),
      vm.Vector3(halfSize, 0, -halfSize),
      vm.Vector3(halfSize, 0, halfSize),
      vm.Vector3(-halfSize, 0, halfSize),
      vm.Vector3(-halfSize, 0, -halfSize),
    ];

/// The pure vertex/index buffers for a double-sided [halfSize]-radius square,
/// flat in the local XZ plane (Fix 2's fix for single-sided rendering).
///
/// `flutter_scene`'s `Material.bind()` always back-face-culls a translucent
/// (`AlphaMode.blend`) material's geometry - `cullBackFace = !doubleSided ||
/// !isOpaque()` unconditionally culls when the material isn't opaque,
/// regardless of `Material.doubleSided` - so a translucent single quad is
/// only ever visible from one side no matter what material flag is set.
/// The fix has to be geometric instead: this duplicates the quad's 4
/// corners as two oppositely-wound triangle pairs (indices 0-3 wound for a
/// +Y-facing front; indices 4-7, the same 4 positions again, wound for a
/// -Y-facing back), so one copy is always front-facing - and therefore
/// drawn - no matter which side the camera is on.
class DoubleSidedQuadBuffers {
  final Float32List positions;
  final Float32List normals;
  final List<int> indices;

  const DoubleSidedQuadBuffers({
    required this.positions,
    required this.normals,
    required this.indices,
  });
}

DoubleSidedQuadBuffers doubleSidedQuadBuffers(double halfSize) {
  final corners = referencePlaneBorderPoints(halfSize).take(4).toList();

  final positions = Float32List(8 * 3);
  final normals = Float32List(8 * 3);
  for (var i = 0; i < 4; i++) {
    final p = corners[i];

    final frontBase = i * 3;
    positions[frontBase] = p.x;
    positions[frontBase + 1] = p.y;
    positions[frontBase + 2] = p.z;
    normals[frontBase + 1] = 1.0;

    final backBase = (i + 4) * 3;
    positions[backBase] = p.x;
    positions[backBase + 1] = p.y;
    positions[backBase + 2] = p.z;
    normals[backBase + 1] = -1.0;
  }

  return DoubleSidedQuadBuffers(
    positions: positions,
    normals: normals,
    // Front (+Y, corners 0-3): CCW when viewed from +Y.
    // Back (-Y, corners 4-7, same positions): reversed winding, so it's
    // CCW - and therefore not culled - when viewed from -Y instead.
    indices: const [0, 2, 1, 0, 3, 2, 4, 5, 6, 4, 6, 7],
  );
}

/// Builds the always-on-scene [Node] rendering [plane]: a double-sided
/// translucent fill (Fix 1/2) plus a fully-opaque border outline (Fix 3),
/// both tinted by [ReferencePlaneKindX.tintColor]/[borderColor]'s
/// normal-axis convention (Fix 4) - combined as two [MeshPrimitive]s of one
/// [Mesh], so they share a single [Node]/transform.
///
/// GPU-bound (`MeshGeometry.fromArrays`'s vertex upload, and
/// `PolylineGeometry`'s own underlying updatable `MeshGeometry`), so - like
/// the placeholder mesh - this cannot be exercised in a headless
/// `flutter test` run. [doubleSidedQuadBuffers] and
/// [referencePlaneBorderPoints] above are the pure, testable counterparts
/// for the geometry layout, and [hitTestReferencePlanes] below is the pure
/// counterpart for plane selection.
Node buildReferencePlaneNode(ReferencePlaneKind plane, {bool selected = false}) {
  final fillMaterial = UnlitMaterial()
    ..alphaMode = AlphaMode.blend
    ..baseColorFactor = plane.tintColor(selected: selected);
  final fillBuffers = doubleSidedQuadBuffers(_referencePlaneHalfSize);
  final fillGeometry = MeshGeometry.fromArrays(
    positions: fillBuffers.positions,
    normals: fillBuffers.normals,
    indices: fillBuffers.indices,
  );

  final borderMaterial = UnlitMaterial()
    ..alphaMode = AlphaMode.opaque
    ..baseColorFactor = plane.borderColor;
  final borderGeometry = PolylineGeometry(
    referencePlaneBorderPoints(_referencePlaneHalfSize),
    width: _referencePlaneBorderWidth,
  );

  return Node(
    name: 'reference-plane-${plane.apiValue}',
    localTransform: plane.localTransform,
    mesh: Mesh.primitives(primitives: [
      MeshPrimitive(fillGeometry, fillMaterial),
      MeshPrimitive(borderGeometry, borderMaterial),
    ]),
  );
}

/// A tap that intersected [plane] at world-space [point].
class ReferencePlaneHit {
  final ReferencePlaneKind plane;
  final vm.Vector3 point;

  const ReferencePlaneHit({required this.plane, required this.point});
}

/// Pure ray-vs-reference-planes intersection: tests [ray] against all three
/// fixed, origin-centered axis planes and returns the closest hit (smallest
/// non-negative `t` along the ray) that also falls within the rendered
/// [referencePlaneSize] rectangle - not just the infinite mathematical plane
/// - or null if the ray misses every rendered rectangle.
///
/// Since all three planes pass through the origin and are axis-aligned, this
/// is plain per-axis algebra (`origin[axis] + t * direction[axis] == 0`)
/// rather than the general mesh-picking `flutter_scene` already ships in
/// `raycast.dart` - deliberately not used here, since that picks against
/// real triangle data and these planes' GPU geometry only exists once
/// `PartViewport` has a live scene, while this stays GPU-independent and
/// unit-testable.
ReferencePlaneHit? hitTestReferencePlanes(vm.Ray ray, {double halfSize = _referencePlaneHalfSize}) {
  ReferencePlaneHit? best;
  double? bestT;

  for (final plane in ReferencePlaneKind.values) {
    final axis = plane._zeroAxis;
    final originOnAxis = ray.origin[axis];
    final directionOnAxis = ray.direction[axis];
    if (directionOnAxis.abs() < 1e-9) continue; // Parallel to (or lying within) this plane.

    final t = -originOnAxis / directionOnAxis;
    if (t < 0) continue; // Behind the ray's origin.

    final point = ray.at(t);
    final spanAxes = plane._spanAxes;
    if (point[spanAxes[0]].abs() > halfSize || point[spanAxes[1]].abs() > halfSize) {
      continue; // Inside the infinite plane but outside the rendered rectangle.
    }

    if (bestT == null || t < bestT) {
      bestT = t;
      best = ReferencePlaneHit(plane: plane, point: point);
    }
  }

  return best;
}
