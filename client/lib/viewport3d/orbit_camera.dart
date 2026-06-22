import 'dart:ui' show Size;

import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart' as vm;

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
  static const double minDistance = 5;
  static const double maxDistance = 300;

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

  OrbitCamera({this.distance = 30, vm.Vector3? target})
      : target = target ?? vm.Vector3.zero(),
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

  /// Drag-to-orbit: dragging up tilts the camera further overhead, dragging
  /// right swings it around to the left - an arbitrary but internally
  /// consistent convention, same as any orbit-cam UI. Pitch is applied
  /// about the camera's *current* right axis (so it always tilts the view
  /// the way it's currently facing), then yaw about the fixed world-up axis
  /// (so left/right drags always swing around the same vertical regardless
  /// of how far the camera has already been tilted) - composed as
  /// quaternions, with no clamping, so this never gets stuck.
  void orbitByScreenDelta(double dxPixels, double dyPixels) {
    final pitch = vm.Quaternion.axisAngle(_right, -dyPixels * orbitSensitivity);
    final yaw = vm.Quaternion.axisAngle(_localUp, -dxPixels * orbitSensitivity);
    orientation = (orientation * pitch * yaw).normalized();
  }

  /// Drag-to-pan: moves [target] (and so the whole view) in the camera's own
  /// screen-relative right/up plane, so the point under the cursor at drag
  /// start tracks the cursor - the same "grab and drag the scene" feel as
  /// [SketchViewport.panByScreenDelta], just projected into 3D.
  void panByScreenDelta(double dxPixels, double dyPixels) {
    final scale = panSensitivityPerDistance * distance;
    target = target - _right * (dxPixels * scale) + _up * (dyPixels * scale);
  }

  void zoomByFactor(double scaleFactor) {
    distance = (distance * scaleFactor).clamp(minDistance, maxDistance);
  }

  void reset() {
    orientation = _defaultOrientation();
    distance = 30;
    target = vm.Vector3.zero();
  }
}
