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

  /// A Bevel Pair's own tooth-mesh close-up (`null` for a standalone Bevel
  /// Gear, which has no mate to mesh against) - drawn as a small "picture
  /// in picture" inset over the main axial-cross-section view, since the
  /// envelope drawn above never shows a single real tooth (`10-bevel-gear.
  /// md`'s own "a bevel tooth has no flat 2D cut profile" point - see
  /// `BevelPairMeshPreviewDto`'s own doc comment for why the mesh preview
  /// needs an entirely separate close-up rather than reusing this same
  /// outline).
  final BevelPairMeshPreviewDto? meshPreview;

  const BevelPreviewCanvas({super.key, required this.members, this.meshPreview});

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
          if (widget.meshPreview != null)
            Positioned(
              right: 8,
              bottom: 8,
              child: _MeshPreviewInset(meshPreview: widget.meshPreview!),
            ),
        ],
      ),
    );
  }
}

/// The "picture in picture" tooth-mesh close-up - a fixed-size bordered box
/// in the main preview's corner, independent of the main view's own
/// pan/zoom (deliberately: this close-up's whole point is to always show
/// tooth shape/backlash at a glance, not to require the user to zoom the
/// main envelope view in to a scale where it would even be visible).
class _MeshPreviewInset extends StatelessWidget {
  final BevelPairMeshPreviewDto meshPreview;

  const _MeshPreviewInset({required this.meshPreview});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 168,
      height: 168,
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A26),
        border: Border.all(color: Colors.white24),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Stack(
        children: [
          Positioned.fill(child: CustomPaint(painter: _MeshPreviewPainter(meshPreview: meshPreview))),
          const Positioned(
            left: 4,
            top: 2,
            child: Text(
              'Tooth mesh',
              style: TextStyle(color: Colors.white54, fontSize: 10),
            ),
          ),
        ],
      ),
    );
  }
}

class _MeshPreviewPainter extends CustomPainter {
  final BevelPairMeshPreviewDto meshPreview;

  _MeshPreviewPainter({required this.meshPreview});

  @override
  void paint(Canvas canvas, Size size) {
    final allTeeth = [...meshPreview.member1Teeth, ...meshPreview.member2Teeth];
    if (allTeeth.isEmpty) return;

    // Fit every displayed tooth's own bounding box, not a hardcoded
    // absolute-mm radius - module (and therefore real tooth size) is a
    // free user parameter, so a fixed radius would over- or under-fill
    // this inset depending on what module the user picked. Mirrors
    // `_BevelPreviewPainter`'s own "measure the real geometry, then
    // scale to fit" approach above, just over points instead of
    // `coneDistance`.
    double minX = double.infinity, maxX = double.negativeInfinity;
    double minY = double.infinity, maxY = double.negativeInfinity;
    for (final tooth in allTeeth) {
      for (final point in tooth) {
        minX = math.min(minX, point[0]);
        maxX = math.max(maxX, point[0]);
        minY = math.min(minY, point[1]);
        maxY = math.max(maxY, point[1]);
      }
    }
    final extentX = math.max(maxX - minX, 1e-6);
    final extentY = math.max(maxY - minY, 1e-6);
    const padding = 10.0;
    final scale = math.min(
      (size.width - 2 * padding) / extentX,
      (size.height - 2 * padding) / extentY,
    );
    final boundsCenter = Offset((minX + maxX) / 2, (minY + maxY) / 2);
    final canvasCenter = Offset(size.width / 2, size.height / 2 + 6);
    // Flip y: gear_math's +y is "up", Canvas's +y is "down".
    Offset toCanvas(double x, double y) =>
        canvasCenter + Offset((x - boundsCenter.dx) * scale, -(y - boundsCenter.dy) * scale);

    void drawTeeth(List<List<List<double>>> teeth, Color color) {
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..color = color;
      final fillPaint = Paint()
        ..style = PaintingStyle.fill
        ..color = color.withValues(alpha: 0.18);
      for (final tooth in teeth) {
        if (tooth.isEmpty) continue;
        final path = Path();
        final first = toCanvas(tooth.first[0], tooth.first[1]);
        path.moveTo(first.dx, first.dy);
        for (final point in tooth.skip(1)) {
          final canvasPoint = toCanvas(point[0], point[1]);
          path.lineTo(canvasPoint.dx, canvasPoint.dy);
        }
        path.close();
        canvas.drawPath(path, fillPaint);
        canvas.drawPath(path, paint);
      }
    }

    drawTeeth(meshPreview.member1Teeth, _roleColors['member_1']!);
    drawTeeth(meshPreview.member2Teeth, _roleColors['member_2']!);

    // The shared pitch point (origin) - the reference the close-up is
    // framed around.
    canvas.drawCircle(toCanvas(0, 0), 1.5, Paint()..color = Colors.white54);
  }

  @override
  bool shouldRepaint(covariant _MeshPreviewPainter oldDelegate) => oldDelegate.meshPreview != meshPreview;
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
