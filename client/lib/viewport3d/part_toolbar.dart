import 'dart:math';

import 'package:flutter/material.dart';

import 'orbit_camera.dart' show kDefaultFarClip;
import 'render_mode.dart';
import 'selection_filter.dart';
import 'view_prefs_sheets.dart';
import 'view_preferences.dart';

// A3: logarithmic mapping for the far-clip slider so the range 500–50000 mm
// feels linear in perceived depth. Exposed at library level for unit tests.
double sliderToClip(double t) =>
    exp(log(500) + (log(50000) - log(500)) * t).roundToDouble();
double clipToSlider(double farClip) =>
    (log(farClip) - log(500)) / (log(50000) - log(500));

/// [PartScreen]'s contextual toolbar - styled and animated to match
/// [SketchRibbon]'s slide-in-from-the-left panel (same [Material] card with
/// rounded trailing corners, same [AnimatedSlide] offscreen-to-the-left
/// hide), opened via [PartScreen]'s persistent top-left toggle button.
///
/// Stage 18 restructures this into the brief's two top-level categories,
/// File and View, as [ExpansionTile]s. Stage 19b Item 2 moved the one
/// contextual action this used to show ("New Sketch on [plane]") out into
/// its own fly-up bottom sheet (see [showPlaneContextSheet]), so this is now
/// purely the static File/View menu structure with no contextual entries.
/// A third top-level menu, Selection Filters, was split out of View
/// afterwards (see [_buildSelectionFilterMenu]'s doc comment) - it gates
/// what a viewport tap selects, a distinct concern from View's display
/// settings.
class PartToolbar extends StatelessWidget {
  final bool visible;

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

  /// Native Save/Load: reads/writes the whole Document (every Part's
  /// ordered Feature list, plus every Sketch it references) as this app's
  /// own native project file - see `PartScreen._saveNativeFile`/
  /// `_openNativeFile`.
  final VoidCallback? onSaveNative;
  final VoidCallback? onOpenNative;

  /// Export: writes the current Part's geometry out to one of four
  /// interchange formats (`'step'`/`'stl'`/`'obj'`/`'glb'`) - see
  /// `PartScreen._exportPart`.
  final void Function(String format)? onExportPart;

  /// Import: brings an external STEP/STL/OBJ/glTF file in as a fixed,
  /// non-parametric Body - see `PartScreen._importGeometry`.
  final VoidCallback? onImportGeometry;

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

  // A4: perspective toggle (off = orthographic default per A4 brief).
  final bool isPerspective;
  final void Function(bool isPerspective)? onPerspectiveChanged;

  // A3: far clip override slider (500–50000 mm, logarithmic).
  final double farClip;
  final void Function(double farClip)? onFarClipChanged;

  /// Prompt A2: which entity kinds the 3D viewport's selection hit-testing
  /// considers - [PartScreen] owns the state (session-only, no persistence,
  /// same convention as `SketchScreen`'s Canvas Colour/Transparency toggles),
  /// this just renders the four toggle entries.
  final SelectionFilterState selectionFilter;
  final void Function(bool value)? onVertexFilterChanged;
  final void Function(bool value)? onEdgeFilterChanged;
  final void Function(bool value)? onFaceFilterChanged;
  final void Function(bool value)? onBodyFilterChanged;

  /// Prompt C1: toggles for the two new Sketch entity kinds, same
  /// Body-exclusive convention as the other four (see [_buildSelectionFilterMenu]).
  final void Function(bool value)? onSketchPointFilterChanged;
  final void Function(bool value)? onSketchLineFilterChanged;

  const PartToolbar({
    super.key,
    required this.visible,
    this.referencePlanesHidden = false,
    this.onToggleReferencePlanes,
    this.renderMode = ViewportRenderMode.shaded,
    this.onRenderModeChanged,
    this.onOpenConnectionSettings,
    this.onSaveNative,
    this.onOpenNative,
    this.onExportPart,
    this.onImportGeometry,
    this.bgColourHex = ViewPreferences.defaultBgColourHex,
    this.bodyColourHex = ViewPreferences.defaultBodyColourHex,
    this.bodyOpacity = ViewPreferences.defaultBodyOpacity,
    this.onBgColourChanged,
    this.onBodyColourChanged,
    this.onBodyOpacityChanged,
    this.isPerspective = ViewPreferences.defaultIsPerspective,
    this.onPerspectiveChanged,
    this.farClip = kDefaultFarClip,
    this.onFarClipChanged,
    this.selectionFilter = SelectionFilterState.defaults,
    this.onVertexFilterChanged,
    this.onEdgeFilterChanged,
    this.onFaceFilterChanged,
    this.onBodyFilterChanged,
    this.onSketchPointFilterChanged,
    this.onSketchLineFilterChanged,
  });

