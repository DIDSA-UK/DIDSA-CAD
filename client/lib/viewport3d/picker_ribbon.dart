import 'package:flutter/material.dart';

/// [ResizableToolPanel]'s sibling for a pure viewport-picking mode that has
/// no fields/form of its own yet (picking a Sweep path, a Profile, a plane
/// for a new Sketch, or the seed Body/Bodies for Mirror/Pattern) - on-
/// device feedback ("check the other tools for the same problem"): these
/// used to show a full-width banner floating at `top: 8`, blocking the
/// same corner FABs [ResizableToolPanel]'s own doc comment describes for
/// every panel-backed tool. Same title-plus-divider-plus-tooltip header,
/// but fixed height and non-scrollable (there is no further content below
/// it to make scrolling meaningful) and no drag handle.
///
/// [showConfirm] is `false` for a mode that auto-advances the instant
/// something is tapped (Pattern's/plane-selection's own single-pick steps,
/// which have never had a separate confirm action) - the button is
/// omitted outright, not just disabled, since there is no confirm step to
/// even land on. When `true` (Sweep's path picker, the Profile picker,
/// Mirror's body picker), [onConfirm] being `null` renders it present but
/// disabled - the same "pass null to disable" convention every
/// `FloatingActionButton.onPressed` here already uses - rather than
/// hidden, so the button doesn't pop in/out of existence as the picked
/// count crosses zero.
///
/// Pattern/Mirror scoping's Phase 6 (on-device feedback: "on the flyup
/// ribbon, there should be an extra button that says 'select feature'"):
/// [extraActionLabel]/[onExtraAction] add one optional extra button to the
/// button row, for a picking mode that offers a second way to add to the
/// same in-progress selection (Pattern's own `pickingBodies` step - see
/// `PartScreen._startPatternPicker` - can be seeded from a Body tap in the
/// viewport *or* a Feature-tree pick via this button, opening the Build
/// Tree's own multi-select picker without leaving `pickingBodies`). `null`
/// (the default) omits it entirely, same "omitted, not just disabled"
/// convention [showConfirm] uses.
///
/// Bug fix (on-device feedback: "the select ribbon with tool tip shows
/// overflow error"): title, divider, tooltip, [extraActionLabel] and
/// Cancel/Confirm used to all share one `Row`, which overflowed on narrow
/// phone screens the moment [extraActionLabel] was non-null and the
/// tooltip text was of any real length. The title/divider/tooltip now sit
/// in their own row (matching [ResizableToolPanel]'s own title-row
/// convention, which wraps the tooltip in an `Expanded` on a row of its
/// own) and the buttons sit below in a right-aligned `Wrap` - mirrors
/// every panel's own Cancel/Confirm row shape (see e.g. `PatternPanel`'s
/// `mainAxisAlignment: MainAxisAlignment.end` row), but wraps to a second
/// line instead of overflowing on the narrowest phone widths, where
/// [extraActionLabel] plus Cancel plus Confirm together still don't fit
/// on one line.
class PickerRibbon extends StatelessWidget {
  final String title;
  final String tooltip;
  final VoidCallback onCancel;
  final bool showConfirm;
  final VoidCallback? onConfirm;
  final String? extraActionLabel;
  final VoidCallback? onExtraAction;

  const PickerRibbon({
    super.key,
    required this.title,
    required this.tooltip,
    required this.onCancel,
    this.showConfirm = false,
    this.onConfirm,
    this.extraActionLabel,
    this.onExtraAction,
  });

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.bottomCenter,
      child: SafeArea(
        top: false,
        child: Material(
          elevation: 4,
          borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(12), topRight: Radius.circular(12)),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Text(title,
                        style: const TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 16)),
                    const SizedBox(width: 12),
                    SizedBox(
                      height: 18,
                      child: VerticalDivider(
                          width: 1,
                          thickness: 1,
                          color: Theme.of(context).colorScheme.outlineVariant),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        tooltip,
                        style: TextStyle(
                            fontSize: 13,
                            color: Theme.of(context).colorScheme.onSurfaceVariant),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Wrap(
                  alignment: WrapAlignment.end,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 4,
                  runSpacing: 4,
                  children: [
                    if (extraActionLabel != null)
                      TextButton.icon(
                        onPressed: onExtraAction,
                        icon: const Icon(Icons.account_tree_outlined, size: 16),
                        label: Text(extraActionLabel!),
                      ),
                    TextButton(onPressed: onCancel, child: const Text('Cancel')),
                    if (showConfirm)
                      IconButton.filled(
                        tooltip: 'Confirm',
                        onPressed: onConfirm,
                        icon: const Icon(Icons.check),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
