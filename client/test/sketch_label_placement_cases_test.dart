// The golden label placements (docs/sketch-label-placement-cases.json, DIDSA-VR docs/dimension-constraint-parity-plan.md section 3.2):
// for each placement kind, a geometry and three pointers, with the placement the pointer gives (what `PUT .../constraints/{id}/label`
// saves) and the label centre that placement lays out. Both apps test against these numbers; this test holds the flat app's
// LabelDragResolver and dimension_types.dart to them.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

import 'package:didsa_cad_client/api/dimension_label_placement.dart';
import 'package:didsa_cad_client/api/sketch_api_client.dart';
import 'package:didsa_cad_client/sketch/dimension_types.dart';
import 'package:didsa_cad_client/sketch/label_drag_resolver.dart';

const String casesPath = '../docs/sketch-label-placement-cases.json';

typedef Pt = (double, double);

Pt _pt(Object? json) {
  final list = (json as List).cast<num>();
  return (list[0].toDouble(), list[1].toDouble());
}

/// [kind]'s placement for [pointer] on [geometry] (named points as `[x, y]`, plus `value_degrees` / `quadrant` / `side` where the kind
/// has them), and the label centre that placement gives. Null placement: the pointer says nothing (the label keeps its last place).
(DimensionLabelPlacement?, Pt?) placementCase(String kind, Map<String, dynamic> geometry, Pt pointer) {
  Pt g(String name) => _pt(geometry[name]);
  final quadrant = (geometry['quadrant'] as num?)?.toInt();
  final side = geometry['side'] as String?;
  switch (kind) {
    case 'distance_linear' || 'distance_horizontal' || 'distance_vertical':
      final orientation = kind == 'distance_linear' ? null : kind.substring('distance_'.length);
      final placement = LabelDragResolver.linear(a: g('a'), b: g('b'), orientation: orientation, p: pointer);
      return (
        placement,
        placement == null
            ? null
            : LabelDragResolver.linearLabelCenter(a: g('a'), b: g('b'), orientation: orientation, placement: placement),
      );
    case 'point_line_distance':
      // Linear, from the Point to its foot on the line's infinite extension.
      final p = g('point'), s = g('line_start'), e = g('line_end');
      final d = (e.$1 - s.$1, e.$2 - s.$2);
      final t = ((p.$1 - s.$1) * d.$1 + (p.$2 - s.$2) * d.$2) / (d.$1 * d.$1 + d.$2 * d.$2);
      final foot = (s.$1 + d.$1 * t, s.$2 + d.$2 * t);
      final placement = LabelDragResolver.linear(a: p, b: foot, p: pointer);
      return (placement, placement == null ? null : LabelDragResolver.linearLabelCenter(a: p, b: foot, placement: placement));
    case 'ellipse_axis':
      // Linear, from the opposite tip of the axis to the tip the dimension names.
      final placement = LabelDragResolver.linear(a: g('opposite_tip'), b: g('tip'), p: pointer);
      return (
        placement,
        placement == null ? null : LabelDragResolver.linearLabelCenter(a: g('opposite_tip'), b: g('tip'), placement: placement),
      );
    case 'line_distance':
      final placement = LabelDragResolver.lineDistance(
        line1Start: g('line1_start'),
        line1End: g('line1_end'),
        line2Start: g('line2_start'),
        p: pointer,
      );
      return (
        placement,
        placement == null
            ? null
            : LabelDragResolver.lineDistanceLabelCenter(
                line1Start: g('line1_start'),
                line1End: g('line1_end'),
                line2Start: g('line2_start'),
                placement: placement,
              ),
      );
    case 'radius' || 'diameter':
      final c = g('center'), rim = g('rim');
      final r = _dist(c, rim);
      final placement = LabelDragResolver.radial(center: c, rim: rim, radius: r, p: pointer);
      return (
        placement,
        placement == null ? null : LabelDragResolver.radialLabelCenter(center: c, rim: rim, radius: r, placement: placement),
      );
    case 'angle':
      final value = (geometry['value_degrees'] as num?)?.toDouble();
      final placement = LabelDragResolver.angle(
        line1Start: g('line1_start'),
        line1End: g('line1_end'),
        line2Start: g('line2_start'),
        line2End: g('line2_end'),
        p: pointer,
        valueDegrees: value,
        quadrant: quadrant,
      );
      return (
        placement,
        placement == null
            ? null
            : LabelDragResolver.angleLabelCenter(
                line1Start: g('line1_start'),
                line1End: g('line1_end'),
                line2Start: g('line2_start'),
                line2End: g('line2_end'),
                placement: placement,
                valueDegrees: value,
                quadrant: quadrant,
              ),
      );
    case 'arc_length' ||
          'horizontal_angle' ||
          'point_angle' ||
          'point_circle_distance' ||
          'circle_distance' ||
          'line_circle_distance':
      final names = geometry.keys.where((k) => geometry[k] is List).toList();
      final at = {for (final n in names) n: g(n)};
      final ConstraintDto c = switch (kind) {
        'arc_length' => const ArcLengthConstraintDto(
            id: 'd',
            arcId: 'arc',
            centerPointId: 'center',
            startPointId: 'start',
            endPointId: 'end',
            length: 0,
          ),
        'horizontal_angle' => HorizontalAngleConstraintDto(
            id: 'd',
            lineId: 'line',
            lineStartId: 'line_start',
            lineEndId: 'line_end',
            angleDegrees: 0,
            quadrant: quadrant,
          ),
        'point_angle' => PointAngleConstraintDto(
            id: 'd',
            vertexPointId: 'vertex',
            point1Id: 'point1',
            point2Id: 'point2',
            angleDegrees: 0,
            quadrant: quadrant,
          ),
        'point_circle_distance' => PointCircleDistanceConstraintDto(
            id: 'd',
            pointId: 'point',
            circleOrArcId: 'circle',
            centerPointId: 'center',
            radiusPointId: 'rim',
            distance: 0,
            side: side!,
          ),
        'circle_distance' => CircleCircleDistanceConstraintDto(
            id: 'd',
            entity1Id: 'circle1',
            center1PointId: 'center1',
            radius1PointId: 'rim1',
            entity2Id: 'circle2',
            center2PointId: 'center2',
            radius2PointId: 'rim2',
            distance: 0,
            side: side!,
          ),
        _ => LineCircleDistanceConstraintDto(
            id: 'd',
            lineId: 'line',
            lineStartId: 'line_start',
            lineEndId: 'line_end',
            circleOrArcId: 'circle',
            centerPointId: 'center',
            radiusPointId: 'rim',
            distance: 0,
            side: side!,
          ),
      };
      XY? pointAt(String id) => at[id];
      final placement = dimensionPlacementAt(c, pointAt, pointer);
      return (placement, placement == null ? null : dimensionLayout(c, pointAt, placement)?.label);
  }
  throw ArgumentError('unknown placement kind $kind');
}

