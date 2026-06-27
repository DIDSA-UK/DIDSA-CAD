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
/// Every button is disabled - Stage 23 only scaffolds these actions, it
/// doesn't implement Chamfer/Fillet/Create Plane - see
/// [_disabledCallbackFor]'s per-action `// TODO: wire up <action>` comments
/// for where a later stage's real callback belongs.
class SelectionContextPanel extends StatelessWidget {
  final Set<SelectionEntityRef> selectedEntities;

  const SelectionContextPanel({super.key, required this.selectedEntities});

  @override
  Widget build(BuildContext context) {
    final actions = contextActionsFor(selectedEntities);
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
                      onPressed: _disabledCallbackFor(action),
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

  /// Every branch returns `null` (every action is a disabled scaffold per
  /// the brief) - kept as a per-action switch, rather than one shared
  /// `null` constant, so each future CAD operation gets its own
  /// `// TODO: wire up <action>` comment at its own callback site.
  VoidCallback? _disabledCallbackFor(ContextAction action) {
    switch (action.label) {
      case 'Chamfer':
        // TODO: wire up Chamfer once the backend Chamfer operation exists.
        return null;
      case 'Fillet':
        // TODO: wire up Fillet once the backend Fillet operation exists.
        return null;
      case 'Create Plane':
      case 'Create Plane (Normal to Edge Through Vertex)':
      case 'Create Plane (Parallel to Face Through Vertex)':
        // TODO: wire up Create Plane once the backend Create Plane operation exists.
        return null;
      default:
        return null;
    }
  }
}
