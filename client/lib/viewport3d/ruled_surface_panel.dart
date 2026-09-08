import 'package:flutter/material.dart';

import 'resizable_tool_panel.dart';

/// The bottom-sheet-style panel [PartScreen] opens for a Ruled Surface - the
/// simplest of the Phase 1 surfacing tools after Planar Surface (see the
/// backend `RuledSurfaceFeature`'s own docstring): exactly 2 sections
/// (picked before this panel ever opens - see [PartScreen]'s own section-
/// picking flow, capped at 2 and auto-confirming the instant the 2nd is
/// picked), no ruled toggle, no reference-point/alignment-point/guide-curve
/// UI at all - just a summary of the two picked sections plus Confirm/
/// Cancel.
///
/// Same "nothing to debounce" shape as [PlanarSurfacePanel] - the Feature is
/// created once, eagerly, the instant the panel opens.
class RuledSurfacePanel extends StatelessWidget {
  /// 'Ruled Surface' when creating a brand-new Feature (default), 'Edit
  /// Ruled Surface' when [PartScreen] opened this to edit an already-
  /// existing one instead.
  final String title;

  final String? tooltip;

  /// The two picked sections' own display names (e.g. "Sketch 1", "Sketch
  /// 2") - purely informational, nothing here changes them.
  final List<String> sectionNames;

  /// Mirrors [PlanarSurfacePanel.ready] exactly.
  final bool ready;

  final VoidCallback onConfirm;
  final VoidCallback onCancel;

  const RuledSurfacePanel({
    super.key,
    this.title = 'Ruled Surface',
    this.tooltip,
    required this.sectionNames,
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
          for (var i = 0; i < sectionNames.length; i++)
            Text(
              'Section ${i + 1}: ${sectionNames[i]}',
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
