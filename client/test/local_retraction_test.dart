// Local nearest-point retraction (`docs/motion/projector-spec.md` §4b): the `local_retract` golden vectors, the analytic
// Jacobian against central differences, model parsing and the "never worse" acceptance.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

import 'package:didsa_cad_client/motion/local_retraction.dart';
import 'package:didsa_cad_client/motion/se3.dart';

const String _vectorsPath = '../docs/motion/vectors.json';

List<double> _dl(Object? v) => (v as List).map((x) => (x as num).toDouble()).toList();

Pose _poseIn(Object? j) {
  final m = j as Map<String, dynamic>;
  return Pose.fromWire(
    translation: _dl(m['translation']),
    rotationAxis: _dl(m['rotation_axis']),
    rotationAngleDegrees: (m['rotation_angle_degrees'] as num).toDouble(),
  );
}

Pose _poseOut(Object? j) {
  final m = j as Map<String, dynamic>;
  return Pose(_dl(m['translation']), Mat3(_dl(m['rotation'])));
}

void _expectPose(Pose got, Object? want, String ctx, double tol) {
  final w = _poseOut(want);
  for (var i = 0; i < 3; i++) {
    expect((got.t[i] - w.t[i]).abs(), lessThan(tol), reason: '$ctx t[$i]: ${got.t[i]} vs ${w.t[i]}');
  }
  for (var i = 0; i < 9; i++) {
    expect((got.r.m[i] - w.r.m[i]).abs(), lessThan(tol), reason: '$ctx r[$i]: ${got.r.m[i]} vs ${w.r.m[i]}');
  }
}

void main() {
  final file = File(_vectorsPath);
  if (!file.existsSync()) fail('$_vectorsPath not found (run `flutter test` from client/)');
  final doc = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  final tol = (doc['tolerance'] as num).toDouble();
  final constants = doc['constants'] as Map<String, dynamic>;
  final cases = [
    for (final c in doc['cases'] as List)
      if ((c as Map<String, dynamic>)['kind'] == 'local_retract') c,
  ];

  test('the constants in the file are the ones compiled in', () {
    expect((constants['local_follower'] as num).toDouble(), kLocalFollower);
    expect((constants['local_iters'] as num).toInt(), kLocalIterations);
    expect((constants['local_polish'] as num).toInt(), kLocalPolish);
    expect((constants['local_trust'] as num).toDouble(), kLocalTrust);
    expect((constants['local_rot_cap'] as num).toDouble(), kLocalRotationCap);
    expect((constants['local_lam_abs'] as num).toDouble(), kLocalLambdaAbs);
    expect((constants['local_accept_residual'] as num).toDouble(), kLocalAcceptResidual);
    expect((constants['local_accept_distance'] as num).toDouble(), kLocalAcceptDistance);
    expect(cases.length, greaterThanOrEqualTo(12));
  });

  for (final c in cases) {
    final id = c['id'] as String;
    test('golden: $id', () {
      final inp = c['input'] as Map<String, dynamic>;
      final exp = c['expected'] as Map<String, dynamic>;
      final model = LocalRetractor.tryParse(inp['model'] as Map<String, dynamic>);
      expect(model, isNotNull, reason: 'the model parses');
      final poses = [for (final p in inp['poses'] as List) _poseIn(p)];
      final wishes = [for (final p in inp['wishes'] as List) _poseIn(p)];
      final fallback = [for (final p in inp['fallback_poses'] as List) _poseIn(p)];
      final lever = (inp['lever_arm'] as num).toDouble();
      final r = model!.frame(poses: poses, wishes: wishes, fallback: fallback, lever: lever);
      expect(r.accepted, exp['accepted'], reason: '$id accepted');
      for (var i = 0; i < poses.length; i++) {
        // A NON-converged raw answer (residual far above the acceptance bar) is a sensitive function of the rounding of
        // the linear solve; only converged ones are pinned.
        if ((exp['residual_inf'] as num) <= kLocalAcceptResidual) {
          _expectPose(r.localPoses[i], (exp['local_poses'] as List)[i], '$id local[$i]', tol);
        }
        _expectPose(r.poses[i], (exp['poses'] as List)[i], '$id shown[$i]', tol);
      }
      if ((exp['residual_inf'] as num) <= kLocalAcceptResidual) {
        expect((r.residualInf - (exp['residual_inf'] as num).toDouble()).abs(), lessThan(tol), reason: '$id residual');
        expect((r.fallbackDistance - (exp['fallback_distance'] as num).toDouble()).abs(), lessThan(tol), reason: '$id distance');
      } else {
        expect(r.residualInf, greaterThan(kLocalAcceptResidual), reason: '$id stays non-converged');
      }
    });

    test('analytic Jacobian = central differences at the start and at the answer: $id', () {
      final inp = c['input'] as Map<String, dynamic>;
      final model = LocalRetractor.tryParse(inp['model'] as Map<String, dynamic>)!;
      final start = [for (final p in inp['poses'] as List) _poseIn(p)];
      final wishes = [for (final p in inp['wishes'] as List) _poseIn(p)];
      final w = localScale(model.members, (inp['lever_arm'] as num).toDouble());
      for (final poses in <List<Pose>>[start, model.retract(start, wishes, w)]) {
        final jac = model.jacobian(poses);
        const h = 1e-6;
        for (var col = 0; col < 6 * model.members; col++) {
          final e = List<double>.filled(6 * model.members, 0);
          e[col] = h;
          final plus = [for (var i = 0; i < poses.length; i++) applyDelta(poses[i], e, 6 * i)];
          for (var k = 0; k < e.length; k++) {
            e[k] = -e[k];
          }
          final minus = [for (var i = 0; i < poses.length; i++) applyDelta(poses[i], e, 6 * i)];
          final rp = model.residual(plus), rm = model.residual(minus);
          for (var row = 0; row < rp.length; row++) {
            final fd = (rp[row] - rm[row]) / (2 * h);
            expect((jac[row][col] - fd).abs(), lessThan(1e-6 * (1 + fd.abs())), reason: '$id J[$row][$col]');
          }
        }
      }
    });
  }

  group('model parsing', () {
    Map<String, dynamic> base() => jsonDecode(jsonEncode((cases.first['input'] as Map<String, dynamic>)['model'])) as Map<String, dynamic>;

    test('a valid model parses', () => expect(LocalRetractor.tryParse(base()), isNotNull));
    test('null, another version, an unknown mate type, a missing side field or an out-of-range member -> projection only', () {
      expect(LocalRetractor.tryParse(null), isNull);
      expect(LocalRetractor.tryParse(base()..['version'] = 2), isNull);
      final unknown = base();
      ((unknown['mates'] as List).first as Map<String, dynamic>)['type'] = 'gear';
      expect(LocalRetractor.tryParse(unknown), isNull);
      final missing = base();
      (((missing['mates'] as List).first as Map<String, dynamic>)['a'] as Map<String, dynamic>).remove('axis_origin');
      expect(LocalRetractor.tryParse(missing), isNull);
      final badMember = base();
      (((badMember['mates'] as List).first as Map<String, dynamic>)['a'] as Map<String, dynamic>)['member'] = 5;
      expect(LocalRetractor.tryParse(badMember), isNull);
    });
    test('groups bigger than the limit are not solved locally', () {
      expect(LocalRetractor.tryParse(base(), maxMembers: 0), isNull);
      final big = base()..['members'] = List<String>.generate(kLocalMaxMembers + 1, (i) => 'm$i');
      expect(LocalRetractor.tryParse(big), isNull);
    });
  });

  test('a long drag stays on the manifold: 60 frames of a 40 degree turn on the off-axis pin', () {
    final c = cases.firstWhere((x) => x['id'] == 'local-swing-offset-pin-4deg');
    final inp = c['input'] as Map<String, dynamic>;
    final model = LocalRetractor.tryParse(inp['model'] as Map<String, dynamic>)!;
    final lever = (inp['lever_arm'] as num).toDouble();
    var shown = [for (final p in inp['poses'] as List) _poseIn(p)];
    final start = shown.first;
    var worst = 0.0;
    for (var f = 1; f <= 60; f++) {
      final wish = applyDelta(start, <double>[0, 0, 0, 0, 0, 40.0 * math.pi / 180 * f / 60]);
      final r = model.frame(poses: shown, wishes: [wish], fallback: shown, lever: lever);
      expect(r.accepted, isTrue, reason: 'frame $f: ${r.residualInf} ${r.fallbackDistance}');
      worst = math.max(worst, r.residualInf);
      shown = r.poses;
    }
    expect(worst, lessThan(1e-6));
  });

  localBenchmark();
}

