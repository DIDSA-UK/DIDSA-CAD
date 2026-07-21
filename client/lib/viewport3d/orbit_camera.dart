import 'dart:math' as math;
import 'dart:ui' show Size;

import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart' as vm;

import 'orthographic_camera.dart';
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

  // A4/Phase 2: perspective vs orthographic toggle, wired through the View
  // menu. Was a dead flag until the sketcher restructure's Phase 2 - real
  // orthographic rendering needed flutter_scene to expose a usable
  // CameraProjection extension point, confirmed possible (and needed) by
  // Spike B - see [cameraFor] for where this now actually takes effect.
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

  /// On-device feedback + two numeric calibration rounds (a temporary debug
  /// readout in `part_viewport.dart`, cross-checked against the on-screen
  /// triad rather than eyeballed): the true isometric corner view - world
  /// X+/Y+ both read as screen-right (their shared `right` component is
  /// positive), Z+ reads as pure screen-up. Built from the desired
  /// [right]/[up] world-space vectors directly (not composed axis-angle
  /// rotations - the `pitch * yaw` structure this replaced can only ever
  /// produce an `up` with a zero world-X component, since yaw leaves the
  /// local-up axis untouched and pitch alone can't introduce that; it's
  /// structurally incapable of reaching this specific corner).
  ///
  /// **2026-07-22**: [right] negated (`(1, 1, 0)`, was `(-1, -1, 0)`) - not a
  /// re-calibration, a mechanical correction for [FixedPerspectiveCamera]'s
  /// own fix (see `orthographic_camera.dart`'s `correctedLookAt`). Unlike
  /// [orientationFacingBasis], this function has no compensating logic at
  /// all - it builds a raw quaternion directly from hardcoded world vectors,
  /// so the same on-screen picture needs a different quaternion once the
  /// renderer's own right/forward relationship changes. Hand-derived (not
  /// guessed) via the same vector algebra as [orientationFacingBasis]'s own
  /// fix: with the old renderer, `renderRight = up.cross(forward)` reduced -
  /// through this constructor's `back = right.cross(up)`, `forward =
  /// -orientation.rotated(localBack) = -back` - to `renderRight = -right`
  /// (this variable, negated) via `up.cross(-back) = -(up.cross(right.cross(up)))
  /// = -right` (vector triple product, `up`⊥`right` by construction); with
  /// the new renderer, `renderRight = forward.cross(up) = (-back).cross(up)`
  /// reduces to `+right` instead (`back.cross(up) = -right` by the matching
  /// identity) - an exact sign flip on `renderRight` alone, `renderUp`
  /// provably unchanged either way (`right.cross(forward)` reduces to `up`
  /// under both orderings, since the `up`-component of the triple product's
  /// other term vanishes by the same perpendicularity). Negating [right]
  /// exactly cancels that flip, reproducing the identical on-screen corner
  /// as before this whole investigation - confirmed by the fact that
  /// `orbit_camera_test.dart`'s own "matches the on-screen triad exactly"
  /// values are back to their original (pre-2026-07-22) numbers once both
  /// this fix and the test's own updated triad formula are in place
  /// together.
  static vm.Quaternion _isometricOrientation() {
    final right = vm.Vector3(1, 1, 0).normalized();
    const elevation = 0.6154797086703873; // asin(1 / sqrt(3)), true isometric
    final diagonal = math.sin(elevation) / math.sqrt2;
    final up = vm.Vector3(diagonal, -diagonal, math.cos(elevation));
    final back = right.cross(up);
    // vector_math's own Quaternion.rotate() computes `conjugate(this) * v *
    // this`, not the more commonly assumed `this * v * conjugate(this)` -
    // .conjugated() compensates so `.rotated(localAxis)` actually produces
    // right/up/back as constructed above, not their own inverse rotation
    // (confirmed empirically, not assumed - see the git history of this
    // file's own previous round for the numeric probe that found it).
    return vm.Quaternion.fromRotation(vm.Matrix3.columns(right, up, back)).conjugated();
  }

  /// The default cold-start view - now the same true isometric corner as
  /// [isometricOrientation] (see [_isometricOrientation]'s own doc comment)
  /// rather than a separate, looser ~30-degree elevation - on-device feedback
  /// specifically asked for "the nearest isometric view" as the default.
  static vm.Quaternion _defaultOrientation() => _isometricOrientation();

  /// The standard CAD isometric corner view, plane-independent unlike
  /// [orientationFacingPlane] - used for the sketch-orientation-definition
  /// step, before the user has confirmed which plane/flip/rotation they're
  /// actually defining, so there's no single "facing" view yet to animate
  /// the camera toward. Now identical to [_defaultOrientation] (see its own
  /// doc comment) - both are "the" isometric view, not two different ones.
  static vm.Quaternion isometricOrientation() => _isometricOrientation();

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

  /// Returns a [PerspectiveCamera] or [OrthographicCamera] depending on
  /// [isPerspective] - the two are interchangeable to every caller
  /// (`screenPointToRay`/`getViewTransform`/`getFrustum`/`scene.render` are
  /// all implemented once on the base `Camera` class), so this is the one
  /// place that decision gets made.
  Camera cameraFor(Size size) {
    if (isPerspective) {
      // FixedPerspectiveCamera, not flutter_scene's own PerspectiveCamera -
      // see orthographic_camera.dart's correctedLookAt for why: that
      // package's own view-matrix construction is a confirmed, genuine
      // mirror (2026-07-22), not this class.
      return FixedPerspectiveCamera(
        position: position,
        target: target,
        up: _up,
        fovNear: nearClip,
        fovFar: farClip,
      );
    }
    return orthographicCameraFor(this, size);
  }

  /// Drag-to-orbit: real-device testing found all four drag directions felt
  /// backwards under the original `-dyPixels`/`-dxPixels` mapping, so both
  /// signs were flipped to `+dyPixels`/`+dxPixels`. That fixed vertical
  /// (pitch) orbit, but horizontal (yaw) orbit was still backwards -
  /// swiping left rotated the model right and vice versa - so only the yaw
  /// term was flipped again, back to `-dxPixels`; the pitch term's
  /// `+dyPixels` untouched and confirmed correct on-device. Pitch is
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
  ///
  /// **2026-07-22**: yaw's sign flipped back to `+dxPixels` (pitch
  /// untouched). This drag mapping was hand-tuned entirely by feel against
  /// [FixedPerspectiveCamera]'s predecessor - flutter_scene's own, now-fixed
  /// `PerspectiveCamera`, which had a confirmed left-right mirror baked into
  /// its view matrix (see `orthographic_camera.dart`'s `correctedLookAt`).
  /// [_right]/[_up]/[orientation]'s own math are all untouched by that fix
  /// (only how a given orientation actually renders on screen changed), so
  /// a horizontal swipe now visibly swings the model the opposite way it
  /// used to for the exact same [orientation] change - on-device feedback
  /// confirmed only horizontal orbit felt backwards post-fix, consistent
  /// with the render fix only mirroring the horizontal axis, vertical
  /// unaffected (see [FixedPerspectiveCamera]'s own doc comment).
  void orbitByScreenDelta(double dxPixels, double dyPixels) {
    final pitch = vm.Quaternion.axisAngle(_right, dyPixels * orbitSensitivity);
    final yaw = vm.Quaternion.axisAngle(_up, dxPixels * orbitSensitivity);
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

  /// Keeps a body from touching the exact viewport edge once framed - purely
  /// cosmetic breathing room, not a correctness factor.
  static const double _frameRadiusPadding = 1.2;

  /// Sets [distance] to frame a sphere of [radius] within [viewportSize] -
  /// the auto-fit [reset] never actually did: [reset] alone only returns
  /// [distance] to [_defaultDistance], a fixed value tuned against the
  /// *reference planes'* own fixed size (see that constant's own doc
  /// comment), never the current body's actual size. On-device feedback: a
  /// body significantly larger than that tuning (e.g. an imported STEP file
  /// spanning 100+ world units) left "Reset View" pointed at a distance far
  /// too close to show any of it.
  ///
  /// Matches [orthographicCameraFor]'s identical 45-degree vertical FOV
  /// assumption (see its own doc comment) so perspective/orthographic frame
  /// the same body identically, and accounts for [viewportSize]'s aspect
  /// ratio the same way that function's `halfWidth = halfHeight *
  /// aspectRatio` does - a portrait viewport is width-limited, a landscape
  /// one height-limited, so this picks whichever bound is actually tighter
  /// rather than assuming a square viewport.
  ///
  /// No-op (leaves [distance] untouched) for a non-positive [radius] or an
  /// empty [viewportSize] - nothing meaningful to frame yet, same "caller
  /// falls back to the `default*` constants" contract [setZoomBoundsForRadius]
  /// already uses.
  void frameRadius(double radius, Size viewportSize) {
    if (radius <= 0 || viewportSize.isEmpty) return;
    const halfFovY = 45 * math.pi / 180 / 2;
    final aspectRatio = viewportSize.width / viewportSize.height;
    final limitingTan = math.tan(halfFovY) * math.min(1.0, aspectRatio);
    distance = (radius * _frameRadiusPadding / limitingTan).clamp(minDistance, maxDistance);
  }
}

