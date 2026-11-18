// The dimension types of bug report 2026-11-18 part D (arc length, angle to horizontal, three-point angle, minimum / maximum and
// tangent distances to circles), written once for the controller, the flat canvas, the 3D overlay and the label drag.
//
// Pure Dart, this project's own code: written from the geometry in docs/bug-report-2026-11-18-plan.md and the HTTP shapes the backend
// returns, not from the backend or SolveSpace (LICENSING.md, rule 1). Everything is in sketch units: a view projects the layout with its
// own camera, so the flat canvas and the 3D view draw the same dimension.
//
// What each type gives:
//   * [measureDimension]: its value on the current Points (what a preview shows and the editor pre-fills);
//   * [dimensionPlacementAt]: the label placement for a pointer (the label drag and the click-to-drop preview);
//   * [dimensionLayout]: the dimension's lines, arcs, arrows and label centre for a placement (both painters);
//   * [dimensionCreateJson]: the POST body that makes it.
import 'dart:math' as math;

import '../api/dimension_label_placement.dart';
import '../api/sketch_api_client.dart';

typedef XY = (double, double);

/// Where a Sketch Point is now; null for one not loaded.
typedef PointAt = XY? Function(String pointId);

/// The dimension types this file draws and lays out.
bool isLaidOutDimension(ConstraintDto c) =>
    c is ArcLengthConstraintDto ||
    c is HorizontalAngleConstraintDto ||
    c is PointAngleConstraintDto ||
    c is PointCircleDistanceConstraintDto ||
    c is CircleCircleDistanceConstraintDto ||
    c is LineCircleDistanceConstraintDto;

/// Whether [c]'s value is an angle (degrees) rather than a length.
bool isAngularDimension(ConstraintDto c) => c is HorizontalAngleConstraintDto || c is PointAngleConstraintDto;

/// [c]'s stored value (the dimension the user asked for).
double? storedDimensionValue(ConstraintDto c) => switch (c) {
      ArcLengthConstraintDto d => d.length,
      HorizontalAngleConstraintDto d => d.angleDegrees,
      PointAngleConstraintDto d => d.angleDegrees,
      PointCircleDistanceConstraintDto d => d.distance,
      CircleCircleDistanceConstraintDto d => d.distance,
      LineCircleDistanceConstraintDto d => d.distance,
      _ => null,
    };

/// The label text for [c] with [value] (its stored value by default): the number with the type's own mark.
String dimensionLabelText(ConstraintDto c, {double? value, int decimals = 2}) {
  final v = value ?? storedDimensionValue(c) ?? 0.0;
  final number = v.abs().toStringAsFixed(isAngularDimension(c) ? 1 : decimals);
  return switch (c) {
    ArcLengthConstraintDto() => '⌒$number',
    HorizontalAngleConstraintDto() || PointAngleConstraintDto() => '$number°',
    _ => number,
  };
}

/// The preview's label for [c] (no value yet).
String dimensionPreviewText(ConstraintDto c) => switch (c) {
      ArcLengthConstraintDto() => '⌒?',
      HorizontalAngleConstraintDto() || PointAngleConstraintDto() => '?°',
      _ => '?',
    };

