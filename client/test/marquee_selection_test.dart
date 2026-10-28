import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';

import 'package:didsa_cad_client/sketch/marquee_selection.dart';

/// Desktop input D2 (`docs/desktop-input-scope.md`): the crossing box
/// select's geometry tests.
void main() {
  const box = Rect.fromLTRB(0, 0, 10, 10);

  group('segmentTouchesRect', () {
    test('an end inside touches', () {
      expect(segmentTouchesRect(const Offset(5, 5), const Offset(50, 50), box), isTrue);
    });

    test('a segment passing straight through touches', () {
      expect(segmentTouchesRect(const Offset(-5, 5), const Offset(15, 5), box), isTrue);
    });

    test('a diagonal clipping one corner touches', () {
      expect(segmentTouchesRect(const Offset(-1, 2), const Offset(2, -1), box), isTrue);
    });

    test('a segment beside the box, or past a corner, does not', () {
      expect(segmentTouchesRect(const Offset(-5, -1), const Offset(15, -1), box), isFalse);
      expect(segmentTouchesRect(const Offset(-2, 1), const Offset(1, -2), box), isFalse);
    });

    test('a segment lying along an edge touches', () {
      expect(segmentTouchesRect(const Offset(-5, 0), const Offset(15, 0), box), isTrue);
    });
  });

  test('polylineTouchesRect checks the closing segment only when closed', () {
    final open = [const Offset(-5, -5), const Offset(15, -5), const Offset(15, 15), const Offset(-5, 15)];
    expect(polylineTouchesRect(open, box), isFalse);
    // The closing segment (-5,15)->(-5,-5) still misses; a box over it doesn't.
    expect(polylineTouchesRect(open, const Rect.fromLTRB(-6, 0, -4, 1)), isFalse);
    expect(polylineTouchesRect(open, const Rect.fromLTRB(-6, 0, -4, 1), closed: true), isTrue);
  });

  group('ellipsePolyline', () {
    test('a circle: every sample on the radius, ends where asked', () {
      final points = ellipsePolyline(const Offset(1, 2), 5, 5, 0, 0, math.pi / 2);
      for (final p in points) {
        expect((p - const Offset(1, 2)).distance, closeTo(5, 1e-9));
      }
      expect(points.first.dx, closeTo(6, 1e-9));
      expect(points.last.dy, closeTo(7, 1e-9), reason: 'a quarter turn counter-clockwise ends straight up');
    });

    test('a rotated ellipse puts its major axis along the rotation', () {
      final points = ellipsePolyline(Offset.zero, 4, 1, math.pi / 2, 0, 2 * math.pi);
      expect(points.first.dx, closeTo(0, 1e-9));
      expect(points.first.dy, closeTo(4, 1e-9));
    });
  });

  test('cubicPolyline runs from the first point to the last', () {
    final points = cubicPolyline(Offset.zero, const Offset(0, 10), const Offset(10, 10), const Offset(10, 0));
    expect(points.first, Offset.zero);
    expect(points.last.dx, closeTo(10, 1e-9));
    expect(points.last.dy, closeTo(0, 1e-9));
    expect(points.length, kCrossingSamplesPerSpan + 1);
  });
}
