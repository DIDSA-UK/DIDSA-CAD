import 'package:material_ui/material_ui.dart';

import '../api/document_api_client.dart';
import 'resizable_tool_panel.dart';
import 'keyboard_shortcuts.dart';

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

  /// The Feature / Body tabs and the Scope field (`seed_scope.dart` [SeedScopeSection], the same widget Pattern shows - bug report
  /// 2026-11-17 items M.3 / M.4), above the Mirror plane field.
  final Widget? scopeSection;

  /// False while the scope cannot make a mirror (empty, or cuts and bodies mixed): Confirm is disabled.
  final bool scopeValid;

  /// Whether viewport picks go to the mirror plane (true) or to the scope; tapping the Mirror plane field calls [onActivatePlane].
  final bool planeActive;
  final VoidCallback? onActivatePlane;

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

  final VoidCallback onConfirm;
  final VoidCallback onCancel;

  const MirrorPanel({
    super.key,
    this.title = 'Mirror',
    this.tooltip,
    required this.hasPlanePicked,
    required this.merge,
    required this.onMergeChanged,
    this.scopeSection,
    this.scopeValid = true,
    this.planeActive = true,
    this.onActivatePlane,
    this.toolFeatureSummary,
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
          if (scopeSection != null) Padding(padding: const EdgeInsets.only(bottom: 12), child: scopeSection),
          InkWell(
            key: const ValueKey('mirror-plane-field'),
            onTap: onActivatePlane,
            borderRadius: BorderRadius.circular(8),
            child: InputDecorator(
              isFocused: planeActive,
              decoration: InputDecoration(
                labelText: 'Mirror plane',
                border: const OutlineInputBorder(),
                isDense: true,
                helperText: planeActive ? 'Tap a face, a reference plane or a plane' : null,
              ),
              child: Text(
                hasPlanePicked ? 'Mirror plane selected' : 'Select a face, reference plane, or plane to mirror about',
                style: TextStyle(
                  color: hasPlanePicked ? Theme.of(context).colorScheme.onSurfaceVariant : Theme.of(context).colorScheme.error,
                  fontSize: 12,
                ),
              ),
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
          ],
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              ToolPanelKeys(onConfirm: hasPlanePicked && scopeValid ? onConfirm : null, onCancel: onCancel),
              TextButton(onPressed: onCancel, child: const Text('Cancel')),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: hasPlanePicked && scopeValid ? onConfirm : null,
                child: const Text('Confirm'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
