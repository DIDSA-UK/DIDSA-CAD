import 'package:flutter/material.dart';

/// Actions available from the "Add" FAB's second-level Feature picker.
/// [extrude], (C3) [plane], (on-device feedback) [fillet], (Prompt E)
/// [chamfer], and (Prompt F) [revolve] are wired to a real flow - Sweep is
/// still listed (per the Stage 19b brief) but rendered disabled since this
/// codebase has no flow for it yet.
enum FeaturePickerAction { extrude, plane, fillet, chamfer, revolve }

/// Shows the fly-up bottom sheet listing every feature type the "Add" FAB's
/// Feature entry offers - same drag-handle/rounded-top-corner shape as
/// [showPlaneContextSheet], so both Stage 19b fly-ups feel consistent.
Future<FeaturePickerAction?> showFeaturePickerSheet(BuildContext context) {
  return showModalBottomSheet<FeaturePickerAction>(
    context: context,
    // C3: added a sixth entry (Plane) - scroll-controlled so this sheet can
    // grow past its old fixed-fraction default height instead of clipping/
    // overflowing on a short viewport (a small phone in landscape, or a
    // split-screen window) the way a fixed-size six-row sheet otherwise
    // risks doing.
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (context) {
      final disabledColor = Theme.of(context).disabledColor;
      return SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: _DragHandle(),
              ),
              ListTile(
                leading: const Icon(Icons.move_to_inbox_outlined),
                title: const Text('Extrude'),
                onTap: () =>
                    Navigator.of(context).pop(FeaturePickerAction.extrude),
              ),
              ListTile(
                leading: const Icon(Icons.crop_square),
                title: const Text('Plane'),
                onTap: () =>
                    Navigator.of(context).pop(FeaturePickerAction.plane),
              ),
              ListTile(
                leading: const Icon(Icons.rotate_right),
                title: const Text('Revolve'),
                onTap: () =>
                    Navigator.of(context).pop(FeaturePickerAction.revolve),
              ),
              ListTile(
                enabled: false,
                leading: Icon(Icons.gesture, color: disabledColor),
                title: Text('Sweep', style: TextStyle(color: disabledColor)),
              ),
              ListTile(
                leading: const Icon(Icons.rounded_corner),
                title: const Text('Fillet'),
                onTap: () =>
                    Navigator.of(context).pop(FeaturePickerAction.fillet),
              ),
              ListTile(
                leading: const Icon(Icons.change_history),
                title: const Text('Chamfer'),
                onTap: () =>
                    Navigator.of(context).pop(FeaturePickerAction.chamfer),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      );
    },
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