/// [c] with its value replaced by [value] (a preview built from a template, an edited value).
ConstraintDto dimensionWithValue(ConstraintDto c, double value) => switch (c) {
      ArcLengthConstraintDto d => ArcLengthConstraintDto(
          id: d.id,
          label: d.label,
          arcId: d.arcId,
          centerPointId: d.centerPointId,
          startPointId: d.startPointId,
          endPointId: d.endPointId,
          length: value,
        ),
      HorizontalAngleConstraintDto d => _horizontalAngle(d, value: value),
      PointAngleConstraintDto d => _pointAngle(d, value: value),
      PointCircleDistanceConstraintDto d => PointCircleDistanceConstraintDto(
          id: d.id,
          label: d.label,
          pointId: d.pointId,
          circleOrArcId: d.circleOrArcId,
          centerPointId: d.centerPointId,
          radiusPointId: d.radiusPointId,
          distance: value,
          side: d.side,
        ),
      CircleCircleDistanceConstraintDto d => CircleCircleDistanceConstraintDto(
          id: d.id,
          label: d.label,
          entity1Id: d.entity1Id,
          center1PointId: d.center1PointId,
          radius1PointId: d.radius1PointId,
          entity2Id: d.entity2Id,
          center2PointId: d.center2PointId,
          radius2PointId: d.radius2PointId,
          distance: value,
          side: d.side,
        ),
      LineCircleDistanceConstraintDto d => LineCircleDistanceConstraintDto(
          id: d.id,
          label: d.label,
          lineId: d.lineId,
          lineStartId: d.lineStartId,
          lineEndId: d.lineEndId,
          circleOrArcId: d.circleOrArcId,
          centerPointId: d.centerPointId,
          radiusPointId: d.radiusPointId,
          distance: value,
          side: d.side,
        ),
      _ => c,
    };

PointAngleConstraintDto _pointAngle(PointAngleConstraintDto d, {double? value, int? quadrant}) => PointAngleConstraintDto(
      id: d.id,
      label: d.label,
      vertexPointId: d.vertexPointId,
      point1Id: d.point1Id,
      point2Id: d.point2Id,
      angleDegrees: value ?? d.angleDegrees,
      quadrant: quadrant ?? d.quadrant,
    );

HorizontalAngleConstraintDto _horizontalAngle(HorizontalAngleConstraintDto d, {double? value, int? quadrant}) =>
    HorizontalAngleConstraintDto(
      id: d.id,
      label: d.label,
      lineId: d.lineId,
      lineStartId: d.lineStartId,
      lineEndId: d.lineEndId,
      angleDegrees: value ?? d.angleDegrees,
      quadrant: quadrant ?? d.quadrant,
    );

/// Which of the angles of [c] the user means is the one the pointer [p] is in (a preview follows it): the angle to horizontal is drawn
/// at the end of the line nearer the pointer, towards the side of the vertical through that end the pointer is on. [c] unchanged for
/// a type with no such choice.
ConstraintDto dimensionFollowingPointer(ConstraintDto c, PointAt at, XY p) {
  switch (c) {
    case HorizontalAngleConstraintDto d:
      final start = at(d.lineStartId), end = at(d.lineEndId);
      if (start == null || end == null) return c;
      final atEnd = _len(_sub(p, end)) < _len(_sub(p, start));
      final vertex = atEnd ? end : start;
      return _horizontalAngle(d, quadrant: (atEnd ? 1 : 0) | (p.$1 < vertex.$1 ? 2 : 0));
    case PointAngleConstraintDto d:
      // The sector the pointer is in: write its direction from the vertex as a r1 + b r2 over the two rays; a negative a flips ray 1,
      // a negative b ray 2.
      final v = at(d.vertexPointId), p1 = at(d.point1Id), p2 = at(d.point2Id);
      if (v == null || p1 == null || p2 == null) return c;
      final r1 = _sub(p1, v), r2 = _sub(p2, v), w = _sub(p, v);
      final det = r1.$1 * r2.$2 - r1.$2 * r2.$1;
      if (det.abs() < 1e-12 * (_len(r1) * _len(r2) + 1e-300) || _len(w) < 1e-12) return c;
      final a = (w.$1 * r2.$2 - w.$2 * r2.$1) / det;
      final b = (r1.$1 * w.$2 - r1.$2 * w.$1) / det;
      return _pointAngle(d, quadrant: (a < 0 ? 1 : 0) | (b < 0 ? 2 : 0));
    default:
      return c;
  }
}

/// [c]'s quadrant (which of the angles it is), for a value update; null for a type without one.
int? dimensionQuadrant(ConstraintDto c) => switch (c) {
      HorizontalAngleConstraintDto d => d.quadrant,
      PointAngleConstraintDto d => d.quadrant,
      _ => null,
    };

