import 'dart:math' as math;

import 'package:didsa_cad_client/viewport3d/sketch_geometry_3d.dart';
import 'package:flutter_test/flutter_test.dart';

double _polygonArea(List<(double, double)> polygon) {
  var area = 0.0;
  for (var i = 0; i < polygon.length; i++) {
    final (x1, y1) = polygon[i];
    final (x2, y2) = polygon[(i + 1) % polygon.length];
    area += x1 * y2 - x2 * y1;
  }
  return area.abs() / 2;
}

double _triangulatedArea(List<(double, double)> polygon, List<int> indices) {
  var total = 0.0;
  for (var t = 0; t + 2 < indices.length; t += 3) {
    final (x1, y1) = polygon[indices[t]];
    final (x2, y2) = polygon[indices[t + 1]];
    final (x3, y3) = polygon[indices[t + 2]];
    total += ((x2 - x1) * (y3 - y1) - (x3 - x1) * (y2 - y1)).abs() / 2;
  }
  return total;
}

void main() {
  test('square: triangulated area matches polygon area exactly', () {
    final square = [(0.0, 0.0), (4.0, 0.0), (4.0, 4.0), (0.0, 4.0)];
    final indices = earClipTriangleIndices(square);
    expect(indices.length, 6); // 2 triangles
    expect(_triangulatedArea(square, indices), closeTo(_polygonArea(square), 1e-9));
  });

  test('non-convex L-shape: triangulated area matches polygon area (no gaps/overlaps)', () {
    // An L-shape: a 4x4 square with a 2x2 notch bitten out of the top-right.
    final lShape = [
      (0.0, 0.0),
      (4.0, 0.0),
      (4.0, 2.0),
      (2.0, 2.0),
      (2.0, 4.0),
      (0.0, 4.0),
    ];
    final indices = earClipTriangleIndices(lShape);
    expect(indices.length, 12); // 4 triangles for 6 vertices
    expect(_triangulatedArea(lShape, indices), closeTo(_polygonArea(lShape), 1e-9));
  });

  test('clockwise winding still triangulates correctly (area sign-agnostic)', () {
    final square = [(0.0, 0.0), (0.0, 4.0), (4.0, 4.0), (4.0, 0.0)]; // CW
    final indices = earClipTriangleIndices(square);
    expect(indices.length, 6);
    expect(_triangulatedArea(square, indices), closeTo(_polygonArea(square), 1e-9));
  });

  test('many-sided near-circle polygon triangulates completely and terminates promptly', () {
    const n = 64;
    final polygon = [
      for (var i = 0; i < n; i++) (math.cos(2 * math.pi * i / n) * 10, math.sin(2 * math.pi * i / n) * 10),
    ];
    final stopwatch = Stopwatch()..start();
    final indices = earClipTriangleIndices(polygon);
    stopwatch.stop();

    expect(indices.length, (n - 2) * 3);
    expect(_triangulatedArea(polygon, indices), closeTo(_polygonArea(polygon), 1e-6));
    expect(stopwatch.elapsedMilliseconds, lessThan(2000));
  });

  test('degenerate input (fewer than 3 points) returns empty rather than throwing', () {
    expect(earClipTriangleIndices(const []), isEmpty);
    expect(earClipTriangleIndices(const [(0.0, 0.0)]), isEmpty);
    expect(earClipTriangleIndices(const [(0.0, 0.0), (1.0, 0.0)]), isEmpty);
  });

  test('self-intersecting (bowtie) input degrades to empty/partial rather than hanging', () {
    final bowtie = [(0.0, 0.0), (4.0, 4.0), (4.0, 0.0), (0.0, 4.0)];
    final stopwatch = Stopwatch()..start();
    final indices = earClipTriangleIndices(bowtie);
    stopwatch.stop();
    // The real assertion: this terminates at all (proof against the
    // dashedSegments-class of bug), not any particular triangle count.
    expect(stopwatch.elapsedMilliseconds, lessThan(2000));
    expect(indices.length % 3, 0);
  });
}
