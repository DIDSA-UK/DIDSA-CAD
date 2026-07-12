import 'dart:math' as math;
import 'dart:ui' show Size;

import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart' as vm;

import 'reference_planes.dart';
import 'sketch_geometry_3d.dart';

// A3: near/far clip defaults adjacent to where clip distances are set.
// kDefaultNearClip: 0.1 mm is the minimum without z-fighting on a 24-bit
// depth buffer. kDefaultFarClip: 3000 mm keeps parts up to ~1000 mm visible
// from any orbit angle (the auto-fit on recentre can extend this further).
const double kDefaultNearClip = 0.1;
const double kDefaultFarClip = 3000.0;

/// Mutable orbit/pan/zoom state for the 3D viewport - the 3D equivalent of
/// [SketchViewport], producing a `flutter_scene` [PerspectiveCamera] for a
/// given canvas size.
///
/// Orientation is tracked as a quaternion rather than azimuth/elevation
/// Euler angles. An earlier azimuth/elevation version had to clamp
/// elevation just shy of the poles, because at the poles azimuth becomes
/// meaningless and the look-at-style camera construction flips - in
/// practice this felt like the camera "getting stuck" and refusing to
/// rotate past certain orientations. Composing incremental rotations as
/// quaternions has no such pole: [direction] and [up] are both derived from
/// the same [orientation] and stay mutually consistent (orthogonal) at any
/// orientation, including looking straight down or straight up, so orbiting
/// can pass through them smoothly with no dead zone or flip.
class OrbitCamera {
  /// Zoom bounds used when no body exists yet (or the current body is
  /// empty) to scale them against - see [setZoomBoundsForRadius].
  static const double defaultMinDistance = 5;
  static const double defaultMaxDistance = 300;

  /// Multiplier applied to a body's bounding-sphere radius to derive
  /// [maxDistance] - chosen so it keeps the camera close enough to still be
  /// a recognisable shape on screen (radius x20), per the brief's own
  /// heuristic. [minDistance] is no longer radius-derived directly - see
  /// [nearClip]/[setZoomBoundsForRadius].
  static const double _maxDistanceRadiusFactor = 20;

  /// [nearClip]/[farClip] defaults - used whenever no body exists yet (or
  /// the current body is empty). Alias the top-level [kDefaultNearClip]/
  /// [kDefaultFarClip] so callers that already use the class-level names
  /// keep working without changes.
  static const double defaultNearClip = kDefaultNearClip;
  static const double defaultFarClip = kDefaultFarClip;

  /// Multiplier applied to a body's bounding-sphere radius to derive
  /// [farClip] - generous enough that the far plane never clips a large
  /// model from any orbit angle, per the project brief.
  static const double _farClipRadiusFactor = 4.0;

  /// [farClip] never drops below this, even for a tiny/empty body - keeps
  /// the fixed reference planes (which extend well beyond any one body)
  /// from being clipped. Matches [kDefaultFarClip] so a model always sees
  /// the same minimum depth budget.
  static const double _minFarClip = kDefaultFarClip;

  /// [nearClip] is derived as `farClip / _nearFarRatio` - a 1:10000 near/far
  /// ratio is safe for a 24-bit depth buffer and avoids z-fighting.
  static const double _nearFarRatio = 10000.0;

  /// [minDistance] is derived as `nearClip * _minDistanceNearClipFactor` -
  /// keeps the camera just outside the near clip plane, so zooming in is
  /// limited by the depth buffer's precision, not an arbitrary distance
  /// that doesn't scale with the scene (see Item 2 of the Stage 16 brief).
  static const double _minDistanceNearClipFactor = 2.0;

  /// Mutable, unlike the fixed bounds of an earlier version - scaled to the
  /// accumulated mesh's actual size by [setZoomBoundsForRadius] (see
  /// [PartViewport._syncMeshNode]) so zooming out always stops a sensible
  /// distance from the current geometry rather than a one-size-fits-all
  /// fixed distance.
  double minDistance = defaultMinDistance;
  double maxDistance = defaultMaxDistance;