/// Two dimensions of the same type on the same things (an edit of one, not a second one); ignores the id and the value.
bool sameDimensionTarget(ConstraintDto a, ConstraintDto b) => switch ((a, b)) {
      (ArcLengthConstraintDto x, ArcLengthConstraintDto y) => x.arcId == y.arcId,
      (HorizontalAngleConstraintDto x, HorizontalAngleConstraintDto y) => x.lineId == y.lineId,
      (PointCircleDistanceConstraintDto x, PointCircleDistanceConstraintDto y) =>
        x.pointId == y.pointId && x.circleOrArcId == y.circleOrArcId && x.side == y.side,
      (CircleCircleDistanceConstraintDto x, CircleCircleDistanceConstraintDto y) =>
        x.side == y.side && {x.entity1Id, x.entity2Id}.containsAll({y.entity1Id, y.entity2Id}),
      (LineCircleDistanceConstraintDto x, LineCircleDistanceConstraintDto y) =>
        x.lineId == y.lineId && x.circleOrArcId == y.circleOrArcId && x.side == y.side,
      (PointAngleConstraintDto x, PointAngleConstraintDto y) =>
        x.vertexPointId == y.vertexPointId && {x.point1Id, x.point2Id}.containsAll({y.point1Id, y.point2Id}),
      _ => false,
    };

/// The `POST .../constraints` body that makes [c] with [value].
Map<String, Object?> dimensionCreateJson(ConstraintDto c, double value) => switch (c) {
      ArcLengthConstraintDto d => {'type': 'arc_length', 'arc_id': d.arcId, 'length': value},
      HorizontalAngleConstraintDto d => {
          'type': 'horizontal_angle',
          'line_id': d.lineId,
          'angle_degrees': value,
          if (d.quadrant != null) 'quadrant': d.quadrant,
        },
      PointCircleDistanceConstraintDto d => {
          'type': 'point_circle_distance',
          'point_id': d.pointId,
          'circle_or_arc_id': d.circleOrArcId,
          'distance': value,
          'side': d.side,
        },
      CircleCircleDistanceConstraintDto d => {
          'type': 'circle_distance',
          'entity1_id': d.entity1Id,
          'entity2_id': d.entity2Id,
          'distance': value,
          'side': d.side,
        },
      LineCircleDistanceConstraintDto d => {
          'type': 'line_circle_distance',
          'line_id': d.lineId,
          'circle_or_arc_id': d.circleOrArcId,
          'distance': value,
          'side': d.side,
        },
      PointAngleConstraintDto d => {
          'type': 'point_angle',
          'vertex_point_id': d.vertexPointId,
          'point1_id': d.point1Id,
          'point2_id': d.point2Id,
          'angle_degrees': value,
          if (d.quadrant != null) 'quadrant': d.quadrant,
        },
      _ => throw ArgumentError('Not a laid-out dimension: $c'),
    };

// ---- geometry --------------------------------------------------------------------------------------------------------

XY _sub(XY a, XY b) => (a.$1 - b.$1, a.$2 - b.$2);
double _len(XY a) => math.sqrt(a.$1 * a.$1 + a.$2 * a.$2);
XY _polar(XY c, double r, double angle) => (c.$1 + r * math.cos(angle), c.$2 + r * math.sin(angle));
double _wrapPi(double a) {
  var d = a;
  while (d > math.pi) {
    d -= 2 * math.pi;
  }
  while (d <= -math.pi) {
    d += 2 * math.pi;
  }
  return d;
}

/// The counter-clockwise angle from [start] to [end] about [center], in (0, 2 pi] (a sketch Arc's sweep).
double ccwSweep(XY center, XY start, XY end) {
  final a0 = math.atan2(start.$2 - center.$2, start.$1 - center.$1);
  final a1 = math.atan2(end.$2 - center.$2, end.$1 - center.$1);
  var sweep = (a1 - a0) % (2 * math.pi);
  if (sweep <= 1e-12) sweep = 2 * math.pi;
  return sweep;
}

