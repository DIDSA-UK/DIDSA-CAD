// Track 2, Spike B, B1+B2 — throwaway on-device interaction/camera
// prototype. NOT wired into the app's real navigation; temporarily set as
// main.dart's home screen for this test, then reverted. Deliberately
// standalone (not PartViewport) so it doesn't touch any production widget -
// reuses the same real building blocks PartViewport itself uses
// (OrbitCamera, buildReferencePlaneNode, hitTestReferencePlanes,
// Camera.screenPointToRay), just with its own minimal gesture handling and
// render loop.
//
// B1 tests the interaction mechanic: tap -> ray -> hitTestReferencePlanes ->
// place one visible point. Single-finger drag orbits, pinch zooms.
//
// B2 adds a perspective/orthographic toggle. `OrthographicProjection`
// implements flutter_scene 0.18.1's own documented extension point
// (`CameraProjection` - see camera.dart: "applications can implement
// CameraProjection for orthographic or other projections") - no patch or
// fork needed, confirmed by the earlier research pass. `OrthographicCamera`
// mirrors `PerspectiveCamera`'s eye/target/up bookkeeping and its private
// look-at matrix construction (reimplemented here since it's a private
// top-level function in the package, not exported) - everything else
// (screenPointToRay, getViewTransform, getFrustum) is inherited unchanged
// from the base `Camera` class, so ray-based picking should work under
// orthographic with zero extra code - that's exactly what this screen's
// tap-to-place test confirms on-device.

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart' as vm;

import 'orbit_camera.dart';
import 'reference_planes.dart';

/// A standard orthographic projection - same [0,1] depth-range convention
/// flutter_scene's own `PerspectiveProjection`/`_matrix4Perspective` uses
/// (confirmed by reading that private function), just without the
/// perspective divide (w stays 1).
class OrthographicProjection extends CameraProjection {
  OrthographicProjection({required this.halfHeight, this.near = 0.1, this.far = 1000.0});

  /// Half the world-space height of the view volume - the orthographic
  /// equivalent of [PerspectiveProjection.fovRadiansY].
  double halfHeight;
  double near;
  double far;

  @override
  vm.Matrix4 getProjectionMatrix(double aspectRatio) {
    final halfWidth = halfHeight * aspectRatio;
    return vm.Matrix4(
      1.0 / halfWidth, 0.0, 0.0, 0.0, //
      0.0, 1.0 / halfHeight, 0.0, 0.0, //
      0.0, 0.0, 1.0 / (far - near), 0.0, //
      0.0, 0.0, -near / (far - near), 1.0, //
    );
  }
}

vm.Matrix4 _lookAt(vm.Vector3 eye, vm.Vector3 target, vm.Vector3 up) {
  final forward = (target - eye).normalized();
  final right = up.cross(forward).normalized();
  final realUp = forward.cross(right).normalized();
  return vm.Matrix4(
    right.x, realUp.x, forward.x, 0.0, //
    right.y, realUp.y, forward.y, 0.0, //
    right.z, realUp.z, forward.z, 0.0, //
    -right.dot(eye), -realUp.dot(eye), -forward.dot(eye), 1.0, //
  );
}

/// The orthographic counterpart to [PerspectiveCamera] - same eye/target/up
/// shape, paired with [OrthographicProjection] instead.
class OrthographicCamera extends Camera {
  OrthographicCamera({
    required this.position,
    required this.target,
    required this.up,
    required this.halfHeight,
    this.near = 0.1,
    this.far = 1000.0,
  });

  @override
  vm.Vector3 position;
  vm.Vector3 target;
  @override
  vm.Vector3 up;
  double halfHeight;
  double near;
  double far;

  @override
  vm.Vector3 get forward => (target - position).normalized();

  @override
  CameraProjection get projection => OrthographicProjection(halfHeight: halfHeight, near: near, far: far);

  @override
  vm.Matrix4 getViewMatrix() => _lookAt(position, target, up);
}

class B1TapTestScreen extends StatefulWidget {
  const B1TapTestScreen({super.key});

  @override
  State<B1TapTestScreen> createState() => _B1TapTestScreenState();
}

class _B1TapTestScreenState extends State<B1TapTestScreen> {
  final OrbitCamera _camera = OrbitCamera();
  Scene? _scene;
  Size _viewportSize = Size.zero;
  String? _status;
  bool _orthographic = false;

  static const double _markerRadius = 0.3;

  /// The active [Camera] for both rendering and ray-casting - swapping this
  /// is the entire B2 change; `screenPointToRay`/`hitTestReferencePlanes`
  /// downstream are completely unaware which kind they got.
  Camera _cameraFor(Size size) {
    if (!_orthographic) return _camera.cameraFor(size);
    // Match perspective's apparent scale at the current distance so
    // toggling doesn't jarringly resize the view: half-height = distance *
    // tan(halfFovY), using PerspectiveCamera's default 45deg vertical FOV
    // (OrbitCamera.cameraFor doesn't override fovRadiansY).
    final halfHeight = _camera.distance * math.tan(45 * math.pi / 180 / 2);
    return OrthographicCamera(
      position: _camera.position,
      target: _camera.target,
      up: _camera.up,
      halfHeight: halfHeight,
      near: _camera.nearClip,
      far: _camera.farClip,
    );
  }

