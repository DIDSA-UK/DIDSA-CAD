import 'package:flutter/material.dart';

/// Actions available from a Feature's long-press context menu. Stage 8 adds
/// [toggleVisibility] above the existing [delete] - later stages can add
/// further entries here without changing how the menu itself is shown or
/// wired up.
enum FeatureContextMenuAction { toggleVisibility, delete }

/// Shows a bottom sheet of actions for a single Feature, opened by a
/// long-press on its row in the tree. A bottom sheet - rather than wiring
/// long-press directly to a single action - is what lets later stages add
/// more entries alongside Delete without restructuring this call site or
/// [FeatureTreePanel].
///
/// [isHidden] selects the Hide/Show label and icon for the toggle-visibility
/// entry, reflecting that Feature's current state in [PartScreen].
Future<FeatureContextMenuAction?> showFeatureContextMenu(
  BuildContext context, {
  required bool isHidden,
}) {
  return showModalBottomSheet<FeatureContextMenuAction>(
    context: context,
    builder: (context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: Icon(isHidden ? Icons.visibility : Icons.visibility_off),
            title: Text(isHidden ? 'Show' : 'Hide'),
            onTap: () => Navigator.of(context).pop(FeatureContextMenuAction.toggleVisibility),
          ),
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
