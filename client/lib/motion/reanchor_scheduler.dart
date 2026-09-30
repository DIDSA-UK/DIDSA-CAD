/// Re-anchor scheduler (`docs/motion/projector-spec.md` §8, §11) with an
/// injected clock so it is testable without real time.
library;

/// Re-anchor interval (ms).
const double kReanchorMs = 150.0;

/// Interval (ms) when `sigma_gap` says a rank change is near.
const double kReanchorMsNearSingular = 75.0;

/// `sigma_gap` below this halves the interval. Uncalibrated placeholder.
const double kSigmaGapLow = 100.0;

/// Consecutive anchor misses before the "can't follow that move" cue.
const int kMissesBeforeCue = 3;

/// Minimum spacing (ms) between "can't follow" cues.
const double kCueThrottleMs = 1000.0;

class ReanchorDecision {
  final bool reanchor;

  /// `in_flight`, `time`, `time_near_singular`, `distance` or `none`.
  final String reason;

  const ReanchorDecision(this.reanchor, this.reason);
}

/// The pure decision (what the golden vectors pin).
ReanchorDecision needsReanchor({
  required double nowMs,
  required double anchorMs,
  required double travel,
  required double? maxStep,
  required double? sigmaGap,
  required bool inFlight,
}) {
  if (inFlight) return const ReanchorDecision(false, 'in_flight');
  final nearSingular = sigmaGap != null && sigmaGap < kSigmaGapLow;
  final interval = nearSingular ? kReanchorMsNearSingular : kReanchorMs;
  if (nowMs - anchorMs >= interval) {
    return ReanchorDecision(true, nearSingular ? 'time_near_singular' : 'time');
  }
  if (maxStep != null && travel >= maxStep) return const ReanchorDecision(true, 'distance');
  return const ReanchorDecision(false, 'none');
}

/// Stateful wrapper: one request in flight, `t_anchor` = SEND time of the
/// request whose response was last accepted, miss counting for §11.
class ReanchorScheduler {
  final double Function() _nowMs;

  ReanchorScheduler(this._nowMs);

  bool _inFlight = false;
  double _pendingSentMs = 0;
  double _anchorMs = 0;
  double? _maxStep;
  double? _sigmaGap;
  int _misses = 0;
  double? _lastCueMs;

  bool get inFlight => _inFlight;
  int get consecutiveMisses => _misses;
  double get anchorMs => _anchorMs;

  /// Clears everything for a new drag.
  void reset() {
    _inFlight = false;
    _anchorMs = 0;
    _maxStep = null;
    _sigmaGap = null;
    _misses = 0;
    _lastCueMs = null;
  }

  /// Should a request go out now? [travel] = `FreeMotionProjector.travel(shown)`.
  ReanchorDecision check(double travel) => needsReanchor(
        nowMs: _nowMs(),
        anchorMs: _anchorMs,
        travel: travel,
        maxStep: _maxStep,
        sigmaGap: _sigmaGap,
        inFlight: _inFlight,
      );

  /// Call when a request is sent. Returns false (and does nothing) if one is already in flight.
  bool onRequestSent() {
    if (_inFlight) return false;
    _inFlight = true;
    _pendingSentMs = _nowMs();
    return true;
  }

  /// The in-flight request's response was accepted: its send time becomes `t_anchor`.
  void onAccepted({double? maxStep, double? sigmaGap}) {
    _inFlight = false;
    _anchorMs = _pendingSentMs;
    _maxStep = maxStep;
    _sigmaGap = sigmaGap;
    _misses = 0;
  }

  /// Rejected anchor, `converged:false`, or a transport error: counts as a miss and does NOT restart the timer.
  void onMiss() {
    _inFlight = false;
    _misses++;
  }

  /// Drop the in-flight token (release): its response must be ignored by the caller.
  void invalidate() {
    _inFlight = false;
  }

  /// True at most once per [kCueThrottleMs] while [kMissesBeforeCue] or more misses are pending (spec §11).
  bool takeCue() {
    if (_misses < kMissesBeforeCue) return false;
    final now = _nowMs();
    if (_lastCueMs != null && now - _lastCueMs! < kCueThrottleMs) return false;
    _lastCueMs = now;
    return true;
  }
}
