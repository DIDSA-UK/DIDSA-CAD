import 'package:flutter/material.dart';
import 'package:vector_math/vector_math.dart' as vm;

/// Desktop input D5 (`docs/desktop-input-scope.md` section 4): the view
/// cube the Space key opens - a small cube drawn with the camera's current
/// orientation. A click on a face, an edge or a corner (26 targets) turns the
/// view to look from that side. The geometry here is pure (and unit tested);
/// [showViewCube] is the popup around it.

/// The camera's axes in world space, as the cube is drawn with them: where
/// screen-right, screen-up and "towards the viewer" point.
class ViewCubeBasis {
  const ViewCubeBasis({required this.right, required this.up, required this.back});

  final vm.Vector3 right;
  final vm.Vector3 up;
  final vm.Vector3 back;
}

/// The eye direction and up vector that look at the origin from target
/// [direction] - each component -1, 0 or 1, not all zero (a face, an edge or a
/// corner of the cube). Up is world Y, except for the top and bottom faces
/// (and anything on the Y axis), which keep SOLIDWORKS' Top / Bottom ups.
(vm.Vector3 eye, vm.Vector3 up) viewCubeEyeAndUp(vm.Vector3 direction) {
  final eye = direction.normalized();
  final onYAxis = direction.x == 0 && direction.z == 0;
  final up = !onYAxis ? vm.Vector3(0, 1, 0) : (direction.y > 0 ? vm.Vector3(0, 0, -1) : vm.Vector3(0, 0, 1));
  return (eye, up);
}

/// The SOLIDWORKS name of a cube target: "Front", "Top Right", "Front Top Right".
String viewCubeTargetName(vm.Vector3 d) {
  final parts = <String>[
    if (d.z > 0) 'Front' else if (d.z < 0) 'Back',
    if (d.y > 0) 'Top' else if (d.y < 0) 'Bottom',
    if (d.x > 0) 'Right' else if (d.x < 0) 'Left',
  ];
  return parts.join(' ');
}

/// The cube [-1, 1]^3 drawn orthographically into a square of side [size],
/// seen along [basis]. Pure geometry: projection, which faces show, and which
/// of the 26 targets a point lies on.
class ViewCubeProjection {
  ViewCubeProjection(this.basis, this.size) : _scale = size * 0.28;

  final ViewCubeBasis basis;
  final double size;
  final double _scale;

  /// The six face normals (the cube's faces).
  static final List<vm.Vector3> faceNormals = [
    vm.Vector3(0, 0, 1),
    vm.Vector3(0, 0, -1),
    vm.Vector3(1, 0, 0),
    vm.Vector3(-1, 0, 0),
    vm.Vector3(0, 1, 0),
    vm.Vector3(0, -1, 0),
  ];

  Offset project(vm.Vector3 v) =>
      Offset(size / 2 + v.dot(basis.right) * _scale, size / 2 - v.dot(basis.up) * _scale);

  /// Whether the face with [normal] turns towards the viewer.
  bool faceVisible(vm.Vector3 normal) => normal.dot(basis.back) > 1e-6;

  /// The two in-face axes of a face, as unit world vectors (u, v).
  (vm.Vector3, vm.Vector3) _faceAxes(vm.Vector3 normal) {
    if (normal.x != 0) return (vm.Vector3(0, 0, 1), vm.Vector3(0, 1, 0));
    if (normal.y != 0) return (vm.Vector3(1, 0, 0), vm.Vector3(0, 0, 1));
    return (vm.Vector3(1, 0, 0), vm.Vector3(0, 1, 0));
  }

  /// The four corners of the face with [normal], projected.
  List<Offset> faceQuad(vm.Vector3 normal) {
    final (u, v) = _faceAxes(normal);
    return [
      for (final (a, b) in const [(-1, -1), (1, -1), (1, 1), (-1, 1)]) project(normal + u * a.toDouble() + v * b.toDouble()),
    ];
  }