/// Points along the circle about [c] of radius [r] from angle [a0] through [sweep] (signed), for drawing an arc as a polyline (which
/// a perspective view projects point by point).
List<XY> _arcPolyline(XY c, double r, double a0, double sweep) {
  final n = math.max(2, (sweep.abs() / 0.06).ceil());
  return [for (var i = 0; i <= n; i++) _polar(c, r, a0 + sweep * i / n)];
}

/// Value of [c] on the current Points; null when something it stands on is missing or the geometry has no such value.
double? measureDimension(ConstraintDto c, PointAt at) {
  switch (c) {
    case ArcLengthConstraintDto d:
      final center = at(d.centerPointId), start = at(d.startPointId), end = at(d.endPointId);
      if (center == null || start == null || end == null) return null;
      return _len(_sub(start, center)) * ccwSweep(center, start, end);
    case HorizontalAngleConstraintDto d:
      final rays = _horizontalAngleRays(d, at);
      return rays == null ? null : _angleBetween(rays.ray1, rays.ray2);
    case PointAngleConstraintDto d:
      final rays = _pointAngleRays(d, at);
      return rays == null ? null : _angleBetween(rays.ray1, rays.ray2);
    case PointCircleDistanceConstraintDto d:
      final ends = _measuredEnds(d, at);
      return ends == null ? null : _len(_sub(ends.$2, ends.$1));
    case CircleCircleDistanceConstraintDto d:
      // Signed for the gap: negative where the circles overlap (there is no gap then).
      final c1 = at(d.center1PointId), r1 = at(d.radius1PointId), c2 = at(d.center2PointId), r2 = at(d.radius2PointId);
      if (c1 == null || r1 == null || c2 == null || r2 == null) return null;
      final gap = _len(_sub(c2, c1));
      if (gap < 1e-12) return null;
      final radii = _len(_sub(r1, c1)) + _len(_sub(r2, c2));
      return d.side == 'min' ? gap - radii : gap + radii;
    case LineCircleDistanceConstraintDto d:
      // Signed for the tangent side: negative where the line cuts the circle.
      final s = at(d.lineStartId), e = at(d.lineEndId), center = at(d.centerPointId), rim = at(d.radiusPointId);
      if (s == null || e == null || center == null || rim == null) return null;
      final along = _sub(e, s);
      final length = _len(along);
      if (length < 1e-12) return null;
      final off = ((center.$1 - s.$1) * along.$2 - (center.$2 - s.$2) * along.$1).abs() / length;
      final r = _len(_sub(rim, center));
      return d.side == 'min' ? off - r : off + r;
    default:
      return null;
  }
}

double _angleBetween(XY u, XY v) {
  final cosine = ((u.$1 * v.$1 + u.$2 * v.$2) / (_len(u) * _len(v))).clamp(-1.0, 1.0);
  return math.acos(cosine) * 180 / math.pi;
}

/// An angle dimension's vertex and its two rays (unit), with how long the measured geometry runs along each ray from the vertex (0: no
/// geometry there, so the dimension draws its own reference line).
typedef _AngleRays = ({XY vertex, XY ray1, XY ray2, double reach1, double reach2});

/// See [HorizontalAngleConstraintDto.quadrant]: ray 1 along the line from the chosen end, ray 2 the horizontal.
_AngleRays? _horizontalAngleRays(HorizontalAngleConstraintDto d, PointAt at) {
  final start = at(d.lineStartId), end = at(d.lineEndId);
  if (start == null || end == null) return null;
  final q = d.quadrant ?? 0;
  final vertex = q & 1 != 0 ? end : start;
  final other = q & 1 != 0 ? start : end;
  final along = _sub(other, vertex);
  final length = _len(along);
  if (length < 1e-9) return null;
  return (
    vertex: vertex,
    ray1: (along.$1 / length, along.$2 / length),
    ray2: (q & 2 != 0 ? -1.0 : 1.0, 0.0),
    reach1: length,
    reach2: 0.0,
  );
}