/// The camera orientation that looks straight at [plane] for the
/// camera-animation-into-Sketch feature, Orbit View's entry pose, and the
/// shaded-body-behind-canvas backdrop.
///
/// **2026-07-22 update**: the render-time formula this function targets
/// changed. It used to solve for `renderRight = up.cross(forward)`/
/// `renderUp = forward.cross(right)` - `flutter_scene`'s own `PerspectiveCamera`
/// convention, confirmed (by reading its actual source,
/// `package:flutter_scene/src/camera.dart`'s `_matrix4LookAt`) to be a real,
/// confirmed bug: `up.cross(forward)` is the wrong cross-product order for a
/// right-handed view space (`up.cross(forward) = -(forward.cross(up))` for
/// *any* up/forward - a general identity, not a one-off case), producing a
/// genuine, un-rotatable mirror image for every camera built through it. See
/// `orthographic_camera.dart`'s `correctedLookAt` for the full derivation and
/// on-device confirmation (a labeled SolidWorks STEP import and a from-
/// scratch DIDSA-CAD Boss both mirrored, independent of that bug, and
/// unrelated to any world-space/backend data - `plane_geometry.py`'s sketch
/// basis and the STEP import/export paths are all independently verified
/// clean). [OrbitCamera.cameraFor] now returns [FixedPerspectiveCamera],
/// which fixes this at its root (`renderRight = forward.cross(up)`) - so
/// this function's own target formula moves with it, below.
///
/// On-device feedback (2026-07-10, predates the above): re-opening a Sketch
/// on an existing Body showed the shaded backdrop's own rendering mirrored
/// left/right against its *own* ghost outline (the same body's edges,
/// projected onto the plane via [SketchPlaneBasis] - a plain CPU dot-product,
/// no camera involved) - the version of this function *before* that fix
/// verified [OrbitCamera]'s own `right`/`up`/`direction` getters directly
/// against `SketchPlaneBasis.fixed(plane)`, which isn't actually what
/// renders (`OrbitCamera.right` is the camera's own local-frame vector, not
/// flutter_scene's independently-rederived render-time right - `triad.dart`'s
/// world compass already knew this, which is why the compass rendered
/// correctly all along while this function's plane-facing views didn't).
/// That fix targeted the true (then-buggy) render-time formula directly
/// instead - correct methodology, now re-targeted at the *actual-correct*
/// render-time formula per the update above, with the exact same "solve
/// [vm.Quaternion.rotated]'s known `R(q^-1)` convention directly via a
/// rotation matrix rather than hand-composed axis-angle quaternions" approach
/// (see git history for the original, now-superseded derivation this one
/// replaces).
///
/// A camera with `renderRight = basis.xAxis` and `renderUp = basis.yAxis`
/// now (post-fix) views from the *[basis.normal]-side* of the plane (`forward
/// = renderRight x renderUp = basis.xAxis x basis.yAxis = basis.normal`, so
/// the camera physically sits at `target + basis.normal * distance`, looking
/// back through -normal at the plane's front face - the intuitive side,
/// unlike the pre-fix version's `target - basis.normal * distance`) -
/// `SketchPlaneBasis` is always right-handed (`xAxis x yAxis = normal`,
/// confirmed for all three planes by the backend's own
/// `test_xz_basis_is_now_right_handed` and true by construction client-side
/// too - see [SketchPlaneBasis.fixed]'s own values), and the camera's own
/// [FixedPerspectiveCamera] view space now matches that same handedness, so
/// the two agree directly rather than needing a compensating negation.
///
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
}) =>
    orientationFacingBasis(
      SketchPlaneBasis.oriented(plane, flip: flip, rotationQuarterTurns: rotationQuarterTurns),
    );

