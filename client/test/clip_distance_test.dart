import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

import 'package:didsa_cad_client/viewport3d/orbit_camera.dart';
import 'package:didsa_cad_client/viewport3d/part_toolbar.dart';

// Mirror of _doRecentre's AABB → far-clip formula (private to PartViewportState,
// so tested here against the same arithmetic rather than through the full widget).
double _autoFitFarClip(List<List<double>> vertices) {
  if (vertices.isEmpty) return kDefaultFarClip;
  double minX = double.infinity, maxX = double.negativeInfinity;
  double minY = double.infinity, maxY = double.negativeInfinity;
  double minZ = double.infinity, maxZ = double.negativeInfinity;
  for (final v in vertices) {
    if (v[0] < minX) minX = v[0];
    if (v[0] > maxX) maxX = v[0];
    if (v[1] < minY) minY = v[1];
    if (v[1] > maxY) maxY = v[1];
    if (v[2] < minZ) minZ = v[2];
    if (v[2] > maxZ) maxZ = v[2];
  }
  final dx = maxX - minX, dy = maxY - minY, dz = maxZ - minZ;
  final diagonal = math.sqrt(dx * dx + dy * dy + dz * dz);
  return math.max(kDefaultFarClip, 2.0 * diagonal);
}

void main() {
  group('A3 logarithmic far-clip slider math', () {
    test('sliderToClip(0.0) rounds to 500', () {
      expect(sliderToClip(0.0), closeTo(500.0, 1.0));
    });

    test('sliderToClip(1.0) rounds to 50000', () {
      expect(sliderToClip(1.0), closeTo(50000.0, 1.0));
    });

    test('sliderToClip(clipToSlider(3000)) round-trips to 3000', () {
      expect(sliderToClip(clipToSlider(3000.0)), closeTo(3000.0, 1.0));
    });

    test('sliderToClip(clipToSlider(x)) round-trips for several values', () {
      for (final x in [500.0, 1000.0, 5000.0, 10000.0, 25000.0, 50000.0]) {
        expect(sliderToClip(clipToSlider(x)), closeTo(x, x * 0.001),
            reason: 'round-trip failed for $x');
      }
    });

    test('clipToSlider(500) == 0.0', () {
      expect(clipToSlider(500.0), closeTo(0.0, 1e-9));
    });

    test('clipToSlider(50000) == 1.0', () {
      expect(clipToSlider(50000.0), closeTo(1.0, 1e-9));
    });

    test('sliderToClip is monotonically increasing', () {
      for (var i = 0; i < 9; i++) {
        final t1 = i / 10.0;
        final t2 = (i + 1) / 10.0;
        expect(sliderToClip(t1), lessThan(sliderToClip(t2)));
      }
    });
  });

  group('A3 recentre auto-fit far-clip formula', () {
    test('returns kDefaultFarClip when vertices list is empty', () {
      expect(_autoFitFarClip([]), equals(kDefaultFarClip));
    });

    test('returns kDefaultFarClip when mesh diagonal is smaller than default', () {
      // A 10x10x10 box has diagonal = sqrt(300) ≈ 17.3 mm; 2 * 17.3 = 34.6 < 3000.
      final vertices = [
        [0.0, 0.0, 0.0],
        [10.0, 10.0, 10.0],
      ];
      expect(_autoFitFarClip(vertices), equals(kDefaultFarClip));
    });

    test('returns 2 * diagonal when diagonal is large enough to exceed kDefaultFarClip', () {
      // A 2000 mm side cube has diagonal = sqrt(3) * 2000 ≈ 3464 mm;
      // 2 * 3464 ≈ 6928 > kDefaultFarClip = 3000.
      final vertices = [
        [0.0, 0.0, 0.0],
        [2000.0, 2000.0, 2000.0],
      ];
      final diagonal = math.sqrt(3) * 2000;
      expect(_autoFitFarClip(vertices), closeTo(2.0 * diagonal, 1.0));
    });

    test('max(kDefaultFarClip, 2 * diagonal) with exact boundary', () {
      // diagonal = kDefaultFarClip / 2 exactly → result = kDefaultFarClip.
      final half = kDefaultFarClip / 2;
      final vertices = [
        [0.0, 0.0, 0.0],
        [half, 0.0, 0.0],
      ];
      // diagonal = half; 2 * half = kDefaultFarClip → max = kDefaultFarClip.
      expect(_autoFitFarClip(vertices), equals(kDefaultFarClip));
    });
  });
}