// Cost of one local frame (3 iterations + polish, Jacobians included). Printed, only loosely asserted: `flutter test` runs the
// JIT in debug mode, a release/AOT build is several times faster.
void localBenchmark() {
  final doc = jsonDecode(File(_vectorsPath).readAsStringSync()) as Map<String, dynamic>;
  for (final id in const ['local-bolt-pull-off-and-spin', 'local-floating-bolt-slide-and-spin']) {
    test('cost per local frame: $id', () {
      final c = (doc['cases'] as List).cast<Map<String, dynamic>>().firstWhere((x) => x['id'] == id);
      final inp = c['input'] as Map<String, dynamic>;
      final model = LocalRetractor.tryParse(inp['model'] as Map<String, dynamic>)!;
      final poses = [for (final p in inp['poses'] as List) _poseIn(p)];
      final wishes = [for (final p in inp['wishes'] as List) _poseIn(p)];
      final lever = (inp['lever_arm'] as num).toDouble();
      for (var i = 0; i < 200; i++) {
        model.frame(poses: poses, wishes: wishes, fallback: poses, lever: lever);
      }
      final sw = Stopwatch()..start();
      const n = 2000;
      for (var i = 0; i < n; i++) {
        model.frame(poses: poses, wishes: wishes, fallback: poses, lever: lever);
      }
      final us = sw.elapsedMicroseconds / n;
      // ignore: avoid_print
      print('local frame $id: members=${model.members} rows=${model.rows} -> ${us.toStringAsFixed(1)} us/frame (JIT, debug)');
      expect(us, lessThan(5000), reason: 'a frame must stay far below a 16 ms budget');
    });
  }
}
