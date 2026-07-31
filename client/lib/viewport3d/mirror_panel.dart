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

  /// Pattern/Mirror scoping's Phase 6 (`docs/pattern-mirror-scope.md`
  /// §2.8/§4): Feature-tree entries (by Feature id) named as additional
  /// mirror sources, on top of whatever Bodies were picked in the viewport
  /// - see [PartScreen._mirrorSourceFeatureIds]. Only their count is shown
  /// here (a full name-per-entry list would need a Feature lookup this
  /// panel doesn't otherwise need) - [onPickSourceFeatures] opens the
  /// Build Tree in its own multi-select picker mode to add/remove entries.
  final List<String> sourceFeatureIds;
  final VoidCallback onPickSourceFeatures;

  /// Pattern/Mirror scoping's Phase 8 (`docs/pattern-mirror-scope.md`
  /// §2.11/§4): non-null while this session's seed is the third,
  /// mutually-exclusive `tool_feature_id` mode (entered via a long-press
  /// "Mirror" on an eligible upstream Cut/Boss - see
  /// `PartScreen._openMirrorPanelFromFeature`) rather than a Body/
  /// Feature-tree pick - a short display name for the referenced Feature
  /// (e.g. "Extrude 2"). When set, the [sourceFeatureIds]/[merge] rows are
  /// replaced with a single status line, since neither is user-editable in
  /// this mode (`merge` is forced to `fuseIntoOne` server-side - see the
  /// backend's own `_validate_tool_feature_id`).
  final String? toolFeatureSummary;

  /// Pattern/Mirror scoping's Phase 9 (`docs/pattern-mirror-scope.md`
  /// §2.12/§4): non-null only while this session was opened via a
  /// Feature's own long-press "Mirror" entry *and* that Feature qualifies
  /// for both seed kinds (`source_feature_ids`/`tool_feature_id`) - shows
  /// the "Mirror Body"/"Mirror Feature" toggle, letting the user switch
  /// which of the two mutually-exclusive fields carries the seed Feature's
  /// id (see `PartScreen._mirrorSeedKind`). Null (hidden) for every other
  /// seed path - an ambient Body selection, an Add-from-Tree pick, editing
  /// an existing Feature, or a long-press seed that only qualifies for one
  /// kind - in which case [toolFeatureSummary]/[sourceFeatureIds] already
  /// unambiguously show which single mode is active, with nothing to
  /// toggle. Mirrors [PatternPanel.seedKind]'s own identical shape.
  final PatternMirrorSeedKind? seedKind;
  final void Function(PatternMirrorSeedKind kind)? onSeedKindChanged;

  final VoidCallback onConfirm;
  final VoidCallback onCancel;

  const MirrorPanel({
    super.key,
    this.title = 'Mirror',
    this.tooltip,
    required this.hasPlanePicked,
    required this.merge,
    required this.onMergeChanged,
    this.sourceFeatureIds = const [],
    required this.onPickSourceFeatures,
    this.toolFeatureSummary,
    this.seedKind,
    this.onSeedKindChanged,
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
          if (seedKind != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: SegmentedButton<PatternMirrorSeedKind>(
                segments: const [
                  ButtonSegment(value: PatternMirrorSeedKind.body, label: Text('Mirror Body')),
                  ButtonSegment(value: PatternMirrorSeedKind.feature, label: Text('Mirror Feature')),
                ],
                selected: {seedKind!},
                onSelectionChanged: (selection) => onSeedKindChanged?.call(selection.first),
              ),
            ),
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
          if (toolFeatureSummary != null)
            Row(
              children: [
                Icon(Icons.account_tree_outlined,
                    size: 16, color: Theme.of(context).colorScheme.onSurfaceVariant),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'Mirroring $toolFeatureSummary into its own target - always merges',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
            )
          else ...[
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
              children: [
                Expanded(
                  child: Text(
                    sourceFeatureIds.isEmpty
                        ? 'No Features added from the Build Tree'
                        : '${sourceFeatureIds.length} Feature'
                            '${sourceFeatureIds.length == 1 ? '' : 's'} added from the Build Tree',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      fontSize: 12,
                    ),
                  ),
                ),
                TextButton.icon(
                  onPressed: onPickSourceFeatures,
                  icon: const Icon(Icons.account_tree_outlined, size: 16),
                  label: const Text('Add from Tree'),
                ),
              ],
            ),
          ],
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
