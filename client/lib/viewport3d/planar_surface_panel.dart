import 'package:flutter/material.dart';

import 'resizable_tool_panel.dart';

/// The bottom-sheet-style panel [PartScreen] opens for a Planar Surface -
/// the simplest of the Phase 1 surfacing tools (see the backend
/// `PlanarSurfaceFeature`'s own docstring): a flat face straight from an
/// already-picked SketchFeature's closed Profile, with no further
/// parameters of its own at all - no Boss/Cut, no target-body picking, no
/// distance/angle/path field to edit. This panel is purely a summary +
/// Confirm/Cancel, mirroring [SurfacePanel]'s overall shape minus every
/// field it has.
///
/// Unlike every other panel in this family, there is nothing here for
/// [PartScreen] to debounce a live-preview update for - the Feature is
/// created once, eagerly, the instant the panel opens (see
/// [PartScreen._ensurePlanarSurfaceFeatureExists]), and never PATCHed again
/// until Confirm/Cancel.
class PlanarSurfacePanel extends StatelessWidget {
  /// 'Planar Surface' when creating a brand-new Feature (default), 'Edit
  /// Planar Surface' when [PartScreen] opened this to edit an already-
  /// existing one instead - purely a label, same convention as
  /// [SurfacePanel.title].
  final String title;

  final String? tooltip;

  /// Whether the backing PlanarSurfaceFeature has actually been created (or,
  /// in edit mode, already exists) yet - `false` only for the brief window
  /// between the panel opening and its eager create call resolving. Confirm
  /// stays disabled until this is `true`, since there's nothing yet to
  /// confirm.
  final bool ready;

  final VoidCallback onConfirm;
  final VoidCallback onCancel;

  const PlanarSurfacePanel({
    super.key,
    this.title = 'Planar Surface',
    this.tooltip,
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
            'A flat face straight from the selected sketch\'s closed profile.',
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
