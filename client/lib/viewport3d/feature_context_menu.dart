import 'package:flutter/material.dart';

/// Actions available from a Feature's long-press context menu. Stage 7e
/// adds only [delete] - later stages can add entries here (e.g. rename,
/// edit) without changing how the menu itself is shown or wired up.
enum FeatureContextMenuAction { delete }

/// Shows a bottom sheet of actions for a single Feature, opened by a
/// long-press on its row in the tree. A bottom sheet - rather than wiring
/// long-press directly to a single action - is what lets later stages add
/// more entries alongside Delete without restructuring this call site or
/// [FeatureTreePanel].
Future<FeatureContextMenuAction?> showFeatureContextMenu(BuildContext context) {
  return showModalBottomSheet<FeatureContextMenuAction>(
    context: context,
    builder: (context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.delete, color: Colors.red),
            title: const Text('Delete'),
            onTap: () => Navigator.of(context).pop(FeatureContextMenuAction.delete),
          ),
        ],
      ),
    ),
  );
}
