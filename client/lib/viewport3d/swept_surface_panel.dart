import 'package:flutter/material.dart';

import 'resizable_tool_panel.dart';

/// The bottom-sheet-style panel [PartScreen] opens for a Swept Surface -
/// mirrors [SweepPanel] exactly, minus the Boss/Cut segmented control and
/// target-body picking (a Swept Surface never combines with an existing
/// Body - always a brand-new, standalone Surface, see the backend
/// `SweptSurfaceFeature`'s own docstring). Only the read-only path summary
/// line remains.
///
/// Same "nothing to debounce" shape as [PlanarSurfacePanel]/
/// [RuledSurfacePanel] - the path is already fixed by the time this panel
/// opens (picked via [PartScreen]'s own two-stage sketch-then-path picker),
/// and there is no other field left for the user to change, so the Feature
/// is created once, eagerly, the instant the panel opens.
class SweptSurfacePanel extends StatelessWidget {
  /// 'Swept Surface' when creating a brand-new Feature (default), 'Edit
  /// Swept Surface' when [PartScreen] opened this to edit an already-
  /// existing one instead.
  final String title;

  final String? tooltip;

  /// Mirrors [SweepPanel.pathSegmentCount]/[SweepPanel.pathIsClosed] exactly.
  final int pathSegmentCount;
  final bool pathIsClosed;

  /// Mirrors [PlanarSurfacePanel.ready] exactly.
  final bool ready;

  final VoidCallback onConfirm;
  final VoidCallback onCancel;

  const SweptSurfacePanel({
    super.key,
    this.title = 'Swept Surface',
    this.tooltip,
    required this.pathSegmentCount,
    required this.pathIsClosed,
    required this.ready,
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
            'Path: $pathSegmentCount segment${pathSegmentCount == 1 ? '' : 's'}, '
            '${pathIsClosed ? 'closed' : 'open'}',
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
                onPressed: ready ? onConfirm : null,
                child: const Text('Confirm'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
