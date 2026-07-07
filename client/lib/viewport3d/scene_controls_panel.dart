import 'package:flutter/material.dart';

import 'scene_preferences.dart';
import 'view_preferences.dart';
import 'view_prefs_sheets.dart';

/// The "Scene" controls introduced alongside the `PhysicallyBasedMaterial`
/// lighting/shading upgrade - roughness/light intensity/luminescence
/// sliders, plus an optional inline base-colour swatch row.
///
/// Shared between two different hosts, which is why it's a plain content
/// widget rather than a sheet/dialog of its own:
/// - `part_toolbar.dart` embeds this directly inside a nested "Scene"
///   `ExpansionTile` in the existing View menu, live-updating as the user
///   drags (same convention the View menu's own Far Clip slider already
///   uses) - it omits [onBaseColourChanged], since that toolbar already has
///   a separate, longer-standing "Body Colour" entry right above it and
///   showing colour swatches twice in the same menu would be redundant.
/// - `mesh_viewer_screen.dart` has no other colour picker at all (there was
///   never a "Body Colour" equivalent there before this upgrade), so its own
///   View > Scene entry wraps this in a modal sheet (see
///   `showScenePrefsSheet`) *with* [onBaseColourChanged] supplied - that's
///   the only place a mesh's colour can be changed at all.
class SceneControlsPanel extends StatelessWidget {
  final String? baseColourHex;
  final ValueChanged<String>? onBaseColourChanged;
  final double roughness;
  final ValueChanged<double>? onRoughnessChanged;
  final double lightIntensity;
  final ValueChanged<double>? onLightIntensityChanged;
  final double emissiveIntensity;
  final ValueChanged<double>? onEmissiveIntensityChanged;

  const SceneControlsPanel({
    super.key,
    this.baseColourHex,
    this.onBaseColourChanged,
    required this.roughness,
    this.onRoughnessChanged,
    required this.lightIntensity,
    this.onLightIntensityChanged,
    required this.emissiveIntensity,
    this.onEmissiveIntensityChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (onBaseColourChanged != null) ...[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Text('Colour', style: Theme.of(context).textTheme.bodySmall),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Wrap(
              spacing: 12,
              runSpacing: 8,
              children: [
                for (final swatch in bodyColourSwatches)
                  _ColourDot(
                    hex: swatch.hex,
                    selected: swatch.hex == baseColourHex,
                    onTap: () => onBaseColourChanged!(swatch.hex),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 8),
        ],
        _sliderRow(
          context,
          label: 'Roughness',
          value: roughness,
          min: 0.0,
          max: 1.0,
          onChanged: onRoughnessChanged,
        ),
        _sliderRow(
          context,
          label: 'Light Intensity',
          value: lightIntensity,
          min: 0.0,
          max: ScenePreferences.maxLightIntensity,
          onChanged: onLightIntensityChanged,
        ),
        _sliderRow(
          context,
          label: 'Luminescence',
          value: emissiveIntensity,
          min: 0.0,
          max: 1.0,
          onChanged: onEmissiveIntensityChanged,
        ),
      ],
    );
  }

  Widget _sliderRow(
    BuildContext context, {
    required String label,
    required double value,
    required double min,
    required double max,
    required ValueChanged<double>? onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$label: ${value.toStringAsFixed(2)}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}

class _ColourDot extends StatelessWidget {
  final String hex;
  final bool selected;
  final VoidCallback onTap;

  const _ColourDot({required this.hex, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final color = colorFromHex(hex);
    final checkColor = color.computeLuminance() > 0.5 ? Colors.black : Colors.white;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(
            color: selected ? Theme.of(context).colorScheme.primary : Colors.grey,
            width: selected ? 3 : 1,
          ),
        ),
        child: selected ? Icon(Icons.check, size: 16, color: checkColor) : null,
      ),
    );
  }
}

/// Wraps [SceneControlsPanel] in a modal sheet - used by
/// `mesh_viewer_screen.dart`'s View > Scene entry, which (unlike
/// `part_toolbar.dart`) has no `ExpansionTile`-based menu surface to embed
/// the panel into directly. Live-updates via the supplied callbacks as the
/// user interacts, same as the embedded case - there's no separate
/// "Apply"/OK step, so [Navigator.pop] (back gesture or tapping outside)
/// simply closes it once the user's done.
Future<void> showScenePrefsSheet(
  BuildContext context, {
  required String baseColourHex,
  required ValueChanged<String> onBaseColourChanged,
  required double roughness,
  required ValueChanged<double> onRoughnessChanged,
  required double lightIntensity,
  required ValueChanged<double> onLightIntensityChanged,
  required double emissiveIntensity,
  required ValueChanged<double> onEmissiveIntensityChanged,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (sheetContext) => StatefulBuilder(
      builder: (sheetContext, setSheetState) {
        var currentColour = baseColourHex;
        var currentRoughness = roughness;
        var currentLight = lightIntensity;
        var currentEmissive = emissiveIntensity;
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16),
                  child: Text('Scene', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                ),
                const SizedBox(height: 8),
                SceneControlsPanel(
                  baseColourHex: currentColour,
                  onBaseColourChanged: (hex) {
                    setSheetState(() => currentColour = hex);
                    onBaseColourChanged(hex);
                  },
                  roughness: currentRoughness,
                  onRoughnessChanged: (value) {
                    setSheetState(() => currentRoughness = value);
                    onRoughnessChanged(value);
                  },
                  lightIntensity: currentLight,
                  onLightIntensityChanged: (value) {
                    setSheetState(() => currentLight = value);
                    onLightIntensityChanged(value);
                  },
                  emissiveIntensity: currentEmissive,
                  onEmissiveIntensityChanged: (value) {
                    setSheetState(() => currentEmissive = value);
                    onEmissiveIntensityChanged(value);
                  },
                ),
              ],
            ),
          ),
        );
      },
    ),
  );
}
