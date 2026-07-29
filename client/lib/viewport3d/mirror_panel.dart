import 'package:flutter/material.dart';

import '../api/document_api_client.dart';
import 'resizable_tool_panel.dart';

/// Pattern/Mirror scoping's Phase 1 (`docs/pattern-mirror-scope.md`
/// §2.1/§4): the bottom-sheet-style panel [PartScreen] opens once Mirror is
/// enabled (a single Body selected - see `selection_actions.dart`'s
/// `contextActionsFor`) - mirrors [FilletPanel]'s Confirm/Cancel session
/// shape and slide-up presentation exactly. Unlike [FilletPanel], Phase 1
/// has no numeric field at all - the only thing to pick is the mirror
/// plane itself (a Body face, a fixed reference plane, or an existing
/// Plane feature, via [PlaneRefDto] - see [PartScreen._planeRefDtoFor]),
/// picked live in the viewport while this panel is open, so Confirm is
/// enabled once [hasPlanePicked] is true and disabled (with hint text)
/// otherwise - mirrors [CreatePlanePanel]'s own no-numeric-field modes
/// (e.g. [CreatePlaneMode.normalToLineAtPoint]).
class MirrorPanel extends StatelessWidget {
  /// 'Mirror' when creating a brand-new Feature (default), 'Edit Mirror'
  /// when [PartScreen] opened this to edit an already-existing one instead -
  /// purely a label, same convention as [FilletPanel.title].
  final String title;

  /// On-device feedback ("the tooltip at the top of the screen blocks the
  /// FABs"): see [ResizableToolPanel]'s own doc comment - the guided-entry
  /// "Select Mirror Plane or Face" banner text, now shown in the title row
  /// instead of a separate floating banner. Null once a plane is picked
  /// (this panel's own status line below already covers that state).
  final String? tooltip;

  /// True once a mirror plane has been picked in the viewport (a face, a
  /// fixed reference plane, or an existing Plane) - see
  /// [PartScreen._currentMirrorPlaneRef]. Confirm is disabled until then,
  /// same "nothing valid to create yet" reasoning [FilletPanel]'s radius
  /// field uses, just driven by a viewport pick instead of a text field.
  final bool hasPlanePicked;

  /// Pattern/Mirror scoping's Phase 5 (`docs/pattern-mirror-scope.md`
  /// §2.10/§4): `MergeMode.keepSeparate` (the default - every mirrored
  /// copy registers as its own Body) or `MergeMode.fuseIntoOne` (every
  /// mirrored copy plus every source Body fused together into one).
  final MergeMode merge;
  final void Function(MergeMode merge) onMergeChanged;

  final VoidCallback onConfirm;
  final VoidCallback onCancel;

  const MirrorPanel({
    super.key,
    this.title = 'Mirror',
    this.tooltip,
    required this.hasPlanePicked,
    required this.merge,
    required this.onMergeChanged,
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
            hasPlanePicked
                ? 'Mirror plane selected'
                : 'Select a face, reference plane, or plane to mirror about',
            style: TextStyle(
              color: hasPlanePicked
                  ? Theme.of(context).colorScheme.onSurfaceVariant
                  : Theme.of(context).colorScheme.error,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 12),
          SegmentedButton<MergeMode>(
            segments: const [
              ButtonSegment(
                  value: MergeMode.keepSeparate, label: Text('Keep Separate')),
              ButtonSegment(
                  value: MergeMode.fuseIntoOne,
                  label: Text('Merge into One Body')),
            ],
            selected: {merge},
            onSelectionChanged: (selection) => onMergeChanged(selection.first),
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(onPressed: onCancel, child: const Text('Cancel')),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: hasPlanePicked ? onConfirm : null,
                child: const Text('Confirm'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
