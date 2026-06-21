import 'dart:math' as math;
import 'dart:ui' show Size;

import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart' as vm;

/// Mutable orbit/pan/zoom state for the 3D viewport - the 3D equivalent of
/// [SketchViewport], producing a `flutter_scene` [PerspectiveCamera] for a
/// given canvas size. Orbits and pans around [target] using spherical
/// coordinates ([azimuth]/[elevation]/[distance]) rather than storing a
/// camera position directly, so "zoom" and "orbit" can never accidentally
/// fight each other (e.g. zooming all the way in flipping the view through
/// the target).
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

  /// Clamped just shy of the poles so the camera can never look straight
  /// down/up, where azimuth becomes meaningless and the view can flip.
  static const double _maxElevation = 89 * math.pi / 180;

  double azimuth;
  double elevation;
  double distance;
  vm.Vector3 target;

  OrbitCamera({
    this.azimuth = math.pi / 4,
    this.elevation = math.pi / 6,
    this.distance = 30,
    vm.Vector3? target,
  }) : target = target ?? vm.Vector3.zero();

  /// Unit vector from [target] towards the camera.
  vm.Vector3 get _direction => vm.Vector3(
        math.cos(elevation) * math.sin(azimuth),
        math.sin(elevation),
        math.cos(elevation) * math.cos(azimuth),
      );

  PerspectiveCamera cameraFor(Size size) {
    final position = target + _direction * distance;
    return PerspectiveCamera(position: position, target: target, up: vm.Vector3(0, 1, 0));
  }

  /// Drag-to-orbit: dragging up tilts the camera further overhead (elevation
  /// increases), dragging right swings it around to the left (azimuth
  /// increases) - an arbitrary but internally consistent convention, same as
  /// any orbit-cam UI.
  void orbitByScreenDelta(double dxPixels, double dyPixels) {
    azimuth += dxPixels * orbitSensitivity;
    elevation = (elevation - dyPixels * orbitSensitivity).clamp(-_maxElevation, _maxElevation);
  }

  /// Drag-to-pan: moves [target] (and so the whole view) in the camera's own
  /// screen-relative right/up plane, so the point under the cursor at drag
  /// start tracks the cursor - the same "grab and drag the scene" feel as
  /// [SketchViewport.panByScreenDelta], just projected into 3D.
  void panByScreenDelta(double dxPixels, double dyPixels) {
    final forward = -_direction;
    final worldUp = vm.Vector3(0, 1, 0);
    final right = worldUp.cross(forward).normalized();
    final camUp = forward.cross(right).normalized();
    final scale = panSensitivityPerDistance * distance;
    target = target - right * (dxPixels * scale) + camUp * (dyPixels * scale);
  }

  void zoomByFactor(double scaleFactor) {
    distance = (distance * scaleFactor).clamp(minDistance, maxDistance);
  }

  void reset() {
    azimuth = math.pi / 4;
    elevation = math.pi / 6;
    distance = 30;
    target = vm.Vector3.zero();
  }
}
