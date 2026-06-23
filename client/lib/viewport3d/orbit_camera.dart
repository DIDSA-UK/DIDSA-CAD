import 'dart:math' as math;
import 'dart:ui' show Size;

import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart' as vm;

import 'reference_planes.dart';

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

  /// Multipliers applied to a body's bounding-sphere radius to derive
  /// [minDistance]/[maxDistance] - chosen so the minimum keeps the camera
  /// just outside the body (radius x2) and the maximum keeps it close
  /// enough to still be a recognisable shape on screen (radius x20), per
  /// the brief's own heuristic.
  static const double _minDistanceRadiusFactor = 2;
  static const double _maxDistanceRadiusFactor = 20;

  /// Mutable, unlike the fixed bounds of an earlier version - scaled to the
  /// accumulated mesh's actual size by [setZoomBoundsForRadius] (see
  /// [PartViewport._syncMeshNode]) so zooming out always stops a sensible
  /// distance from the current geometry rather than a one-size-fits-all
  /// fixed distance.
  double minDistance = defaultMinDistance;
  double maxDistance = defaultMaxDistance;

  /// Radians/pixel for a mouse drag or 1:1-scaled touch drag - matches the
  /// "real device px -> visible angle" feel [SketchViewport] aims for with
  /// its own per-pixel sensitivity constants.
  static const double orbitSensitivity = 0.01;

  /// World units of [target] travel per screen pixel of pan drag, *
  /// [distance] - panning by a fixed angle/world-distance per pixel would
  /// feel too fast when zoomed in and too slow zoomed out, so it scales with
  /// how far the camera currently is from its target.
  static const double panSensitivityPerDistance = 0.002;

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
  static const double _defaultDistance = 30;

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

  PerspectiveCamera cameraFor(Size size) {
    final position = target + _direction * distance;
    return PerspectiveCamera(position: position, target: target, up: _up);
  }

  /// Drag-to-orbit: real-device testing found all four drag directions felt
  /// backwards under the original `-dyPixels`/`-dxPixels` mapping, so both
  /// signs were flipped to `+dyPixels`/`+dxPixels`. That fixed vertical
  /// (pitch) orbit, but horizontal (yaw) orbit was still backwards -
  /// swiping left rotated the model right and vice versa - so only the yaw
  /// term is flipped again here, back to `-dxPixels`; the pitch term's
  /// `+dyPixels` is untouched and confirmed correct on-device. Pitch is
  /// applied about the camera's *current* right axis (so it always tilts
  /// the view the way it's currently facing), then yaw about the fixed
  /// world-up axis (so left/right drags always swing around the same
  /// vertical regardless of how far the camera has already been tilted) -
  /// composed as quaternions, with no clamping, so this never gets stuck.
  ///
  /// Once the camera has orbited past vertical, [_up] points away from
  /// world-up rather than towards it - the model now reads as
  /// "upside-down" - and yawing about the fixed world-up axis then swings
  /// the view the opposite way the drag visually suggests. Flipping
  /// `dxPixels` whenever [_up] and world-up have gone more than 90 degrees
  /// apart (a negative dot product) keeps horizontal drag direction feeling
  /// consistent regardless of orientation; vertical/pitch is unaffected.
  void orbitByScreenDelta(double dxPixels, double dyPixels) {
    final upsideDown = _up.dot(_localUp) < 0;
    final yawDx = upsideDown ? -dxPixels : dxPixels;
    final pitch = vm.Quaternion.axisAngle(_right, dyPixels * orbitSensitivity);
    final yaw = vm.Quaternion.axisAngle(_localUp, -yawDx * orbitSensitivity);
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

  /// Scales [minDistance]/[maxDistance] to [radius] (a body's bounding-
  /// sphere radius - see [boundsOfMesh]), per [_minDistanceRadiusFactor]/
  /// [_maxDistanceRadiusFactor], so zooming out always stops a sensible
  /// distance from the current geometry rather than the one-size-fits-all
  /// [defaultMinDistance]/[defaultMaxDistance]. A non-positive [radius]
  /// (no body yet, or an empty one - [boundsOfMesh] returns `null` in that
  /// case) falls back to those defaults instead. [distance] is re-clamped
  /// to the new bounds immediately, so a body shrinking never leaves the
  /// camera further out than [maxDistance] now allows.
  void setZoomBoundsForRadius(double radius) {
    if (radius > 0) {
      minDistance = radius * _minDistanceRadiusFactor;
      maxDistance = radius * _maxDistanceRadiusFactor;
    } else {
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

/// The camera orientation that looks straight down at [plane] from the side
/// specified for the camera-animation-into-Sketch feature - XY from +Z (down
/// -Z), XZ from +Y (down -Y), YZ from +X (down -X). Derived by hand from
/// [OrbitCamera]'s own `_direction = orientation.rotated((0, 0, 1))` /
/// `_up = orientation.rotated((0, 1, 0))` convention: identity orientation
/// already gives direction=+Z (XY's case), and the other two are a single
/// axis-angle rotation each that carries +Z to +Y or +X respectively.
///
/// XZ and YZ's resulting "up" (world (0, 0, -1) and world (0, 1, 0)
/// respectively) is a deliberate but unforced convention choice - the brief
/// only specifies the look-from direction, not which way is "up" for a
/// top-down/side-on view - and would benefit from a real-device check that
/// it doesn't feel upside-down.
vm.Quaternion orientationFacingPlane(ReferencePlaneKind plane) => switch (plane) {
      ReferencePlaneKind.xy => vm.Quaternion.identity(),
      ReferencePlaneKind.xz => vm.Quaternion.axisAngle(vm.Vector3(1, 0, 0), -math.pi / 2),
      ReferencePlaneKind.yz => vm.Quaternion.axisAngle(vm.Vector3(0, 1, 0), math.pi / 2),
    };
