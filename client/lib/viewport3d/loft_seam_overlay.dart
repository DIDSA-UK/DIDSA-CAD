import 'package:flutter/material.dart';
import 'package:flutter_scene/scene.dart' show Camera;
import 'package:vector_math/vector_math.dart' as vm;

import '../api/document_api_client.dart' show LoftSeamHandleDto;
import 'screen_projection.dart';

/// A loft section's profile in screen space, ready for hit-testing and drawing: [points] is
/// the profile sampled at equal arc-length fractions from its default start (closed - the last
/// sample connects back to the first), projected through [camera]. A sample behind the camera is
/// null and its neighbouring segments are skipped.
List<Offset?> loftSeamScreenPolyline(
  Camera camera,
  Size viewportSize,
  vm.Matrix4? focusTransform,
  List<vm.Vector3> points,
) =>
    [for (final p in points) worldToScreenFocused(camera, viewportSize, focusTransform, p)];

/// Where a marker at [fraction] (0..1 around the closed profile) sits on screen, or null when
/// that stretch of the profile is behind the camera.
Offset? loftSeamScreenPosition(List<Offset?> polyline, double fraction) {
  if (polyline.isEmpty) return null;
  final scaled = (fraction % 1.0) * polyline.length;
  final index = scaled.floor() % polyline.length;
  final t = scaled - scaled.floor();
  final a = polyline[index];
  final b = polyline[(index + 1) % polyline.length];
  if (a == null || b == null) return null;
  return Offset.lerp(a, b, t);
}

/// The fraction (0..1, from the profile's default start) of the point on the screen-space closed
/// polyline nearest [screenPoint], for dragging a marker along the profile. Null when no segment
/// is visible.
double? loftSeamFractionForScreenPoint(List<Offset?> polyline, Offset screenPoint) {
  if (polyline.length < 2) return null;
  double? bestFraction;
  var bestDistance = double.infinity;
  for (var i = 0; i < polyline.length; i++) {
    final a = polyline[i];
    final b = polyline[(i + 1) % polyline.length];
    if (a == null || b == null) continue;
    final ab = b - a;
    final lengthSquared = ab.dx * ab.dx + ab.dy * ab.dy;
    final t = lengthSquared < 1e-12
        ? 0.0
        : (((screenPoint - a).dx * ab.dx + (screenPoint - a).dy * ab.dy) / lengthSquared).clamp(0.0, 1.0);
    final distance = (screenPoint - Offset.lerp(a, b, t)!).distance;
    if (distance < bestDistance) {
      bestDistance = distance;
      bestFraction = (i + t) / polyline.length;
    }
  }
  return bestFraction == null ? null : bestFraction % 1.0;
}

/// The draggable start markers of a loft's closed sections, over the 3D view: each section's
/// profile outline, a dot where it starts and an arrow for the direction it runs. Dragging a
/// dot slides it along the profile and reports the new seam fraction through [onSeamChanged],
/// which is what `LoftSection.seam_param` stores.
///
/// A sibling above the viewport's own pointer [Listener] (like `ConstraintOverlay`), so a drag
/// that starts on a dot is claimed here and never orbits the camera; anywhere else falls through.
class LoftSeamOverlay extends StatefulWidget {
  final Camera camera;
  final Size viewportSize;
  final vm.Matrix4? focusTransform;

  /// One entry per loft section; null for a section without a seam.
  final List<LoftSeamHandleDto?> handles;
  final void Function(int sectionIndex, double fraction) onSeamChanged;

  const LoftSeamOverlay({
    super.key,
    required this.camera,
    required this.viewportSize,
    required this.handles,
    required this.onSeamChanged,
    this.focusTransform,
  });

  @override
  State<LoftSeamOverlay> createState() => _LoftSeamOverlayState();
}

class _LoftSeamOverlayState extends State<LoftSeamOverlay> {
  // A marker keeps showing where it was dragged to until fresh handles arrive from the backend.
  final Map<int, double> _dragged = {};

  /// How far from a marker's centre a press still grabs it.
  static const double _grabRadius = 24;

  @override
  void didUpdateWidget(LoftSeamOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.handles, widget.handles)) _dragged.clear();
  }

  double _fractionOf(int index) => _dragged[index] ?? widget.handles[index]?.seamParam ?? 0.0;

  List<Offset?> _polyline(int index) => loftSeamScreenPolyline(
        widget.camera,
        widget.viewportSize,
        widget.focusTransform,
        widget.handles[index]!.points,
      );

  @override
  Widget build(BuildContext context) {
    final children = <Widget>[];
    for (var i = 0; i < widget.handles.length; i++) {
      final handle = widget.handles[i];
      if (handle == null) continue;
      final polyline = _polyline(i);
      final position = loftSeamScreenPosition(polyline, _fractionOf(i));
      children.add(IgnorePointer(
        child: CustomPaint(
          size: widget.viewportSize,
          painter: _SeamPainter(
            polyline: polyline,
            fraction: _fractionOf(i),
            reverse: handle.reverse,
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
      ));
      if (position == null) continue;
      children.add(Positioned(
        left: position.dx - _grabRadius,
        top: position.dy - _grabRadius,
        width: _grabRadius * 2,
        height: _grabRadius * 2,
        child: GestureDetector(
          key: ValueKey('loft-seam-handle-$i'),
          behavior: HitTestBehavior.opaque,
          onPanUpdate: (details) {
            // Project from the pointer's own position in the viewport, not the handle's.
            final box = context.findRenderObject() as RenderBox;
            final local = box.globalToLocal(details.globalPosition);
            final fraction = loftSeamFractionForScreenPoint(_polyline(i), local);
            if (fraction == null) return;
            setState(() => _dragged[i] = fraction);
            widget.onSeamChanged(i, fraction);
          },
          child: const SizedBox.expand(),
        ),
      ));
    }
    return Stack(children: children);
  }
}

class _SeamPainter extends CustomPainter {
  final List<Offset?> polyline;
  final double fraction;
  final bool reverse;
  final Color color;

  _SeamPainter({required this.polyline, required this.fraction, required this.reverse, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final outline = Paint()
      ..color = color.withValues(alpha: 0.55)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    for (var i = 0; i < polyline.length; i++) {
      final a = polyline[i];
      final b = polyline[(i + 1) % polyline.length];
      if (a != null && b != null) canvas.drawLine(a, b, outline);
    }
    final position = loftSeamScreenPosition(polyline, fraction);
    if (position == null) return;
    // An arrow a little way along the direction the section runs from its start.
    final ahead = loftSeamScreenPosition(polyline, fraction + (reverse ? -1 : 1) * 0.03);
    if (ahead != null && (ahead - position).distance > 1) {
      final direction = (ahead - position) / (ahead - position).distance;
      final tip = position + direction * 22;
      final normal = Offset(-direction.dy, direction.dx);
      final arrow = Path()
        ..moveTo(tip.dx, tip.dy)
        ..lineTo((tip - direction * 8 + normal * 5).dx, (tip - direction * 8 + normal * 5).dy)
        ..lineTo((tip - direction * 8 - normal * 5).dx, (tip - direction * 8 - normal * 5).dy)
        ..close();
      canvas.drawLine(position, tip - direction * 6, Paint()..color = color..strokeWidth = 2);
      canvas.drawPath(arrow, Paint()..color = color);
    }
    canvas.drawCircle(position, 9, Paint()..color = Colors.white);
    canvas.drawCircle(position, 7, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_SeamPainter old) =>
      old.polyline != polyline || old.fraction != fraction || old.reverse != reverse || old.color != color;
}
