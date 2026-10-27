import 'dart:math' as math;
import 'dart:ui';

/// Desktop input D2 (`docs/desktop-input-scope.md`): geometry for a
/// *crossing* box select (a mouse box dragged right to left, SOLIDWORKS /
/// AutoCAD style) - an entity is picked if any part of it touches the box,
/// not only when it lies wholly inside (the window select, dragged left to
/// right, which [SketchController.selectInRect] already did). Curves are
/// tested as fine polylines, so a curve that only grazes a corner of the box
/// by less than one sample's chord may be missed - a crossing box is a
/// coarse gesture, and the window rules stay exact/conservative as before.

/// Samples per full turn for circles, arcs and ellipses.
const int kCrossingSamplesPerTurn = 96;

/// Samples per cubic Bezier span of a spline.
const int kCrossingSamplesPerSpan = 24;

bool _inside(Offset p, Rect r) => p.dx >= r.left && p.dx <= r.right && p.dy >= r.top && p.dy <= r.bottom;

/// Whether segment [a]-[b] touches [r]: an end inside, or the segment
/// crossing one of the box's four edges.
bool segmentTouchesRect(Offset a, Offset b, Rect r) {
  if (_inside(a, r) || _inside(b, r)) return true;
  // Quick reject: both ends beyond the same side.
  if ((a.dx < r.left && b.dx < r.left) ||
      (a.dx > r.right && b.dx > r.right) ||
      (a.dy < r.top && b.dy < r.top) ||
      (a.dy > r.bottom && b.dy > r.bottom)) {
    return false;
  }
  return _segmentsIntersect(a, b, r.topLeft, r.topRight) ||
      _segmentsIntersect(a, b, r.topRight, r.bottomRight) ||
      _segmentsIntersect(a, b, r.bottomRight, r.bottomLeft) ||
      _segmentsIntersect(a, b, r.bottomLeft, r.topLeft);
}

double _cross(Offset o, Offset a, Offset b) => (a.dx - o.dx) * (b.dy - o.dy) - (a.dy - o.dy) * (b.dx - o.dx);

bool _onSegment(Offset p, Offset a, Offset b) =>
    math.min(a.dx, b.dx) - 1e-12 <= p.dx &&
    p.dx <= math.max(a.dx, b.dx) + 1e-12 &&
    math.min(a.dy, b.dy) - 1e-12 <= p.dy &&
    p.dy <= math.max(a.dy, b.dy) + 1e-12;

bool _segmentsIntersect(Offset p1, Offset p2, Offset q1, Offset q2) {
  final d1 = _cross(q1, q2, p1);
  final d2 = _cross(q1, q2, p2);
  final d3 = _cross(p1, p2, q1);
  final d4 = _cross(p1, p2, q2);
  if (((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0)) && ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0))) return true;
  if (d1 == 0 && _onSegment(p1, q1, q2)) return true;
  if (d2 == 0 && _onSegment(p2, q1, q2)) return true;
  if (d3 == 0 && _onSegment(q1, p1, p2)) return true;
  if (d4 == 0 && _onSegment(q2, p1, p2)) return true;
  return false;
}

/// Whether any segment of [points] touches [r] ([closed] adds the closing
/// segment back to the first point).
bool polylineTouchesRect(List<Offset> points, Rect r, {bool closed = false}) {
  if (points.isEmpty) return false;
  if (points.length == 1) return _inside(points.first, r);
  for (var i = 0; i < points.length - 1; i++) {
    if (segmentTouchesRect(points[i], points[i + 1], r)) return true;
  }
  return closed && segmentTouchesRect(points.last, points.first, r);
}

/// Points along an ellipse centred on [center] with semi-axes [a] (along
/// [rotation], radians from +x) and [b], from parametric angle [start]
/// sweeping [sweep] radians counter-clockwise. A circle is `a == b`; a
/// circular arc's parametric angle is its polar angle.
List<Offset> ellipsePolyline(Offset center, double a, double b, double rotation, double start, double sweep) {
  final steps = math.max(2, (kCrossingSamplesPerTurn * sweep.abs() / (2 * math.pi)).ceil());
  final cosR = math.cos(rotation), sinR = math.sin(rotation);
  return [
    for (var i = 0; i <= steps; i++)
      () {
        final t = start + sweep * i / steps;
        final lx = a * math.cos(t), ly = b * math.sin(t);
        return Offset(center.dx + lx * cosR - ly * sinR, center.dy + lx * sinR + ly * cosR);
      }(),
  ];
}

/// Points along the cubic Bezier [p0] [c1] [c2] [p3].
List<Offset> cubicPolyline(Offset p0, Offset c1, Offset c2, Offset p3) => [
      for (var i = 0; i <= kCrossingSamplesPerSpan; i++)
        () {
          final t = i / kCrossingSamplesPerSpan;
          final u = 1 - t;
          return p0 * (u * u * u) + c1 * (3 * u * u * t) + c2 * (3 * u * t * t) + p3 * (t * t * t);
        }(),
    ];

/// The colour of a crossing box (mouse, right to left), as AutoCAD draws
/// it; a window box stays blue.
const Color kCrossingBoxColor = Color(0xFF43A047);
