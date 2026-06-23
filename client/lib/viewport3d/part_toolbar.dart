import 'package:flutter/material.dart';

import 'reference_planes.dart';
import 'render_mode.dart';

/// [PartScreen]'s contextual toolbar - styled and animated to match
/// [SketchRibbon]'s slide-in-from-the-left panel (same [Material] card with
/// rounded trailing corners, same [AnimatedSlide] offscreen-to-the-left
/// hide), opened via [PartScreen]'s persistent top-left toggle button.
/// Always has "Show Feature Tree"; gains a second "New Sketch on
/// [selectedPlane]" action whenever a reference plane is tapped-selected
/// in the 3D viewport, since that's the only other Part-level action this
/// stage adds. Exists as its own widget so future Part-level actions have
/// somewhere to go without growing [PartScreen] itself.
class PartToolbar extends StatelessWidget {
  final bool visible;
  final VoidCallback onShowFeatureTree;

  /// The currently tap-selected reference plane, or null if none is
  /// selected - mirrors [PartViewport]'s controlled `selectedPlane`. Drives
  /// whether the "New Sketch on..." entry below shows at all, and (Fix 4)
  /// its leading color swatch, matching the plane's own
  /// [ReferencePlaneKindX.borderColor] tint in the 3D viewport.
  final ReferencePlaneKind? selectedPlane;
  final VoidCallback? onNewSketchOnPlane;

  /// Stage 10b: whether all three reference planes are currently hidden -
  /// mirrors [PartViewport]'s controlled `referencePlanesHidden`, the same
  /// pattern [selectedPlane] already uses. Flips the toggle entry's
  /// label/icon between "Hide"/"Show".
  final bool referencePlanesHidden;
  final VoidCallback? onToggleReferencePlanes;

  /// Stage 11: the viewport's current display mode - mirrors
  /// [PartViewport]'s controlled `renderMode`, same pattern as
  /// [referencePlanesHidden]. Renders one tappable entry per
  /// [ViewportRenderMode] value (not a single cycling toggle, since three
  /// states don't fit the "label names the next state" convention the
  /// Hide/Show entry above uses), with a check mark on whichever is active.
  final ViewportRenderMode renderMode;
  final void Function(ViewportRenderMode mode)? onRenderModeChanged;

  const PartToolbar({
    super.key,
    required this.visible,
    required this.onShowFeatureTree,
    this.selectedPlane,
    this.onNewSketchOnPlane,
    this.referencePlanesHidden = false,
    this.onToggleReferencePlanes,
    this.renderMode = ViewportRenderMode.shaded,
    this.onRenderModeChanged,
  });

  @override
  Widget build(BuildContext context) {
    final plane = selectedPlane;
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
                        ListTile(
                          leading: Icon(
                            referencePlanesHidden ? Icons.grid_on_outlined : Icons.grid_off_outlined,
                          ),
                          title: Text(
                            referencePlanesHidden ? 'Show Reference Planes' : 'Hide Reference Planes',
                          ),
                          onTap: onToggleReferencePlanes,
                        ),
                        const Divider(height: 1),
                        for (final mode in ViewportRenderMode.values)
                          ListTile(
                            leading: Icon(mode.icon),
                            title: Text(mode.label),
                            trailing: mode == renderMode ? const Icon(Icons.check) : null,
                            onTap: onRenderModeChanged == null
                                ? null
                                : () => onRenderModeChanged!(mode),
                          ),
                        const Divider(height: 1),
                        if (plane != null)
                          ListTile(
                            leading: Icon(Icons.add_box_outlined, color: _colorOf(plane)),
                            title: Text('New Sketch on ${plane.apiValue}'),
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

  /// Converts [plane]'s [ReferencePlaneKindX.borderColor] (a `flutter_scene`
  /// `vm.Vector4`, 0..1 per channel) into a Flutter [Color] for the leading
  /// swatch above - the only place this toolbar needs that conversion.
  Color _colorOf(ReferencePlaneKind plane) {
    final c = plane.borderColor;
    return Color.fromARGB(
      (c.w * 255).round(),
      (c.x * 255).round(),
      (c.y * 255).round(),
      (c.z * 255).round(),
    );
  }
}
