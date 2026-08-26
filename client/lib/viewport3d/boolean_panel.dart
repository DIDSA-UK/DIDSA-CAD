import 'package:flutter/material.dart';

import 'resizable_tool_panel.dart';

/// Boolean family, Subtract/Common: the bottom-sheet-style panel [PartScreen]
/// opens once the two-stage guided Subtract/Common flow's tool-picking stage
/// is confirmed (1+ target Bodies, then 1+ tool Bodies - see
/// `selection_actions.dart`'s `contextActionsFor` for the ambient entry's own
/// identical gate, pre-seeding stage 1 from the current selection and
/// jumping straight to stage 2). Shared by both Subtract and Common - the
/// backend `BooleanFeature`'s own docstring covers why the two operations
/// are otherwise pixel-identical (same target/tool Bodies, same consume-vs-
/// keep option, differing only in which OCCT boolean call runs) -
/// [isSubtract] only varies this panel's own header verb/icon; the caller
/// ([PartScreen]) is the one that actually sends the right `BooleanOperation`
/// on create/update. Mirrors [MergePanel]'s own summary-row-plus-Cancel/
/// Confirm shape, plus the Keep/Consume Tool Bodies toggle - a two-state
/// option, [MirrorPanel]'s own `MergeMode` `SegmentedButton` is this
/// control's established template, not a `Checkbox`.
class BooleanPanel extends StatelessWidget {
  /// 'Subtract'/'Common', or 'Edit Subtract'/'Edit Common' while editing an
  /// already-existing BooleanFeature - matches every other panel's `title`
  /// param (see `PartScreen._openBooleanPanelForEdit`).
  final String title;

  /// True for Subtract, false for Common - drives this panel's own header
  /// icon/summary-copy only ([title] already carries the verb).
  final bool isSubtract;

  final String? tooltip;

  /// How many Bodies were picked in each of the guided flow's two stages -
  /// always 1+ each by the time this panel is shown (both the guided and
  /// ambient entries gate on it, same reasoning as [MergePanel.bodyCount]).
  final int targetBodyCount;
  final int toolBodyCount;

  /// Whether [toolBodyCount] Bodies are deleted once the operation runs
  /// (`true`, the default - matches the backend's own `BooleanFeature.
  /// consume_tool_bodies` default) or kept registered and untouched
  /// (`false`).
  final bool consumeToolBodies;
  final void Function(bool consume) onConsumeToolBodiesChanged;

  final VoidCallback onConfirm;
  final VoidCallback onCancel;

  const BooleanPanel({
    super.key,
    required this.title,
    required this.isSubtract,
    this.tooltip,
    required this.targetBodyCount,
    required this.toolBodyCount,
    required this.consumeToolBodies,
    required this.onConsumeToolBodiesChanged,
    required this.onConfirm,
    required this.onCancel,
  });

  static String _pluralBody(int count) => count == 1 ? 'body' : 'bodies';

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
                isSubtract ? Icons.remove_circle_outline : Icons.layers_outlined,
                size: 16,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  isSubtract
                      ? 'Subtracting $toolBodyCount tool ${_pluralBody(toolBodyCount)} from '
                          '$targetBodyCount target ${_pluralBody(targetBodyCount)}'
                      : 'Keeping the shared volume of $targetBodyCount target '
                          '${_pluralBody(targetBodyCount)} and $toolBodyCount tool '
                          '${_pluralBody(toolBodyCount)}',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    fontSize: 12,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: false, label: Text('Keep Tool Bodies')),
              ButtonSegment(value: true, label: Text('Consume Tool Bodies')),
            ],
            selected: {consumeToolBodies},
            onSelectionChanged: (selection) => onConsumeToolBodiesChanged(selection.first),
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
