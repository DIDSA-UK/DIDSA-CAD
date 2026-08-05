import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../api/document_api_client.dart';

/// `docs/gear-design/08-entry-screen-and-preview.md`'s "Chain/planetary/
/// bevel-pair preview" extension - the multi-gear counterpart to
/// [GearPreviewCanvas]. Draws every [GearPreviewMemberDto]'s own
/// `outlinePoints` polygon directly (already positioned/rotated by the
/// backend into the chain/assembly's shared 2D frame - `00-conventions.md`'s
/// "don't duplicate the math client-side" point, same as the single-gear
/// canvas), tinted by [GearPreviewMemberDto.displayColor] when set
/// (`GearGroup` colour-coding - a no-op for v1's single-implicit-group
/// chains, real once a compound/multi-group chain exists) or a role-based
/// fallback colour for planetary's fixed sun/ring/planet roles. Any member
/// named in [interferenceFindings] is drawn in red (overlap) or amber
/// (clearance) instead, directly on the offending gears.
class GearChainPreviewCanvas extends StatefulWidget {
  final List<GearPreviewMemberDto> members;
  final List<GearPreviewInterferenceFindingDto> interferenceFindings;

  const GearChainPreviewCanvas({super.key, required this.members, required this.interferenceFindings});

  @override
  State<GearChainPreviewCanvas> createState() => _GearChainPreviewCanvasState();
}

class _GearChainPreviewCanvasState extends State<GearChainPreviewCanvas> {
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
                    painter: _GearChainPreviewPainter(
                      members: widget.members,
                      interferenceFindings: widget.interferenceFindings,
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
const double _highlightStrokeWidth = 2.2;

/// A default per-role/per-stage palette, cycling when a chain has more
/// stages than colours - only ever used when the member has no explicit
/// `displayColor` from its own `GearGroup` (planetary members never carry
/// one, since `GearGroup` doesn't apply there - `05-gear-chain-and-
/// planetary.md`).
const List<Color> _defaultPalette = [
  Colors.lightBlueAccent,
  Colors.lightGreenAccent,
  Colors.orangeAccent,
  Colors.purpleAccent,
  Colors.pinkAccent,
  Colors.tealAccent,
];

class _GearChainPreviewPainter extends CustomPainter {
  final List<GearPreviewMemberDto> members;
  final List<GearPreviewInterferenceFindingDto> interferenceFindings;
  final double zoomScale;

  _GearChainPreviewPainter({required this.members, required this.interferenceFindings, required this.zoomScale});

  Color _colorFor(GearPreviewMemberDto member, int index) {
    if (member.label == 'sun') return Colors.lightBlueAccent;
    if (member.label == 'ring') return Colors.orangeAccent;
    if (member.displayColor != null) {
      final hex = member.displayColor!.replaceFirst('#', '');
      final value = int.tryParse(hex.length == 6 ? 'FF$hex' : hex, radix: 16);
      if (value != null) return Color(value);
    }
    return _defaultPalette[index % _defaultPalette.length];
  }

  /// `overlap` findings win over `clearance` ones when a member appears in
  /// both (a genuine collision is worse than a near-miss) - null when the
  /// member isn't named in any finding at all.
  String? _findingKindFor(GearPreviewMemberDto member) {
    String? kind;
    for (final finding in interferenceFindings) {
      final matchesA = finding.stageIndexA == member.stageIndex && finding.memberLabelA == member.label;
      final matchesB = finding.stageIndexB == member.stageIndex && finding.memberLabelB == member.label;
      if (matchesA || matchesB) {
        if (finding.kind == 'overlap') return 'overlap';
        kind = finding.kind;
      }
    }
    return kind;
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (members.isEmpty) return;

    double maxExtent = 1.0;
    for (final member in members) {
      for (final point in member.outlinePoints) {
        maxExtent = math.max(maxExtent, math.max(point[0].abs(), point[1].abs()));
      }
    }

    final scale = (math.min(size.width, size.height) / 2) * 0.85 / maxExtent;
    final center = Offset(size.width / 2, size.height / 2);
    // Flip y: gear_math's +y is "up", Canvas's +y is "down".
    Offset toCanvas(double x, double y) => center + Offset(x * scale, -y * scale);

    for (var i = 0; i < members.length; i++) {
      final member = members[i];
      if (member.outlinePoints.isEmpty) continue;
      final findingKind = _findingKindFor(member);
      final color = findingKind == 'overlap'
          ? Colors.redAccent
          : findingKind == 'clearance'
              ? Colors.amber
              : _colorFor(member, i);
      final strokeWidth = (findingKind != null ? _highlightStrokeWidth : _outlineStrokeWidth) / zoomScale;
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..color = color;

      final path = Path();
      final first = toCanvas(member.outlinePoints.first[0], member.outlinePoints.first[1]);
      path.moveTo(first.dx, first.dy);
      for (final point in member.outlinePoints.skip(1)) {
        final canvasPoint = toCanvas(point[0], point[1]);
        path.lineTo(canvasPoint.dx, canvasPoint.dy);
      }
      path.close();
      canvas.drawPath(path, paint);

      // A small centre-cross marker per member - makes each gear's own
      // pitch/rotation centre legible at a glance, especially once several
      // members overlap visually near the origin (e.g. a planetary set).
      final centerPoint = toCanvas(member.center[0], member.center[1]);
      final crossPaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.6 / zoomScale
        ..color = color.withValues(alpha: 0.6);
      final crossSize = 3.0;
      canvas.drawLine(
        centerPoint - Offset(crossSize, 0),
        centerPoint + Offset(crossSize, 0),
        crossPaint,
      );
      canvas.drawLine(
        centerPoint - Offset(0, crossSize),
        centerPoint + Offset(0, crossSize),
        crossPaint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _GearChainPreviewPainter oldDelegate) =>
      oldDelegate.members != members ||
      oldDelegate.interferenceFindings != interferenceFindings ||
      oldDelegate.zoomScale != zoomScale;
}
