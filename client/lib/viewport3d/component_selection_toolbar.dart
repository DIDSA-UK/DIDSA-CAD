import 'package:flutter/material.dart';

/// Bug fix ("selecting a component shows no contextual toolbar"): the
/// Assembly-lens equivalent of `SelectionContextPanel` (which is deliberately
/// Part-lens-only - see its own gating comment in `part_screen.dart`) for a
/// single selected Occurrence - Move, Fix/Float, Delete, mirroring the same
/// three actions `component_context_menu.dart`'s long-press-only
/// `ComponentContextMenuAction.moveRotate`/`fix`/`float`/`delete` entries
/// already offer, reusing their exact same handlers
/// (`PartScreen._setOccurrenceFixed`/`_confirmDeleteOccurrence`, and the
/// `_moveRotateComponentActive` activation Move/Rotate already uses). This
/// widget only renders the row; `PartScreen` decides when/where to show it
/// (gated on `_selectedOccurrenceId` being non-null and no other tool/picker
/// session already owning the screen), the same split `SelectionContextPanel`
/// uses for its own visibility.
class ComponentSelectionToolbar extends StatelessWidget {
  /// Whether the selected Occurrence is currently `fixed` - picks the
  /// Fix/Float button's label/icon the same "label names the next state"
  /// convention `component_context_menu.dart`'s own entry uses.
  final bool fixed;

  final VoidCallback onMove;
  final VoidCallback onFixFloat;
  final VoidCallback onDelete;

  const ComponentSelectionToolbar({
    super.key,
    required this.fixed,
    required this.onMove,
    required this.onFixFloat,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
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
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: OutlinedButton.icon(
                    onPressed: onMove,
                    icon: const Icon(Icons.open_with),
                    label: const Text('Move'),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: OutlinedButton.icon(
                    onPressed: onFixFloat,
                    icon: Icon(fixed ? Icons.push_pin : Icons.push_pin_outlined),
                    label: Text(fixed ? 'Float' : 'Fix'),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: OutlinedButton.icon(
                    onPressed: onDelete,
                    icon: const Icon(Icons.delete_outline),
                    label: const Text('Delete'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
