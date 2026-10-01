// The session with the local nearest-point retraction (`docs/motion/projector-spec.md` §4b): a fake `mate-motion` backend for the
// off-axis pin (the CURVED mate: the part's own origin is 15 mm off the pin's axis) that also sends the `constraint_model`.
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

import 'package:didsa_cad_client/api/document_api_client.dart';
import 'package:didsa_cad_client/motion/constrained_drag_session.dart';
import 'package:didsa_cad_client/motion/local_retraction.dart';
import 'package:didsa_cad_client/motion/mate_motion_bridge.dart';
import 'package:didsa_cad_client/motion/se3.dart';

const double _lever = 10.0;
const double _cx = 15.0;

Map<String, dynamic> _model() => <String, dynamic>{
      'version': 1,
      'members': <String>['pin'],
      'mates': <Map<String, dynamic>>[
        <String, dynamic>{
          'type': 'concentric',
          'value': null,
          'allow_rotation': true,
          'a': <String, dynamic>{'member': 0, 'axis_origin': <double>[_cx, 0, 0], 'direction': <double>[0, 0, 1]},
          'b': <String, dynamic>{'member': -1, 'axis_origin': <double>[0, 0, 0], 'direction': <double>[0, 0, 1]},
        },
      ],
    };

/// On the pin: rotation `theta` about the part's z, origin at `-R (cx,0,0)` so the part's axis point lies on the world z axis.
Pose _onPin(double theta, double z) {
  final r = rotFromRotvec(<double>[0, 0, theta]);
  final p = r.mulVec(<double>[_cx, 0, 0]);
  return Pose(<double>[-p[0], -p[1], z], r);
}

class _Pin {
  _Pin({this.sendModel = true, this.riseAfterCalls});

  /// After this many calls the answer's basis gains a direction (a dof rise: the hysteresis adopts it after 3 frames of real gain).
  final int? riseAfterCalls;

  final bool sendModel;
  Pose stored = _onPin(0, 30);
  int calls = 0;
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
    calls++;
    modelRequested.add(includeConstraintModel);
    Pose at = stored;
    if (transform != null) {
      // an ON-manifold answer for the wish: its spin angle and height (not the nearest point, which does not matter here)
      final wish = poseOfDto(transform);
      // the weighted-nearest on-manifold pose, like the real backend after F1b
      final from = reference == null ? stored : poseOfDto(reference.first.transform);
      at = LocalRetractor.tryParse(_model())!.retract(<Pose>[from], <Pose>[wish], localScale(1, _lever), iterations: 40, polish: 3).first;
    }
    if (commit) stored = at;
    // free motion at `at`: spin about the world z axis through the origin, slide along z (raw twists, spatial left chart)
    final t = at.t;
    final spin = <double>[-t[1], t[0], 0, 0, 0, 1];
    final slide = <double>[0, 0, 1, 0, 0, 0];
    return MateMotionDto(
      converged: true,
      dof: 2,
      grounded: true,
      members: <MateMotionMemberDto>[MateMotionMemberDto(occurrenceId: 'pin', transform: dtoOfPose(at), mobility: 2)],
      basis: <List<double>>[spin, slide, if (riseAfterCalls != null && calls > riseAfterCalls!) <double>[1, 0, 0, 0, 0, 0]],
      chart: const MateMotionChartDto(kind: 'se3_owner_frame', leverArm: _lever),
      quality: const MateMotionQualityDto(residualInf: 1e-12, sigmaGap: 1e4),
      committed: commit,
      constraintModel: sendModel && includeConstraintModel ? _model() : null,
    );
  }
}

class _Clock {
  double now = 0;
  double call() => now;
}

Future<({double worst, ConstrainedDragSession session})> _drag({required bool local, bool sendModel = true}) async {
  final api = _Pin(sendModel: sendModel);
  final clock = _Clock();
  final s = ConstrainedDragSession(
    call: api.call,
    partId: 'root',
    grabbedId: 'pin',
    leverArm: _lever,
    nowMs: clock.call,
    useLocalRetraction: local,
  );
  await s.begin();
  final retractor = LocalRetractor.tryParse(_model())!;
  final start = _onPin(0, 30);
  var worst = 0.0;
  for (var f = 1; f <= 120; f++) {
    clock.now += 1000 / 60;
    // the hand turns the part about its OWN origin (not about the pin): the wish is off the manifold by up to ~15 mm
    final wish = applyDelta(start, <double>[0, 0, 0, 0, 0, 70.0 * math.pi / 180 * f / 120]);
    final fr = s.update(wish);
    if (fr != null) worst = math.max(worst, retractor.residualInf(fr.poses));
    await Future<void>.delayed(Duration.zero);
  }
  return (worst: worst, session: s);
}

