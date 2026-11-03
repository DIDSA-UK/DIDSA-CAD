import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:didsa_cad_client/api/document_api_client.dart';
import 'package:didsa_cad_client/assembly/pattern_copy_pose.dart';
import 'package:didsa_cad_client/motion/mate_motion_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

/// S2 of `docs/pattern-followers-smoothness-plan.md`: the client `patternCopyPose` mirrors the backend's `assembly.pattern_copy_pose`.
/// The numbers are a committed fixture GENERATED FROM THE BACKEND (`tools/motion_vectors/pattern_copy_pose_vectors.py`; the backend's own
/// `tests/test_pattern_copy_pose_vectors.py` recomputes them from the backend, VR's `tests/pattern_copy_pose.gd` checks its port against a
/// copy). Poses are compared as translation + 3x3 matrix (never axis-angle).
const String _fixture = 'test/fixtures/pattern_copy_pose_vectors.json';

RigidTransformDto _pose(Map<String, dynamic> j) => RigidTransformDto.fromJson(j);

ComponentPatternDto _pattern(Map<String, dynamic> j) {
  final axis = j['axis'] as Map<String, dynamic>?;
  List<double> v(Object? o) => [for (final x in o as List) (x as num).toDouble()];
  return ComponentPatternDto(
    id: 'p',
    sourceOccurrenceIds: const ['src'],
    patternType: j['pattern_type'] as String,
    direction: v(j['direction']),
    count: j['count'] as int,
    spacing: (j['spacing'] as num).toDouble(),
    reverse: j['reverse'] as bool,
    direction2: v(j['direction_2']),
    count2: j['count_2'] as int,
    spacing2: (j['spacing_2'] as num).toDouble(),
    reverse2: j['reverse_2'] as bool,
    axis: axis == null ? null : ComponentPatternAxisDto(origin: v(axis['origin']), direction: v(axis['direction'])),
    countAngular: j['count_angular'] as int,
    angleTotal: (j['angle_total'] as num).toDouble(),
    reverseAngular: j['reverse_angular'] as bool,
    skipIndices: [for (final x in j['skip_indices'] as List) x as int],
    orientWithRotation: j['orient_with_rotation'] as bool,
  );
}

/// The row-major 3x3 of a pose.
List<double> _rotation(RigidTransformDto t) => poseOfDto(t).r.m; // double math (matrix4FromRigidTransform is float32)