  /// Camera frustum near/far clip distances, fed into [cameraFor]'s
  /// [PerspectiveCamera] as `fovNear`/`fovFar` - scaled to the current body's
  /// bounding-sphere radius by [setZoomBoundsForRadius], the same hook
  /// [minDistance]/[maxDistance] use, so a large model is never far-clipped
  /// and the near clip plane (and so [minDistance]) shrinks to match a small
  /// one.
  double nearClip = defaultNearClip;
  double farClip = defaultFarClip;

  /// Radians/pixel for a mouse drag or 1:1-scaled touch drag - matches the
  /// "real device px -> visible angle" feel [SketchViewport] aims for with
  /// its own per-pixel sensitivity constants.
  static const double orbitSensitivity = 0.01;

  /// World units of [target] travel per screen pixel of pan drag, *
  /// [distance] - panning by a fixed angle/world-distance per pixel would
  /// feel too fast when zoomed in and too slow zoomed out, so it scales with
  /// how far the camera currently is from its target.
  static const double panSensitivityPerDistance = 0.002;

  // A4: perspective vs orthographic toggle. flutter_scene 0.18.x provides only
  // PerspectiveCamera with a fixed π/4 vertical FOV — true orthographic
  // projection is not available through its public API. This flag correctly
  // reflects the user's preference and is wired through the View menu; the
  // rendering difference will take effect once flutter_scene exposes an
  // OrthographicCamera or a settable FOV.
  bool isPerspective = false;

  static final vm.Vector3 _localRight = vm.Vector3(1, 0, 0);
  static final vm.Vector3 _localUp = vm.Vector3(0, 1, 0);
  static final vm.Vector3 _localBack = vm.Vector3(0, 0, 1);

  /// Rotation from the local camera frame (right=+X, up=+Y, the camera sits
  /// along +Z looking back towards [target]) into world space. [direction],
  /// [up] and [right] are all read from this rather than stored separately,
  /// so they can never drift out of being mutually orthogonal.
  vm.Quaternion orientation;
  double distance;
  vm.Vector3 target;

  /// What [reset] returns [distance] to, clamped to the current
  /// [minDistance]/[maxDistance] - those bounds may since have been
  /// narrowed by [setZoomBoundsForRadius] to a body smaller than this
  /// default, so resetting can't just assign it outright.
  ///
  /// Stage 19a Item 6: was `30`, which - given `flutter_scene`'s 45-degree
  /// default vertical FOV and the fixed reference planes' real
  /// [referencePlaneSize] of 20 world units - left the planes filling
  /// nearly the full screen (~80% of its linear extent) on a cold launch.
  /// Raised to `48` (planes ~25% of screen, ~50% of linear extent) to fix
  /// that, then further out to `80` by explicit request to push the
  /// default zoom level farther out still (planes now read at roughly
  /// (48/80)^2 ≈ 36% of that screen coverage - correspondingly smaller/
  /// farther-looking on open). Also what "Reset View" (see [reset])
  /// returns to, whenever the loaded body's zoom-out bound allows it -
  /// a small body's own `maxDistance` (see [setZoomBoundsForRadius])
  /// still clamps below this exactly as it did before, unaffected by this
  /// constant's value.
  static const double _defaultDistance = 80;

  /// What [reset] returns [target] to - defaults to the origin, but
  /// [setTarget] moves this along with [target] so "Reset view" re-centers
  /// on the real geometry instead of snapping back to world-space (0,0,0).
  vm.Vector3 _defaultTarget;

  OrbitCamera({this.distance = _defaultDistance, vm.Vector3? target})
      : target = target ?? vm.Vector3.zero(),
        _defaultTarget = target ?? vm.Vector3.zero(),
        orientation = _defaultOrientation();

