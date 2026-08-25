import 'package:flutter/material.dart';

import 'resizable_tool_panel.dart';

/// Boolean family, first entry: the bottom-sheet-style panel [PartScreen]
/// opens once the `pickingBodies` step of the guided Merge flow is confirmed
/// (2+ Bodies picked - see `selection_actions.dart`'s `contextActionsFor`
/// for the ambient entry's own identical gate). Unlike [MirrorPanel]/
/// [SurfacePanel], Merge has no options at all - symmetric, no target/tool
/// distinction, every input Body is always consumed into the result (see
/// the backend `MergeFeature`'s own docstring) - so this is just a summary
/// row plus Cancel/Confirm, mirroring [MirrorPanel]'s Confirm/Cancel
/// session shape without any of its plane-picking/merge-mode machinery.
class MergePanel extends StatelessWidget {
  /// 'Merge', or 'Edit Merge' while editing an already-existing
  /// MergeFeature - matches every other panel's `title` param (see
  /// `PartScreen._openMergePanelForEdit`).
  final String title;

  final String? tooltip;

  /// How many Bodies are being merged - always 2+ by the time this panel is
  /// shown (the guided/ambient entries both gate on it - see this class's
  /// own doc comment).
  final int bodyCount;

  final VoidCallback onConfirm;
  final VoidCallback onCancel;

  const MergePanel({
    super.key,
    this.title = 'Merge',
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
            'Merging $bodyCount bodies',
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
              FilledButton(onPressed: onConfirm, child: const Text('Confirm')),
            ],
          ),
        ],
      ),
    );
  }
}
