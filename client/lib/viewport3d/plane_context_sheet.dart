import 'package:flutter/material.dart';

import 'reference_planes.dart';
import 'svg_icon.dart';

/// Actions available from a tap-selected reference plane's fly-up bottom
/// sheet. Stage 19b Item 2 moved this out of the hamburger drawer (where it
/// sat as a one-off "New Sketch on..." entry alongside the static File/View
/// menus) into its own sheet, opened directly from the 3D viewport tap.
enum PlaneContextSheetAction { newSketch }

/// Shows the fly-up bottom sheet of contextual actions for [plane], tapped
/// in the 3D viewport - a drag handle, a title row naming the selected
/// plane, then its one action (more may be added alongside it in later
/// stages without restructuring this call site, the same reasoning
/// [showFeatureContextMenu] already follows for a Feature's long-press menu).
Future<PlaneContextSheetAction?> showPlaneContextSheet(
  BuildContext context, {
  required ReferencePlaneKind plane,
}) {
  return showModalBottomSheet<PlaneContextSheetAction>(
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
                SvgIcon('assets/icons/feature/feature_plane.svg', color: _colorOf(plane)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Reference Plane — ${plane.apiValue}',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              ],
            ),
          ),
          ListTile(
            leading: const SvgIcon('assets/icons/feature/feature_new_sketch.svg'),
            title: Text('New Sketch on ${plane.apiValue}'),
            onTap: () => Navigator.of(context).pop(PlaneContextSheetAction.newSketch),
          ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
}

/// Converts [plane]'s [ReferencePlaneKindX.borderColor] (a `flutter_scene`
/// `vm.Vector4`, 0..1 per channel) into a Flutter [Color] for the title
/// row's leading swatch above.
Color _colorOf(ReferencePlaneKind plane) {
  final c = plane.borderColor;
  return Color.fromARGB(
    (c.w * 255).round(),
    (c.x * 255).round(),
    (c.y * 255).round(),
    (c.z * 255).round(),
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
