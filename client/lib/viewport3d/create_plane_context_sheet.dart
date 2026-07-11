import 'package:flutter/material.dart';

import 'svg_icon.dart';

/// C3: actions available from a tap-selected created Plane's fly-up bottom
/// sheet - mirrors `plane_context_sheet.dart`'s [PlaneContextSheetAction]
/// for the three fixed reference planes, just for a `CreatePlaneFeature`
/// instead: [newSketch] ("Create Sketch on Plane") and [delete] ("Delete
/// Plane").
enum CreatePlaneContextSheetAction { newSketch, delete }

/// Shows the fly-up bottom sheet of contextual actions for the created Plane
/// [featureId] - a drag handle, a title row, then its two actions. Same
/// shape/presentation as [showPlaneContextSheet], so both kinds of plane the
/// viewport renders (fixed reference planes and created ones) feel
/// consistent to tap.
Future<CreatePlaneContextSheetAction?> showCreatePlaneContextSheet(
  BuildContext context, {
  required String featureId,
}) {
  return showModalBottomSheet<CreatePlaneContextSheetAction>(
    context: context,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: _DragHandle(),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Row(
              children: [
                const SvgIcon('assets/icons/feature/feature_plane.svg', color: Color(0xFFF5A623)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('Plane', style: Theme.of(context).textTheme.titleMedium),
                ),
              ],
            ),
          ),
          ListTile(
            leading: const SvgIcon('assets/icons/feature/feature_new_sketch.svg'),
            title: const Text('Create Sketch on Plane'),
            onTap: () => Navigator.of(context).pop(CreatePlaneContextSheetAction.newSketch),
          ),
          ListTile(
            leading: Icon(Icons.delete_outline, color: Theme.of(context).colorScheme.error),
            title: Text('Delete Plane', style: TextStyle(color: Theme.of(context).colorScheme.error)),
            onTap: () => Navigator.of(context).pop(CreatePlaneContextSheetAction.delete),
          ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
}

class _DragHandle extends StatelessWidget {
  const _DragHandle();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 32,
      height: 4,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(2),
      ),
    );
  }
}
