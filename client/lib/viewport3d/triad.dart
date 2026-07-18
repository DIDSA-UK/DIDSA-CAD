import 'package:flutter/material.dart';
import 'package:flutter_scene/scene.dart' show Camera;
import 'package:vector_math/vector_math.dart' as vm;

/// One axis of the on-screen orientation triad: its label, color, and the
/// screen-space direction it should point (see [triadAxes]).
class TriadAxis {
  final String label;
  final Color color;

  /// Screen-space direction (x right, y down) - not necessarily unit
  /// length: an axis pointing towards/away from the camera foreshortens
  /// towards zero length, the same visual cue a real 3D arrow would give.
  final Offset direction;

  const TriadAxis({required this.label, required this.color, required this.direction});
}

/// Stage 18's axis colours, matching the reference planes' own RGB-axis
/// coding (see `reference_planes.dart`'s `_baseColor`).
const Color triadColorX = Color(0xFFE8364A);
const Color triadColorY = Color(0xFF27AE60);
const Color triadColorZ = Color(0xFF3A7BD5);

/// Orientation-only projection of the world X/Y/Z axes onto [camera]'s
/// screen right/up directions - the same "compass gizmo" approach CAD tools
/// use for an always-readable orientation indicator. Deliberately ignores
/// [camera]'s position/target/distance (translation and zoom never apply)
/// so the result only depends on which way the camera is currently facing -
/// this is what lets [PartViewport] draw the triad at a fixed screen
/// position/size regardless of orbit/pan/zoom, per the project brief's
/// "screen-space overlay... is the more reliable approach for always-visible
/// clarity".
///
/// Pure vector math - no [Canvas]/GPU dependency - so this is unit-testable
/// with a plain camera, unlike the actual paint step. Typed to the base
/// [Camera] (not [PerspectiveCamera] specifically) since it only ever reads
/// [Camera.forward]/[Camera.up], both implemented identically by
/// [OrthographicCamera].
List<TriadAxis> triadAxes(Camera camera) {
  final forward = camera.forward;
  final right = camera.up.cross(forward).normalized();
  final up = forward.cross(right).normalized();

  Offset project(vm.Vector3 worldAxis) => Offset(worldAxis.dot(right), -worldAxis.dot(up));

  return [
    TriadAxis(label: 'X', color: triadColorX, direction: project(vm.Vector3(1, 0, 0))),
    TriadAxis(label: 'Y', color: triadColorY, direction: project(vm.Vector3(0, 1, 0))),
    TriadAxis(label: 'Z', color: triadColorZ, direction: project(vm.Vector3(0, 0, 1))),
  ];
}

/// TEMPORARY (camera-calibration debug aid, on-device feedback): for each
/// world axis, how much of it currently reads as screen-right, screen-up,
/// and pointing *out of* the screen toward the camera (vs. into it) - the
/// exact three numbers a sentence like "Z out of the screen"/"Z right"/"Y
/// up" describes directly. Shares [triadAxes]' own right/up derivation
/// (`camera.up.cross(camera.forward)`, then `forward.cross(right)`) rather
/// than reading `OrbitCamera.right`/`.up` directly - those are the camera's
/// own local-frame vectors, and (confirmed by deriving this formula
/// algebraically, not assumed) read the *opposite* sign for "right" from
/// what actually renders on screen. Shared by [PartViewport] and the mesh
/// viewer's own viewport so both read identically to the trusted on-screen
/// triad.
String debugCameraOrientationText(Camera camera) {
  final forward = camera.forward;
  final right = camera.up.cross(forward).normalized();
  final up = forward.cross(right).normalized();
  final towardCamera = -forward;

  String axisLine(String label, vm.Vector3 axis) {
    final r = axis.dot(right).toStringAsFixed(2);
    final u = axis.dot(up).toStringAsFixed(2);
    final o = axis.dot(towardCamera).toStringAsFixed(2);
    return '$label: right=$r up=$u out=$o';
  }

  return [
    axisLine('X', vm.Vector3(1, 0, 0)),
    axisLine('Y', vm.Vector3(0, 1, 0)),
    axisLine('Z', vm.Vector3(0, 0, 1)),
  ].join('\n');
}

/// TEMPORARY (camera-calibration debug aid): [debugCameraOrientationText]
/// wrapped as a small top-centered overlay - shared so [PartViewport] and
/// the mesh viewer's own viewport show it identically.
class DebugCameraOrientationOverlay extends StatelessWidget {
  final Camera camera;

  const DebugCameraOrientationOverlay({super.key, required this.camera});

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: 8,
      left: 0,
      right: 0,
      child: Center(
        child: IgnorePointer(
          // Container/BoxDecoration, not the Material widget - callers of
          // this widget already import flutter_scene's own (unrelated)
          // Material class for 3D materials, and the two names collide.
          child: Container(
            decoration: BoxDecoration(
              color: Colors.black54,
              borderRadius: BorderRadius.circular(8),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Text(
              debugCameraOrientationText(camera),
              style: const TextStyle(
                color: Colors.white,
                fontFamily: 'monospace',
                fontSize: 12,
                height: 1.4,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Paints [axes] (see [triadAxes]) as a fixed-size compass centered at
/// [center] - each axis as a short colored line with a label at its tip.
void paintTriad(Canvas canvas, Offset center, List<TriadAxis> axes, {double armLength = 28}) {
  for (final axis in axes) {
    final tip = center + axis.direction * armLength;
    canvas.drawLine(
      center,
      tip,
      Paint()
        ..color = axis.color
        ..strokeWidth = 2,
    );
    canvas.drawCircle(tip, 2.5, Paint()..color = axis.color);
    final textPainter = TextPainter(
      text: TextSpan(
        text: axis.label,
        style: TextStyle(color: axis.color, fontSize: 12, fontWeight: FontWeight.bold),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    textPainter.paint(canvas, tip + const Offset(4, -6));
  }
}
