import 'package:flutter/material.dart';

import 'resizable_tool_panel.dart';

/// Direct Editing family, fourth entry: the bottom-sheet-style panel
/// [PartScreen] opens once a single planar face is selected and "Delete
/// Face" is chosen (see `selection_actions.dart`'s `contextActionsFor`
/// single-planar-face branch). Mirrors [DeleteBodyPanel]'s shape exactly -
/// a DeleteFaceFeature has no options/fields of its own (v1 client scope:
/// the face is fixed once picked, no re-picking a different face mid-
/// session - see `docs/direct-editing-scope.md`), so this is just a
/// summary row plus Cancel/Confirm, with no live-tunable parameter.
class DeleteFacePanel extends StatelessWidget {
  /// 'Delete Face', or 'Edit Delete Face' while editing an already-existing
  /// DeleteFaceFeature - matches every other panel's `title` param.
  final String title;

  final String? tooltip;

  final VoidCallback onConfirm;
  final VoidCallback onCancel;

  const DeleteFacePanel({
    super.key,
    this.title = 'Delete Face',
    this.tooltip,
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
            'Deleting 1 face',
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
