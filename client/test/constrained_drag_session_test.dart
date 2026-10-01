import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:didsa_cad_client/api/document_api_client.dart';
import 'package:didsa_cad_client/api/sketch_api_client.dart' show ApiException;
import 'package:didsa_cad_client/motion/constrained_drag_session.dart';
import 'package:didsa_cad_client/motion/mate_motion_bridge.dart';
import 'package:didsa_cad_client/motion/se3.dart';

const double _lever = 10.0;

Pose _at(double x, double y, double z) => Pose(<double>[x, y, z], Mat3.identity());

RigidTransformDto _dto(double x, double y, double z) =>
    RigidTransformDto(translation: [x, y, z], rotationAxis: [0, 0, 1], rotationAngleDegrees: 0);

class _Clock {
  double now = 0;
  double call() => now;
}

/// A fake `mate-motion` backend for ONE flat-face mate (free: x, y, spin about z; blocked: z and tilts) on the
/// grabbed occurrence `B`, optionally with a follower `D` that rides along in x (rank-1 coupling) - the basis
/// rows are in the response's equal-weight metric ([1,1,1,L,L,L] per member).
class _FakeBackend {
  _FakeBackend({this.withFollower = false});

  final bool withFollower;
  Map<String, List<double>> stored = <String, List<double>>{
    'B': [0, 0, 0],
    'D': [30, 0, 0],
  };

  final List<({RigidTransformDto? transform, double? lever, bool commit})> calls = [];
  final List<List<MateMotionMemberDto>?> references = [];

  /// Modes for the NEXT answers, consumed one per call; empty = behave.
  final List<String> script = [];
  Completer<void>? gate;

  int get commitCalls => calls.where((c) => c.commit).length;
  int get anchorCalls => calls.where((c) => !c.commit).length;

  Future<MateMotionDto> call(
    String partId,
    String occId, {
    RigidTransformDto? transform,
    double? leverArm,
    bool commit = false,
    List<MateMotionMemberDto>? reference,
  }) async {
    calls.add((transform: transform, lever: leverArm, commit: commit));
    references.add(reference);
    final g = gate;
    if (g != null) await g.future;
    final mode = script.isEmpty ? 'ok' : script.removeAt(0);
    if (mode == 'transport') throw ApiException('Could not reach the server: boom');
    if (mode == 'http422') throw ApiException('Server returned 422', statusCode: 422);
    if (mode == 'not_converged') {
      return MateMotionDto(converged: false, quality: const MateMotionQualityDto(residualInf: 5.0));
    }
    final b = stored['B']!;
    final wish = transform?.translation ?? b;
    // Nearest satisfying pose on the free manifold: in-plane only.
    final x = wish[0], y = wish[1];
    final bPose = mode == 'far' ? _dto(x + 1000, y, 0) : _dto(x, y, 0);
    final dx = x - b[0];
    final members = <MateMotionMemberDto>[
      MateMotionMemberDto(occurrenceId: 'B', transform: bPose, mobility: 3),
      if (withFollower)
        MateMotionMemberDto(
          occurrenceId: 'D',
          transform: _dto(stored['D']![0] + dx, stored['D']![1], stored['D']![2]),
          mobility: 1,
        ),
    ];
    if (commit && mode != 'unconverged_commit') stored = {'B': [x, y, 0], if (withFollower) 'D': [stored['D']![0] + dx, stored['D']![1], stored['D']![2]]};
    // Anchors are re-based on the anchor pose: rows are relative to the returned refs.
    final k = members.length;
    List<double> row(List<int> idx, List<double> vals) {
      final r = List<double>.filled(6 * k, 0);
      for (var i = 0; i < idx.length; i++) {
        r[idx[i]] = vals[i];
      }
      return r;
    }

    final basis = <List<double>>[
      if (withFollower) row([0, 6], [1 / 1.4142135623730951, 1 / 1.4142135623730951]) else row([0], [1]),
      row([1], [1]),
      row([5], [1 / _lever]),
    ];
    return MateMotionDto(
      converged: true,
      dof: basis.length,
      grounded: true,
      members: members,
      basis: basis,
      chart: const MateMotionChartDto(kind: 'se3_owner_frame', leverArm: _lever),
      quality: const MateMotionQualityDto(residualInf: 1e-12, sigmaGap: 1e4),
      committed: commit,
    );
  }
}