  /// The quad of one third-by-third cell of a face ([cellU], [cellV] each
  /// -1, 0 or 1), projected - what a click on it selects.
  List<Offset> cellQuad(vm.Vector3 normal, int cellU, int cellV) {
    final (u, v) = _faceAxes(normal);
    double lo(int c) => c * 2 / 3 - 1 / 3;
    double hi(int c) => c * 2 / 3 + 1 / 3;
    return [
      for (final (a, b) in [(lo(cellU), lo(cellV)), (hi(cellU), lo(cellV)), (hi(cellU), hi(cellV)), (lo(cellU), hi(cellV))])
        project(normal + u * a + v * b),
    ];
  }

  /// The target ([ViewCubeTarget] direction) under [point], or null off the
  /// cube. Each visible face is a 3 x 3 grid: the middle cell is the face,
  /// an edge cell the edge it touches, a corner cell the corner.
  vm.Vector3? targetAt(Offset point) {
    for (final normal in faceNormals) {
      if (!faceVisible(normal)) continue;
      final (u, v) = _faceAxes(normal);
      // Solve point = project(normal + a*u + b*v) for (a, b): a 2x2 linear system.
      final origin = project(normal);
      final du = project(normal + u) - origin;
      final dv = project(normal + v) - origin;
      final det = du.dx * dv.dy - du.dy * dv.dx;
      if (det.abs() < 1e-9) continue;
      final p = point - origin;
      final a = (p.dx * dv.dy - p.dy * dv.dx) / det;
      final b = (du.dx * p.dy - du.dy * p.dx) / det;
      if (a < -1 || a > 1 || b < -1 || b > 1) continue;
      int cell(double t) => t < -1 / 3 ? -1 : (t > 1 / 3 ? 1 : 0);
      return normal + u * cell(a).toDouble() + v * cell(b).toDouble();
    }
    return null;
  }

  /// The cell polygon for [target] on the visible face it lies on (the one
  /// that faces the viewer most), for the hover highlight.
  List<Offset>? cellOf(vm.Vector3 target) {
    vm.Vector3? best;
    var bestDot = 0.0;
    for (final normal in faceNormals) {
      if (!faceVisible(normal)) continue;
      // The target lies on this face when it has the face's coordinate.
      final onFace = (normal.x != 0 && target.x == normal.x) ||
          (normal.y != 0 && target.y == normal.y) ||
          (normal.z != 0 && target.z == normal.z);
      if (!onFace) continue;
      final d = normal.dot(basis.back);
      if (d > bestDot) {
        bestDot = d;
        best = normal;
      }
    }
    if (best == null) return null;
    final (u, v) = _faceAxes(best);
    return cellQuad(best, target.dot(u).round(), target.dot(v).round());
  }
}

/// The popup: the cube drawn at [basis], with a Normal To button.
/// [onPick] gets the chosen target direction; [onNormalTo] is null when no
/// flat face or plane is selected (the button is disabled then).
Future<void> showViewCube(
  BuildContext context, {
  required Offset anchor,
  required ViewCubeBasis basis,
  required ValueChanged<vm.Vector3> onPick,
  VoidCallback? onNormalTo,
}) {
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Close the view cube',
    barrierColor: Colors.transparent,
    transitionDuration: const Duration(milliseconds: 80),
    pageBuilder: (dialogContext, _, __) {
      return CustomSingleChildLayout(
        delegate: _AnchoredLayout(anchor),
        child: Material(
          elevation: 8,
          borderRadius: BorderRadius.circular(12),
          child: _ViewCubePanel(
            basis: basis,
            onPick: (target) {
              Navigator.of(dialogContext).pop();
              onPick(target);
            },
            onNormalTo: onNormalTo == null
                ? null
                : () {
                    Navigator.of(dialogContext).pop();
                    onNormalTo();
                  },
          ),
        ),
      );
    },
  );
}

/// Puts the panel's top-left corner at the anchor, moved back inside the screen if it would overhang.
class _AnchoredLayout extends SingleChildLayoutDelegate {
  _AnchoredLayout(this.anchor);

  final Offset anchor;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) => constraints.loosen();

  @override
  Offset getPositionForChild(Size size, Size childSize) => Offset(
        anchor.dx.clamp(8.0, (size.width - childSize.width - 8).clamp(8.0, double.infinity)),
        anchor.dy.clamp(8.0, (size.height - childSize.height - 8).clamp(8.0, double.infinity)),
      );

  @override
  bool shouldRelayout(_AnchoredLayout oldDelegate) => oldDelegate.anchor != anchor;
}

