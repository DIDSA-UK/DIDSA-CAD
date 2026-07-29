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
class PickerRibbon extends StatelessWidget {
  final String title;
  final String tooltip;
  final VoidCallback onCancel;
  final bool showConfirm;
  final VoidCallback? onConfirm;

  const PickerRibbon({
    super.key,
    required this.title,
    required this.tooltip,
    required this.onCancel,
    this.showConfirm = false,
    this.onConfirm,
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
            child: Row(
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
                const SizedBox(width: 12),
                TextButton(onPressed: onCancel, child: const Text('Cancel')),
                if (showConfirm) ...[
                  const SizedBox(width: 4),
                  IconButton.filled(
                    tooltip: 'Confirm',
                    onPressed: onConfirm,
                    icon: const Icon(Icons.check),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
