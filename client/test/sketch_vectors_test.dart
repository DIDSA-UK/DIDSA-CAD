// The sketch projector's golden vectors (docs/motion/sketch-vectors.json; spec: docs/motion/sketch-projector-spec.md).
//
//   flutter test test/sketch_vectors_test.dart                                  # check (also part of the full suite)
//   DIDSA_SKETCH_VECTORS=write flutter test test/sketch_vectors_test.dart       # (re)write the file
//   tools/sketch_vectors/export.sh [--check]                                    # the same, from the repo root
//
// Check mode fails when a regeneration differs from the committed file (a number by more than `regenerate_tolerance`, or
// anything else at all), when the Dart projector does not reproduce a vector from its JSON alone within the case's tolerance,
// or when a nudge of the inputs at the file's rounding grain moves an answer by more than a tenth of that tolerance (so a
// port's own rounding cannot fail a vector).
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:didsa_cad_client/api/sketch_api_client.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/sketch_vectors.dart';

void main() {
  final write = Platform.environment['DIDSA_SKETCH_VECTORS'] == 'write';
  final file = File(kSketchVectorsPath);

  test('the vectors regenerate to the committed file${write ? ' (writing it)' : ''}', () {
    final fresh = buildSketchVectors();
    final text = encodeSketchVectors(fresh);
    if (write) {
      file.writeAsStringSync(text);
      final cases = fresh['cases'] as List;
      final kinds = <String, int>{};
      var frames = 0;
      for (final c in cases) {
        kinds[c['kind'] as String] = (kinds[c['kind']] ?? 0) + 1;
        frames += (c['frames'] as List).length;
      }
      // ignore: avoid_print
      print('wrote $kSketchVectorsPath: ${cases.length} cases, $frames frames $kinds');
      return;
    }
    expect(file.existsSync(), isTrue, reason: '$kSketchVectorsPath is missing: run tools/sketch_vectors/export.sh');
    final committedText = file.readAsStringSync();
    final problems = sketchVectorDifferences(jsonDecode(committedText), jsonDecode(text), kRegenerateTolerance);
    expect(problems, isEmpty, reason: 'regenerate with tools/sketch_vectors/export.sh:\n${problems.take(20).join('\n')}');
    // ignore: avoid_print
    if (committedText != text) print('sketch vectors: equal within $kRegenerateTolerance, not byte for byte');
  });

  group('the Dart projector passes its own vectors (read from the file alone)', () {
    if (!file.existsSync()) return;
    final doc = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    final cases = (doc['cases'] as List).cast<Map<String, dynamic>>();

    test('every constraint\'s wire form reads back to the same wire form', () {
      for (final c in cases) {
        for (final wire in c['input']['constraints'] as List) {
          final again = constraintToWire(ConstraintDto.fromJson(wire as Map<String, dynamic>));
          expect(jsonEncode(again), jsonEncode(wire), reason: c['id'] as String);
        }
      }
    });

    test('every supported constraint type has a golden case and a drag path', () {
      final types = <String, Set<String>>{};
      for (final c in cases) {
        for (final wire in c['input']['constraints'] as List) {
          (types[c['kind'] as String] ??= <String>{}).add(wire['type'] as String);
        }
      }
      const supported = {
        'distance', 'vertical', 'horizontal', 'angle', 'coincident', 'concentric', 'parallel', 'perpendicular', 'equal_length',
        'collinear', 'line_distance', 'point_line_distance', 'at_midpoint', 'tangent', 'curve_tangent', 'equal_radius',
        'point_on_line', 'point_on_circle', 'point_on_ellipse', 'arc_length', 'horizontal_angle', 'point_angle',
        'point_circle_distance', 'circle_distance', 'line_circle_distance',
      };
      expect(types['golden'], containsAll(supported));
      expect(types['drag'], containsAll(supported));
      expect(types['scene'], containsAll({'fixed', 'spline_tangent'}));
    });

    for (final c in cases) {
      test(c['id'] as String, () {
        final tolerance = (c['tolerance'] as num).toDouble();
        final frames = c['frames'] as List;
        for (var k = 0; k < frames.length; k++) {
          final want = frames[k]['expected'] as Map<String, dynamic>;
          final got = expectedOf(replayFrame(c, k));
          final why = '${c['id']} frame $k';
          for (final key in ['unsupported', 'converged', 'variable_points', 'rows']) {
            expect(got[key], want[key], reason: '$why: $key');
          }
          final gotPoints = got['points'] as Map<String, dynamic>, wantPoints = want['points'] as Map<String, dynamic>;
          expect(gotPoints.keys.toSet(), wantPoints.keys.toSet(), reason: '$why: the group');
          for (final id in wantPoints.keys) {
            for (var d = 0; d < 2; d++) {
              expect((gotPoints[id][d] as num).toDouble(), closeTo((wantPoints[id][d] as num).toDouble(), tolerance),
                  reason: '$why: $id[$d]');
            }
          }
        }
      });
    }

    test('the nearly straight chain moves (F6: the rescue step at a singular start, spec 7.3)', () {
      final c = cases.firstWhere((c) => c['id'] == 'scene-chain-20-nearly-straight');
      final frames = c['frames'] as List;
      for (var k = 0; k < frames.length; k++) {
        final r = replayFrame(c, k);
        final before = frameStart(c, k)['p20']!;
        final (tx, ty) = r.points['p20']!;
        final wish = (frames[k]['wish'] as Map)['p20'] as List;
        final (wx, wy) = ((wish[0] as num).toDouble(), (wish[1] as num).toDouble());
        double gap(double x, double y) => math.sqrt((wx - x) * (wx - x) + (wy - y) * (wy - y));
        // The nearest feasible tip is on the reach circle (radius 100 round the pinned p0) towards the wish, or the wish itself.
        final reach = math.min(100.0, math.sqrt(wx * wx + wy * wy));
        final angle = math.atan2(wy, wx);
        final nearestGap = gap(reach * math.cos(angle), reach * math.sin(angle));
        expect(r.converged, isTrue, reason: 'frame $k');
        expect(gap(tx, ty), lessThan(gap(before.$1, before.$2)), reason: 'frame $k: the tip moved towards the hand');
        expect(gap(tx, ty) - nearestGap, lessThan(0.5), reason: 'frame $k: within 0.5 of the nearest feasible tip');
      }
    });

    test('a nudge of the inputs at the rounding grain moves no answer by more than a tenth of its tolerance', () {
      var worstRatio = 0.0;
      var worstAt = '';
      for (final c in cases) {
        final tolerance = (c['tolerance'] as num).toDouble();
        final frames = c['frames'] as List;
        for (var k = 0; k < frames.length; k++) {
          // Nudge every wished coordinate and every start coordinate by +-1e-10 (alternating), keep the rest.
          final nudged = jsonDecode(jsonEncode(c)) as Map<String, dynamic>;
          var sign = 1.0;
          void nudge(Map<String, dynamic> pts) {
            for (final v in pts.values) {
              v[0] = (v[0] as num).toDouble() + sign * 1e-10;
              v[1] = (v[1] as num).toDouble() - sign * 1e-10;
              sign = -sign;
            }
          }

          nudge(nudged['input']['start'] as Map<String, dynamic>);
          nudge((nudged['frames'] as List)[k]['wish'] as Map<String, dynamic>);
          for (var j = 0; j < k; j++) {
            nudge((nudged['frames'] as List)[j]['expected']['points'] as Map<String, dynamic>);
          }
          final got = expectedOf(replayFrame(nudged, k));
          final want = frames[k]['expected'] as Map<String, dynamic>;
          expect(got['converged'], want['converged'], reason: '${c['id']} frame $k');
          final wantPoints = want['points'] as Map<String, dynamic>;
          for (final id in wantPoints.keys) {
            for (var d = 0; d < 2; d++) {
              final diff = ((got['points'][id][d] as num) - (wantPoints[id][d] as num)).abs().toDouble();
              if (diff / tolerance > worstRatio) {
                worstRatio = diff / tolerance;
                worstAt = '${c['id']} frame $k $id[$d]: $diff';
              }
            }
          }
        }
      }
      // ignore: avoid_print
      print('sketch vectors: worst nudge response ${(worstRatio * 100).toStringAsFixed(4)} % of the tolerance ($worstAt)');
      expect(worstRatio, lessThan(0.1), reason: worstAt);
    });

    test('timing: the slowest frame (reported only)', () {
      var slowest = 0.0;
      var at = '';
      for (final c in cases) {
        for (var k = 0; k < (c['frames'] as List).length; k++) {
          final watch = Stopwatch()..start();
          for (var i = 0; i < 5; i++) {
            replayFrame(c, k);
          }
          watch.stop();
          final us = watch.elapsedMicroseconds / 5;
          if (us > slowest) {
            slowest = us;
            at = '${c['id']} frame $k';
          }
        }
      }
      // ignore: avoid_print
      print('sketch vectors: slowest frame ${math.max(0, slowest).toStringAsFixed(0)} us ($at; JIT in flutter test)');
    });
  });
}
