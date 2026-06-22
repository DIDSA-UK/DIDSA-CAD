import 'package:flutter/material.dart';

/// [PartScreen]'s contextual toolbar - styled and animated to match
/// [SketchRibbon]'s slide-in-from-the-left panel (same [Material] card with
/// rounded trailing corners, same [AnimatedSlide] offscreen-to-the-left
/// hide), opened via [PartScreen]'s persistent top-left toggle button.
/// Always has "Show Feature Tree"; gains a second "New Sketch on
/// [selectedPlaneLabel]" action whenever a reference plane is tapped-selected
/// in the 3D viewport, since that's the only other Part-level action this
/// stage adds. Exists as its own widget so future Part-level actions have
/// somewhere to go without growing [PartScreen] itself.
class PartToolbar extends StatelessWidget {
  final bool visible;
  final VoidCallback onShowFeatureTree;

  /// The currently tap-selected reference plane's display label (e.g.
  /// `'XY'`), or null if none is selected - mirrors [PartViewport]'s
  /// controlled `selectedPlane`. Drives whether the "New Sketch on..." entry
  /// below shows at all.
  final String? selectedPlaneLabel;
  final VoidCallback? onNewSketchOnPlane;

  const PartToolbar({
    super.key,
    required this.visible,
    required this.onShowFeatureTree,
    this.selectedPlaneLabel,
    this.onNewSketchOnPlane,
  });

  @override
  Widget build(BuildContext context) {
    final planeLabel = selectedPlaneLabel;
    return Align(
      alignment: Alignment.topLeft,
      child: ClipRect(
        child: AnimatedSlide(
          offset: visible ? Offset.zero : const Offset(-1.05, 0),
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
          child: SafeArea(
            bottom: false,
            child: Padding(
              // Clears the persistent toggle button this is opened from,
              // which sits in the same top-left corner.
              padding: const EdgeInsets.only(top: 56),
              child: Material(
                elevation: 4,
                borderRadius: const BorderRadius.only(
                  topRight: Radius.circular(12),
                  bottomRight: Radius.circular(12),
                ),
                child: SizedBox(
                  width: 220,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        ListTile(
                          leading: const Icon(Icons.account_tree_outlined),
                          title: const Text('Show Feature Tree'),
                          onTap: onShowFeatureTree,
                        ),
                        if (planeLabel != null)
                          ListTile(
                            leading: const Icon(Icons.add_box_outlined),
                            title: Text('New Sketch on $planeLabel'),
                            onTap: onNewSketchOnPlane,
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
