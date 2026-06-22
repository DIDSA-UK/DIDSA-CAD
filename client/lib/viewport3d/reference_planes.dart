import 'dart:math' as math;

import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart' as vm;

/// One of the three fixed, origin-centered axis-aligned reference planes -
/// XY (z=0), XZ (y=0), YZ (x=0). There are no arbitrary/custom user-defined
/// planes in this stage; a later Extrude-capable stage may add them, but
/// every plane this stage ever renders or hit-tests is one of these three.
enum ReferencePlaneKind { xy, xz, yz }

/// Side length of each rendered reference-plane rectangle, centered on the
/// origin. Named so it stays easy to tune: large enough to be clearly
/// visible/tappable at [OrbitCamera]'s default distance (30) without
/// dominating the view next to the placeholder 10x10x10 box mesh.
const double referencePlaneSize = 20.0;
const double _referencePlaneHalfSize = referencePlaneSize / 2;

const double _referencePlaneAlpha = 0.25;
const double _referencePlaneSelectedAlpha = 0.55;

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

  /// Standard CAD tint: each plane is colored by mixing the two axis colors
  /// it contains - XY (red X, green Y) reads yellow-green, XZ (red X, blue
  /// Z) reads magenta, YZ (green Y, blue Z) reads cyan. [selected] brightens
  /// the tint (in place of a separate outline) when this is the current tap
  /// selection.
  vm.Vector4 tintColor({bool selected = false}) {
    final alpha = selected ? _referencePlaneSelectedAlpha : _referencePlaneAlpha;
    return switch (this) {
      ReferencePlaneKind.xy => vm.Vector4(0.9, 0.9, 0.1, alpha),
      ReferencePlaneKind.xz => vm.Vector4(0.9, 0.1, 0.9, alpha),
      ReferencePlaneKind.yz => vm.Vector4(0.1, 0.9, 0.9, alpha),
    };
  }

  /// Reorients `PlaneGeometry`'s rectangle - always built flat in the XZ
  /// plane - onto this plane: XZ needs no rotation; XY rotates 90 degrees
  /// about the X axis; YZ rotates 90 degrees about the Z axis. (Derivation:
  /// `Matrix4.rotationX(pi/2)` maps a local `(x, 0, z)` point to `(x, -z,
  /// 0)` - on the z=0/XY plane; `Matrix4.rotationZ(pi/2)` maps it to `(0,
  /// x, z)` - on the x=0/YZ plane. See `reference_planes_test.dart`.)
  vm.Matrix4 get localTransform => switch (this) {
        ReferencePlaneKind.xy => vm.Matrix4.rotationX(math.pi / 2),
        ReferencePlaneKind.xz => vm.Matrix4.identity(),
        ReferencePlaneKind.yz => vm.Matrix4.rotationZ(math.pi / 2),
      };
}

/// Builds the always-on-scene [Node] rendering [plane] as a semi-transparent
/// coloured rectangle. [UnlitMaterial.alphaMode] = [AlphaMode.blend] is
/// `flutter_scene`'s supported route to a translucent surface - no custom
/// shader needed - combined with [UnlitMaterial.baseColorFactor]'s alpha
/// channel for the actual transparency.
///
/// GPU-bound (same as [geometryFromMesh]) via `PlaneGeometry`'s underlying
/// `MeshGeometry.fromArrays` upload, so - like the placeholder mesh - this
/// cannot be exercised in a headless `flutter test` run. [hitTestReferencePlanes]
/// below is the pure, testable counterpart that drives plane selection.
Node buildReferencePlaneNode(ReferencePlaneKind plane, {bool selected = false}) {
  final material = UnlitMaterial()
    ..alphaMode = AlphaMode.blend
    ..baseColorFactor = plane.tintColor(selected: selected);
  final geometry = PlaneGeometry(width: referencePlaneSize, depth: referencePlaneSize);
  return Node(
    name: 'reference-plane-${plane.apiValue}',
    localTransform: plane.localTransform,
    mesh: Mesh(geometry, material),
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