/// [orientationFacingPlane]'s own math, generalized to any [SketchPlaneBasis]
/// - not just one of the three fixed [ReferencePlaneKind]s - so a custom
/// (Feature-anchored) plane Sketch's Orbit View can frame it exactly the same
/// way a fixed-plane Sketch's already does (see [PartViewport.
/// initialViewBasis]/[PartViewportState.animateToBasis]). [orientationFacingPlane]
/// is now just this applied to [SketchPlaneBasis.oriented]'s result - every
/// word of this function's own derivation above still applies verbatim,
/// [basis] is just handed in directly instead of built from a
/// [ReferencePlaneKind] first.
///
/// Bug fix (on-device feedback - camera calibration, "8 possible
/// orientations for each plane" not all working correctly): [basis.flip]
/// makes [basis.xAxis]/[basis.yAxis] a *left-handed* pair relative to
/// [basis.normal] - confirmed by computing `xAxis.cross(yAxis)` directly
/// (not assumed): it equals `-basis.normal` whenever flip is applied, for
/// every plane, regardless of rotation. `Quaternion.fromRotation` can only
/// represent a proper rotation (determinant +1); handed a matrix built from
/// [basis.normal] directly whenever that's left-handed relative to
/// xAxis/yAxis, it silently produced an incorrect result instead of the
/// intended flipped/mirrored view - this is what made every previous
/// per-plane flip default an unpredictable moving target. Fixed by deriving
/// the camera's own viewing direction from the basis's own *actual*
/// handedness (`xAxis.cross(yAxis)`) instead of trusting [basis.normal]
/// blindly - a no-op for every already-correct (right-handed, unflipped)
/// case, since `xAxis.cross(yAxis) == basis.normal` there by construction;
/// only changes anything for a flipped (left-handed) basis, exactly the
/// case that was broken.
///
/// **2026-07-22**: `targetRight`/`targetBack` no longer negate
/// [basis.xAxis]/`effectiveNormal` - those negations existed solely to
/// compensate for the render-time mirror described in this function's own
/// doc comment above, now fixed at its actual root
/// ([FixedPerspectiveCamera]) instead of here. Removing them keeps this
/// function's own external contract identical (`renderRight` still equals
/// `basis.xAxis`, `renderUp` still equals `basis.yAxis`, for every plane/
/// flip/rotation) - only the internal target-back/right values (and which
/// physical side of the plane the camera ends up on) changed; every caller
/// of [orientationFacingPlane]/[orientationFacingBasis] should see the exact
/// same on-screen result as before this update, just against a renderer
/// that no longer needs correcting.
vm.Quaternion orientationFacingBasis(SketchPlaneBasis basis) {
  final targetRight = basis.xAxis;
  final targetUp = basis.yAxis;
  final effectiveNormal = basis.xAxis.cross(basis.yAxis);
  final targetBack = effectiveNormal;
  final rotation = vm.Matrix3.columns(
    vm.Vector3(targetRight.x, targetUp.x, targetBack.x),
    vm.Vector3(targetRight.y, targetUp.y, targetBack.y),
    vm.Vector3(targetRight.z, targetUp.z, targetBack.z),
  );
  return vm.Quaternion.fromRotation(rotation);
}
