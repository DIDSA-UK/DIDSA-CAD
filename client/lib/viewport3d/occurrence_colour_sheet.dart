import 'package:flutter/material.dart';

import 'view_prefs_sheets.dart' show ColourSwatch, bodyColourSwatches;
import 'view_preferences.dart';

/// Bug report (assembly testing): "a colour disc that when tapped allows
/// user to select the colour of that part" - the Assembly tree's own
/// colour-disc row (`AssemblyTreePanel._buildOccurrenceTile`) opens this.
/// Reuses [bodyColourSwatches] (the same palette the Body Colour picker
/// already offers - `view_prefs_sheets.dart`'s [showColourSwatchSheet]),
/// plus a leading "Default" tile [showColourSwatchSheet] itself has no
/// equivalent of: a per-Occurrence override is optional (`Occurrence.color`
/// defaults to `null`, "inherit the ordinary default body colour"), so this
/// sheet needs a third choice alongside "pick a swatch" - "stop overriding"
/// - which an empty-string swatch entry can't safely express through that
/// shared widget's own `colorFromHex` swatch rendering (an empty hex isn't
/// a parseable colour).
///
/// Returns the chosen `"#RRGGBB"` hex string on a swatch tap, `''` (empty
/// string) on the Default tile - the same explicit-clear sentinel
/// `DocumentApiClient.updateOccurrenceColor` passes straight through to the
/// backend's own `OccurrenceTransformUpdate.color` tri-state (see that
/// field's own doc comment: `null` omitted/unchanged, `''` clears, anything
/// else stored verbatim) - or `null` if dismissed without a choice at all.
Future<String?> showOccurrenceColourSheet(BuildContext context, {required String? selectedHex}) {
  return showModalBottomSheet<String>(
    context: context,
    builder: (sheetContext) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Component Colour', style: Theme.of(sheetContext).textTheme.titleMedium),
            const SizedBox(height: 16),
            Wrap(
              spacing: 20,
              runSpacing: 16,
              children: [
                _DefaultColourTile(
                  selected: selectedHex == null,
                  onTap: () => Navigator.of(sheetContext).pop(''),
                ),
                for (final swatch in bodyColourSwatches)
                  _ColourSwatchTile(
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

/// Mirrors `view_prefs_sheets.dart`'s own private `_SwatchTile` exactly
/// (same 48px circle/label/selected-ring shape) - duplicated rather than
/// exported/shared since that widget is a private implementation detail of
/// a different file, and this sheet's own "Default" tile alongside it
/// (below) needs a visually matching but distinctly-shaped sibling anyway.
class _ColourSwatchTile extends StatelessWidget {
  final ColourSwatch swatch;
  final bool selected;
  final VoidCallback onTap;

  const _ColourSwatchTile({required this.swatch, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final color = colorFromHex(swatch.hex);
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

/// The "stop overriding, inherit the ordinary default body colour" tile -
/// a hollow circle (no fill to pick, unlike every real [_ColourSwatchTile])
/// with a "no colour" slash icon, so it reads as a distinct third choice
/// rather than one more swatch.
class _DefaultColourTile extends StatelessWidget {
  final bool selected;
  final VoidCallback onTap;

  const _DefaultColourTile({required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: selected ? Theme.of(context).colorScheme.primary : Colors.grey,
                width: selected ? 3 : 1,
              ),
            ),
            child: Icon(
              Icons.block,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              size: 22,
            ),
          ),
          const SizedBox(height: 4),
          const Text('Default', style: TextStyle(fontSize: 12)),
        ],
      ),
    );
  }
}
