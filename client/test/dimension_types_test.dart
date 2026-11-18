// Bug report 2026-11-18 part D: the new dimension types on the client - the shared maths of `dimension_types.dart` (value, label
// placement and layout), the DOF table, the drag projector's model, the Point Merge / delete point lists, and the flat canvas putting
// a dragged label where it was dropped. The dimension tool's flow (offered, previewed, confirmed) is in `sketch_controller_test.dart`.
import 'dart:math' as math;

import 'package:didsa_cad_client/api/sketch_api_client.dart';
import 'package:didsa_cad_client/sketch/dimension_types.dart';
import 'package:didsa_cad_client/sketch/dof_analysis.dart';
import 'package:didsa_cad_client/sketch/point_merge_rule.dart';
import 'package:didsa_cad_client/sketch/projector/sketch_projector.dart';
import 'package:didsa_cad_client/sketch/sketch_canvas.dart' show dimensionLabelCenterScreen;
import 'package:didsa_cad_client/sketch/sketch_controller.dart';
import 'package:didsa_cad_client/sketch/view_transform.dart';
import 'package:flutter_test/flutter_test.dart';

typedef Pt = (double, double);

double _dist(Pt a, Pt b) => math.sqrt(math.pow(a.$1 - b.$1, 2) + math.pow(a.$2 - b.$2, 2));

PointAt _at(Map<String, Pt> points) => (id) => points[id];

/// Drags [id]'s label to [p] and checks the flat canvas draws its centre there at several zooms.
void _expectDraggedLabelLandsWhereDropped(SketchController controller, String id, List<Pt> drops) {
  for (final p in drops) {
    expect(controller.beginLabelDrag(id), isTrue);
    controller.dragLabelToPointer(p.$1, p.$2);
    controller.endLabelDrag();
    for (final ppu in [8.0, 20.0, 64.0]) {
      final transform = ViewTransform(pixelsPerUnit: ppu, originScreen: const Offset(300, 400));
      final center = dimensionLabelCenterScreen(controller, transform, id);
      final wanted = transform.sketchToScreen(p.$1, p.$2);
      expect(center, isNotNull, reason: '$id at $ppu px/unit');
      expect(center!.dx, closeTo(wanted.dx, 1e-6), reason: '$id x at $ppu px/unit');
      expect(center.dy, closeTo(wanted.dy, 1e-6), reason: '$id y at $ppu px/unit');
    }
  }
}

