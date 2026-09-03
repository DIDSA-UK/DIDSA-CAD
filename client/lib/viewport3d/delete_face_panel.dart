import 'package:flutter/material.dart';

import 'resizable_tool_panel.dart';

/// Direct Editing family, fourth entry: the bottom-sheet-style panel
/// [PartScreen] opens once one or more faces of the same solid Body are
/// selected and "Delete Face" is chosen (see `selection_actions.dart`'s
/// `contextActionsFor` multi-face branch). Mirrors [FilletPanel]'s "just the
/// value field(s)/summary, the viewport does the picking" shape - a
/// DeleteFaceFeature has no per-face options of its own (V2: one shared
/// removal applied to every face in `face_refs`, live-re-pickable the same
/// way Fillet's `edge_refs` is - see `docs/direct-editing-scope.md`), so
/// this is just a live face-count summary plus Cancel/Confirm.
class DeleteFacePanel extends StatelessWidget {
  /// 'Delete Face', or 'Edit Delete Face' while editing an already-existing
  /// DeleteFaceFeature - matches every other panel's `title` param.
  final String title;

  final String? tooltip;

  /// The live count of faces currently picked (`_currentDeleteFaceRefs().
  /// length` in `part_screen.dart`) - updates immediately as the user taps
  /// faces in the viewport, mirroring how [FilletPanel] shows its own live
  /// radius.
  final int faceCount;

  final VoidCallback onConfirm;
  final VoidCallback onCancel;

  const DeleteFacePanel({
    super.key,
    this.title = 'Delete Face',
    this.tooltip,
    required this.faceCount,
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
            faceCount == 0
                ? 'Tap one or more faces of the same body to delete'
                : 'Deleting $faceCount ${faceCount == 1 ? 'face' : 'faces'}',
            style: TextStyle(
              color: faceCount == 0
                  ? Theme.of(context).colorScheme.error
                  : Theme.of(context).colorScheme.onSurfaceVariant,
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
                onPressed: faceCount > 0 ? onConfirm : null,
                style: FilledButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.error,
                  foregroundColor: Theme.of(context).colorScheme.onError,
                ),
                child: const Text('Delete'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
