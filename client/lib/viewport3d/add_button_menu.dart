import 'package:flutter/material.dart';

import 'svg_icon.dart';

/// Actions available from the floating "Add" button's flyout. Stage 10b adds
/// [newSketch]; Stage 19b Item 3 adds [feature] (opens the second-level
/// Feature picker - see [showFeaturePickerSheet]) alongside it.
enum AddButtonMenuAction { newSketch, feature }

/// Shows a bottom sheet of actions for the "Add" FAB, replacing its old
/// direct-to-`_addSketchFeature` behaviour - per the Stage 10b brief, the FAB
/// should open a flyout rather than act directly.
Future<AddButtonMenuAction?> showAddButtonMenu(BuildContext context) {
  return showModalBottomSheet<AddButtonMenuAction>(
    context: context,
    builder: (context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const SvgIcon('assets/icons/feature/feature_new_sketch.svg'),
            title: const Text('New Sketch'),
            onTap: () => Navigator.of(context).pop(AddButtonMenuAction.newSketch),
          ),
          ListTile(
            leading: const SvgIcon('assets/icons/feature/feature_tree.svg'),
            title: const Text('Feature'),
            onTap: () => Navigator.of(context).pop(AddButtonMenuAction.feature),
          ),
        ],
      ),
    ),
  );
}
