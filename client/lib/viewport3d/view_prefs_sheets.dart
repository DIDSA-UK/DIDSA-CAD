import 'package:flutter/material.dart';

import 'view_preferences.dart';

/// One tappable swatch in a [showColourSwatchSheet] - a label paired with the
/// `"#RRGGBB"` string [ViewPreferences] persists.
class ColourSwatch {
  final String label;
  final String hex;
  const ColourSwatch(this.label, this.hex);
}

const List<ColourSwatch> backgroundColourSwatches = [
  ColourSwatch('Studio Dark', ViewPreferences.defaultBgColourHex),
  ColourSwatch('Charcoal', '#2C2C2C'),
  ColourSwatch('Slate', '#4A5568'),
  ColourSwatch('Off-white', '#F5F5F0'),
  ColourSwatch('White', '#FFFFFF'),
];

const List<ColourSwatch> bodyColourSwatches = [
  ColourSwatch('Aluminium', ViewPreferences.defaultBodyColourHex),
  ColourSwatch('Steel Blue', '#6C8EAD'),
  ColourSwatch('Teal', '#4A9B8E'),
  ColourSwatch('Warm Grey', '#C4B9A8'),
  ColourSwatch('Orange', '#E8834A'),
];

/// Shows a bottom sheet of [swatches], pre-highlighting whichever one matches
/// [selectedHex] - tapping a swatch immediately pops the sheet with that
/// swatch's hex string as the result, or null if dismissed without a choice.
Future<String?> showColourSwatchSheet(
  BuildContext context, {
  required String title,
  required List<ColourSwatch> swatches,
  required String selectedHex,
}) {
  return showModalBottomSheet<String>(
    context: context,
    builder: (sheetContext) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(sheetContext).textTheme.titleMedium),
            const SizedBox(height: 16),
            Wrap(
              spacing: 20,
              runSpacing: 16,
              children: [
                for (final swatch in swatches)
                  _SwatchTile(
                    swatch: swatch,
                    selected: swatch.hex == selectedHex,
                    onTap: () => Navigator.of(sheetContext).pop(swatch.hex),
                  ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}

class _SwatchTile extends StatelessWidget {
  final ColourSwatch swatch;
  final bool selected;
  final VoidCallback onTap;

  const _SwatchTile({required this.swatch, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final color = colorFromHex(swatch.hex);
    // Checkmark contrast: dark on light swatches, light on dark ones.
    final checkColor = color.computeLuminance() > 0.5 ? Colors.black : Colors.white;
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              border: Border.all(
                color: selected ? Theme.of(context).colorScheme.primary : Colors.grey,
                width: selected ? 3 : 1,
              ),
            ),
            child: selected ? Icon(Icons.check, color: checkColor) : null,
          ),
          const SizedBox(height: 4),
          Text(swatch.label, style: const TextStyle(fontSize: 12)),
        ],
      ),
    );
  }
}

/// Shows a bottom sheet with a single slider for body transparency (0% =
/// fully opaque, 100% = fully transparent, 5% steps) - returns the chosen
/// *opacity* (the inverse of what the slider displays) on Apply, or null if
/// dismissed without applying.
Future<double?> showBodyOpacitySheet(BuildContext context, {required double initialOpacity}) {
  return showModalBottomSheet<double>(
    context: context,
    builder: (sheetContext) => _BodyOpacitySheet(initialOpacity: initialOpacity),
  );
}

class _BodyOpacitySheet extends StatefulWidget {
  final double initialOpacity;
  const _BodyOpacitySheet({required this.initialOpacity});

  @override
  State<_BodyOpacitySheet> createState() => _BodyOpacitySheetState();
}

class _BodyOpacitySheetState extends State<_BodyOpacitySheet> {
  late double _opacity;

  @override
  void initState() {
    super.initState();
    _opacity = widget.initialOpacity;
  }

  @override
  Widget build(BuildContext context) {
    final transparencyPercent = ((1 - _opacity) * 100).round();
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Body Transparency', style: Theme.of(context).textTheme.titleMedium),
            Row(
              children: [
                Expanded(
                  child: Slider(
                    value: transparencyPercent.toDouble(),
                    min: 0,
                    max: 100,
                    divisions: 20,
                    label: '$transparencyPercent%',
                    onChanged: (value) => setState(() => _opacity = 1 - (value / 100)),
                  ),
                ),
                SizedBox(width: 48, child: Text('$transparencyPercent%', textAlign: TextAlign.end)),
              ],
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: () => Navigator.of(context).pop(_opacity),
                child: const Text('Apply'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