  /// pi/4 azimuth, pi/6 elevation - the angles a previous azimuth/elevation
  /// version of this camera used as its default view, reproduced here as a
  /// quaternion so the initial view is unchanged even though the underlying
  /// representation isn't.
  static vm.Quaternion _defaultOrientation() {
    final pitch = vm.Quaternion.axisAngle(_localRight, 0.5235987755982988);
    final yaw = vm.Quaternion.axisAngle(_localUp, -0.7853981633974483);
    return (pitch * yaw).normalized();
  }

  /// Unit vector from [target] towards the camera.
  vm.Vector3 get _direction => orientation.rotated(_localBack);

  vm.Vector3 get _up => orientation.rotated(_localUp);

  vm.Vector3 get _right => orientation.rotated(_localRight);

  /// Public accessors for the camera's local axes — used by
  /// `PartViewportState._worldToScreen` for box-selection projection (A2).
  vm.Vector3 get up => _up;
  vm.Vector3 get right => _right;

  /// World-space camera position derived from [target]/[orientation]/
  /// [distance] - the same value [cameraFor] feeds [PerspectiveCamera].
  vm.Vector3 get position => target + _direction * distance;

  PerspectiveCamera cameraFor(Size size) {
    return PerspectiveCamera(
      position: position,
      target: target,
      up: _up,
      fovNear: nearClip,
      fovFar: farClip,
    );
  }

  /// Drag-to-orbit: real-device testing found all four drag directions felt
  /// backwards under the original `-dyPixels`/`-dxPixels` mapping, so both
  /// signs were flipped to `+dyPixels`/`+dxPixels`. That fixed vertical
  /// (pitch) orbit, but horizontal (yaw) orbit was still backwards -
  /// swiping left rotated the model right and vice versa - so only the yaw
  /// term is flipped again here, back to `-dxPixels`; the pitch term's
  /// `+dyPixels` is untouched and confirmed correct on-device. Pitch is
  /// applied about the camera's *current* right axis, and yaw about the
  /// camera's *current* up axis - both read fresh from [orientation] every
  /// call, so each always tilts/swings the view the way it's currently
  /// facing, regardless of how far it's already been orbited.
  ///
  /// An earlier version yawed about the *fixed* world-up axis instead, with
  /// a special-cased sign flip once [_up] pointed away from world-up (i.e.
  /// past vertical, where the model reads as "upside-down") to keep
  /// horizontal drag direction feeling consistent. Yawing about the
  /// camera's own current up axis needs no such case: that axis already
  /// incorporates whatever pitch has been applied, so a horizontal drag
  /// always swings the view the same way relative to the camera's own
  /// point of view, at any orientation - this is the standard
  /// trackball-style orbit. Composed as quaternions, with no clamping, so
  /// this never gets stuck.
  void orbitByScreenDelta(double dxPixels, double dyPixels) {
    final pitch = vm.Quaternion.axisAngle(_right, dyPixels * orbitSensitivity);
    final yaw = vm.Quaternion.axisAngle(_up, -dxPixels * orbitSensitivity);
    orientation = (orientation * pitch * yaw).normalized();
  }

  /// Drag-to-pan: moves [target] (and so the whole view) in the camera's own
  /// screen-relative right/up plane, so the point under the cursor at drag
  /// start tracks the cursor - the same "grab and drag the scene" feel as
  /// [SketchViewport.panByScreenDelta], just projected into 3D. Only the
  /// horizontal term is negated relative to the vertical one - confirmed on
  /// a real device that left/right pan was inverted but up/down wasn't.
  void panByScreenDelta(double dxPixels, double dyPixels) {
    final scale = panSensitivityPerDistance * distance;
    target = target + _right * (dxPixels * scale) + _up * (dyPixels * scale);
  }

  void zoomByFactor(double scaleFactor) {
    distance = (distance * scaleFactor).clamp(minDistance, maxDistance);
  }

