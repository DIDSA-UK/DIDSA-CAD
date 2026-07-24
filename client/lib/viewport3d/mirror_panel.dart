import 'package:flutter/material.dart';

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

  /// True once a mirror plane has been picked in the viewport (a face, a
  /// fixed reference plane, or an existing Plane) - see
  /// [PartScreen._currentMirrorPlaneRef]. Confirm is disabled until then,
  /// same "nothing valid to create yet" reasoning [FilletPanel]'s radius
  /// field uses, just driven by a viewport pick instead of a text field.
  final bool hasPlanePicked;

  final VoidCallback onConfirm;
  final VoidCallback onCancel;

  const MirrorPanel({
    super.key,
    this.title = 'Mirror',
    required this.hasPlanePicked,
    required this.onConfirm,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.bottomCenter,
      child: SafeArea(
        top: false,
        child: Material(
          elevation: 4,
          borderRadius: const BorderRadius.only(topLeft: Radius.circular(12), topRight: Radius.circular(12)),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                const SizedBox(height: 12),
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
          ),
        ),
      ),
    );
  }
}