void main() {
  test('with a constraint model every drawn frame satisfies the mates; the projector alone drifts off between anchors', () async {
    final withLocal = await _drag(local: true);
    final without = await _drag(local: false);
    // ignore: avoid_print
    print('residual_max local=${withLocal.worst.toStringAsExponential(2)} projector=${without.worst.toStringAsExponential(2)} '
        '| ${withLocal.session.counters.logLine()}');
    expect(withLocal.worst, lessThan(1e-5), reason: 'the retraction keeps every frame on the mate');
    expect(without.worst, greaterThan(1e-4), reason: 'the linearised projection drifts off between anchors (what F1 removes; here the pin orbit is a screw, so only ~1e-3)');
    expect(withLocal.session.counters.localAccepted, greaterThan(50));
    expect(withLocal.session.counters.localFallbacks, 0);
    expect(withLocal.session.counters.anchorsRejectedTotal, 0, reason: 'anchors are measured against the local answer, which agrees with the nearest-point anchor');
    expect(withLocal.session.counters.holds, 0);
    expect(withLocal.session.counters.localResidualMax, lessThan(1e-6));
    expect(without.session.counters.localAccepted, 0);
  });

  test('the constraint model is requested once per drag, then kept (later answers omit it) and the drag still runs locally', () async {
    final api = _Pin();
    final clock = _Clock();
    final s = ConstrainedDragSession(call: api.call, partId: 'root', grabbedId: 'pin', leverArm: _lever, nowMs: clock.call);
    await s.begin();
    final start = _onPin(0, 30);
    for (var f = 1; f <= 60; f++) {
      clock.now += 1000 / 60;
      s.update(applyDelta(start, <double>[0, 0, 0, 0, 0, 0.5 * f / 60]));
      await Future<void>.delayed(Duration.zero);
    }
    expect(api.modelRequested.first, isTrue, reason: 'the grab anchor asks for the model');
    expect(api.modelRequested.skip(1), everyElement(isFalse), reason: 'later anchors do not');
    expect(api.modelRequested.length, greaterThan(3));
    expect(s.counters.localAccepted, greaterThan(40));
    expect(s.counters.localFallbacks, 0);
  });

  test('no constraint_model in the answer: the projector is used and nothing is counted as local', () async {
    final r = await _drag(local: true, sendModel: false);
    expect(r.session.counters.localAccepted + r.session.counters.localFallbacks, 0);
    expect(r.worst, greaterThan(1e-4));
  });

  test('the local frame step is smaller than the projector\'s anchor pop: shown steps stay near the hand step', () async {
    final a = await _drag(local: true);
    final b = await _drag(local: false);
    // ignore: avoid_print
    print('max shown step local=${a.session.counters.maxShownStep.toStringAsFixed(3)} projector=${b.session.counters.maxShownStep.toStringAsFixed(3)}');
    expect(a.session.counters.maxShownStep, lessThanOrEqualTo(b.session.counters.maxShownStep + 1e-9));
  });

  wallTests();

  test('a dof rise (hysteresis adopts a new direction) mid-drag: the adoption frame is drawn from the projector, nothing breaks', () async {
    final api = _Pin(riseAfterCalls: 3);
    final clock = _Clock();
    final s = ConstrainedDragSession(call: api.call, partId: 'root', grabbedId: 'pin', leverArm: _lever, nowMs: clock.call);
    await s.begin();
    final start = _onPin(0, 30);
    var frames = 0;
    for (var f = 1; f <= 120; f++) {
      clock.now += 1000 / 60;
      // the hand also slides along x, which only the NEW direction can follow
      final fr = s.update(applyDelta(start, <double>[f * 0.2, 0, 0, 0, 0, 0.4 * f / 120]));
      if (fr != null) {
        frames++;
        for (final p in fr.poses) {
          expect(p.t.every((v) => v.isFinite), isTrue);
        }
      }
      await Future<void>.delayed(Duration.zero);
    }
    expect(frames, greaterThan(100));
    expect(s.counters.localAccepted, greaterThan(20));
    expect(s.counters.anchorsAccepted, greaterThan(3));
  });

  test('the commit still sends the release wish and reports the stored poses (unchanged by the local solve)', () async {
    final api = _Pin();
    final clock = _Clock();
    final s = ConstrainedDragSession(call: api.call, partId: 'root', grabbedId: 'pin', leverArm: _lever, nowMs: clock.call);
    await s.begin();
    final wish = applyDelta(_onPin(0, 30), <double>[0, 0, 0, 0, 0, 0.5]);
    s.update(wish);
    final c = await s.finish(wish: wish);
    expect(c.committed, isTrue);
    expect(api.stored.t[2], closeTo(30, 1e-9));
  });
}

/// A fully locked part (dof 0, empty basis) whose backend answer to a far wish is another branch of "nearest" far away.
class _Wall {
  int calls = 0;
  Future<MateMotionDto> call(String partId, String occId,
      {RigidTransformDto? transform, double? leverArm, bool commit = false, List<MateMotionMemberDto>? reference, bool includeConstraintModel = true}) async {
    calls++;
    final at = transform == null ? _onPin(0, 30) : _onPin(0, 30 + 400);
    return MateMotionDto(
      converged: true,
      dof: 0,
      grounded: true,
      members: <MateMotionMemberDto>[MateMotionMemberDto(occurrenceId: 'pin', transform: dtoOfPose(at), mobility: 0)],
      basis: const <List<double>>[],
      chart: const MateMotionChartDto(kind: 'se3_owner_frame', leverArm: _lever),
      quality: const MateMotionQualityDto(residualInf: 1e-12, sigmaGap: null),
      committed: commit,
    );
  }
}

void wallTests() {
  test('a far wish against a fully locked part: far-branch anchors are set aside, no miss, no hold, no cue', () async {
    final api = _Wall();
    final clock = _Clock();
    final cues = <String>[];
    final s = ConstrainedDragSession(
      call: api.call, partId: 'root', grabbedId: 'pin', leverArm: _lever, nowMs: clock.call, onCue: cues.add, useLocalRetraction: false);
    await s.begin();
    final start = _onPin(0, 30);
    for (var f = 1; f <= 90; f++) {
      clock.now += 1000 / 60;
      final fr = s.update(applyDelta(start, <double>[0, 0, 0, math.pi * math.min(1.0, f / 6.0), 0, 0]));
      if (fr != null) expect(weightedDist(fr.poses[0], start, _lever), lessThan(1e-9), reason: 'the locked part stays put');
      await Future<void>.delayed(Duration.zero);
    }
    expect(s.counters.wallsIgnored, greaterThan(3));
    expect(s.counters.anchorsRejectedTotal, 0);
    expect(s.counters.holds, 0);
    expect(cues, isEmpty);
  });
}
