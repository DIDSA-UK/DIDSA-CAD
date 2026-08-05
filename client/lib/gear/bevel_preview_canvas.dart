import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../api/document_api_client.dart';

/// `docs/gear-design/10-bevel-gear.md`/`11-bevel-pair.md`'s own preview -
/// draws each [GearPreviewBevelMemberDto]'s axial cross-section envelope
/// (already positioned/rotated by the backend, apex at the origin - `00-
/// conventions.md`'s "don't duplicate the math client-side" point) plus a
/// dashed axis line and a pitch-line reference per member. A single-gear
/// preview draws one member along local +x; a pair preview draws both
/// members meeting at the shared apex, member 2's own axis at the pair's
/// `shaft_angle_degrees` from member 1's - the literal "dual-axis" shape
/// `08-entry-screen-and-preview.md` asks for.
class BevelPreviewCanvas extends StatefulWidget {
  final List<GearPreviewBevelMemberDto> members;

  const BevelPreviewCanvas({super.key, required this.members});

  @override
  State<BevelPreviewCanvas> createState() => _BevelPreviewCanvasState();
}

class _BevelPreviewCanvasState extends State<BevelPreviewCanvas> {
  final TransformationController _transformController = TransformationController();

  @override
  void dispose() {
    _transformController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF12121C),
      child: Stack(
        children: [
          Positioned.fill(
            child: InteractiveViewer(
              transformationController: _transformController,
              minScale: 0.5,
              maxScale: 12,
              boundaryMargin: const EdgeInsets.all(2000),
              child: SizedBox.expand(
                child: AnimatedBuilder(
                  animation: _transformController,
                  builder: (context, child) => CustomPaint(
                    painter: _BevelPreviewPainter(
                      members: widget.members,
                      zoomScale: _transformController.value.getMaxScaleOnAxis(),
                    ),
                    child: child,
                  ),
                  child: widget.members.isEmpty
                      ? const Center(
                          child: Text(
                            'Enter valid parameters to see a preview',
                            style: TextStyle(color: Colors.white38),
                          ),
                        )
                      : null,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

const double _outlineStrokeWidth = 1.1;
const double _referenceStrokeWidth = 0.6;
const double _axisStrokeWidth = 0.5;

const Map<String, Color> _roleColors = {
  'single': Colors.lightBlueAccent,
  'member_1': Colors.lightBlueAccent,
  'member_2': Colors.orangeAccent,
};

class _BevelPreviewPainter extends CustomPainter {
  final List<GearPreviewBevelMemberDto> members;
  final double zoomScale;

  _BevelPreviewPainter({required this.members, required this.zoomScale});

  @override
  void paint(Canvas canvas, Size size) {
    if (members.isEmpty) return;

    double maxExtent = 1.0;
    for (final member in members) {
      maxExtent = math.max(maxExtent, member.coneDistance);
    }
    final scale = (math.min(size.width, size.height) / 2) * 0.85 / maxExtent;
    final center = Offset(size.width / 2, size.height / 2);
    // Flip y: gear_math's +y is "up", Canvas's +y is "down".
    Offset toCanvas(double x, double y) => center + Offset(x * scale, -y * scale);

    for (final member in members) {
      final color = _roleColors[member.label] ?? Colors.lightGreenAccent;

      // Axis line, apex to just past the outer cone distance, dashed via a
      // simple short-segment loop (no dashed-path dependency needed).
      final axisAngle = member.axisAngleDegrees * math.pi / 180;
      final axisEnd = Offset(
        (member.coneDistance * 1.15) * math.cos(axisAngle),
        (member.coneDistance * 1.15) * math.sin(axisAngle),
      );
      final axisPaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = _axisStrokeWidth / zoomScale
        ..color = Colors.white24;
      _drawDashedLine(canvas, toCanvas(0, 0), toCanvas(axisEnd.dx, axisEnd.dy), axisPaint);

      // Pitch line reference.
      final pitchPaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = _referenceStrokeWidth / zoomScale
        ..color = color.withValues(alpha: 0.5);
      final pitchStart = toCanvas(member.pitchLine[0][0], member.pitchLine[0][1]);
      final pitchEnd = toCanvas(member.pitchLine[1][0], member.pitchLine[1][1]);
      canvas.drawLine(pitchStart, pitchEnd, pitchPaint);

      // The envelope outline itself.
      final outlinePaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = _outlineStrokeWidth / zoomScale
        ..color = color;
      final path = Path();
      final first = toCanvas(member.outlinePoints.first[0], member.outlinePoints.first[1]);
      path.moveTo(first.dx, first.dy);
      for (final point in member.outlinePoints.skip(1)) {
        final canvasPoint = toCanvas(point[0], point[1]);
        path.lineTo(canvasPoint.dx, canvasPoint.dy);
      }
      path.close();
      canvas.drawPath(path, outlinePaint);
    }

    // The shared apex, one small marker for every member (always the
    // origin, since both a single gear's and a pair's apexes coincide
    // there - 00-conventions.md/11-bevel-pair.md).
    final apexPaint = Paint()..color = Colors.white70;
    canvas.drawCircle(toCanvas(0, 0), 2.5 / zoomScale, apexPaint);
  }

  void _drawDashedLine(Canvas canvas, Offset start, Offset end, Paint paint) {
    const dashLength = 4.0;
    const gapLength = 3.0;
    final total = (end - start).distance;
    if (total == 0) return;
    final direction = (end - start) / total;
    var covered = 0.0;
    while (covered < total) {
      final segmentEnd = math.min(covered + dashLength, total);
      canvas.drawLine(start + direction * covered, start + direction * segmentEnd, paint);
      covered += dashLength + gapLength;
    }
  }

  @override
  bool shouldRepaint(covariant _BevelPreviewPainter oldDelegate) =>
      oldDelegate.members != members || oldDelegate.zoomScale != zoomScale;
}