  @override
  Widget build(BuildContext context) {
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
                          _buildSelectionFilterMenu(context),
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

  static const List<String> _filePlaceholders = ['New', 'Save As…'];

  // format, label, icon - each drives one Export ListTile below.
  static const List<(String, String, IconData)> _exportFormats = [
    ('step', 'Export STEP', Icons.view_in_ar_outlined),
    ('stl', 'Export STL', Icons.view_in_ar_outlined),
    ('obj', 'Export OBJ', Icons.view_in_ar_outlined),
    ('glb', 'Export glTF', Icons.view_in_ar_outlined),
  ];

  Widget _buildFileMenu(BuildContext context) {
    final disabledColor = Theme.of(context).disabledColor;
    return ExpansionTile(
      leading: const Icon(Icons.folder_outlined),
      title: const Text('File'),
      children: [
        ListTile(
          leading: const Icon(Icons.folder_open_outlined),
          title: const Text('Open…'),
          onTap: onOpenNative,
        ),
        ListTile(
          leading: const Icon(Icons.save_outlined),
          title: const Text('Save'),
          onTap: onSaveNative,
        ),
        ListTile(
          leading: const Icon(Icons.file_upload_outlined),
          title: const Text('Import…'),
          onTap: onImportGeometry,
        ),
        for (final label in _filePlaceholders)
          ListTile(
            enabled: false,
            title: Text(label, style: TextStyle(color: disabledColor)),
          ),
        for (final (format, label, icon) in _exportFormats)
          ListTile(
            leading: Icon(icon),
            title: Text(label),
            onTap: onExportPart == null ? null : () => onExportPart!(format),
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
        // A4: Perspective toggle (first View entry, off = orthographic default).
        // Bug 7: flutter_scene 0.18.x has no OrthographicCamera, so both
        // settings currently render identically; a subtitle notes this.
        ListTile(
          leading: Icon(isPerspective ? Icons.check_box : Icons.check_box_outline_blank),
          title: const Text('Perspective'),
          subtitle: isPerspective
              ? null
              : const Text(
                  'Renders as perspective\n(orthographic not yet available)',
                  style: TextStyle(fontSize: 11),
                ),
          isThreeLine: !isPerspective,
          onTap: onPerspectiveChanged == null
              ? null
              : () => onPerspectiveChanged!(!isPerspective),
        ),
        // A3: Far clip slider (logarithmic 500–50000 mm).
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Far clip: ${farClip.round()} mm',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              Slider(
                value: clipToSlider(farClip).clamp(0.0, 1.0),
                onChanged: onFarClipChanged == null
                    ? null
                    : (t) => onFarClipChanged!(sliderToClip(t)),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
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

  /// Prompt A2's selection filter toggles - which entity kinds are
  /// hit-testable in Selection mode. Split out of the View sub-menu into its
  /// own top-level one: these gate *what a tap in the viewport selects*,
  /// a distinct concern from View's display/appearance settings. Body is
  /// exclusive against the other three (see `PartScreen._setBodyFilter`'s
  /// doc comment for why): there's no click target that's "body but not
  /// vertex/edge/face", so whenever Body is on, Vertices/Edges/Faces are
  /// forced off and greyed out here rather than left independently
  /// toggleable.
  Widget _buildSelectionFilterMenu(BuildContext context) {
    return ExpansionTile(
      leading: const Icon(Icons.filter_alt_outlined),
      title: const Text('Selection Filters'),
      children: [
        _filterToggle(
          label: 'Vertices',
          value: selectionFilter.vertex,
          onChanged: selectionFilter.body ? null : onVertexFilterChanged,
        ),
        _filterToggle(
          label: 'Edges',
          value: selectionFilter.edge,
          onChanged: selectionFilter.body ? null : onEdgeFilterChanged,
        ),
        _filterToggle(
          label: 'Faces',
          value: selectionFilter.face,
          onChanged: selectionFilter.body ? null : onFaceFilterChanged,
        ),
        _filterToggle(
          label: 'Bodies',
          value: selectionFilter.body,
          onChanged: onBodyFilterChanged,
        ),
        _filterToggle(
          label: 'Sketch Points',
          value: selectionFilter.sketchPoint,
          onChanged: selectionFilter.body ? null : onSketchPointFilterChanged,
        ),
        _filterToggle(
          label: 'Sketch Lines',
          value: selectionFilter.sketchLine,
          onChanged: selectionFilter.body ? null : onSketchLineFilterChanged,
        ),
      ],
    );
  }

  /// One selection-filter toggle row - same checkbox-icon [ListTile]
  /// convention as the Perspective entry above, rather than a [SwitchListTile],
  /// so all boolean toggles in this menu look consistent. `enabled:` (not
  /// just a null `onTap`) is what actually greys out the icon/label -
  /// `onTap: null` alone only disables the tap, it doesn't restyle the row.
  Widget _filterToggle({
    required String label,
    required bool value,
    required void Function(bool value)? onChanged,
  }) {
    return ListTile(
      enabled: onChanged != null,
      leading: Icon(value ? Icons.check_box : Icons.check_box_outline_blank),
      title: Text(label),
      onTap: onChanged == null ? null : () => onChanged(!value),
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
}
