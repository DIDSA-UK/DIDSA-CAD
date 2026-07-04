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
/// C2 is the first to wire a real callback (Create Plane) - Chamfer/Fillet
/// stay disabled scaffolds until D/E exist, see [_callbackFor]'s per-action
/// `// TODO: wire up <action>` comments.
class SelectionContextPanel extends StatelessWidget {
  final Set<SelectionEntityRef> selectedEntities;

  /// C2: threaded through to [contextActionsFor] so its one sketch-entity
  /// combo (a Line + the Point that's its own endpoint) can actually be
  /// told apart from a Line + some other, unrelated Point - see
  /// [PointOnLineChecker]'s own doc comment for why this has to be a
  /// callback rather than something [contextActionsFor] can work out from
  /// [SelectionEntityRef] alone.
  final PointOnLineChecker? isPointOnLine;

  /// C2: fired when the user taps an *enabled* Create Plane button - never
  /// called for a disabled/placeholder one. [PartScreen] inspects
  /// [selectedEntities] itself to decide which of the two flows
  /// (offset-from-face vs. normal-to-line-at-point) to open, rather than
  /// this panel trying to encode that choice in the callback's signature.
  final VoidCallback? onCreatePlane;

  const SelectionContextPanel({
    super.key,
    required this.selectedEntities,
    this.isPointOnLine,
    this.onCreatePlane,
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
                    child: OutlinedButton(
                      onPressed: _callbackFor(action),
                      child: Text(action.label),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// C2: 'Create Plane' only ever gets a real callback when
  /// [SelectionContextAction.enabled] is true (the two flows
  /// [contextActionsFor] now actually wires) - its still-scaffolded
  /// placeholder variants ("... Through Vertex)") and every other action
  /// stay null, kept as a per-action switch so each future CAD operation
  /// gets its own `// TODO: wire up <action>` comment at its own callback
  /// site.
  VoidCallback? _callbackFor(SelectionContextAction action) {
    switch (action.label) {
      case 'Chamfer':
        // TODO: wire up Chamfer once the backend Chamfer operation exists.
        return null;
      case 'Fillet':
        // TODO: wire up Fillet once the backend Fillet operation exists.
        return null;
      case 'Create Plane':
      case 'Create Plane (Midplane)':
        return action.enabled ? onCreatePlane : null;
      case 'Create Plane (Normal to Edge Through Vertex)':
      case 'Create Plane (Parallel to Face Through Vertex)':
        // TODO: wire up once these two plane types are ever built - out of
        // C2's own two-plane-type v1 scope.
        return null;
      default:
        return null;
    }
  }
}