ConstrainedDragSession _session(_FakeBackend api, _Clock clock, {void Function(String)? onCue}) => ConstrainedDragSession(
      call: api.call,
      partId: 'root',
      grabbedId: 'B',
      leverArm: _lever,
      nowMs: clock.call,
      onCue: onCue,
    );

Future<void> _settle() => Future<void>.delayed(Duration.zero);

void main() {
  group('ConstrainedDragSession', () {
    test('60-frame drag = 1 grab anchor + 1 per ~150 ms + 1 commit; blocked z is dropped, in-plane follows', () async {
      final api = _FakeBackend();
      final clock = _Clock();
      final s = _session(api, clock);
      await s.begin();
      expect(s.hasModel, isTrue);
      expect(api.calls.first.transform, isNull, reason: 'grab anchor asks for the stored pose');
      expect(api.calls.first.lever, _lever);

      DragFrame? last;
      for (var f = 1; f <= 60; f++) {
        clock.now += 1000 / 60;
        last = s.update(_at(f * 0.5, f * 0.25, 7)); // the hand also pulls 7 off the plane
        await _settle();
      }
      expect(last, isNotNull);
      final grabbed = last!.poses[0];
      expect(grabbed.t[2], closeTo(0, 1e-9), reason: 'off-plane motion is blocked');
      expect(grabbed.t[0], closeTo(30, 1e-6));
      expect(grabbed.t[1], closeTo(15, 1e-6));

      final c = await s.finish();
      expect(c.committed, isTrue);
      // 1000 ms at 150 ms cadence -> 6 re-anchors; +1 grab, +1 commit.
      expect(api.anchorCalls, 1 + 6);
      expect(api.commitCalls, 1);
      expect(s.counters.requests, 8);
      expect(s.counters.frames, 60);
      expect(s.counters.anchorsAccepted, 7);
      expect(s.counters.reanchorsByReason, {'time': 6});
      expect(s.counters.holds, 0);
      expect(s.counters.logLine(), contains('requests=8'));
    });

    test('before the first anchor arrives update() shows nothing moving (null) and does not flood requests', () async {
      final api = _FakeBackend()..gate = Completer<void>();
      final clock = _Clock();
      final s = _session(api, clock);
      final first = s.begin();
      for (var f = 0; f < 20; f++) {
        clock.now += 16;
        expect(s.update(_at(f.toDouble(), 0, 0)), isNull);
      }
      expect(api.calls.length, 1, reason: 'one request in flight, ever');
      api.gate!.complete();
      await first;
      expect(s.hasModel, isTrue);
      expect(s.update(_at(5, 0, 0))!.poses[0].t[0], closeTo(5, 1e-9));
    });

    test('group follow: the follower is returned with the grabbed pose and rides along in x only', () async {
      final api = _FakeBackend(withFollower: true);
      final clock = _Clock();
      final s = _session(api, clock);
      await s.begin();
      expect(s.memberIds, ['B', 'D']);
      clock.now += 16;
      final f = s.update(_at(4, 6, 0))!;
      expect(f.ids, ['B', 'D']);
      expect(f.poses[0].t[0], closeTo(4, 1e-3));
      expect(f.poses[1].t[0], closeTo(34, 1e-3), reason: 'D follows B +4 in x');
      expect(f.poses[1].t[1], closeTo(0, 1e-9), reason: 'D does not follow B in y');
      final c = await s.finish();
      expect(c.poses.keys, containsAll(['B', 'D']));
      expect(c.poses['D']!.t[0], closeTo(34, 1e-9));
    });

    test('an anchor the acceptance test rejects ("jump") holds the pose and is counted; the next good anchor resumes', () async {
      final api = _FakeBackend();
      final clock = _Clock();
      final s = _session(api, clock);
      await s.begin();
      clock.now += 16;
      s.update(_at(1, 0, 0));
      api.script.add('far'); // answers 1000 mm away from the model's own projection of the same wish
      clock.now += 150;
      final before = s.update(_at(2, 0, 0))!;
      await _settle();
      expect(s.counters.anchorsRejected, {'jump': 1});
      expect(s.counters.holds, 1);
      expect(s.holding, isTrue);
      clock.now += 16;
      final held = s.update(_at(3, 0, 0))!;
      expect(held.held, isTrue);
      expect(held.poses[0].t[0], closeTo(before.poses[0].t[0], 1e-9), reason: 'held pose does not follow the hand');
      // next request honours the normal cadence (not every frame)
      final n = api.anchorCalls;
      for (var i = 0; i < 5; i++) {
        clock.now += 16;
        s.update(_at(3, 0, 0));
      }
      expect(api.anchorCalls, n, reason: 'no faster than the 150 ms cap after a miss');
      clock.now += 100;
      s.update(_at(3, 0, 0));
      await _settle();
      expect(api.anchorCalls, n + 1);
      expect(s.holding, isFalse, reason: 'good anchor accepted: resume');
      final resumed = s.update(_at(3, 0, 0))!;
      expect(resumed.held, isFalse);
      expect(resumed.poses[0].t[0], closeTo(3, 1.5), reason: 'eases back onto the wish with the blend');
      await s.finish();
    });

    test('converged:false and transport errors hold, cue after 3 misses throttled to 1/s', () async {
      final api = _FakeBackend();
      final clock = _Clock();
      final cues = <String>[];
      final s = _session(api, clock, onCue: cues.add);
      await s.begin();
      clock.now += 16;
      s.update(_at(1, 0, 0));
      api.script.addAll(['not_converged', 'transport', 'http422', 'not_converged', 'not_converged', 'not_converged', 'not_converged', 'not_converged']);
      for (var i = 0; i < 7; i++) {
        clock.now += 160;
        s.update(_at(1.0 + i, 0, 0));
        await _settle();
      }
      expect(s.counters.anchorsRejected['not_converged'], 5);
      expect(s.counters.anchorsRejected['transport'], 1);
      expect(s.counters.anchorsRejected['http_422'], 1);
      expect(s.counters.transportErrors, 1);
      expect(s.counters.holds, 1, reason: 'one continuous hold');
      // misses 3..7 over 5 * 160 = 800 ms + -> first cue at miss 3, next one only after 1000 ms
      expect(cues.length, 1);
      clock.now += 1000;
      s.update(_at(9, 0, 0));
      await _settle();
      expect(cues.length, 2);
      await s.finish();
    });

    test('release sends ONE commit:true with the release-time wish (not the shown pose) and the in-flight answer is ignored', () async {
      final api = _FakeBackend();
      final clock = _Clock();
      final s = _session(api, clock);
      await s.begin();
      clock.now += 16;
      s.update(_at(1, 2, 0));
      clock.now += 200;
      api.gate = Completer<void>();
      s.update(_at(2, 4, 0)); // re-anchor goes in flight
      await _settle();
      expect(s.counters.requests, 2);
      final commit = s.finish(wish: _at(8, 9, 3));
      api.gate!.complete();
      final c = await commit;
      expect(c.committed, isTrue);
      expect(api.commitCalls, 1);
      final sent = api.calls.last;
      expect(sent.commit, isTrue);
      expect(sent.transform!.translation, [8, 9, 3], reason: 'the wish, off-plane component included - the backend projects it');
      expect(s.counters.anchorsAccepted, 1, reason: 'the in-flight re-anchor answer was dropped');
      expect(api.stored['B'], [8, 9, 0]);
    });

    test('commit converged:false stores nothing and reports failure (caller restores)', () async {
      final api = _FakeBackend();
      final clock = _Clock();
      final s = _session(api, clock);
      await s.begin();
      clock.now += 16;
      s.update(_at(1, 0, 0));
      api.script.add('not_converged');
      final c = await s.finish();
      expect(c.committed, isFalse);
      expect(c.poses, isEmpty);
      expect(c.message, isNotNull);
      expect(api.stored['B'], [0, 0, 0]);
    });

    test('a transport error on the commit is retried ONCE, an HTTP error is not', () async {
      final api = _FakeBackend();
      final clock = _Clock();
      var s = _session(api, clock);
      await s.begin();
      clock.now += 16;
      s.update(_at(1, 0, 0));
      api.script.add('transport');
      var c = await s.finish();
      expect(c.committed, isTrue);
      expect(api.commitCalls, 2);
      expect(s.counters.transportErrors, 1);

      final api2 = _FakeBackend();
      s = _session(api2, clock);
      await s.begin();
      s.update(_at(1, 0, 0));
      api2.script.add('http422');
      c = await s.finish();
      expect(c.committed, isFalse);
      expect(api2.commitCalls, 1);

      final api3 = _FakeBackend();
      s = _session(api3, clock);
      await s.begin();
      s.update(_at(1, 0, 0));
      api3.script.addAll(['transport', 'transport']);
      c = await s.finish();
      expect(c.committed, isFalse);
      expect(api3.commitCalls, 2, reason: 'one retry only');
    });

    test('poll() resumes a held drag with an idle pointer only when an anchor was accepted', () async {
      final api = _FakeBackend();
      final clock = _Clock();
      final s = _session(api, clock);
      await s.begin();
      clock.now += 16;
      s.update(_at(1, 0, 0));
      api.script.add('not_converged');
      clock.now += 160;
      s.update(_at(1, 0, 0));
      await _settle();
      expect(s.holding, isTrue);
      expect(s.poll(), isNull);
      clock.now += 160;
      expect(s.poll(), isNull, reason: 'request just went out');
      await _settle();
      expect(s.holding, isFalse);
      expect(s.poll(), isNotNull, reason: 'accepted since the last frame');
      expect(s.poll(), isNull);
      await s.finish();
    });

    test('the largest per-frame shown step stays at the hand step for an on-manifold drag', () async {
      final api = _FakeBackend();
      final clock = _Clock();
      final s = _session(api, clock);
      await s.begin();
      for (var f = 1; f <= 60; f++) {
        clock.now += 1000 / 60;
        s.update(_at(f * 0.5, 0, 0));
        await _settle();
      }
      expect(s.counters.maxShownStep, closeTo(0.5, 1e-6));
      await s.finish();
    });

    test('warm start: the last accepted anchor\'s poses go out as `reference` with every request after the first (commit included)', () async {
      final api = _FakeBackend(withFollower: true);
      final clock = _Clock();
      final s = _session(api, clock);
      await s.begin();
      expect(api.references.first, isNull, reason: 'the grab anchor has nothing to be relative to');
      clock.now += 16;
      s.update(_at(1, 0, 0));
      clock.now += 200;
      s.update(_at(2, 0, 0));
      await _settle();
      final second = api.references[1]!;
      expect(second.map((m) => m.occurrenceId), ['B', 'D']);
      await s.finish();
      expect(api.references.last!.map((m) => m.occurrenceId), ['B', 'D']);

      final off = ConstrainedDragSession(
          call: api.call, partId: 'root', grabbedId: 'B', leverArm: _lever, nowMs: clock.call, useReference: false);
      await off.begin();
      clock.now += 200;
      off.update(_at(1, 0, 0));
      await _settle();
      expect(api.references.last, isNull, reason: 'useReference: false keeps the old stored-pose behaviour');
    });

    test('constrainedDragNotice explains a fully constrained or locked component, says nothing otherwise', () {
      MateMotionDto dto({int? dof, int mobility = 3, bool converged = true}) => MateMotionDto(
            converged: converged,
            dof: dof,
            members: [MateMotionMemberDto(occurrenceId: 'B', transform: _dto(0, 0, 0), mobility: mobility)],
          );
      expect(constrainedDragNotice(dto(dof: 0, mobility: 0)), contains('Fully constrained'));
      expect(constrainedDragNotice(dto(dof: 3, mobility: 0)), contains('lock'));
      expect(constrainedDragNotice(dto(dof: 3)), isNull);
      expect(constrainedDragNotice(dto(converged: false)), isNull);
      expect(constrainedDragNotice(null), isNull);
    });

    test('counters.reset clears the new fields; toJson carries them', () {
      final c = _session(_FakeBackend(), _Clock()).counters
        ..recordReanchor('distance')
        ..recordShownStep(1.5);
      expect(c.toJson()['reanchors_by_reason'], {'distance': 1});
      expect(c.toJson()['max_shown_step'], 1.5);
      c.reset();
      expect(c.reanchorsByReason, isEmpty);
      expect(c.maxShownStep, 0);
    });

    test('bridge: members/wish round trip through dtoOfPose', () {
      final p = poseOfDto(_dto(1, 2, 3));
      expect(dtoOfPose(p).translation, [1, 2, 3]);
    });
  });
}
