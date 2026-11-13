// The drag session with a version-8 `constraint_model` (rigid sets): the anchor lists EVERY member, the model only the sets' leads. The fake
// backend is the off-axis pin of constrained_drag_local_test.dart with a `cover` bolted to the pin (a follower 50 mm along the pin's x).
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

import 'package:didsa_cad_client/api/document_api_client.dart';
import 'package:didsa_cad_client/motion/constrained_drag_session.dart';
import 'package:didsa_cad_client/motion/local_retraction.dart';
import 'package:didsa_cad_client/motion/mate_motion_bridge.dart';
import 'package:didsa_cad_client/motion/se3.dart';

const double _lever = 10.0;
const double _cx = 15.0;
const List<double> _offT = <double>[50, 0, 0];

Map<String, dynamic> _model() => <String, dynamic>{
      'version': kLocalRigidModelVersion,
      'members': <String>['pin'],
      'rigid_sets': <Map<String, dynamic>>[
        <String, dynamic>{
          'member': 0,
          'followers': <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 'cover',
              'r': <List<double>>[<double>[1, 0, 0], <double>[0, 1, 0], <double>[0, 0, 1]],
              't': _offT,
            },
          ],
        },
      ],
      'mates': <Map<String, dynamic>>[
        <String, dynamic>{
          'type': 'concentric',
          'value': null,
          'allow_rotation': true,
          'alignment': 1,
          'side': 1,
          'perp': 1,
          'a': <String, dynamic>{'member': 0, 'axis_origin': <double>[_cx, 0, 0], 'direction': <double>[0, 0, 1]},
          'b': <String, dynamic>{'member': -1, 'axis_origin': <double>[0, 0, 0], 'direction': <double>[0, 0, 1]},
        },
      ],
    };

Pose _onPin(double theta, double z) {
  final r = rotFromRotvec(<double>[0, 0, theta]);
  final p = r.mulVec(<double>[_cx, 0, 0]);
  return Pose(<double>[-p[0], -p[1], z], r);
}

Pose _cover(Pose pin) {
  final o = pin.r.mulVec(_offT);
  return Pose(<double>[pin.t[0] + o[0], pin.t[1] + o[1], pin.t[2] + o[2]], pin.r);
}

class _Fake {
  _Fake();
  Pose stored = _onPin(0, 30);
  final List<bool> modelRequested = <bool>[];

  Future<MateMotionDto> call(
    String partId,
    String occId, {
    RigidTransformDto? transform,
    double? leverArm,
    bool commit = false,
    List<MateMotionMemberDto>? reference,
    bool includeConstraintModel = true,
  }) async {
    modelRequested.add(includeConstraintModel);
    Pose at = stored;
    if (transform != null) {
      final wish = poseOfDto(transform);
      final from = reference == null ? stored : poseOfDto(reference.first.transform);
      at = LocalRetractor.tryParse(_model())!.retract(<Pose>[from], <Pose>[wish], localScale(1, _lever), iterations: 40, polish: 3).first;
    }
    if (commit) stored = at;
    final cover = _cover(at);
    // free motion: spin about the world z axis, slide along z; a follower's block is its lead's twist moved to its own origin
    final spin = <double>[-at.t[1], at.t[0], 0, 0, 0, 1, -cover.t[1], cover.t[0], 0, 0, 0, 1];
    final slide = <double>[0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 0, 0];
    return MateMotionDto(
      converged: true,
      dof: 2,
      grounded: true,
      members: <MateMotionMemberDto>[
        MateMotionMemberDto(occurrenceId: 'pin', transform: dtoOfPose(at), mobility: 2),
        MateMotionMemberDto(occurrenceId: 'cover', transform: dtoOfPose(cover), mobility: 2),
      ],
      basis: <List<double>>[spin, slide],
      chart: const MateMotionChartDto(kind: 'se3_owner_frame', leverArm: _lever),
      quality: const MateMotionQualityDto(residualInf: 1e-12, sigmaGap: 1e4),
      committed: commit,
      constraintModel: includeConstraintModel ? _model() : null,
    );
  }
}

class _Clock {
  double now = 0;
  double call() => now;
}