  @override
  void initState() {
    super.initState();
    Scene.initializeStaticResources().then((_) {
      if (!mounted) return;
      final scene = Scene();
      for (final plane in ReferencePlaneKind.values) {
        scene.add(buildReferencePlaneNode(plane));
      }
      setState(() => _scene = scene);
    });
  }

  void _placeMarker(vm.Vector3 point) {
    final scene = _scene;
    if (scene == null) return;
    final existing = scene.root.children.where((n) => n.name == 'b1-marker').toList();
    for (final node in existing) {
      scene.remove(node);
    }
    final material = UnlitMaterial()
      ..alphaMode = AlphaMode.opaque
      ..baseColorFactor = vm.Vector4(1.0, 0.15, 0.15, 1.0);
    scene.add(Node(
      name: 'b1-marker',
      localTransform: vm.Matrix4.translation(point),
      mesh: Mesh.primitives(primitives: [MeshPrimitive(SphereGeometry(radius: _markerRadius), material)]),
    ));
  }

  void _handleTapUp(TapUpDetails details) {
    if (_viewportSize == Size.zero) return;
    final ray = _cameraFor(_viewportSize).screenPointToRay(details.localPosition, _viewportSize);
    final hit = hitTestReferencePlanes(ray);
    if (hit == null) {
      setState(() => _status = 'Tap missed every reference plane.');
      return;
    }
    _placeMarker(hit.point);
    setState(() {
      _status =
          '${hit.plane.name.toUpperCase()} plane @ world (${hit.point.x.toStringAsFixed(2)}, '
          '${hit.point.y.toStringAsFixed(2)}, ${hit.point.z.toStringAsFixed(2)}), rayT=${hit.rayT.toStringAsFixed(2)}';
    });
  }

  Offset? _lastFocalPoint;
  double _lastScale = 1.0;

  void _handleScaleStart(ScaleStartDetails details) {
    _lastFocalPoint = details.localFocalPoint;
    _lastScale = 1.0;
  }

  void _handleScaleUpdate(ScaleUpdateDetails details) {
    final last = _lastFocalPoint;
    if (last != null && details.pointerCount == 1) {
      final delta = details.localFocalPoint - last;
      _camera.orbitByScreenDelta(delta.dx, delta.dy);
    }
    if (details.pointerCount >= 2) {
      final scaleDelta = details.scale / _lastScale;
      // zoomByFactor multiplies *distance* by its argument (factor > 1 =>
      // further away). Fingers spreading apart (scaleDelta > 1) should
      // zoom in (distance decreases) - invert.
      if (scaleDelta.isFinite && scaleDelta > 0) {
        _camera.zoomByFactor(1 / scaleDelta);
      }
      _lastScale = details.scale;
    }
    _lastFocalPoint = details.localFocalPoint;
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final scene = _scene;
    return Scaffold(
      appBar: AppBar(
        title: Text('B1/B2 test — ${_orthographic ? "orthographic" : "perspective"}'),
        actions: [
          Switch(
            value: _orthographic,
            onChanged: (v) => setState(() => _orthographic = v),
          ),
        ],
      ),
      body: scene == null
          ? const Center(child: CircularProgressIndicator())
          : Stack(
              children: [
                LayoutBuilder(
                  builder: (context, constraints) {
                    _viewportSize = Size(constraints.maxWidth, constraints.maxHeight);
                    return GestureDetector(
                      onTapUp: _handleTapUp,
                      onScaleStart: _handleScaleStart,
                      onScaleUpdate: _handleScaleUpdate,
                      child: CustomPaint(
                        size: _viewportSize,
                        painter: _B1ScenePainter(scene: scene, camera: _cameraFor(_viewportSize), size: _viewportSize),
                      ),
                    );
                  },
                ),
                Positioned(
                  left: 8,
                  right: 8,
                  bottom: 8,
                  child: Container(
                    padding: const EdgeInsets.all(8),
                    color: Colors.black54,
                    child: Text(
                      _status ?? 'Drag to orbit, pinch to zoom, tap a plane to place a point. Toggle top-right for orthographic.',
                      style: const TextStyle(color: Colors.white),
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}

class _B1ScenePainter extends CustomPainter {
  _B1ScenePainter({required this.scene, required this.camera, required this.size});

  final Scene scene;
  final Camera camera;
  final Size size;

  @override
  void paint(ui.Canvas canvas, ui.Size canvasSize) {
    if (canvasSize.isEmpty) return;
    scene.render(camera, canvas, viewport: Offset.zero & canvasSize);
  }

  @override
  bool shouldRepaint(covariant _B1ScenePainter oldDelegate) => true;
}
