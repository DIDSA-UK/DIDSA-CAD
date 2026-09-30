// Golden vectors for the free-motion projector
// (`docs/motion/projector-spec.md` §15, `docs/motion/vectors.json`).
//
// The same JSON gates the GDScript port in DIDSA-VR. It is read from the repo
// root so a regenerated file is picked up; nothing is copied or forked here.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

import 'package:didsa_cad_client/motion/anchor_acceptance.dart';
import 'package:didsa_cad_client/motion/dof_hysteresis.dart';
import 'package:didsa_cad_client/motion/free_motion_projector.dart';
import 'package:didsa_cad_client/motion/motion_blender.dart';
import 'package:didsa_cad_client/motion/reanchor_scheduler.dart';
import 'package:didsa_cad_client/motion/se3.dart';
import 'package:didsa_cad_client/motion/weighted_basis.dart';

const String _vectorsPath = '../docs/motion/vectors.json';

late Map<String, dynamic> _doc;
late double _tol;

List<double> _dl(Object? v) => (v as List).map((x) => (x as num).toDouble()).toList();
List<List<double>> _dll(Object? v) => (v as List).map(_dl).toList();

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

/// Poses are compared as translation + matrix, never axis-angle.
void _expectPose(Pose got, Object? want, String ctx) {
  final w = _poseOut(want);
  for (var i = 0; i < 3; i++) {
    expect((got.t[i] - w.t[i]).abs(), lessThan(_tol), reason: '$ctx t[$i]: ${got.t[i]} vs ${w.t[i]}');
  }
  for (var i = 0; i < 9; i++) {
    expect((got.r.m[i] - w.r.m[i]).abs(), lessThan(_tol), reason: '$ctx r[$i]: ${got.r.m[i]} vs ${w.r.m[i]}');
  }
}

void _expectNum(num? got, Object? want, String ctx) {
  if (want == null) {
    expect(got, isNull, reason: ctx);
    return;
  }
  expect(got, isNotNull, reason: ctx);
  expect((got!.toDouble() - (want as num).toDouble()).abs(), lessThan(_tol), reason: '$ctx: $got vs $want');
}

void _expectRows(List<List<double>> got, Object? want, String ctx) {
  final w = _dll(want);
  expect(got.length, w.length, reason: '$ctx row count');
  for (var r = 0; r < w.length; r++) {
    expect(got[r].length, w[r].length, reason: '$ctx row $r width');
    for (var c = 0; c < w[r].length; c++) {
      expect((got[r][c] - w[r][c]).abs(), lessThan(_tol), reason: '$ctx [$r][$c]: ${got[r][c]} vs ${w[r][c]}');
    }
  }
}

// ---- swing sequence scene helpers (the off-axis concentric pin; mirrors generate.py) ----
const double _cx = 15.0;
double _rad(double deg) => deg * math.pi / 180.0;

Pose _concPose(double thetaDeg, double z) {
  final th = _rad(thetaDeg);
  return Pose(<double>[-_cx * math.cos(th), -_cx * math.sin(th), z], rotFromRotvec(<double>[0, 0, th]));
}

List<List<double>> _concRows(Pose p) => <List<double>>[
      <double>[0, 0, 1, 0, 0, 0],
      <double>[-p.t[1], p.t[0], 0, 0, 0, 1],
    ];

double _concViolation(Pose p) {
  final q = p.r.mulVec(<double>[_cx, 0, 0]);
  return math.sqrt(math.pow(q[0] + p.t[0], 2) + math.pow(q[1] + p.t[1], 2));
}

