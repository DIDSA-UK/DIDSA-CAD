/// Plain instrumentation for the drag loop (investigation §H): request
/// counters, per-frame projection timing, anchor accept/reject counts. No UI.
library;

class MotionCounters {
  int requests = 0;
  int commitRequests = 0;
  int responses = 0;
  int transportErrors = 0;
  int anchorsAccepted = 0;
  final Map<String, int> anchorsRejected = <String, int>{};
  int frames = 0;
  int projectionMicrosTotal = 0;
  int projectionMicrosMax = 0;
  int holds = 0;

  int get anchorsRejectedTotal => anchorsRejected.values.fold(0, (a, b) => a + b);

  double get projectionMicrosMean => frames == 0 ? 0 : projectionMicrosTotal / frames;

  void recordRequest({bool commit = false}) {
    requests++;
    if (commit) commitRequests++;
  }

  void recordResponse() => responses++;

  void recordTransportError() => transportErrors++;

  void recordAccepted() => anchorsAccepted++;

  /// [reason] is the acceptance verdict (`not_converged`, `residual`, `jump`) or `transport`.
  void recordRejected(String reason) => anchorsRejected[reason] = (anchorsRejected[reason] ?? 0) + 1;

  void recordHold() => holds++;

  /// One projected frame that took [elapsed].
  void recordFrame(Duration elapsed) {
    frames++;
    final us = elapsed.inMicroseconds;
    projectionMicrosTotal += us;
    if (us > projectionMicrosMax) projectionMicrosMax = us;
  }

  /// Times [body] as one frame.
  T timeFrame<T>(T Function() body) {
    final sw = Stopwatch()..start();
    final out = body();
    sw.stop();
    recordFrame(sw.elapsed);
    return out;
  }

  void reset() {
    requests = commitRequests = responses = transportErrors = anchorsAccepted = 0;
    anchorsRejected.clear();
    frames = projectionMicrosTotal = projectionMicrosMax = holds = 0;
  }

  Map<String, Object> toJson() => <String, Object>{
        'requests': requests,
        'commit_requests': commitRequests,
        'responses': responses,
        'transport_errors': transportErrors,
        'anchors_accepted': anchorsAccepted,
        'anchors_rejected': Map<String, int>.of(anchorsRejected),
        'frames': frames,
        'projection_us_mean': projectionMicrosMean,
        'projection_us_max': projectionMicrosMax,
        'holds': holds,
      };
}
