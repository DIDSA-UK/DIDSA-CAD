/// Overlapping loads of one thing (P2 of `docs/assembly-tree-overhaul-scope.md`, 10.3's stale-answer rule): only the answer of the latest
/// [run] is applied. A run that a newer one superseded drops its own answer (or its own error) and completes when the newest run does, with
/// the newest run's error if that failed, so `await run(...)` always means "what is in hand now is current" (or throws).
class LatestCall {
  int _generation = 0;
  Future<void>? _latest;

  /// Fetches with [fetch] and hands the answer to [apply] when no newer run started meanwhile. [fetch]'s own error goes to this caller.
  Future<void> run<T>(Future<T> Function() fetch, void Function(T answer) apply) {
    final call = _run(fetch, apply);
    _latest = call;
    return call;
  }

  Future<void> _run<T>(Future<T> Function() fetch, void Function(T answer) apply) async {
    final generation = ++_generation;
    final T answer;
    try {
      answer = await fetch();
    } catch (_) {
      // A superseded run's own failure does not matter: the newer run's outcome is this caller's (below). Only the latest run throws its own.
      if (generation == _generation) rethrow;
      await _waitForNewer();
      return;
    }
    if (generation != _generation) {
      await _waitForNewer();
      return;
    }
    apply(answer);
  }

  /// A newer run is on its way: wait for it, and pass on its error (this caller would otherwise carry on with what was there before). A newer run
  /// that succeeds returns quietly here, whether this one failed or not.
  Future<void> _waitForNewer() async {
    final latest = _latest;
    if (latest != null) await latest;
  }
}