  /// Scales [nearClip]/[farClip] and [minDistance]/[maxDistance] to [radius]
  /// (a body's bounding-sphere radius - see [boundsOfMesh]), so a large
  /// model is never far-clipped, the near clip plane (and so the zoom-in
  /// limit) shrinks for a small model instead of staying at a one-size-
  /// fits-all distance, and zooming out always stops a sensible distance
  /// from the current geometry. A non-positive [radius] (no body yet, or an
  /// empty one - [boundsOfMesh] returns `null` in that case) falls back to
  /// the `default*` constants instead. [distance] is re-clamped to the new
  /// bounds immediately, so a body shrinking never leaves the camera further
  /// out than [maxDistance] now allows.
  void setZoomBoundsForRadius(double radius) {
    if (radius > 0) {
      farClip = math.max(_minFarClip, radius * _farClipRadiusFactor);
      nearClip = farClip / _nearFarRatio;
      minDistance = nearClip * _minDistanceNearClipFactor;
      maxDistance = radius * _maxDistanceRadiusFactor;
    } else {
      nearClip = defaultNearClip;
      farClip = defaultFarClip;
      minDistance = defaultMinDistance;
      maxDistance = defaultMaxDistance;
    }
    distance = distance.clamp(minDistance, maxDistance);
  }

  /// Re-centers both the current and "Reset view" target on [newTarget] -
  /// called once the real geometry's bounds are known, since the
  /// placeholder box isn't centered at the world origin (see
  /// [boundsOfMesh]) and orbiting around (0,0,0) instead made it look
  /// like the model was rotating about one of its corners.
  void setTarget(vm.Vector3 newTarget) {
    target = newTarget;
    _defaultTarget = newTarget;
  }

  void reset() {
    orientation = _defaultOrientation();
    distance = _defaultDistance.clamp(minDistance, maxDistance);
    target = _defaultTarget;
  }
}

