import 'package:flutter/material.dart';

import 'resizable_tool_panel.dart';

/// Boolean family, fourth/last entry: the bottom-sheet-style panel
/// [PartScreen] opens once the guided Split flow's `pickingTool` step
/// resolves a cutting Plane or Surface (see `selection_actions.dart`'s
/// `contextActionsFor` for the ambient entry's own identical single-Body
/// gate). Unlike [MergePanel]/[BooleanPanel] there is no further option to
/// pick here at all - the target Body and the tool are both already fully
/// resolved by the time this shows (`pickingTarget`/`pickingTool` each
/// auto-advance the instant their own single, unambiguous pick lands - see
/// `PartScreen`'s own "Boolean family, fourth/last entry: Split" state-field
/// section header comment) - so this is just a summary row plus
/// Cancel/Confirm, mirroring [MergePanel]'s own minimal shape exactly.
class SplitPanel extends StatelessWidget {
  /// 'Split', or 'Edit Split' while editing an already-existing
  /// SplitFeature - matches every other panel's `title` param (see
  /// `PartScreen._openSplitPanelForEdit`).
  final String title;

  final String? tooltip;

  /// 'Plane' or 'Surface (<name>)' - which kind of tool this Split uses,
  /// and (for a Surface) its own display name when known. Computed by
  /// [PartScreen] (it alone has the id-to-name maps this needs), not this
  /// widget - mirrors [BooleanPanel.isSubtract]'s own "caller decides which
  /// summary copy applies" split.
  final String toolSummary;

  final VoidCallback onConfirm;
  final VoidCallback onCancel;

  const SplitPanel({
    super.key,
    this.title = 'Split',
    this.tooltip,
    required this.toolSummary,
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
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.call_split,
                size: 16,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'Splitting body with tool: $toolSummary',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    fontSize: 12,
                  ),
                ),
              ),
            ],
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