/// The two points a minimum / maximum distance runs between: the Point, and the nearest ("min") or farthest ("max") point of the
/// circle, on the line through the Point and the centre. Null for the Point on the centre.
(XY, XY)? _measuredEnds(ConstraintDto c, PointAt at) {
  switch (c) {
    case PointCircleDistanceConstraintDto d:
      final p = at(d.pointId), center = at(d.centerPointId), rim = at(d.radiusPointId);
      if (p == null || center == null || rim == null) return null;
      final toPoint = _sub(p, center);
      final dist = _len(toPoint);
      if (dist < 1e-12) return null;
      final r = _len(_sub(rim, center)) * (d.side == 'min' ? 1 : -1);
      return (p, (center.$1 + toPoint.$1 / dist * r, center.$2 + toPoint.$2 / dist * r));
    case CircleCircleDistanceConstraintDto d:
      // Each circle's point on the centre line: facing the other circle for the gap, facing away for the overall size.
      final c1 = at(d.center1PointId), r1 = at(d.radius1PointId), c2 = at(d.center2PointId), r2 = at(d.radius2PointId);
      if (c1 == null || r1 == null || c2 == null || r2 == null) return null;
      final along = _sub(c2, c1);
      final gap = _len(along);
      if (gap < 1e-12) return null;
      final u = (along.$1 / gap, along.$2 / gap);
      final s = d.side == 'min' ? 1.0 : -1.0;
      final a1 = _len(_sub(r1, c1)) * s, a2 = _len(_sub(r2, c2)) * s;
      return ((c1.$1 + u.$1 * a1, c1.$2 + u.$2 * a1), (c2.$1 - u.$1 * a2, c2.$2 - u.$2 * a2));
    case LineCircleDistanceConstraintDto d:
      // From the foot of the centre on the line to the circle's point square to the line: towards the line for the tangent side,
      // away from it for the far side. A centre on the line takes the line's left normal.
      final s = at(d.lineStartId), e = at(d.lineEndId), center = at(d.centerPointId), rim = at(d.radiusPointId);
      if (s == null || e == null || center == null || rim == null) return null;
      final along = _sub(e, s);
      final length = _len(along);
      if (length < 1e-12) return null;
      final t = (along.$1 / length, along.$2 / length);
      final fromStart = _sub(center, s);
      final k = fromStart.$1 * t.$1 + fromStart.$2 * t.$2;
      final foot = (s.$1 + t.$1 * k, s.$2 + t.$2 * k);
      final toFoot = _sub(foot, center);
      final off = _len(toFoot);
      final n = off > 1e-12 ? (toFoot.$1 / off, toFoot.$2 / off) : (-t.$2, t.$1);
      final r = _len(_sub(rim, center)) * (d.side == 'min' ? 1 : -1);
      return (foot, (center.$1 + n.$1 * r, center.$2 + n.$2 * r));
    default:
      return null;
  }
}

/// A linear dimension from [a] to [b]: [DimensionLabelPlacement.offset] how far the dimension line sits to the left of a-to-b,
/// [DimensionLabelPlacement.along] where the label sits along it from its middle (the same meanings as a plain distance's).
DimensionLabelPlacement? _linearPlacementAt(XY a, XY b, XY p) {
  final ab = _sub(b, a);
  final length = _len(ab);
  if (length < 1e-12) return null;
  final t = (ab.$1 / length, ab.$2 / length), n = (-ab.$2 / length, ab.$1 / length);
  final mid = ((a.$1 + b.$1) / 2, (a.$2 + b.$2) / 2);
  final fromA = _sub(p, a), fromMid = _sub(p, mid);
  return DimensionLabelPlacement(
    offset: fromA.$1 * n.$1 + fromA.$2 * n.$2,
    along: fromMid.$1 * t.$1 + fromMid.$2 * t.$2,
  );
}

