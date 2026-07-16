import 'package:flutter/material.dart';

import 'svg_icon.dart';

/// Actions available from the "Add" FAB's second-level Feature picker.
/// [extrude], (C3) [plane], (on-device feedback) [fillet], (Prompt E)
/// [chamfer], (Prompt F) [revolve], and [sweep] are all wired to a real
/// flow.
enum FeaturePickerAction { extrude, plane, fillet, chamfer, revolve, sweep }

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
                leading: const SvgIcon('assets/icons/feature/feature_extrude.svg'),
                title: const Text('Extrude'),
                onTap: () =>
                    Navigator.of(context).pop(FeaturePickerAction.extrude),
              ),
              ListTile(
                leading: const SvgIcon('assets/icons/feature/feature_plane.svg'),
                title: const Text('Plane'),
                onTap: () =>
                    Navigator.of(context).pop(FeaturePickerAction.plane),
              ),
              ListTile(
                leading: const SvgIcon('assets/icons/feature/feature_revolve.svg'),
                title: const Text('Revolve'),
                onTap: () =>
                    Navigator.of(context).pop(FeaturePickerAction.revolve),
              ),
              ListTile(
                leading: const SvgIcon('assets/icons/feature/feature_sweep.svg'),
                title: const Text('Sweep'),
                onTap: () =>
                    Navigator.of(context).pop(FeaturePickerAction.sweep),
              ),
              ListTile(
                leading: const SvgIcon('assets/icons/feature/feature_fillet.svg'),
                title: const Text('Fillet'),
                onTap: () =>
                    Navigator.of(context).pop(FeaturePickerAction.fillet),
              ),
              ListTile(
                leading: const SvgIcon('assets/icons/feature/feature_chamfer.svg'),
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
