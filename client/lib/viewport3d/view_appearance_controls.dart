import 'package:material_ui/material_ui.dart';
import 'package:flutter_svg/flutter_svg.dart';

import 'part_toolbar.dart' show clipToSlider, sliderToClip;
import 'scene_controls_panel.dart';
import 'scene_preferences.dart';
import 'svg_icon.dart';
import 'view_preferences.dart';
import 'view_prefs_sheets.dart';

/// The appearance part of the View settings: Background Colour, the appearance override (switch, Body Colour, Body Transparency),
/// Polygon Resolution and the Scene sliders. One widget for both homes (bug report 2026-11-17 item 13): the phone layout's hamburger
/// panel (`PartToolbar`'s View menu) and the desktop layout's "Background, colour and scene…" dialog ([showSceneSettingsDialog]), so
/// the two cannot drift apart. Each entry opens the same picker sheet it always did; a null callback disables its entry.
class ViewAppearanceControls extends StatelessWidget {
  final String bgColourHex;
  final String bodyColourHex;
  final double bodyOpacity;
  final void Function(String hex)? onBgColourChanged;
  final void Function(String hex)? onBodyColourChanged;
  final void Function(double opacity)? onBodyOpacityChanged;
  final bool appearanceOverrideOn;
  final void Function(bool on)? onAppearanceOverrideChanged;
  final double meshQuality;
  final void Function(double quality)? onMeshQualityChanged;
  final double sceneRoughness;
  final double sceneLightIntensity;
  final double sceneEmissiveIntensity;
  final void Function(double value)? onSceneRoughnessChanged;
  final void Function(double value)? onSceneLightIntensityChanged;
  final void Function(double value)? onSceneEmissiveIntensityChanged;

  /// The Scene sliders sit in their own fold-out in the phone menu (it is long); the dialog shows them open.
  final bool sceneInFoldOut;

  const ViewAppearanceControls({
    super.key,
    this.bgColourHex = ViewPreferences.defaultBgColourHex,
    this.bodyColourHex = ViewPreferences.defaultBodyColourHex,
    this.bodyOpacity = ViewPreferences.defaultBodyOpacity,
    this.onBgColourChanged,
    this.onBodyColourChanged,
    this.onBodyOpacityChanged,
    this.appearanceOverrideOn = false,
    this.onAppearanceOverrideChanged,
    this.meshQuality = ViewPreferences.defaultMeshQuality,
    this.onMeshQualityChanged,
    this.sceneRoughness = ScenePreferences.defaultRoughness,
    this.sceneLightIntensity = ScenePreferences.defaultLightIntensity,
    this.sceneEmissiveIntensity = ScenePreferences.defaultEmissiveIntensity,
    this.onSceneRoughnessChanged,
    this.onSceneLightIntensityChanged,
    this.onSceneEmissiveIntensityChanged,
    this.sceneInFoldOut = true,
  });

