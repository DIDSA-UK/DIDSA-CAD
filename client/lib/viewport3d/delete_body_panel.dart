import 'package:flutter/material.dart';

import 'resizable_tool_panel.dart';

/// Direct Editing family, first entry: the bottom-sheet-style panel
/// [PartScreen] opens once one or more Bodies are selected and "Delete
/// Body" is chosen (see `selection_actions.dart`'s `contextActionsFor`
/// body-only-selection branch). Mirrors [MergePanel]'s minimal shape almost
/// exactly - a DeleteBodyFeature has no options/fields of its own (no
/// "keep" mode - see the backend `DeleteBodyFeature`'s own docstring), so
/// this is just a summary row plus Cancel/Confirm, with no live-tunable
/// parameter and therefore no live-preview mesh fetch (Pattern 1 of
/// `docs/live-preview-pattern.md`).
class DeleteBodyPanel extends StatelessWidget {
  /// 'Delete Body', or 'Edit Delete Body' while editing an already-existing
  /// DeleteBodyFeature - matches every other panel's `title` param.
  final String title;

  final String? tooltip;

  /// How many Bodies are selected for deletion - always 1+ by the time
  /// this panel is shown.
  final int bodyCount;

  final VoidCallback onConfirm;
  final VoidCallback onCancel;

  const DeleteBodyPanel({
    super.key,
    this.title = 'Delete Body',
    this.tooltip,
    required this.bodyCount,
    required this.onConfirm,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    return ResizableToolPanel(
      title: title,
      tooltip: tooltip,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            bodyCount == 1 ? 'Deleting 1 body' : 'Deleting $bodyCount bodies',
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(onPressed: onCancel, child: const Text('Cancel')),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: onConfirm,
                style: FilledButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.error,
                  foregroundColor: Theme.of(context).colorScheme.onError,
                ),
                child: const Text('Delete'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