double _dist(Pt a, Pt b) => math.sqrt((a.$1 - b.$1) * (a.$1 - b.$1) + (a.$2 - b.$2) * (a.$2 - b.$2));

void main() {
  final file = File(casesPath);
  if (!file.existsSync()) {
    test('cases file', () => fail('$casesPath not found (run `flutter test` from client/)'));
    return;
  }
  final doc = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  final tolerance = (doc['tolerance'] as num).toDouble();
  final cases = (doc['cases'] as List).cast<Map<String, dynamic>>();

  test('every placement kind the catalogue\'s options create has cases, each with three pointers', () {
    final kinds = {for (final c in cases) c['kind'] as String};
    expect(kinds, (doc['kinds'] as Map).keys.toSet());
    expect(kinds, {
      'distance_linear', 'distance_horizontal', 'distance_vertical', 'point_line_distance', 'ellipse_axis', 'line_distance', //
      'radius', 'diameter', 'angle', 'arc_length', 'horizontal_angle', 'point_angle', 'point_circle_distance', 'circle_distance',
      'line_circle_distance',
    });
    for (final c in cases) {
      expect((c['pointers'] as List).length, 3, reason: '${c['name']}');
    }
  });

  for (final c in cases) {
    test('${c['kind']}: ${c['name']}', () {
      final geometry = c['geometry'] as Map<String, dynamic>;
      for (final row in (c['pointers'] as List).cast<Map<String, dynamic>>()) {
        final pointer = _pt(row['pointer']);
        final (placement, centre) = placementCase(c['kind'] as String, geometry, pointer);
        final want = DimensionLabelPlacement.fromJson(row['placement']);
        if (want == null) {
          expect(placement, isNull, reason: 'pointer $pointer');
          expect(row['label_center'], isNull);
          continue;
        }
        expect(placement, isNotNull, reason: 'pointer $pointer');
        expect(placement!.toJson().keys.toSet(), want.toJson().keys.toSet(), reason: 'the fields this kind sets');
        for (final MapEntry(:key, :value) in want.toJson().entries) {
          expect(placement.toJson()[key], closeTo(value, tolerance), reason: '$key for pointer $pointer');
        }
        final wantCentre = _pt(row['label_center']);
        expect(centre, isNotNull);
        expect(centre!.$1, closeTo(wantCentre.$1, tolerance), reason: 'label centre x for pointer $pointer');
        expect(centre.$2, closeTo(wantCentre.$2, tolerance), reason: 'label centre y for pointer $pointer');
      }
    });
  }
}