void main() {
  final doc = jsonDecode(File(_fixture).readAsStringSync()) as Map<String, dynamic>;
  final tol = (doc['tolerance'] as num).toDouble();
  final cases = (doc['cases'] as List).cast<Map<String, dynamic>>();

  test('the fixture is the backend-generated one (50 cases: every pattern kind x five source poses)', () {
    expect(cases.length, greaterThanOrEqualTo(40));
  });

  test('patternCopyPose reproduces every backend pose (translation and rotation matrix) to 1e-9', () {
    var checks = 0;
    var worst = 0.0;
    for (final c in cases) {
      final pattern = _pattern(c['pattern'] as Map<String, dynamic>);
      final source = _pose(c['source'] as Map<String, dynamic>);
      expect(livePatternIndices(pattern), (c['live_indices'] as List).cast<int>(), reason: c['id'] as String);
      for (final e in (c['expected'] as List).cast<Map<String, dynamic>>()) {
        final got = patternCopyPose(pattern, source, e['index'] as int);
        final want = (e['translation'] as List).cast<num>();
        for (var k = 0; k < 3; k++) {
          worst = math.max(worst, (got.translation[k] - want[k]).abs());
          expect((got.translation[k] - want[k]).abs(), lessThan(tol), reason: '${c['id']} #${e['index']} t[$k]');
        }
        final rot = _rotation(got);
        final wantRot = (e['rotation'] as List).cast<num>();
        for (var k = 0; k < 9; k++) {
          worst = math.max(worst, (rot[k] - wantRot[k]).abs());
          expect((rot[k] - wantRot[k]).abs(), lessThan(tol), reason: '${c['id']} #${e['index']} r[$k]');
        }
        checks += 12;
      }
    }
    // ignore: avoid_print
    print('pattern_copy_pose: $checks checks, worst diff $worst');
  });

  test('a Circular pattern with orient_with_rotation false keeps the source\'s rotation, true turns it with the step', () {
    final base = {...(cases.firstWhere((c) => c['id'] == 'circular-orient/turned-z-30')['pattern'] as Map<String, dynamic>)};
    final source = _pose(cases.firstWhere((c) => c['id'] == 'circular-orient/turned-z-30')['source'] as Map<String, dynamic>);
    final keep = patternCopyPose(_pattern({...base, 'orient_with_rotation': false}), source, 1);
    final turn = patternCopyPose(_pattern({...base, 'orient_with_rotation': true}), source, 1);
    expect(keep.rotationAngleDegrees, closeTo(30.0, 1e-9));
    expect(turn.rotationAngleDegrees, closeTo(30.0 + 72.0, 1e-9));
  });

  group('followPatternCopies (the live-drag overlay)', () {
    RigidTransformDto at(double x, double y, double z) =>
        RigidTransformDto(translation: [x, y, z], rotationAxis: const [0.0, 0.0, 1.0], rotationAngleDegrees: 0.0);
    AssemblyOccurrenceInstanceDto inst(List<String> path, RigidTransformDto t) =>
        AssemblyOccurrenceInstanceDto(occurrencePath: path, partId: 'part', worldTransform: t);
    ComponentPatternDto linear({bool suppressed = false, List<int> skip = const []}) => ComponentPatternDto(
          id: 'p',
          sourceOccurrenceIds: const ['a'],
          patternType: 'linear',
          direction: const [1.0, 0.0, 0.0],
          count: 3,
          spacing: 300.0,
          skipIndices: skip,
          suppressed: suppressed,
        );
    final instances = [
      inst(['a'], at(0, 0, 0)),
      inst(['a#pattern:p:1'], at(300, 0, 0)),
      inst(['a#pattern:p:1', 'inner'], at(305, 2, 0)),
      inst(['a#pattern:p:2'], at(600, 0, 0)),
      inst(['b'], at(50, 50, 50)),
    ];

    test('a moved source moves its copies by the step and what is nested under a copy by the same delta; nothing else changes', () {
      final out = followPatternCopies(instances, focusPath: const [], patterns: [linear()], liveWorld: {'a': at(4, 6, 9)});
      Map<String, List<double>> byPath() => {for (final i in out) i.occurrencePath.join('/'): i.worldTransform.translation};
      expect(byPath()['a#pattern:p:1'], [304.0, 6.0, 9.0]);
      expect(byPath()['a#pattern:p:2'], [604.0, 6.0, 9.0]);
      expect(byPath()['a#pattern:p:1/inner'], [309.0, 8.0, 9.0]);
      expect(byPath()['a'], [0.0, 0.0, 0.0], reason: 'the source itself is the caller\'s own override, not this function\'s');
      expect(byPath()['b'], [50.0, 50.0, 50.0]);
    });

    test('a nested instance keeps its own rotation relative to its copy when the source turns', () {
      final turned = RigidTransformDto(translation: const [0, 0, 0], rotationAxis: const [0.0, 0.0, 1.0], rotationAngleDegrees: 90.0);
      final out = followPatternCopies(instances, focusPath: const [], patterns: [linear()], liveWorld: {'a': turned});
      final copy = out.firstWhere((i) => i.occurrencePath.join('/') == 'a#pattern:p:1').worldTransform;
      final inner = out.firstWhere((i) => i.occurrencePath.join('/') == 'a#pattern:p:1/inner').worldTransform;
      // the copy is the source turned 90 deg, translated by the step (300, 0, 0) -> the 'inner' offset (5, 2) from the old copy turns with it
      expect(copy.rotationAngleDegrees, closeTo(90.0, 1e-9));
      expect(inner.translation[0], closeTo(300.0 - 2.0, 1e-9));
      expect(inner.translation[1], closeTo(5.0, 1e-9));
    });

    test('no change for a suppressed pattern, a skipped copy, or a source that is not being moved (same list returned)', () {
      expect(identical(followPatternCopies(instances, focusPath: const [], patterns: [linear(suppressed: true)], liveWorld: {'a': at(4, 6, 9)}), instances), isTrue);
      expect(identical(followPatternCopies(instances, focusPath: const [], patterns: [linear()], liveWorld: {'b': at(4, 6, 9)}), instances), isTrue);
      final skipped = followPatternCopies(instances, focusPath: const [], patterns: [linear(skip: [2])], liveWorld: {'a': at(4, 6, 9)});
      expect(skipped.firstWhere((i) => i.occurrencePath.join('/') == 'a#pattern:p:2').worldTransform.translation, [600.0, 0.0, 0.0]);
      expect(skipped.firstWhere((i) => i.occurrencePath.join('/') == 'a#pattern:p:1').worldTransform.translation, [304.0, 6.0, 9.0]);
    });

    test('inside a focused sub-assembly the step is applied in the focused Part\'s frame, not the world\'s', () {
      // the focused instance is turned 90 deg about z and sits at (1000, 0, 0): a copy 300 mm "along x" of the Part is 300 mm along the world y
      final parent = RigidTransformDto(translation: const [1000, 0, 0], rotationAxis: const [0.0, 0.0, 1.0], rotationAngleDegrees: 90.0);
      RigidTransformDto turned90(double x, double y, double z) =>
          RigidTransformDto(translation: [x, y, z], rotationAxis: const [0.0, 0.0, 1.0], rotationAngleDegrees: 90.0);
      final inFocus = [
        inst(['s', 'a'], turned90(1000, 0, 0)),
        inst(['s', 'a#pattern:p:1'], turned90(1000, 300, 0)), // 300 along the Part's x = along the world y
      ];
      final out = followPatternCopies(inFocus,
          focusPath: const ['s'], patterns: [linear()], liveWorld: {'a': turned90(1000, 10, 0)}, parentWorld: parent);
      final copy = out.last.worldTransform.translation;
      expect(copy[0], closeTo(1000.0, 1e-9));
      expect(copy[1], closeTo(310.0, 1e-9));
    });
  });
}