class _ViewCubePanel extends StatefulWidget {
  const _ViewCubePanel({required this.basis, required this.onPick, required this.onNormalTo});

  final ViewCubeBasis basis;
  final ValueChanged<vm.Vector3> onPick;
  final VoidCallback? onNormalTo;

  @override
  State<_ViewCubePanel> createState() => _ViewCubePanelState();
}

class _ViewCubePanelState extends State<_ViewCubePanel> {
  static const double _side = 200;
  vm.Vector3? _hovered;

  @override
  Widget build(BuildContext context) {
    final projection = ViewCubeProjection(widget.basis, _side);
    final hovered = _hovered;
    return Padding(
      padding: const EdgeInsets.all(8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          MouseRegion(
            cursor: hovered == null ? SystemMouseCursors.basic : SystemMouseCursors.click,
            onHover: (event) => setState(() => _hovered = projection.targetAt(event.localPosition)),
            onExit: (_) => setState(() => _hovered = null),
            child: GestureDetector(
              key: const Key('view-cube'),
              behavior: HitTestBehavior.opaque,
              onTapUp: (details) {
                final target = projection.targetAt(details.localPosition);
                if (target != null) widget.onPick(target);
              },
              child: SizedBox(
                width: _side,
                height: _side,
                child: CustomPaint(
                  painter: _ViewCubePainter(
                    projection: projection,
                    hovered: hovered,
                    faceColour: Theme.of(context).colorScheme.surfaceContainerHighest,
                    lineColour: Theme.of(context).colorScheme.outline,
                    highlightColour: Theme.of(context).colorScheme.primary,
                    textStyle: Theme.of(context).textTheme.labelMedium ?? const TextStyle(fontSize: 12),
                  ),
                ),
              ),
            ),
          ),
          SizedBox(
            height: 20,
            child: Text(hovered == null ? '' : viewCubeTargetName(hovered), style: Theme.of(context).textTheme.labelMedium),
          ),
          TextButton.icon(
            onPressed: widget.onNormalTo,
            icon: const Icon(Icons.crop_free, size: 18),
            label: const Text('Normal To'),
          ),
        ],
      ),
    );
  }
}

class _ViewCubePainter extends CustomPainter {
  _ViewCubePainter({
    required this.projection,
    required this.hovered,
    required this.faceColour,
    required this.lineColour,
    required this.highlightColour,
    required this.textStyle,
  });

  final ViewCubeProjection projection;
  final vm.Vector3? hovered;
  final Color faceColour;
  final Color lineColour;
  final Color highlightColour;
  final TextStyle textStyle;

  static const _names = {
    (0, 0, 1): 'Front',
    (0, 0, -1): 'Back',
    (1, 0, 0): 'Right',
    (-1, 0, 0): 'Left',
    (0, 1, 0): 'Top',
    (0, -1, 0): 'Bottom',
  };

  @override
  void paint(Canvas canvas, Size size) {
    final fill = Paint()..color = faceColour;
    final line = Paint()
      ..color = lineColour
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    for (final normal in ViewCubeProjection.faceNormals) {
      if (!projection.faceVisible(normal)) continue;
      final quad = projection.faceQuad(normal);
      final path = Path()..addPolygon(quad, true);
      canvas.drawPath(path, fill);
      canvas.drawPath(path, line);
      final centre = projection.project(normal);
      final painter = TextPainter(
        text: TextSpan(text: _names[(normal.x.round(), normal.y.round(), normal.z.round())], style: textStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      painter.paint(canvas, centre - Offset(painter.width / 2, painter.height / 2));
    }
    final target = hovered;
    final cell = target == null ? null : projection.cellOf(target);
    if (cell != null) {
      canvas.drawPath(Path()..addPolygon(cell, true), Paint()..color = highlightColour.withValues(alpha: 0.45));
    }
  }

  @override
  bool shouldRepaint(_ViewCubePainter old) =>
      old.projection.basis != projection.basis || old.hovered != hovered || old.faceColour != faceColour;
}
