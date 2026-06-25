import 'package:flutter/material.dart';

import 'reference_planes.dart';
import 'render_mode.dart';
import 'view_prefs_sheets.dart';
import 'view_preferences.dart';

/// [PartScreen]'s contextual toolbar - styled and animated to match
/// [SketchRibbon]'s slide-in-from-the-left panel (same [Material] card with
/// rounded trailing corners, same [AnimatedSlide] offscreen-to-the-left
/// hide), opened via [PartScreen]'s persistent top-left toggle button.
///
/// Stage 18 restructures this into the brief's two top-level categories,
/// File and View, as [ExpansionTile]s. "New Sketch on [selectedPlane]" -
/// the one contextual action this toolbar shows, when a reference plane is
/// tap-selected in the 3D viewport - sits outside both categories, since
/// it's a one-off contextual action rather than part of the static menu
/// structure the brief describes.
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
  /// Stage 18's brief calls for a "View Settled" toggle that has never
  /// existed in this codebase - this picker is its closest analog, so it
  /// moves into the View sub-menu in its place.
  final ViewportRenderMode renderMode;
  final void Function(ViewportRenderMode mode)? onRenderModeChanged;

  /// Stage 18: navigates to [ConnectionScreen] - the one File entry that
  /// isn't a disabled placeholder.
  final VoidCallback? onOpenConnectionSettings;

  /// Stage 18: current 3D-viewport appearance preferences (see
  /// [ViewPreferences]) and their change callbacks - [PartScreen] owns the
  /// state and persistence, this just renders the entries that open each
  /// preference's picker sheet.
  final String bgColourHex;
  final String bodyColourHex;
  final double bodyOpacity;
  final void Function(String hex)? onBgColourChanged;
  final void Function(String hex)? onBodyColourChanged;
  final void Function(double opacity)? onBodyOpacityChanged;

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
    this.onOpenConnectionSettings,
    this.bgColourHex = ViewPreferences.defaultBgColourHex,
    this.bodyColourHex = ViewPreferences.defaultBodyColourHex,
    this.bodyOpacity = ViewPreferences.defaultBodyOpacity,
    this.onBgColourChanged,
    this.onBodyColourChanged,
    this.onBodyOpacityChanged,
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
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 520),
                  child: SizedBox(
                    width: 240,
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _buildFileMenu(context),
                          _buildViewMenu(context),
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
      ),
    );
  }

  static const List<String> _filePlaceholders = [
    'New',
    'Open…',
    'Save',
    'Save As…',
    'Import…',
    'Export STEP',
    'Export STL',
  ];

  Widget _buildFileMenu(BuildContext context) {
    final disabledColor = Theme.of(context).disabledColor;
    return ExpansionTile(
      leading: const Icon(Icons.folder_outlined),
      title: const Text('File'),
      children: [
        for (final label in _filePlaceholders)
          ListTile(
            enabled: false,
            title: Text(label, style: TextStyle(color: disabledColor)),
          ),
        ListTile(
          leading: const Icon(Icons.settings_ethernet),
          title: const Text('Connection Settings'),
          onTap: onOpenConnectionSettings,
        ),
      ],
    );
  }

  Widget _buildViewMenu(BuildContext context) {
    return ExpansionTile(
      leading: const Icon(Icons.visibility_outlined),
      title: const Text('View'),
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
            onTap: onRenderModeChanged == null ? null : () => onRenderModeChanged!(mode),
          ),
        const Divider(height: 1),
        ListTile(
          leading: Icon(Icons.palette_outlined, color: colorFromHex(bgColourHex)),
          title: const Text('Background Colour'),
          onTap: onBgColourChanged == null ? null : () => _pickBgColour(context),
        ),
        ListTile(
          leading: Icon(Icons.circle, color: colorFromHex(bodyColourHex)),
          title: const Text('Body Colour'),
          onTap: onBodyColourChanged == null ? null : () => _pickBodyColour(context),
        ),
        ListTile(
          leading: const Icon(Icons.opacity_outlined),
          title: const Text('Body Transparency'),
          onTap: onBodyOpacityChanged == null ? null : () => _pickBodyOpacity(context),
        ),
      ],
    );
  }

  Future<void> _pickBgColour(BuildContext context) async {
    final hex = await showColourSwatchSheet(
      context,
      title: 'Background Colour',
      swatches: backgroundColourSwatches,
      selectedHex: bgColourHex,
    );
    if (hex != null) onBgColourChanged!(hex);
  }

  Future<void> _pickBodyColour(BuildContext context) async {
    final hex = await showColourSwatchSheet(
      context,
      title: 'Body Colour',
      swatches: bodyColourSwatches,
      selectedHex: bodyColourHex,
    );
    if (hex != null) onBodyColourChanged!(hex);
  }

  Future<void> _pickBodyOpacity(BuildContext context) async {
    final opacity = await showBodyOpacitySheet(context, initialOpacity: bodyOpacity);
    if (opacity != null) onBodyOpacityChanged!(opacity);
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
