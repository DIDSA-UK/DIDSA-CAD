import 'package:flutter/material.dart';

import 'selection_actions.dart';
import 'selection_hit_test.dart';

/// Stage 23 Item 6: the compact horizontal row of operations available for
/// the current selection, shown directly above [SelectionListDrawer] -
/// reflects [contextActionsFor]'s composition table. [PartScreen] decides
/// when/where to show this (gated on [selectedEntities] being non-empty);
/// this widget itself always renders its content, leaving visibility/
/// positioning to the caller, the same split [SelectionListDrawer] uses.
///
/// C2 is the first to wire a real callback (Create Plane); Prompt D wires
/// Fillet; Prompt E wires Chamfer.
class SelectionContextPanel extends StatelessWidget {
  final Set<SelectionEntityRef> selectedEntities;

  /// C2: threaded through to [contextActionsFor] so its one sketch-entity
  /// combo (a Line + the Point that's its own endpoint) can actually be
  /// told apart from a Line + some other, unrelated Point - see
  /// [PointOnLineChecker]'s own doc comment for why this has to be a
  /// callback rather than something [contextActionsFor] can work out from
  /// [SelectionEntityRef] alone.
  final PointOnLineChecker? isPointOnLine;

  /// C2/C3/C4: fired when the user taps an *enabled* Create Plane button -
  /// never called for a disabled/placeholder one. [PartScreen] inspects
  /// [selectedEntities] itself to decide which of the six flows to open,
  /// rather than this panel trying to encode that choice in the callback's
  /// signature.
  final VoidCallback? onCreatePlane;

  /// Prompt D: fired when the user taps an *enabled* Fillet button - mirrors
  /// [onCreatePlane]'s own "never called for a disabled one" contract.
  final VoidCallback? onFillet;

  /// Prompt E: fired when the user taps an *enabled* Chamfer button - same
  /// "never called for a disabled one" contract as [onFillet].
  final VoidCallback? onChamfer;

  /// On-device feedback: fired when the user taps an *enabled* "New Sketch
  /// on Face" button (a single Body face selected) - same "never called for
  /// a disabled one" contract as [onFillet]/[onChamfer].
  final VoidCallback? onNewSketchOnFace;

  /// On-device feedback (bug fix): fired when the user taps an *enabled*
  /// "New Sketch" button (a single reference plane or existing Plane
  /// selected) - mirrors [onNewSketchOnFace]'s own contract, split into its
  /// own callback since [PartScreen] resolves it differently (a
  /// [SelectionEntityKind.referencePlane]/[SelectionEntityKind.createPlane]
  /// needs no new Plane Feature created first, unlike a Body face).
  final VoidCallback? onNewSketch;

  /// Pattern/Mirror scoping's Phase 1: fired when the user taps an
  /// *enabled* Mirror button (a single Body selected - see
  /// `selection_actions.dart`'s `contextActionsFor`) - same "never called
  /// for a disabled one" contract as [onFillet]/[onChamfer].
  final VoidCallback? onMirror;

  const SelectionContextPanel({
    super.key,
    required this.selectedEntities,
    this.isPointOnLine,
    this.onCreatePlane,
    this.onFillet,
    this.onChamfer,
    this.onNewSketchOnFace,
    this.onNewSketch,
    this.onMirror,
  });

  @override
  Widget build(BuildContext context) {
    final actions = contextActionsFor(selectedEntities, isPointOnLine: isPointOnLine);
    if (actions.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Material(
        elevation: 2,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final action in actions)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: _buildActionButton(action),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Prompt D: wraps the button in a [Tooltip] only when
  /// [SelectionContextAction.disabledReason] is set - every other action
  /// (enabled, or disabled with no reason at all - the "not built yet"
  /// scaffolded case) renders the plain button, so hovering/long-pressing
  /// it doesn't pop up an empty tooltip.
  Widget _buildActionButton(SelectionContextAction action) {
    final button = OutlinedButton(
      onPressed: _callbackFor(action),
      child: Text(action.label),
    );
    final reason = action.disabledReason;
    return reason == null ? button : Tooltip(message: reason, child: button);
  }

  /// C2/C3/C4/D/E: 'Create Plane'/'Fillet'/'Chamfer' only ever get a real
  /// callback when [SelectionContextAction.enabled] is true - every other
  /// action stays null, kept as a per-action switch so each future CAD
  /// operation gets its own callback site.
  VoidCallback? _callbackFor(SelectionContextAction action) {
    switch (action.label) {
      case 'Chamfer':
        return action.enabled ? onChamfer : null;
      case 'Fillet':
        return action.enabled ? onFillet : null;
      case 'Create Plane':
      case 'Create Plane (Midplane)':
      case 'Create Plane (Normal to Edge Through Vertex)':
      case 'Create Plane (Parallel to Face Through Vertex)':
      case 'Create Plane (Three Points)':
        return action.enabled ? onCreatePlane : null;
      case 'New Sketch on Face':
        return action.enabled ? onNewSketchOnFace : null;
      case 'New Sketch':
        return action.enabled ? onNewSketch : null;
      case 'Mirror':
        return action.enabled ? onMirror : null;
      default:
        return null;
    }
  }
}
