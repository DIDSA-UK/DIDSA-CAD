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
bool isLaidOutDimension(ConstraintDto c) => c is ArcLengthConstraintDto;

/// Whether [c]'s value is an angle (degrees) rather than a length.
bool isAngularDimension(ConstraintDto c) => false;

/// [c]'s stored value (the dimension the user asked for).
double? storedDimensionValue(ConstraintDto c) => switch (c) {
      ArcLengthConstraintDto d => d.length,
      _ => null,
    };

/// The label text for [c] with [value] (its stored value by default): the number with the type's own mark.
String dimensionLabelText(ConstraintDto c, {double? value, int decimals = 2}) {
  final v = value ?? storedDimensionValue(c) ?? 0.0;
  final number = v.abs().toStringAsFixed(isAngularDimension(c) ? 1 : decimals);
  return switch (c) {
    ArcLengthConstraintDto() => '⌒$number',
    _ => number,
  };
}

/// The preview's label for [c] (no value yet).
String dimensionPreviewText(ConstraintDto c) => switch (c) {
      ArcLengthConstraintDto() => '⌒?',
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
      _ => c,
    };

/// Two dimensions of the same type on the same things (an edit of one, not a second one); ignores the id and the value.
bool sameDimensionTarget(ConstraintDto a, ConstraintDto b) => switch ((a, b)) {
      (ArcLengthConstraintDto x, ArcLengthConstraintDto y) => x.arcId == y.arcId,
      _ => false,
    };

/// The `POST .../constraints` body that makes [c] with [value].
Map<String, Object?> dimensionCreateJson(ConstraintDto c, double value) => switch (c) {
      ArcLengthConstraintDto d => {'type': 'arc_length', 'arc_id': d.arcId, 'length': value},
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
    default:
      return null;
  }
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
    default:
      return null;
  }
}
