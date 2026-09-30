import 'package:flutter_test/flutter_test.dart';

import 'package:didsa_cad_client/motion/motion_counters.dart';
import 'package:didsa_cad_client/motion/reanchor_scheduler.dart';

class _FakeClock {
  double now = 1000;
  double call() => now;
}

void main() {
  group('ReanchorScheduler (injected clock)', () {
    late _FakeClock clock;
    late ReanchorScheduler s;

    setUp(() {
      clock = _FakeClock();
      s = ReanchorScheduler(clock.call);
    });

    test('first request is due once the interval has elapsed, never while one is in flight', () {
      clock.now = 1000;
      s.onRequestSent();
      s.onAccepted(maxStep: null, sigmaGap: 1e6);
      expect(s.anchorMs, 1000);

      clock.now = 1149.9;
      expect(s.check(0).reanchor, isFalse);
      clock.now = 1150;
      expect(s.check(0).reason, 'time');
      expect(s.onRequestSent(), isTrue);
      expect(s.onRequestSent(), isFalse, reason: 'one request in flight, ever');
      clock.now = 2000;
      expect(s.check(0).reason, 'in_flight');
    });

    test('t_anchor is the SEND time of the accepted request, not its arrival', () {
      clock.now = 1000;
      s.onRequestSent();
      clock.now = 1120; // slow round trip
      s.onAccepted();
      expect(s.anchorMs, 1000);
      clock.now = 1150;
      expect(s.check(0).reanchor, isTrue);
    });

    test('a miss does not restart the timer and is counted; accept resets the count', () {
      clock.now = 1000;
      s.onRequestSent();
      s.onAccepted();
      clock.now = 1160;
      s.onRequestSent();
      clock.now = 1200;
      s.onMiss();
      expect(s.anchorMs, 1000, reason: 'rejected anchor keeps the old t_anchor');
      expect(s.consecutiveMisses, 1);
      expect(s.check(0).reason, 'time', reason: 'still due at the normal cadence');
      s.onRequestSent();
      s.onAccepted();
      expect(s.consecutiveMisses, 0);
      expect(s.anchorMs, 1200);
    });

    test('distance trigger uses max_step from the last accepted anchor; null max_step = time cap only', () {
      clock.now = 1000;
      s.onRequestSent();
      s.onAccepted(maxStep: 5.0, sigmaGap: 1e6);
      clock.now = 1060;
      expect(s.check(4.9).reanchor, isFalse);
      expect(s.check(5.0).reason, 'distance');
      s.onRequestSent();
      s.onAccepted(maxStep: null, sigmaGap: 1e6);
      clock.now = 1100;
      expect(s.check(500).reanchor, isFalse);
    });

    test('sigma_gap below 100 halves the interval', () {
      clock.now = 1000;
      s.onRequestSent();
      s.onAccepted(sigmaGap: 40);
      clock.now = 1075;
      expect(s.check(0).reason, 'time_near_singular');
    });

    test('invalidate drops the in-flight token (release)', () {
      s.onRequestSent();
      s.invalidate();
      expect(s.inFlight, isFalse);
      expect(s.onRequestSent(), isTrue);
    });

    test("can't-follow cue: after 3 misses, at most once per second", () {
      for (var i = 0; i < 2; i++) {
        s.onRequestSent();
        s.onMiss();
      }
      expect(s.takeCue(), isFalse);
      s.onRequestSent();
      s.onMiss();
      expect(s.takeCue(), isTrue);
      clock.now += 500;
      expect(s.takeCue(), isFalse, reason: 'throttled');
      clock.now += 500;
      expect(s.takeCue(), isTrue);
      s.onRequestSent();
      s.onAccepted();
      expect(s.takeCue(), isFalse, reason: 'an accepted anchor clears the misses');
    });

    test('reset clears the state for a new drag', () {
      s.onRequestSent();
      s.onMiss();
      s.reset();
      expect(s.consecutiveMisses, 0);
      expect(s.inFlight, isFalse);
    });
  });

  group('MotionCounters', () {
    test('counts requests, accept/reject reasons and frame timings', () {
      final c = MotionCounters();
      c.recordRequest();
      c.recordRequest(commit: true);
      c.recordResponse();
      c.recordAccepted();
      c.recordRejected('jump');
      c.recordRejected('jump');
      c.recordRejected('residual');
      c.recordFrame(const Duration(microseconds: 100));
      c.recordFrame(const Duration(microseconds: 300));
      expect(c.requests, 2);
      expect(c.commitRequests, 1);
      expect(c.anchorsRejectedTotal, 3);
      expect(c.anchorsRejected['jump'], 2);
      expect(c.projectionMicrosMean, 200);
      expect(c.projectionMicrosMax, 300);
      expect(c.timeFrame(() => 42), 42);
      expect(c.frames, 3);
      expect(c.toJson()['requests'], 2);
      c.reset();
      expect(c.frames, 0);
      expect(c.anchorsRejected, isEmpty);
    });
  });
}
