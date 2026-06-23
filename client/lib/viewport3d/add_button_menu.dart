import 'package:flutter/material.dart';

/// Actions available from the floating "Add" button's flyout. Stage 10b adds
/// just [newSketch]; structured as an enum (mirroring
/// [FeatureContextMenuAction]) so a later stage can add more entries (e.g.
/// "Import", "New plane") without reworking how the menu itself is shown.
enum AddButtonMenuAction { newSketch }

/// Shows a bottom sheet of actions for the "Add" FAB, replacing its old
/// direct-to-`_addSketchFeature` behaviour - per the Stage 10b brief, the FAB
/// should open a flyout rather than act directly, even though for now it
/// only ever offers one entry.
Future<AddButtonMenuAction?> showAddButtonMenu(BuildContext context) {
  return showModalBottomSheet<AddButtonMenuAction>(
    context: context,
    builder: (context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.edit_outlined),
            title: const Text('New Sketch'),
            onTap: () => Navigator.of(context).pop(AddButtonMenuAction.newSketch),
          ),
        ],
      ),
    ),
  );
}
