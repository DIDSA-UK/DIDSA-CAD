import 'package:flutter/material.dart';

/// A single curve pickable as one of [FillSurfacePanel]'s boundaries - a
/// checklist entry, not a live 3D-viewport pick: v1 client scope offers
/// every Sketch line/arc/circle/ellipse/spline entity already selected in
/// the viewport (see `part_screen.dart`'s `_startFillSurface`) plus every
/// existing Curve feature in this Part, since neither a Body edge nor (yet)
/// a Curve feature's own wire is independently tappable.
class FillSurfaceBoundaryChoice {
  final String label;
  final bool isCurveFeature;

  const FillSurfaceBoundaryChoice({required this.label, required this.isCurveFeature});
}

/// The bottom-sheet-style panel for creating a Fill Surface - a single
/// surface filling the closed loop formed by 2-4 boundary curves. Mirrors
/// [CreatePlanePanel]'s "dumb display" shape, except the boundary set
/// itself ([selected]) is fixed for the whole panel session (chosen by
/// [PartScreen] from the viewport's own ambient selection before this panel
/// ever opens, the same "picks already made" convention Create Plane's own
/// modes use) - there is nothing left to edit here but Confirm/Cancel.
class FillSurfacePanel extends StatelessWidget {
  final String title;
  final List<FillSurfaceBoundaryChoice> selected;
  final VoidCallback onConfirm;
  final VoidCallback onCancel;

  const FillSurfacePanel({
    super.key,
    this.title = 'Fill Surface',
    required this.selected,
    required this.onConfirm,
    required this.onCancel,
  });

  bool get _canConfirm => selected.length >= 2 && selected.length <= 4;

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
                  '${selected.length} boundary curve${selected.length == 1 ? '' : 's'} selected',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 4),
                for (final choice in selected)
                  Text(
                    '• ${choice.label}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                const SizedBox(height: 8),
                Text(
                  _canConfirm
                      ? 'Fills the surface bounded by these curves'
                      : 'Select 2 to 4 boundary curves (sketch lines/arcs/circles/'
                          'ellipses/splines, or existing Curve features)',
                  style: TextStyle(
                    color: _canConfirm
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
                      onPressed: _canConfirm ? onConfirm : null,
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
