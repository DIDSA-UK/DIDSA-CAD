import 'package:flutter/material.dart';

import 'resizable_tool_panel.dart';

/// Phase 2 surfacing package, third entry: the bottom-sheet-style panel
/// [PartScreen] opens once the multi-select tree picker's `pickingSurfaces`
/// step is confirmed (2+ surface-producing Features picked). Identical UI
/// shape to [KnitSurfacePanel] (the pick step is genuinely the same
/// mechanics for both tools - only the resulting Feature type/API call and
/// this copy differ, see `PartScreen`'s own "Solid from Surfaces" state
/// block for why the state machine itself stays duplicated anyway), just
/// worded for a solid Body result rather than a Surface one, and always
/// mints a brand-new, standalone Body (no Boss/Cut - see the backend
/// `SolidFromSurfacesFeature`'s own docstring).
class SolidFromSurfacesPanel extends StatelessWidget {
  /// 'Solid from Surfaces', or 'Edit Solid from Surfaces' while editing an
  /// already-existing SolidFromSurfacesFeature.
  final String title;

  final String? tooltip;

  /// Mirrors [KnitSurfacePanel.surfaceCount] exactly - always 2+.
  final int surfaceCount;

  final VoidCallback onConfirm;
  final VoidCallback onCancel;

  const SolidFromSurfacesPanel({
    super.key,
    this.title = 'Solid from Surfaces',
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
            'Combining $surfaceCount surfaces into one watertight solid',
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
