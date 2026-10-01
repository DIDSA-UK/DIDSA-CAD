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

  /// Frames drawn from the local nearest-point retraction / frames where it was available but its answer was rejected
  /// (not converged, or too far from the projection) and the projection was drawn instead (spec §4b.1).
  /// Far-branch answers set aside because the model says the part cannot move that way (spec §11): not misses, no cue.
  int wallsIgnored = 0;

  int localAccepted = 0;
  int localFallbacks = 0;

  /// Largest mate residual of any frame DRAWN from the local retraction (mm-ish; 1e-6 is the acceptance bar).
  double localResidualMax = 0;

  /// Re-anchor requests by the scheduler's reason (`time`, `time_near_singular`, `distance`); the grab
  /// anchor and the release commit are counted in [requests]/[commitRequests] only.
  final Map<String, int> reanchorsByReason = <String, int>{};

  /// Largest per-frame step of the SHOWN grabbed pose (weighted mm, `[1,1,1,L,L,L]` metric): the F1-gate smoothness number.
  double maxShownStep = 0;

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

  void recordWallIgnored() => wallsIgnored++;

  void recordLocal({required bool accepted, required double residualInf}) {
    if (accepted) {
      localAccepted++;
      if (residualInf > localResidualMax) localResidualMax = residualInf;
    } else {
      localFallbacks++;
    }
  }

  void recordReanchor(String reason) => reanchorsByReason[reason] = (reanchorsByReason[reason] ?? 0) + 1;

  void recordShownStep(double step) {
    if (step > maxShownStep) maxShownStep = step;
  }

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
    reanchorsByReason.clear();
    frames = projectionMicrosTotal = projectionMicrosMax = holds = 0;
    localAccepted = localFallbacks = wallsIgnored = 0;
    localResidualMax = 0;
    maxShownStep = 0;
  }

  /// One line for the release-time debug log (the F1 gate's evidence).
  String logLine() {
    String map(Map<String, int> m) =>
        m.isEmpty ? '-' : (m.entries.map((e) => '${e.key}:${e.value}').toList()..sort()).join(',');
    return 'constrained drag: requests=$requests (commit $commitRequests, transport errors $transportErrors) '
        'anchors accepted=$anchorsAccepted rejected=${map(anchorsRejected)} holds=$holds frames=$frames '
        'projection_us mean=${projectionMicrosMean.toStringAsFixed(1)} max=$projectionMicrosMax '
        'reanchors=${map(reanchorsByReason)} max_shown_step=${maxShownStep.toStringAsFixed(3)} '
        'walls_ignored=$wallsIgnored local=$localAccepted/${localAccepted + localFallbacks} (fallbacks $localFallbacks, max residual ${localResidualMax.toStringAsExponential(1)})';
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
        'reanchors_by_reason': Map<String, int>.of(reanchorsByReason),
        'max_shown_step': maxShownStep,
        'walls_ignored': wallsIgnored,
        'local_accepted': localAccepted,
        'local_fallbacks': localFallbacks,
        'local_residual_max': localResidualMax,
      };
}