DimensionLayout? _linearLayout(XY a, XY b, DimensionLabelPlacement? placement) {
  final ab = _sub(b, a);
  final length = _len(ab);
  if (length < 1e-12) return null;
  final t = (ab.$1 / length, ab.$2 / length), n = (-ab.$2 / length, ab.$1 / length);
  final offset = placement?.offset ?? 0.0;
  final along = placement?.along ?? 0.0;
  XY shift(XY p, double s) => (p.$1 + n.$1 * s, p.$2 + n.$2 * s);
  final a2 = shift(a, offset), b2 = shift(b, offset);
  final mid = ((a2.$1 + b2.$1) / 2, (a2.$2 + b2.$2) / 2);
  final label = (mid.$1 + t.$1 * along, mid.$2 + t.$2 * along);
  final strokes = <List<XY>>[
    [a2, b2],
  ];
  // A label slid past either end gets the dimension line carried on to it.
  if (along.abs() > length / 2) strokes.add([along > 0 ? b2 : a2, label]);
  return DimensionLayout(
    strokes: strokes,
    extensions: [
      if (offset.abs() > 1e-12) (a, a2),
      if (offset.abs() > 1e-12) (b, b2),
    ],
    arrows: [(a2, b2), (b2, a2)],
    label: label,
  );
}

/// See [PointAngleConstraintDto.quadrant]: each ray from the vertex towards its Point, or away from it when flipped (then there is no
/// geometry along it and the dimension draws the ray).
_AngleRays? _pointAngleRays(PointAngleConstraintDto d, PointAt at) {
  final v = at(d.vertexPointId), p1 = at(d.point1Id), p2 = at(d.point2Id);
  if (v == null || p1 == null || p2 == null) return null;
  final u1 = _sub(p1, v), u2 = _sub(p2, v);
  final l1 = _len(u1), l2 = _len(u2);
  if (l1 < 1e-9 || l2 < 1e-9) return null;
  final q = d.quadrant ?? 0;
  final s1 = q & 1 != 0 ? -1.0 : 1.0, s2 = q & 2 != 0 ? -1.0 : 1.0;
  return (
    vertex: v,
    ray1: (s1 * u1.$1 / l1, s1 * u1.$2 / l1),
    ray2: (s2 * u2.$1 / l2, s2 * u2.$2 / l2),
    reach1: s1 > 0 ? l1 : 0.0,
    reach2: s2 > 0 ? l2 : 0.0,
  );
}

/// How far from the vertex an angle dimension's arc sits when nobody has placed it: half the shorter measured ray (or of the one there
/// is).
double _defaultAngleRadius(_AngleRays rays) {
  final reaches = [rays.reach1, rays.reach2].where((r) => r > 1e-9);
  return reaches.isEmpty ? 1.0 : reaches.reduce(math.min) * 0.5;
}

/// The counter-clockwise angle of [v].
double _angleOf(XY v) => math.atan2(v.$2, v.$1);

/// The arc of an angle dimension: from ray 1 the short way round to ray 2 (start angle, signed sweep, middle).
({double a1, double sweep, double middle}) _angleArc(_AngleRays rays) {
  final a1 = _angleOf(rays.ray1);
  final sweep = _wrapPi(_angleOf(rays.ray2) - a1);
  return (a1: a1, sweep: sweep, middle: a1 + sweep / 2);
}

/// An angle dimension's placement: [DimensionLabelPlacement.radius] the arc's radius, [DimensionLabelPlacement.angle] the label's
/// position along it, degrees counter-clockwise from the arc's middle.
DimensionLabelPlacement? _anglePlacementAt(_AngleRays rays, XY p) {
  final v = _sub(p, rays.vertex);
  final distance = _len(v);
  if (distance < 1e-9) return null;
  return DimensionLabelPlacement(radius: distance, angle: _wrapPi(_angleOf(v) - _angleArc(rays).middle) * 180 / math.pi);
}

