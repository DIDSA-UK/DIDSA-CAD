// Test-only: the real SolveSpace (host build of tools/solvespace-reference) as a drop-in for the drag clamp, so tests can pin the
// bundled projector (lib/sketch/projector) against the solver it replaced. The app never loads any of this.
import 'package:didsa_cad_client/sketch/projector/sketch_projector.dart';

import 'local_sketch_solver.dart';
import 'slvs_bindings.dart';

/// A [SketchClampOverride] that clamps every drag frame with SolveSpace through [bindings]; null for null.
SketchClampOverride? solveSpaceDragClamp(SlvsNativeBindings? bindings) {
  if (bindings == null) return null;
  return ({
    required points,
    required constraints,
    required lineEndpoints,
    required anchors,
    required pinned,
    required provisionalDistances,
  }) {
    final result = solveSketchLocally(
      bindings: bindings,
      points: points,
      constraints: constraints,
      lineEndpoints: lineEndpoints,
      anchorPointIds: anchors,
      lockedPointIds: pinned,
      provisionalDistances: provisionalDistances,
    );
    return result.solvedPoints;
  };
}
