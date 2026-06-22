import 'package:flutter/material.dart';
import 'package:flutter_scene/scene.dart' show PerspectiveCamera;
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
/// with a plain [PerspectiveCamera], unlike the actual paint step.
List<TriadAxis> triadAxes(PerspectiveCamera camera) {
  final forward = camera.forward;
  final right = camera.up.cross(forward).normalized();
  final up = forward.cross(right).normalized();

  Offset project(vm.Vector3 worldAxis) => Offset(worldAxis.dot(right), -worldAxis.dot(up));

  return [
    TriadAxis(label: 'X', color: Colors.red, direction: project(vm.Vector3(1, 0, 0))),
    TriadAxis(label: 'Y', color: Colors.green, direction: project(vm.Vector3(0, 1, 0))),
    TriadAxis(label: 'Z', color: Colors.blue, direction: project(vm.Vector3(0, 0, 1))),
  ];
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
