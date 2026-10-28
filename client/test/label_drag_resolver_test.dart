import 'dart:math' as math;

import 'package:didsa_cad_client/api/dimension_label_placement.dart';
import 'package:didsa_cad_client/sketch/label_drag_resolver.dart';
import 'package:flutter_test/flutter_test.dart';

void expectPoint((double, double)? actual, (double, double) expected) {
  expect(actual, isNotNull);
  expect(actual!.$1, closeTo(expected.$1, 1e-9));
  expect(actual.$2, closeTo(expected.$2, 1e-9));
}

void main() {
  group('linear', () {
    const targets = [(3.0, 7.0), (-4.0, 2.5), (12.0, -6.0), (5.0, 0.0)];

    test('dragging to a point and laying the placement out puts the label at that point', () {
      for (final (a, b) in [((0.0, 0.0), (10.0, 0.0)), ((1.0, 2.0), (7.0, 9.0)), ((8.0, 3.0), (-2.0, -1.0))]) {
        for (final p in targets) {
          final placement = LabelDragResolver.linear(a: a, b: b, p: p)!;
          expectPoint(LabelDragResolver.linearLabelCenter(a: a, b: b, placement: placement), p);
        }
      }
    });

    test('horizontal and vertical round-trip, whichever point is stored first', () {
      for (final (a, b) in [((0.0, 0.0), (10.0, 4.0)), ((10.0, 4.0), (0.0, 0.0))]) {
        for (final orientation in ['horizontal', 'vertical']) {
          for (final p in targets) {
            final placement = LabelDragResolver.linear(a: a, b: b, orientation: orientation, p: p)!;
            expectPoint(LabelDragResolver.linearLabelCenter(a: a, b: b, orientation: orientation, placement: placement), p);
          }
        }
      }
    });

    test('a vertical dimension measures its offset past the larger x and its along from the middle', () {
      final placement = LabelDragResolver.linear(a: (0.0, 0.0), b: (2.0, 10.0), orientation: 'vertical', p: (5.0, 8.0))!;
      expect(placement.offset, 3.0);
      expect(placement.along, 3.0);
    });

    test('a horizontal dimension measures its offset past the larger y and its along from the middle', () {
      final placement = LabelDragResolver.linear(a: (0.0, 0.0), b: (10.0, 2.0), orientation: 'horizontal', p: (8.0, -1.0))!;
      expect(placement.offset, -3.0);
      expect(placement.along, 3.0);
    });

    test('the placement holds no screen quantity: swapping nothing but the point it is laid out against moves nothing', () {
      // Same sketch geometry, same placement, laid out twice: identical, as there is no zoom or camera in the maths.
      const placement = DimensionLabelPlacement(offset: 4.0, along: -2.0);
      final first = LabelDragResolver.linearLabelCenter(a: (0.0, 0.0), b: (10.0, 0.0), placement: placement);
      final second = LabelDragResolver.linearLabelCenter(a: (0.0, 0.0), b: (10.0, 0.0), placement: placement);
      expect(first, second);
    });

    test('a zero-length segment cannot be placed', () {
      expect(LabelDragResolver.linear(a: (1.0, 1.0), b: (1.0, 1.0), p: (2.0, 2.0)), isNull);
    });
  });

  group('line to line', () {
    test('round trips for lines on either side of line 1', () {
      for (final line2Y in [6.0, -6.0]) {
        const l1s = (0.0, 0.0), l1e = (10.0, 0.0);
        final l2s = (2.0, line2Y);
        for (final p in [(3.0, 3.0), (-5.0, 1.0), (14.0, -9.0)]) {
          final placement = LabelDragResolver.lineDistance(line1Start: l1s, line1End: l1e, line2Start: l2s, p: p)!;
          expectPoint(
            LabelDragResolver.lineDistanceLabelCenter(line1Start: l1s, line1End: l1e, line2Start: l2s, placement: placement),
            p,
          );
        }
      }
    });

    test('offset slides along line 1, along runs towards line 2', () {
      final placement = LabelDragResolver.lineDistance(
        line1Start: (0.0, 0.0),
        line1End: (10.0, 0.0),
        line2Start: (0.0, 6.0),
        p: (9.0, 5.0),
      )!;
      expect(placement.offset, 4.0); // line 1's midpoint is x = 5
      expect(placement.along, 2.0); // the connector's midpoint is y = 3
    });
  });

  group('radius and diameter', () {
    test('round trips around the circle', () {
      const center = (2.0, 3.0), rim = (5.0, 3.0);
      for (final p in [(2.0, 10.0), (-4.0, 3.0), (3.0, -2.0), (7.0, 6.0)]) {
        final placement = LabelDragResolver.radial(center: center, rim: rim, radius: 3.0, p: p)!;
        expectPoint(LabelDragResolver.radialLabelCenter(center: center, rim: rim, radius: 3.0, placement: placement), p);
      }
    });

    test('the angle is counter-clockwise degrees from the rim point, and does not jump when the pointer crosses the centre side', () {
      const center = (0.0, 0.0), rim = (4.0, 0.0);
      expect(LabelDragResolver.radial(center: center, rim: rim, radius: 4.0, p: (0.0, 9.0))!.angle, closeTo(90, 1e-9));
      expect(LabelDragResolver.radial(center: center, rim: rim, radius: 4.0, p: (0.0, -9.0))!.angle, closeTo(-90, 1e-9));
      final justAbove = LabelDragResolver.radial(center: center, rim: rim, radius: 4.0, p: (-9.0, 0.1))!.angle!;
      final justBelow = LabelDragResolver.radial(center: center, rim: rim, radius: 4.0, p: (-9.0, -0.1))!.angle!;
      expect(justAbove, closeTo(179.36, 0.01));
      expect(justBelow, closeTo(-179.36, 0.01));
    });

    test('the leg is the distance beyond the circle and may be negative (a label inside the circle)', () {
      expect(LabelDragResolver.radial(center: (0.0, 0.0), rim: (4.0, 0.0), radius: 4.0, p: (7.0, 0.0))!.leg, closeTo(3, 1e-9));
      expect(LabelDragResolver.radial(center: (0.0, 0.0), rim: (4.0, 0.0), radius: 4.0, p: (1.0, 0.0))!.leg, closeTo(-3, 1e-9));
    });

    test('a pointer exactly on the centre has no direction', () {
      expect(LabelDragResolver.radial(center: (1.0, 1.0), rim: (4.0, 1.0), radius: 3.0, p: (1.0, 1.0)), isNull);
    });
  });

  group('angle', () {
    const l1s = (0.0, 0.0), l1e = (10.0, 0.0);
    const l2s = (0.0, 0.0), l2e = (0.0, 10.0);

    test('round trips', () {
      for (final p in [(3.0, 3.0), (6.0, 1.0), (1.0, 8.0), (5.0, 5.0)]) {
        final placement =
            LabelDragResolver.angle(line1Start: l1s, line1End: l1e, line2Start: l2s, line2End: l2e, p: p)!;
        expectPoint(
          LabelDragResolver.angleLabelCenter(line1Start: l1s, line1End: l1e, line2Start: l2s, line2End: l2e, placement: placement),
          p,
        );
      }
    });

    test('the radius is the arc\'s radius about the intersection and along is measured across the chord', () {
      // The rays are +x and +y, so the arc's chord midpoint is (radius / 2, radius / 2) and the chord runs along (-1, 1).
      final placement = LabelDragResolver.angle(line1Start: l1s, line1End: l1e, line2Start: l2s, line2End: l2e, p: (3.0, 4.0))!;
      expect(placement.radius, closeTo(7, 1e-9));
      expect(placement.along, closeTo(1 / math.sqrt(2), 1e-9));
    });

    test('a pointer behind the vertex cannot place the arc', () {
      expect(LabelDragResolver.angle(line1Start: l1s, line1End: l1e, line2Start: l2s, line2End: l2e, p: (-3.0, -4.0)), isNull);
    });

    test('works when the lines only meet beyond their drawn ends', () {
      const a1 = (5.0, 0.0), a2 = (10.0, 0.0), b1 = (5.0, 5.0), b2 = (5.0, 10.0);
      final basis = LabelDragResolver.angleVertexAndRays(line1Start: a1, line1End: a2, line2Start: b1, line2End: b2)!;
      expect(basis.$1.$1, closeTo(5, 1e-9));
      expect(basis.$1.$2, closeTo(0, 1e-9));
      final p = (8.0, 6.0);
      final placement = LabelDragResolver.angle(line1Start: a1, line1End: a2, line2Start: b1, line2End: b2, p: p)!;
      expectPoint(
        LabelDragResolver.angleLabelCenter(line1Start: a1, line1End: a2, line2Start: b1, line2End: b2, placement: placement),
        p,
      );
    });

    test('parallel lines have no vertex to place an arc about', () {
      expect(
        LabelDragResolver.angle(line1Start: (0.0, 0.0), line1End: (5.0, 0.0), line2Start: (0.0, 3.0), line2End: (5.0, 3.0), p: (2.0, 2.0)),
        isNull,
      );
    });
  });

  group('placement model', () {
    test('json round trip keeps only the fields set', () {
      const placement = DimensionLabelPlacement(offset: 1.5, along: -2);
      expect(placement.toJson(), {'offset': 1.5, 'along': -2.0});
      expect(DimensionLabelPlacement.fromJson(placement.toJson()), placement);
    });

    test('absent, empty or unusable json means no placement', () {
      expect(DimensionLabelPlacement.fromJson(null), isNull);
      expect(DimensionLabelPlacement.fromJson(<String, dynamic>{}), isNull);
      expect(DimensionLabelPlacement.fromJson({'offset': 'wide', 'unknown': 3}), isNull);
      expect(DimensionLabelPlacement.fromJson({'offset': double.nan}), isNull);
    });

    test('a quarter turn is 90 degrees', () {
      // Guards the unit: angle is degrees, not radians.
      final placement = LabelDragResolver.radial(center: (0.0, 0.0), rim: (1.0, 0.0), radius: 1.0, p: (0.0, 2.0))!;
      expect(placement.angle, closeTo(90.0, 1e-9));
      expect(math.pi, isNot(placement.angle));
    });
  });
}