Map<String, dynamic> _runSequence(Map<String, dynamic> inp, Pose Function(int f, Pose w) anchorOf) {
  final hand = (inp['hand'] as List).map(_poseIn).toList();
  final lever = (inp['lever_arm'] as num).toDouble();
  final every = (inp['reanchor_every'] as num).toInt();
  final screw = <Pose>[], blended = <Pose>[], additive = <Pose>[];
  final blender = MotionBlender(1, tauFrames: (inp['tau_frames'] as num).toDouble());
  FreeMotionProjector? model;
  final anchors = <Pose>[];
  var violS = 0.0, violA = 0.0;
  for (var f = 0; f < hand.length; f++) {
    final w = hand[f];
    if (f % every == 0) {
      final newRef = anchorOf(f, w);
      final next = FreeMotionProjector.fromAnchor(refs: [newRef], basis: _concRows(newRef), lever: lever);
      if (model != null) blender.onAnchor(model.project(w), next.project(w));
      model = next;
      anchors.add(newRef);
    }
    final s = model!.project(w);
    final a = model.project(w, integrator: MotionIntegrator.additive);
    screw.add(s[0]);
    additive.add(a[0]);
    blended.add(blender.shown(s)[0]);
    violS = math.max(violS, _concViolation(s[0]));
    violA = math.max(violA, _concViolation(a[0]));
  }

  double steps(List<Pose> seq) {
    var m = 0.0;
    for (var k = 1; k < seq.length; k++) {
      m = math.max(m, weightedDist(seq[k], seq[k - 1], lever));
    }
    return m;
  }

  var maxAnchor = 0.0;
  for (var k = 1; k < anchors.length; k++) {
    maxAnchor = math.max(maxAnchor, weightedDist(anchors[k], anchors[k - 1], lever));
  }
  var maxHandInterval = 0.0;
  for (var k = every; k < hand.length; k++) {
    maxHandInterval = math.max(maxHandInterval, weightedDist(hand[k], hand[k - every], lever));
  }
  return {
    'screw': screw,
    'screw_blended': blended,
    'additive': additive,
    'summary': <String, double>{
      'max_anchor_step_per_interval': maxAnchor,
      'max_hand_step_per_interval': maxHandInterval,
      'max_frame_step_hand': steps(hand),
      'max_frame_step_screw': steps(screw),
      'max_frame_step_screw_blended': steps(blended),
      'max_frame_step_additive': steps(additive),
      'max_violation_screw_mm': violS,
      'max_violation_additive_mm': violA,
    },
  };
}