/// The camera orientation that looks straight at [plane] for the
/// camera-animation-into-Sketch feature, Orbit View's entry pose, and the
/// shaded-body-behind-canvas backdrop.
///
/// On-device feedback (2026-07-10): re-opening a Sketch on an existing Body
/// showed the shaded backdrop's own rendering mirrored left/right against
/// its *own* ghost outline (the same body's edges, projected onto the plane
/// via [SketchPlaneBasis] - a plain CPU dot-product, no camera involved).
/// The previous version of this function (and `test/orientation_facing_plane_test.dart`,
/// which it passed) verified [OrbitCamera]'s own `right`/`up`/`direction`
/// getters (`orientation.rotated(_localRight/_localUp/_localBack)`) against
/// `SketchPlaneBasis.fixed(plane)` directly - but `OrbitCamera.right` is not
/// actually what gets rendered on screen. `flutter_scene`'s `PerspectiveCamera`
/// (see its `_matrix4LookAt`, `packages/flutter_scene/lib/src/camera.dart` in
/// the `bdero/flutter_scene` repo) independently re-derives its own render-time
/// right as `up.cross(forward)` (`forward = (target - position).normalized()`,
/// i.e. `-direction`) - it never reads `OrbitCamera.right` at all. `triad.dart`'s
/// world compass already knew this and computes its own `right` the same way
/// (`camera.up.cross(forward)`), which is exactly why the compass has always
/// rendered correctly while this function's plane-facing views did not.
///
/// Given any right-handed local camera frame (`right x up = back`, true for
/// *any* orientation, regardless of [vm.Quaternion.rotated]'s own quirk - see
/// below), that render-time formula reduces to an exact identity:
/// `renderRight = -OrbitCamera.right` and `renderUp = OrbitCamera.up`, for
/// every orientation. So the previous test's assertion (`OrbitCamera.right ==
/// basis.xAxis`) was guaranteeing the *opposite* of what actually renders.
///
/// The fix targets the true render-time right/up directly. A camera with
/// `renderRight = basis.xAxis` and `renderUp = basis.yAxis` necessarily views
/// from the *opposite* side of the plane from before (`forward = renderRight
/// x renderUp = basis.xAxis x basis.yAxis = +basis.normal`, i.e. the camera
/// sits at `target - basis.normal * distance`, not `target + basis.normal *
/// distance`) - provably, not just empirically: `SketchPlaneBasis` is always
/// right-handed (`xAxis x yAxis = normal`, confirmed for all three planes by
/// `test_stage_c3_plane_basis.py`'s `test_xz_basis_is_now_right_handed` and
/// its neighbours in the backend, and true by construction on the client
/// side too - see [SketchPlaneBasis.fixed]'s own values), while
/// `flutter_scene`'s lookAt convention is left-handed (`right x up = forward`,
/// not `-forward`) - the two conventions can only ever agree from one side.
/// This flip is safe for the opaque shaded backdrop specifically: it isn't
/// translucent, so it doesn't hit the `doubleSidedWinding`/back-face-culling
/// quirk documented on `mesh_geometry.dart`'s `geometryFromMesh` (that quirk
/// only fires for translucent materials), and ordinary per-triangle depth
/// testing already handles being viewed from an arbitrary angle correctly
/// for free-orbiting, so it handles this one too.
///
/// Solved directly via a rotation matrix rather than hand-composed axis-angle
/// quaternions (the previous approach, which needed two separate CI-driven
/// correction rounds - composing quaternions by hand and predicting
/// [vm.Quaternion.rotated]'s effect is exactly the "genuinely error-prone to
/// verify by hand" trap the old doc comment already warned about). Given
/// [vm.Quaternion.rotated] is confirmed (from `vector_math`'s own source) to
/// compute `q.rotated(v) = R(q^-1) * v` - the conjugate/inverse of the
/// textbook `v' = q*v*q^-1` - solving `R(q^-1) * localRight = -basis.xAxis`,
/// `R(q^-1) * localUp = basis.yAxis`, `R(q^-1) * localBack = -basis.normal`
/// (the *negative* signs on right/back are what makes `OrbitCamera`'s own
/// getters land on the "wrong", but now provably-necessary-for-correct-render,
/// side) means `R(q) = R(q^-1)^-1 = R(q^-1)^T` is the matrix whose columns are
/// `(-xAxis.x, yAxis.x, -normal.x)`, `(-xAxis.y, yAxis.y, -normal.y)`,
/// `(-xAxis.z, yAxis.z, -normal.z)` - built directly below and handed to
/// [vm.Quaternion.fromRotation], with no multiplication/composition-order risk
/// at all.
/// Bug fix (on-device feedback: "the animation to sketch has dropped
/// working and should account for user selected sketch orientation"):
/// [flip]/[rotationQuarterTurns] default to the identity (matching every
/// pre-existing call site's behaviour unchanged), but a caller framing a
/// Sketch that has its own non-default orientation (see
/// `SketchDto.flip`/`SketchDto.rotationQuarterTurns`) should pass it
/// through here - otherwise the camera frames the plane's *raw* basis
/// while the Sketch's own geometry (and its Extrude) is actually embedded
/// via the *oriented* one, a mismatch between "which way the camera is
/// looking" and "which way the content is actually laid out".
vm.Quaternion orientationFacingPlane(
  ReferencePlaneKind plane, {
  bool flip = false,
  int rotationQuarterTurns = 0,
}) {
  final basis = SketchPlaneBasis.oriented(
    plane,
    flip: flip,
    rotationQuarterTurns: rotationQuarterTurns,
  );
  final targetRight = -basis.xAxis;
  final targetUp = basis.yAxis;
  final targetBack = -basis.normal;
  final rotation = vm.Matrix3.columns(
    vm.Vector3(targetRight.x, targetUp.x, targetBack.x),
    vm.Vector3(targetRight.y, targetUp.y, targetBack.y),
    vm.Vector3(targetRight.z, targetUp.z, targetBack.z),
  );
  return vm.Quaternion.fromRotation(rotation);
}
