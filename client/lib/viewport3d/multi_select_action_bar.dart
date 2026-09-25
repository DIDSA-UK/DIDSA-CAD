import 'package:flutter/material.dart';

/// Feature 1 (tree multi-select): the header row [PartScreen] slots into
/// [SelectionListDrawer]'s `header` while a Build Tree or Assembly Tree
/// long-press multi-select session is active - a running count plus the
/// bulk actions that apply uniformly to every selected row, whatever its
/// kind (the per-kind backend call behind each button is [PartScreen]'s
/// concern, not this widget's).
///
/// [onMore] is the escape hatch back to a single row's full context menu
/// (Extrude/Pattern/Assign Material/Make Focus/...): long-press now enters
/// multi-select instead of opening that menu directly, so with exactly one
/// row selected this button reopens it. `null` hides the button (e.g. 2+
/// rows selected, where a single-item menu has no meaning).
class MultiSelectActionBar extends StatelessWidget {
  const MultiSelectActionBar({
    super.key,
    required this.count,
    required this.allHidden,
    required this.onToggleVisibility,
    required this.onDelete,
    required this.onCancel,
    this.onMore,
    this.busy = false,
  });

  /// How many rows are currently selected.
  final int count;

  /// True when every selected row is already hidden - the visibility button
  /// then reads "Show" (and shows everything); otherwise it reads "Hide"
  /// (and hides everything), so a mixed selection always converges on one
  /// uniform state instead of flipping each row independently.
  final bool allHidden;

  final VoidCallback onToggleVisibility;
  final VoidCallback onDelete;
  final VoidCallback onCancel;
  final VoidCallback? onMore;

  /// Disables every action while a bulk operation is in flight.
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 4, 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '$count selected',
              key: const ValueKey('multi-select-count'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          // Scales the button cluster down on a narrow drawer rather than
          // overflowing (same fix `assembly_tree_panel.dart`'s trailing
          // badges use).
          Flexible(
            flex: 3,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerRight,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (onMore != null)
                    IconButton(
                      tooltip: 'More actions',
                      icon: const Icon(Icons.more_horiz),
                      onPressed: busy ? null : onMore,
                    ),
                  TextButton.icon(
                    onPressed: busy ? null : onToggleVisibility,
                    icon: Icon(allHidden ? Icons.visibility_outlined : Icons.visibility_off_outlined, size: 18),
                    label: Text(allHidden ? 'Show' : 'Hide'),
                  ),
                  TextButton.icon(
                    onPressed: busy ? null : onDelete,
                    style: TextButton.styleFrom(foregroundColor: colorScheme.error),
                    icon: const Icon(Icons.delete_outline, size: 18),
                    label: const Text('Delete'),
                  ),
                  IconButton(
                    tooltip: 'Cancel selection',
                    icon: const Icon(Icons.close),
                    onPressed: onCancel,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