void main() {
  setUpAll(() {
    final f = File(_vectorsPath);
    if (!f.existsSync()) {
      fail('$_vectorsPath not found (run `flutter test` from client/, the vectors live at docs/motion/vectors.json)');
    }
    _doc = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
    _tol = (_doc['tolerance'] as num).toDouble();
  });

  List<Map<String, dynamic>> cases(String kind) =>
      (_doc['cases'] as List).cast<Map<String, dynamic>>().where((c) => c['kind'] == kind).toList();

  group('vectors file', () {
    test('every kind in the file has a runner in this test', () {
      const handled = {
        'gram_schmidt', 'project', 'hysteresis', 'blend', 'blend_anchor', 'scheduler', 'accept_anchor', 'swing_sequence',
      };
      final kinds = (_doc['cases'] as List).map((c) => (c as Map)['kind'] as String).toSet();
      expect(kinds.difference(handled), isEmpty, reason: 'new vector kind without a Dart runner');
      expect(handled.difference(kinds), isEmpty, reason: 'runner without vectors');
      expect(_tol, 1e-9);
    });

    test('Dart constants equal the vectors constants', () {
      final c = _doc['constants'] as Map<String, dynamic>;
      expect(kFollowerWeight, c['follower_weight']);
      expect(kGramSchmidtDropRelative, c['gram_schmidt_drop_relative']);
      expect(kGramSchmidtDropAbsolute, c['gram_schmidt_drop_absolute']);
      expect(kBlendTauFrames, c['tau_frames']);
      expect(kResidualTol, c['residual_tol']);
      expect(kJumpRejectFactor, c['jump_reject_factor']);
      expect(kReanchorMs, c['reanchor_ms']);
      expect(kReanchorMsNearSingular, c['reanchor_ms_near_singular']);
      expect(kSigmaGapLow, c['sigma_gap_low']);
      expect(kHysteresisGainMin, c['gain_min']);
      expect(kHysteresisGainFrames, c['gain_frames']);
    });
  });

  group('gram_schmidt', () {
    test('all cases', () {
      final cs = cases('gram_schmidt');
      expect(cs, isNotEmpty);
      for (final c in cs) {
        final i = c['input'] as Map<String, dynamic>;
        final s = memberScale((i['members'] as num).toInt(), (i['lever_arm'] as num).toDouble(),
            follower: (i['follower_weight'] as num).toDouble());
        final u = weightedGramSchmidt(_dll(i['rows']), s);
        final e = c['expected'] as Map<String, dynamic>;
        expect(u.length, e['kept'], reason: c['id'] as String);
        _expectRows(u, e['rows'], c['id'] as String);
      }
    });
  });

  group('project', () {
    test('all cases (screw integrator, member poses as matrices)', () {
      final cs = cases('project');
      expect(cs, isNotEmpty);
      for (final c in cs) {
        final i = c['input'] as Map<String, dynamic>;
        final refs = (i['refs'] as List).map(_poseIn).toList();
        final p = FreeMotionProjector.fromAnchor(
          refs: refs,
          basis: _dll(i['basis']),
          lever: (i['lever_arm'] as num).toDouble(),
          followerWeight: (i['follower_weight'] as num).toDouble(),
        );
        final e = c['expected'] as Map<String, dynamic>;
        final id = c['id'] as String;
        expect(p.dim, e['orthonormal_dim'], reason: '$id dim');
        final got = p.project(_poseIn(i['wanted']));
        final want = e['members'] as List;
        expect(got.length, want.length, reason: id);
        for (var m = 0; m < want.length; m++) {
          _expectPose(got[m], want[m], '$id member $m');
        }
        // additive_members is informational in the spec, but the integrator is part of the port: pin it too.
        final add = p.project(_poseIn(i['wanted']), integrator: MotionIntegrator.additive);
        for (var m = 0; m < want.length; m++) {
          _expectPose(add[m], (e['additive_members'] as List)[m], '$id additive member $m');
        }
      }
    });
  });

  group('hysteresis', () {
    test('all cases', () {
      final cs = cases('hysteresis');
      expect(cs, isNotEmpty);
      for (final c in cs) {
        final i = c['input'] as Map<String, dynamic>;
        final lever = (i['lever_arm'] as num).toDouble();
        final h = DofHysteresis();
        final want = (c['expected'] as Map<String, dynamic>)['frames'] as List;
        final frames = i['frames'] as List;
        for (var f = 0; f < frames.length; f++) {
          final fr = frames[f] as Map<String, dynamic>;
          final ctx = '${c['id']} frame $f';
          final w = want[f] as Map<String, dynamic>;
          final anchor = fr['anchor'];
          if (anchor != null) {
            final a = anchor as Map<String, dynamic>;
            final ev = h.onAnchor(FreeMotionProjector.fromAnchor(
                refs: [_poseIn(a['ref'])], basis: _dll(a['rows']), lever: lever));
            expect(ev.name, w['anchor_event'], reason: '$ctx anchor_event');
          } else {
            expect(w['anchor_event'], isNull, reason: '$ctx anchor_event');
          }
          final out = h.frame(_poseIn(fr['wish']));
          _expectNum(out.gain, w['gain'], '$ctx gain');
          expect(out.event, w['event'], reason: '$ctx event');
          expect(h.count, w['count'], reason: '$ctx count');
          expect(h.dim, w['dim'], reason: '$ctx dim');
          _expectPose(out.poses[0], w['projected'], ctx);
        }
      }
    });
  });

  group('blend', () {
    test('all cases', () {
      final cs = cases('blend');
      expect(cs, isNotEmpty);
      for (final c in cs) {
        final i = c['input'] as Map<String, dynamic>;
        final b = MotionBlender((i['offsets'] as List).length, tauFrames: (i['tau_frames'] as num).toDouble());
        b.setOffsets(_dll(i['offsets']));
        final want = (c['expected'] as Map<String, dynamic>)['shown'] as List;
        final proj = i['projected'] as List;
        for (var f = 0; f < proj.length; f++) {
          final got = b.shown((proj[f] as List).map(_poseIn).toList());
          for (var m = 0; m < got.length; m++) {
            _expectPose(got[m], (want[f] as List)[m], '${c['id']} frame $f member $m');
          }
        }
      }
    });

    test('blend_anchor: continuity at the anchor, then decay onto the new projection', () {
      final cs = cases('blend_anchor');
      expect(cs, isNotEmpty);
      for (final c in cs) {
        final i = c['input'] as Map<String, dynamic>;
        final b = MotionBlender(1, tauFrames: (i['tau_frames'] as num).toDouble());
        final anchorFrame = (i['anchor_frame'] as num).toInt();
        final olds = (i['old_projected'] as List).map(_poseIn).toList();
        final news = (i['new_projected'] as List).map(_poseIn).toList();
        final want = (c['expected'] as Map<String, dynamic>)['shown'] as List;
        for (var f = 0; f < olds.length; f++) {
          if (f < anchorFrame) {
            _expectPose(b.shown([olds[f]])[0], want[f], '${c['id']} frame $f');
          } else {
            if (f == anchorFrame) b.onAnchor([olds[f]], [news[f]]);
            _expectPose(b.shown([news[f]])[0], want[f], '${c['id']} frame $f');
          }
        }
      }
    });
  });

  group('scheduler', () {
    test('all cases (pure decision)', () {
      final cs = cases('scheduler');
      expect(cs, isNotEmpty);
      for (final c in cs) {
        final i = c['input'] as Map<String, dynamic>;
        final d = needsReanchor(
          nowMs: (i['now_ms'] as num).toDouble(),
          anchorMs: (i['anchor_ms'] as num).toDouble(),
          travel: (i['travel'] as num).toDouble(),
          maxStep: (i['max_step'] as num?)?.toDouble(),
          sigmaGap: (i['sigma_gap'] as num?)?.toDouble(),
          inFlight: i['in_flight'] as bool,
        );
        final e = c['expected'] as Map<String, dynamic>;
        expect(d.reanchor, e['reanchor'], reason: c['id'] as String);
        expect(d.reason, e['reason'], reason: c['id'] as String);
      }
    });
  });

  group('accept_anchor', () {
    test('all cases', () {
      final cs = cases('accept_anchor');
      expect(cs, isNotEmpty);
      for (final c in cs) {
        final i = c['input'] as Map<String, dynamic>;
        final d = acceptAnchor(
          converged: i['converged'] as bool,
          residualInf: (i['residual_inf'] as num).toDouble(),
          anchorGrabbed: _poseIn(i['grabbed_transform']),
          ownProjection: i['own_projection'] == null ? null : _poseIn(i['own_projection']),
          lever: (i['lever_arm'] as num).toDouble(),
        );
        final e = c['expected'] as Map<String, dynamic>;
        expect(d.accept, e['accept'], reason: c['id'] as String);
        expect(d.reason, e['reason'], reason: c['id'] as String);
        _expectNum(d.clientJump, e['client_jump'], '${c['id']} client_jump');
      }
    });
  });

  group('swing_sequence', () {
    test('all cases: per-frame poses and summary numbers', () {
      final cs = cases('swing_sequence');
      expect(cs, isNotEmpty);
      for (final c in cs) {
        final i = c['input'] as Map<String, dynamic>;
        final e = c['expected'] as Map<String, dynamic>;
        final every = (i['reanchor_every'] as num).toInt();
        // Both anchor series are DATA in the vectors (spin angle per re-anchor): nothing is recomputed here.
        final nearestTheta = _dl(i['nearest_anchor_theta_deg']);
        final backendTheta = _dl(i['backend_anchor_theta_deg']);
        final runs = <String, Map<String, dynamic>>{
          'nearest_anchors': _runSequence(i, (f, w) => _concPose(nearestTheta[f ~/ every], w.t[2])),
          'backend_anchors': _runSequence(i, (f, w) => _concPose(backendTheta[f ~/ every], w.t[2])),
        };
        for (final name in runs.keys) {
          final got = runs[name]!;
          final want = e[name] as Map<String, dynamic>;
          for (final series in const ['screw', 'screw_blended', 'additive']) {
            final g = got[series] as List<Pose>;
            final w = want[series] as List;
            expect(g.length, w.length, reason: '$name $series length');
            for (var f = 0; f < w.length; f++) {
              _expectPose(g[f], w[f], '$name $series frame $f');
            }
          }
          final gs = got['summary'] as Map<String, double>;
          final ws = want['summary'] as Map<String, dynamic>;
          for (final k in ws.keys) {
            _expectNum(gs[k], ws[k], '$name summary.$k');
          }
        }
      }
    });
  });
}