DimensionLayout _angleLayout(_AngleRays rays, DimensionLabelPlacement? placement) {
  final arc = _angleArc(rays);
  final r = placement?.radius ?? _defaultAngleRadius(rays);
  final labelAngle = arc.middle + (placement?.angle ?? 0.0) * math.pi / 180;
  final strokes = <List<XY>>[_arcPolyline(rays.vertex, r, arc.a1, arc.sweep)];
  final beyond = _wrapPi(labelAngle - arc.middle);
  if (beyond.abs() > arc.sweep.abs() / 2) {
    // Carry the arc on to a label placed past either end.
    final half = arc.sweep.abs() / 2 * (beyond > 0 ? 1 : -1);
    strokes.add(_arcPolyline(rays.vertex, r, arc.middle + half, beyond - half));
  }
  final p1 = _polar(rays.vertex, r, arc.a1);
  final p2 = _polar(rays.vertex, r, arc.a1 + arc.sweep);
  final extensions = <(XY, XY)>[];
  void ray(XY dir, double reach, XY onArc) {
    if (reach <= 1e-9) {
      // No geometry along this ray (the horizontal): the dimension draws it, from the vertex to a little past the arc.
      strokes.add([rays.vertex, (rays.vertex.$1 + dir.$1 * r * 1.15, rays.vertex.$2 + dir.$2 * r * 1.15)]);
    } else if (r > reach) {
      extensions.add(((rays.vertex.$1 + dir.$1 * reach, rays.vertex.$2 + dir.$2 * reach), onArc));
    }
  }

  ray(rays.ray1, rays.reach1, p1);
  ray(rays.ray2, rays.reach2, p2);
  final step = math.min(arc.sweep.abs() / 4, 0.2) * (arc.sweep < 0 ? -1 : 1);
  return DimensionLayout(
    strokes: strokes,
    extensions: extensions,
    arrows: [
      (p1, _polar(rays.vertex, r, arc.a1 + step)),
      (p2, _polar(rays.vertex, r, arc.a1 + arc.sweep - step)),
    ],
    label: _polar(rays.vertex, r, labelAngle),
  );
}

/// A dimension laid out in sketch units: what both views draw.
class DimensionLayout {
  /// Dimension lines and arcs, each a polyline.
  final List<List<XY>> strokes;

  /// Extension (witness) lines, from the geometry to the dimension line; a view leaves its usual small gap at the geometry end.
  final List<(XY from, XY to)> extensions;

  /// Arrowheads: the tip, and a point the arrow comes from (its direction is tip minus that point, worked out after projection).
  final List<(XY tip, XY from)> arrows;

  /// The label's centre.
  final XY label;

  const DimensionLayout({required this.strokes, required this.extensions, required this.arrows, required this.label});
}

/// The arc a length is measured on: centre, radius, start angle and (counter-clockwise) sweep.
({XY center, double radius, double a0, double sweep})? _arcOf(ArcLengthConstraintDto d, PointAt at) {
  final center = at(d.centerPointId), start = at(d.startPointId), end = at(d.endPointId);
  if (center == null || start == null || end == null) return null;
  final r = _len(_sub(start, center));
  if (r < 1e-9) return null;
  return (
    center: center,
    radius: r,
    a0: math.atan2(start.$2 - center.$2, start.$1 - center.$1),
    sweep: ccwSweep(center, start, end),
  );
}

/// How far outside the arc its length dimension sits when nobody has placed it: a quarter of the radius.
const double _defaultArcLengthLegFraction = 0.25;