  @override
  Widget build(BuildContext context) {
    final scene = SceneControlsPanel(
      // Body Colour above already covers base colour - no need to show the swatch row a second time here (see SceneControlsPanel's own
      // doc comment).
      roughness: sceneRoughness,
      onRoughnessChanged: onSceneRoughnessChanged,
      lightIntensity: sceneLightIntensity,
      onLightIntensityChanged: onSceneLightIntensityChanged,
      emissiveIntensity: sceneEmissiveIntensity,
      onEmissiveIntensityChanged: onSceneEmissiveIntensityChanged,
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          key: const ValueKey('view-bg-colour'),
          leading: Icon(Icons.palette_outlined, color: colorFromHex(bgColourHex)),
          title: const Text('Background Colour'),
          onTap: onBgColourChanged == null ? null : () => _pickBgColour(context),
        ),
        // C3 (`docs/assembly-perf-mates-and-ui-plan.md`): the header line IS the switch (it used to be a bold header plus a second
        // "Override appearance" in a SwitchListTile that wrapped mid-word on a phone).
        InkWell(
          onTap: onAppearanceOverrideChanged == null ? null : () => onAppearanceOverrideChanged!(!appearanceOverrideOn),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 12, 0),
            child: Row(
              children: [
                const Expanded(
                  child: Text(
                    'Override appearance',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                Switch(
                  key: const ValueKey('view-override-switch'),
                  value: appearanceOverrideOn,
                  onChanged: onAppearanceOverrideChanged == null ? null : (on) => onAppearanceOverrideChanged!(on),
                ),
              ],
            ),
          ),
        ),
        ListTile(
          key: const ValueKey('view-override-colour'),
          // A fixed multi-colour glyph, not tinted like every other icon here - see sketch_screen.dart's own identical Body Colour
          // entry for why (deliberately reads as "colour picker" at a glance rather than reflecting the current selection).
          leading: SvgPicture.asset(
            'assets/icons/sketchbar/sketchbar_body_colour_cube.svg',
            width: 30,
            height: 30,
          ),
          title: const Text('Body Colour'),
          onTap: onBodyColourChanged == null ? null : () => _pickBodyColour(context),
        ),
        ListTile(
          key: const ValueKey('view-override-opacity'),
          leading: const SvgIcon('assets/icons/sketchbar/sketchbar_body_transparency.svg'),
          title: const Text('Body Transparency'),
          onTap: onBodyOpacityChanged == null ? null : () => _pickBodyOpacity(context),
        ),
        ListTile(
          key: const ValueKey('view-polygon-resolution'),
          leading: const Icon(Icons.change_history),
          title: const Text('Polygon Resolution'),
          onTap: onMeshQualityChanged == null ? null : () => _pickMeshQuality(context),
        ),
        const Divider(height: 1),
        if (sceneInFoldOut)
          ExpansionTile(
            leading: const SvgIcon('assets/icons/feature/parttoolbar_scene.svg'),
            title: const Text('Scene'),
            children: [scene],
          )
        else ...[
          const ListTile(
            leading: SvgIcon('assets/icons/feature/parttoolbar_scene.svg'),
            title: Text('Scene'),
          ),
          scene,
        ],
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

  Future<void> _pickMeshQuality(BuildContext context) async {
    final quality = await showPolygonResolutionSheet(context, initialQuality: meshQuality);
    if (quality != null) onMeshQualityChanged!(quality);
  }
}

/// The desktop layout's "Background, colour and scene…" dialog (bug report 2026-11-17 item 13: the desktop used to open the phone
/// layout's hamburger panel for this). [controls] builds the panel from the screen's current values; it is called again after each
/// change, through the `refresh` it is handed, so the dialog shows what was just picked. [isPerspective] / [onPerspectiveChanged] add the
/// Perspective switch at the top and [farClip] / [onFarClipChanged] the far clip slider (the phone menu's other two View settings that
/// the desktop ribbon does not carry; Perspective is on the ribbon too, kept here so the dialog holds the whole View section).
Future<void> showSceneSettingsDialog(
  BuildContext context, {
  required ViewAppearanceControls Function(VoidCallback refresh) controls,
  required bool Function() isPerspective,
  required void Function(bool perspective) onPerspectiveChanged,
  required double Function() farClip,
  required void Function(double farClip) onFarClipChanged,
}) {
  return showDialog<void>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (context, setDialogState) {
        void refresh() {
          if (context.mounted) setDialogState(() {});
        }

        return AlertDialog(
          key: const ValueKey('scene-settings-dialog'),
          title: const Text('Background, colour and scene'),
          contentPadding: const EdgeInsets.symmetric(vertical: 12),
          content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SwitchListTile(
                    key: const ValueKey('scene-settings-perspective'),
                    title: const Text('Perspective'),
                    value: isPerspective(),
                    onChanged: (on) {
                      onPerspectiveChanged(on);
                      refresh();
                    },
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Far clip: ${farClip().round()} mm', style: Theme.of(context).textTheme.bodySmall),
                        Slider(
                          key: const ValueKey('scene-settings-far-clip'),
                          value: clipToSlider(farClip()).clamp(0.0, 1.0),
                          onChanged: (t) {
                            onFarClipChanged(sliderToClip(t));
                            refresh();
                          },
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  controls(refresh),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              key: const ValueKey('scene-settings-close'),
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Close'),
            ),
          ],
        );
      },
    ),
  );
}
