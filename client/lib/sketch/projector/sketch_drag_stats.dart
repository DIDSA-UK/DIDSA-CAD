// Counters for the per-frame constraint step of a sketch drag (docs/constrained-drag-implementation-plan.md S10): how often
// a frame is clamped, rejected by the projector or a guard, or cannot be clamped locally at all, and what the clamp costs.
// Read by the benchmark in test/sketch_drag_bench_test.dart and by DevTools; costs one Stopwatch per frame.
class SketchDragStats {
  int frames = 0;

  /// The clamp answered and every guard passed.
  int accepted = 0;

  /// The projector did not converge, or a guard (blow-up, arc side, residual) dropped the frame.
  int rejected = 0;

  /// The dragged group holds a constraint the projector has no model for.
  int unsupported = 0;
  int totalMicros = 0;
  int maxMicros = 0;

  /// Size of the last projected system (free points, residual rows) and the iterations it took.
  int lastVariablePoints = 0;
  int lastRows = 0;
  int lastIterations = 0;
  int maxIterations = 0;

  void reset() {
    frames = accepted = rejected = unsupported = totalMicros = maxMicros = 0;
    lastVariablePoints = lastRows = lastIterations = maxIterations = 0;
  }

  double get meanMicros => frames == 0 ? 0 : totalMicros / frames;

  void recordTime(int micros) {
    frames++;
    totalMicros += micros;
    if (micros > maxMicros) maxMicros = micros;
  }

  void recordSystem(int variablePoints, int rows, int iterations) {
    lastVariablePoints = variablePoints;
    lastRows = rows;
    lastIterations = iterations;
    if (iterations > maxIterations) maxIterations = iterations;
  }

  @override
  String toString() =>
      'frames=$frames accepted=$accepted rejected=$rejected unsupported=$unsupported '
      'mean=${meanMicros.toStringAsFixed(0)}us max=${maxMicros}us '
      'system=${lastVariablePoints}pts/${lastRows}rows iters(max)=$maxIterations';
}