/// The label placement for the pointer at [p]; null when [p] says nothing (on the centre).
///
/// Arc length: [DimensionLabelPlacement.leg] is how far outside the arc the dimension arc runs (negative: inside) and
/// [DimensionLabelPlacement.angle] where along it the label sits, in degrees counter-clockwise from the arc's middle.
DimensionLabelPlacement? dimensionPlacementAt(ConstraintDto c, PointAt at, XY p) {
  switch (c) {
    case ArcLengthConstraintDto d:
      final arc = _arcOf(d, at);
      if (arc == null) return null;
      final v = _sub(p, arc.center);
      final distance = _len(v);
      if (distance < 1e-9) return null;
      final middle = arc.a0 + arc.sweep / 2;
      return DimensionLabelPlacement(
        leg: distance - arc.radius,
        angle: _wrapPi(math.atan2(v.$2, v.$1) - middle) * 180 / math.pi,
      );
    case HorizontalAngleConstraintDto d:
      final rays = _horizontalAngleRays(d, at);
      return rays == null ? null : _anglePlacementAt(rays, p);
    case PointAngleConstraintDto d:
      final rays = _pointAngleRays(d, at);
      return rays == null ? null : _anglePlacementAt(rays, p);
    case PointCircleDistanceConstraintDto() || CircleCircleDistanceConstraintDto() || LineCircleDistanceConstraintDto():
      final ends = _measuredEnds(c, at);
      return ends == null ? null : _linearPlacementAt(ends.$1, ends.$2, p);
    default:
      return null;
  }
}

/// [c] laid out with its label at [placement] (null: the default place).
DimensionLayout? dimensionLayout(ConstraintDto c, PointAt at, DimensionLabelPlacement? placement) {
  switch (c) {
    case ArcLengthConstraintDto d:
      final arc = _arcOf(d, at);
      if (arc == null) return null;
      final leg = placement?.leg ?? arc.radius * _defaultArcLengthLegFraction;
      // A dimension arc through the centre would have no size: keep it at least a tenth of the radius out.
      final r = math.max(arc.radius + leg, arc.radius * 0.1);
      final middle = arc.a0 + arc.sweep / 2;
      final labelAngle = middle + (placement?.angle ?? 0.0) * math.pi / 180;
      final end = arc.a0 + arc.sweep;
      final arcLine = _arcPolyline(arc.center, r, arc.a0, arc.sweep);
      final strokes = <List<XY>>[arcLine];
      // A label placed beyond either end of the dimension arc gets the arc carried on to it (as a linear dimension's line runs on to
      // a label placed past its extension lines).
      final beyond = _wrapPi(labelAngle - middle);
      if (beyond.abs() > arc.sweep / 2) {
        final fromEnd = beyond > 0 ? end : arc.a0;
        final extra = beyond > 0 ? beyond - arc.sweep / 2 : beyond + arc.sweep / 2;
        strokes.add(_arcPolyline(arc.center, r, fromEnd, extra));
      }
      final startOnDim = _polar(arc.center, r, arc.a0);
      final endOnDim = _polar(arc.center, r, end);
      // Arrows point along the dimension arc, away from its inside.
      final step = math.min(arc.sweep / 4, 0.2);
      return DimensionLayout(
        strokes: strokes,
        extensions: [
          if ((r - arc.radius).abs() > 1e-9) (_polar(arc.center, arc.radius, arc.a0), startOnDim),
          if ((r - arc.radius).abs() > 1e-9) (_polar(arc.center, arc.radius, end), endOnDim),
        ],
        arrows: [
          (startOnDim, _polar(arc.center, r, arc.a0 + step)),
          (endOnDim, _polar(arc.center, r, end - step)),
        ],
        label: _polar(arc.center, r, labelAngle),
      );
    case HorizontalAngleConstraintDto d:
      final rays = _horizontalAngleRays(d, at);
      return rays == null ? null : _angleLayout(rays, placement);
    case PointAngleConstraintDto d:
      final rays = _pointAngleRays(d, at);
      return rays == null ? null : _angleLayout(rays, placement);
    case PointCircleDistanceConstraintDto() || CircleCircleDistanceConstraintDto() || LineCircleDistanceConstraintDto():
      final ends = _measuredEnds(c, at);
      return ends == null ? null : _linearLayout(ends.$1, ends.$2, placement);
    default:
      return null;
  }
}