void main() {
  test('a version-8 drag runs locally: leads and followers both drawn, on the mates, the follower rigid with the pin', () async {
    final api = _Fake();
    final clock = _Clock();
    final s = ConstrainedDragSession(call: api.call, partId: 'root', grabbedId: 'pin', leverArm: _lever, nowMs: clock.call);
    await s.begin();
    final retractor = LocalRetractor.tryParse(_model())!;
    final start = _onPin(0, 30);
    var worst = 0.0, worstRigid = 0.0;
    var frames = 0;
    for (var f = 1; f <= 120; f++) {
      clock.now += 1000 / 60;
      final wish = applyDelta(start, <double>[0, 0, 0, 0, 0, 70.0 * math.pi / 180 * f / 120]);
      final fr = s.update(wish);
      if (fr != null) {
        frames++;
        expect(fr.ids, ['pin', 'cover']);
        expect(fr.poses.length, 2);
        worst = math.max(worst, retractor.residualInf(<Pose>[fr.poses[0]]));
        final want = _cover(fr.poses[0]);
        for (var i = 0; i < 3; i++) {
          worstRigid = math.max(worstRigid, (fr.poses[1].t[i] - want.t[i]).abs());
        }
        for (var i = 0; i < 9; i++) {
          worstRigid = math.max(worstRigid, (fr.poses[1].r.m[i] - want.r.m[i]).abs());
        }
      }
      await Future<void>.delayed(Duration.zero);
    }
    expect(frames, greaterThan(100));
    expect(worst, lessThan(1e-5), reason: 'every frame satisfies the pin mate');
    expect(worstRigid, lessThan(1e-9), reason: 'the follower is its lead times the offset in every frame');
    expect(s.counters.localAccepted, greaterThan(50), reason: 'the local retraction ran (before M2 a version-8 model made the session project)');
    expect(s.counters.localFallbacks, 0);
    expect(s.counters.anchorsRejectedTotal, 0);
    expect(s.counters.holds, 0);
  });

  test('the model is requested once, then kept: later answers omit it and the drag still runs locally', () async {
    final api = _Fake();
    final clock = _Clock();
    final s = ConstrainedDragSession(call: api.call, partId: 'root', grabbedId: 'pin', leverArm: _lever, nowMs: clock.call);
    await s.begin();
    final start = _onPin(0, 30);
    for (var f = 1; f <= 60; f++) {
      clock.now += 1000 / 60;
      s.update(applyDelta(start, <double>[0, 0, 0, 0, 0, 30.0 * math.pi / 180 * f / 60]));
      await Future<void>.delayed(Duration.zero);
    }
    expect(api.modelRequested.first, isTrue);
    expect(api.modelRequested.skip(1).every((x) => !x), isTrue);
    expect(s.counters.localAccepted, greaterThan(30));
  });

  test('a model whose leads and followers are not exactly the anchor\'s members is not used (the session projects)', () async {
    // an anchor with one more member than the model knows: projected, never retracted locally
    final fake = _Fake();
    Future<MateMotionDto> extra(String p, String o,
        {RigidTransformDto? transform, double? leverArm, bool commit = false, List<MateMotionMemberDto>? reference, bool includeConstraintModel = true}) async {
      final r = await fake.call(p, o, transform: transform, leverArm: leverArm, commit: commit, reference: reference, includeConstraintModel: includeConstraintModel);
      return MateMotionDto(
        converged: true,
        dof: r.dof,
        grounded: true,
        members: <MateMotionMemberDto>[...r.members, MateMotionMemberDto(occurrenceId: 'stranger', transform: dtoOfPose(_onPin(0, 0)), mobility: 0)],
        basis: <List<double>>[for (final row in r.basis!) <double>[...row, 0, 0, 0, 0, 0, 0]],
        chart: r.chart,
        quality: r.quality,
        committed: commit,
        constraintModel: r.constraintModel,
      );
    }

    final clock = _Clock();
    final s = ConstrainedDragSession(call: extra, partId: 'root', grabbedId: 'pin', leverArm: _lever, nowMs: clock.call);
    await s.begin();
    final start = _onPin(0, 30);
    for (var f = 1; f <= 30; f++) {
      clock.now += 1000 / 60;
      s.update(applyDelta(start, <double>[0, 0, 0, 0, 0, 10.0 * math.pi / 180 * f / 30]));
      await Future<void>.delayed(Duration.zero);
    }
    expect(s.counters.localAccepted, 0);
  });
}
