import 'package:vector_math/vector_math.dart' as vm;

import 'sketch_geometry_3d.dart' show SketchPlaneBasis;

/// Ray-vs-plane intersection against a single arbitrary plane (given by
/// [basis].origin/normal), for the sketcher restructure Phase 2's
/// 3D-embedded tap-to-place: unlike `reference_planes.dart`'s
/// [hitTestReferencePlanes] (which tests the 3 fixed, axis-aligned
/// reference planes and returns the nearest), the embedded sketch view only
/// ever has one plane to test - the current Sketch's own plane, fixed or
/// custom alike - so this is the general origin/normal case rather than
/// [hitTestReferencePlanes]'s per-axis-zeroing shortcut.
///
/// Standard ray-plane intersection: solving `dot(origin + t*direction -
/// planeOrigin, normal) == 0` for `t` gives `t = dot(planeOrigin - origin,
/// normal) / dot(direction, normal)`. Returns null if the ray is parallel
/// to the plane (`dot(direction, normal)` near zero - no intersection, or
/// the ray lies within the plane and every point is "a hit", neither of
/// which a single point can represent) or the intersection is behind the
/// ray's origin (`t < 0`).
(vm.Vector3 point, double rayT)? hitTestSketchPlane(vm.Ray ray, SketchPlaneBasis basis) {
  final denom = ray.direction.dot(basis.normal);
  if (denom.abs() < 1e-9) return null;
  final t = (basis.origin - ray.origin).dot(basis.normal) / denom;
  if (t < 0) return null;
  return (ray.at(t), t);
}