void main() {
  group('arc length', () {
    const arcLength = ArcLengthConstraintDto(
      id: 'len',
      arcId: 'arc',
      centerPointId: 'c',
      startPointId: 's',
      endPointId: 'e',
      length: 6,
    );
    final quarter = <String, Pt>{'c': (0, 0), 's': (5, 0), 'e': (0, 5)};

    test('measures radius times the counter-clockwise sweep, the long way round when the end is behind the start', () {
      expect(measureDimension(arcLength, _at(quarter)), closeTo(5 * math.pi / 2, 1e-12));
      final threeQuarters = {'c': (0.0, 0.0), 's': (5.0, 0.0), 'e': (0.0, -5.0)};
      expect(measureDimension(arcLength, _at(threeQuarters)), closeTo(5 * 3 * math.pi / 2, 1e-12));
      expect(measureDimension(arcLength, _at({'c': (0, 0), 's': (5, 0)})), isNull);
    });

    test('a placement read from a pointer puts the label back on that pointer', () {
      for (final p in [(6.0, 6.0), (2.0, 1.0), (-7.0, 3.0), (3.0, -8.0)]) {
        final placement = dimensionPlacementAt(arcLength, _at(quarter), p)!;
        final layout = dimensionLayout(arcLength, _at(quarter), placement)!;
        expect(layout.label.$1, closeTo(p.$1, 1e-9));
        expect(layout.label.$2, closeTo(p.$2, 1e-9));
      }
    });

    test('the layout: a concentric arc through the label, extension lines from the arc ends, two arrows at its ends', () {
      final placement = dimensionPlacementAt(arcLength, _at(quarter), (6, 6))!;
      final layout = dimensionLayout(arcLength, _at(quarter), placement)!;
      final r = 6 * math.sqrt(2);
      for (final p in layout.strokes.first) {
        expect(_dist(p, (0, 0)), closeTo(r, 1e-9));
      }
      expect(layout.extensions, hasLength(2));
      expect(_dist(layout.extensions[0].$1, (5, 0)), closeTo(0, 1e-9));
      expect(_dist(layout.extensions[1].$1, (0, 5)), closeTo(0, 1e-9));
      expect(layout.arrows, hasLength(2));
      expect(_dist(layout.arrows[0].$1, (r, 0)), closeTo(0, 1e-9));
      expect(_dist(layout.arrows[1].$1, (0, r)), closeTo(0, 1e-9));
      // No placement: a default place, outside the arc at its middle.
      final standard = dimensionLayout(arcLength, _at(quarter), null)!;
      expect(_dist(standard.label, (0, 0)), greaterThan(5));
    });

    test('label text, preview text, value replacement, create body and identity', () {
      expect(dimensionLabelText(arcLength), '⌒6.00');
      expect(dimensionPreviewText(arcLength), '⌒?');
      expect(storedDimensionValue(dimensionWithValue(arcLength, 9)), 9);
      expect(dimensionCreateJson(arcLength, 7), {'type': 'arc_length', 'arc_id': 'arc', 'length': 7.0});
      expect(sameDimensionTarget(arcLength, dimensionWithValue(arcLength, 2)), isTrue);
      expect(isAngularDimension(arcLength), isFalse);
    });

    test('the response parses into the DTO', () {
      final dto = ConstraintDto.fromJson({
        'type': 'arc_length',
        'id': 'k',
        'arc_id': 'arc',
        'center_point_id': 'c',
        'start_point_id': 's',
        'end_point_id': 'e',
        'length': 4,
        'label': {'leg': 1.5, 'angle': 10},
      });
      expect(dto, isA<ArcLengthConstraintDto>());
      expect((dto as ArcLengthConstraintDto).length, 4.0);
      expect(dto.label?.leg, 1.5);
    });

    test('DOF table: one equation, standing on the arc\'s three points; merge and delete see the same three', () {
      expect(dofCostByConstraintType['arc_length'], 1);
      final described = describeConstraint(arcLength, const {}, const {});
      expect(described.type, 'arc_length');
      expect(described.pointIds.toSet(), {'c', 's', 'e'});
      expect(constraintPointIds(arcLength, const {}), {'c', 's', 'e'});
    });

    test('the drag projector keeps the length: the end slides round the circle to it', () {
      final projection = projectSketch(
        points: {'c': (0, 0), 's': (5, 0), 'e': (1, 6)},
        constraints: const [
          EqualRadiusConstraintDto(id: 'er', center1PointId: 'c', radius1PointId: 's', center2PointId: 'c', radius2PointId: 'e'),
          arcLength,
        ],
        lineEndpoints: (id) => throw StateError('no lines'),
        anchorPointIds: {'e'},
        pinnedPointIds: {'c', 's'},
      );
      expect(projection.unsupported, isFalse);
      expect(projection.converged, isTrue);
      final e = projection.points['e']!;
      expect(_dist(e, (0, 0)), closeTo(5, 1e-5));
      expect(measureDimension(arcLength, _at({'c': (0, 0), 's': (5, 0), 'e': e})), closeTo(6, 1e-5));
    });

    test('flat canvas: a dragged label is drawn where it was dropped, at any zoom', () {
      final controller = SketchController(api: SketchApiClient(httpClient: null));
      quarter.forEach((id, p) => controller.points[id] = SketchPointView(id: id, x: p.$1, y: p.$2));
      controller.arcs['arc'] = const SketchArcView(id: 'arc', centerPointId: 'c', startPointId: 's', endPointId: 'e');
      controller.constraints['len'] = arcLength;
      expect(controller.labelUsesPlacement('len'), isTrue);
      _expectDraggedLabelLandsWhereDropped(controller, 'len', [(6, 6), (-3, 7), (2, 2)]);
      // And the 3D overlay item carries the same layout.
      final item = controller.constraintOverlayItems().whereType<ConstraintLaidOutDimensionItem>().single;
      expect(item.layout.label.$1, closeTo(2, 1e-9));
      expect(item.layout.label.$2, closeTo(2, 1e-9));
    });
  });

  group('angle to horizontal', () {
    const dim = HorizontalAngleConstraintDto(id: 'ha', lineId: 'l', lineStartId: 'a', lineEndId: 'b', angleDegrees: 30, quadrant: 0);
    final line = <String, Pt>{'a': (0, 0), 'b': (10, 3)};
    final leanDegrees = math.atan2(3, 10) * 180 / math.pi;
    HorizontalAngleConstraintDto withQuadrant(int q) =>
        HorizontalAngleConstraintDto(id: 'ha', lineId: 'l', lineStartId: 'a', lineEndId: 'b', angleDegrees: 30, quadrant: q);

    test('each quadrant measures its own angle', () {
      expect(measureDimension(withQuadrant(0), _at(line)), closeTo(leanDegrees, 1e-9));
      expect(measureDimension(withQuadrant(1), _at(line)), closeTo(180 - leanDegrees, 1e-9));
      expect(measureDimension(withQuadrant(2), _at(line)), closeTo(180 - leanDegrees, 1e-9));
      expect(measureDimension(withQuadrant(3), _at(line)), closeTo(leanDegrees, 1e-9));
    });

    test('the pointer picks the nearer end and its side', () {
      int? q(Pt p) => dimensionQuadrant(dimensionFollowingPointer(dim, _at(line), p));
      expect(q((2, -1)), 0);
      expect(q((-2, 1)), 2);
      expect(q((12, 1)), 1);
      expect(q((8, 5)), 3);
    });

    test('a placement read from a pointer puts the label back on it; the arc runs from the line to the horizontal', () {
      for (final quadrant in [0, 1, 2, 3]) {
        final d = withQuadrant(quadrant);
        for (final p in [(4.0, 0.5), (-3.0, 2.0), (6.0, -4.0)]) {
          final placement = dimensionPlacementAt(d, _at(line), p);
          if (placement == null) continue;
          final layout = dimensionLayout(d, _at(line), placement)!;
          expect(_dist(layout.label, p), closeTo(0, 1e-9), reason: 'quadrant $quadrant, $p');
        }
      }
      final layout = dimensionLayout(dim, _at(line), null)!;
      // Default: half the line out from the start; arrows on the line's ray and on +x; the horizontal drawn as a reference stroke.
      final r = _dist((0, 0), (10, 3)) / 2;
      expect(_dist(layout.arrows[0].$1, (10 * r / _dist((0, 0), (10, 3)), 3 * r / _dist((0, 0), (10, 3)))), closeTo(0, 1e-9));
      expect(_dist(layout.arrows[1].$1, (r, 0)), closeTo(0, 1e-9));
      expect(layout.strokes.any((s) => s.length == 2 && s.first == (0.0, 0.0)), isTrue);
    });

    test('text, create body (with the quadrant), identity, DOF, points', () {
      expect(dimensionLabelText(dim), '30.0°');
      expect(isAngularDimension(dim), isTrue);
      expect(dimensionCreateJson(dim, 45), {'type': 'horizontal_angle', 'line_id': 'l', 'angle_degrees': 45.0, 'quadrant': 0});
      expect(sameDimensionTarget(dim, withQuadrant(3)), isTrue);
      expect(dofCostByConstraintType['horizontal_angle'], 1);
      expect(describeConstraint(dim, const {}, const {}).pointIds.toSet(), {'a', 'b'});
      expect(constraintPointIds(dim, const {}), {'a', 'b'});
      final parsed = ConstraintDto.fromJson({
        'type': 'horizontal_angle',
        'id': 'k',
        'line_id': 'l',
        'line_start_id': 'a',
        'line_end_id': 'b',
        'angle_degrees': 12.5,
        'quadrant': 2,
      });
      expect(parsed, isA<HorizontalAngleConstraintDto>());
      expect((parsed as HorizontalAngleConstraintDto).quadrant, 2);
    });

    test('the drag projector holds the angle: the end slides along the 30 degree ray', () {
      for (final (quadrant, direction, wish) in [(0, 30.0, (8.0, 6.0)), (1, 150.0, (-8.0, 6.0))]) {
        final projection = projectSketch(
          points: {'a': (0, 0), 'b': wish},
          constraints: [withQuadrant(quadrant)],
          lineEndpoints: (id) => ('a', 'b'),
          anchorPointIds: {'b'},
          pinnedPointIds: {'a'},
        );
        expect(projection.converged, isTrue);
        final b = projection.points['b']!;
        // Either side of the horizontal is the same angle to it.
        expect((math.atan2(b.$2, b.$1) * 180 / math.pi).abs(), closeTo(direction, 1e-4), reason: 'quadrant $quadrant');
      }
    });

    test('flat canvas: a dragged label is drawn where it was dropped', () {
      final controller = SketchController(api: SketchApiClient(httpClient: null));
      line.forEach((id, p) => controller.points[id] = SketchPointView(id: id, x: p.$1, y: p.$2));
      controller.lines['l'] = const SketchLineView(id: 'l', startPointId: 'a', endPointId: 'b');
      controller.constraints['ha'] = dim;
      _expectDraggedLabelLandsWhereDropped(controller, 'ha', [(4, 0.5), (6, -3), (-2, 2)]);
    });
  });
}
