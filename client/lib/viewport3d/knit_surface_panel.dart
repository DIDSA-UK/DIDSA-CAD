import 'package:flutter/material.dart';

import 'resizable_tool_panel.dart';

/// Phase 2 surfacing package, second entry: the bottom-sheet-style panel
/// [PartScreen] opens once the multi-select tree picker's `pickingSurfaces`
/// step is confirmed (2+ surface-producing Features picked). Mirrors
/// [MergePanel]'s own minimal shape exactly (a summary row plus
/// Cancel/Confirm, no further options - `Sewing.Perform()` has no field of
/// its own to configure, see the backend `KnitSurfaceFeature`'s own
/// docstring).
class KnitSurfacePanel extends StatelessWidget {
  /// 'Knit Surfaces', or 'Edit Knit Surfaces' while editing an already-
  /// existing KnitSurfaceFeature - matches every other panel's `title` param.
  final String title;

  final String? tooltip;

  /// How many surfaces are being sewn together - always 2+ by the time this
  /// panel is shown (the picker's own confirm gate enforces it, mirrors
  /// [MergePanel.bodyCount]'s identical "always 2+" contract).
  final int surfaceCount;

  final VoidCallback onConfirm;
  final VoidCallback onCancel;

  const KnitSurfacePanel({
    super.key,
    this.title = 'Knit Surfaces',
    this.tooltip,
    required this.surfaceCount,
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
            'Sewing $surfaceCount surfaces into one',
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
