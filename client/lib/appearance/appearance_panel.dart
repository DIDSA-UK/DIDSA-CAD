/// The flat app's Appearance panel (`docs/appearance-tool-scope.md` V3; DIDSA-VR's Appearance page and paint breadcrumb in
/// one place): the brush, and what to paint.
///
///   * the brush: the palette and Clear, a full picker (hue bar + saturation / value square), a hex field, recent colours,
///     Opacity, Shine (1 - roughness), Metal and Glow sliders each with a switch (only the switched-on properties are
///     painted, D4), a preview swatch, the eyedropper, and saved appearances (presets plus your own);
///   * what to paint: with the panel open, a click on a part paints its body; the rows for the last thing clicked (Face,
///     Body, Part, Pattern (all N), Every part (N), each sub-assembly, Whole assembly) each show what is there now and
///     whether that level has its own paint. Hovering a row previews it on the model; clicking it paints it.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../viewport3d/resizable_tool_panel.dart';
import '../viewport3d/view_prefs_sheets.dart' show bodyColourSwatches;
import 'appearance_model.dart';
import 'appearance_rule.dart';
import 'scenes_panel.dart' show askSceneName;

/// The palette (the body colours plus a few strong ones; DIDSA-VR's palette is the same idea).
const List<(String, String)> kPaintPalette = [
  ('Red', '#E63946'),
  ('Orange', '#F4A340'),
  ('Yellow', '#F1C40F'),
  ('Green', '#2ECC71'),
  ('Blue', '#3498DB'),
  ('Purple', '#9B59B6'),
  ('White', '#F5F5F5'),
  ('Black', '#222222'),
];

/// The brush's properties: [label, field, min, max, whether the slider shows 1 - field].
const List<(String, String, double, double, bool)> kBrushProperties = [
  ('Opacity', 'opacity', 0.0, 1.0, false),
  ('Shine', 'roughness', 0.0, 1.0, true),
  ('Metal', 'metallic', 0.0, 1.0, false),
  ('Glow', 'emission_strength', 0.0, 10.0, false),
];
const Map<String, double> kBrushDefaults = {'opacity': 1.0, 'roughness': 0.8, 'metallic': 0.0, 'emission_strength': 0.0};

Color colourOfHex(String hex) => Color(0xFF000000 | int.parse(hex.substring(1), radix: 16));

String hexOfColour(Color c) {
  String two(double v) => (v * 255).round().clamp(0, 255).toRadixString(16).padLeft(2, '0').toUpperCase();
  return '#${two(c.r)}${two(c.g)}${two(c.b)}';
}

/// A short description of an appearance ("#3498DB · 50% · metal 0.9"), or "Clear" for an empty one.
String describeAppearance(Json a) {
  if (a.isEmpty) return 'Clear';
  final bits = <String>[];
  if (a['colour'] != null) bits.add(a['colour'] as String);
  if (a['opacity'] != null) bits.add('${((a['opacity'] as num) * 100).round()}%');
  if (a['roughness'] != null) bits.add('shine ${(1 - (a['roughness'] as num)).toStringAsFixed(2)}');
  if (a['metallic'] != null) bits.add('metal ${(a['metallic'] as num).toStringAsFixed(2)}');
  if (a['emission_strength'] != null) bits.add('glow ${(a['emission_strength'] as num).toStringAsFixed(1)}');
  return bits.join(' · ');
}

class AppearancePanel extends StatefulWidget {
  /// The brush: only the fields a paint sets. Empty = Clear.
  final Json brush;
  final ValueChanged<Json> onBrushChanged;

  /// The rows for the last thing clicked, innermost first (empty: nothing clicked yet).
  final List<PaintRow> rows;
  final String? pickLabel;
  final ValueChanged<PaintRow?> onPreviewRow;
  final ValueChanged<PaintRow> onPaintRow;

  final bool eyedropper;
  final ValueChanged<bool> onEyedropperChanged;
  final List<String> recentColours;
  final List<(String, Json)> savedAppearances;
  final ValueChanged<String> onSaveBrush;
  final VoidCallback? onUndo;
  final VoidCallback onClose;

  /// "Painting", or "Painting scene 'Exploded'" while a scene shows (D5: it changes the scene, not the model).
  final String title;
  final bool busy;

  const AppearancePanel({
    super.key,
    required this.brush,
    required this.onBrushChanged,
    required this.rows,
    this.pickLabel,
    required this.onPreviewRow,
    required this.onPaintRow,
    this.eyedropper = false,
    required this.onEyedropperChanged,
    this.recentColours = const [],
    this.savedAppearances = const [],
    required this.onSaveBrush,
    this.onUndo,
    required this.onClose,
    this.title = 'Appearance',
    this.busy = false,
  });

  @override
  State<AppearancePanel> createState() => _AppearancePanelState();
}

class _AppearancePanelState extends State<AppearancePanel> {
  late final TextEditingController _hex = TextEditingController(text: (widget.brush['colour'] as String?) ?? '');
  // Remembered slider values while a property is switched off (so switching it back on keeps it).
  final Map<String, double> _values = Map.of(kBrushDefaults);
  HSVColor _hsv = const HSVColor.fromAHSV(1, 4, 0.73, 0.85);

  @override
  void initState() {
    super.initState();
    _syncFromBrush();
  }

  @override
  void didUpdateWidget(covariant AppearancePanel old) {
    super.didUpdateWidget(old);
    if (old.brush != widget.brush) _syncFromBrush();
  }

  void _syncFromBrush() {
    for (final (_, field, _, _, _) in kBrushProperties) {
      final v = widget.brush[field];
      if (v is num) _values[field] = v.toDouble();
    }
    final hex = widget.brush['colour'];
    if (isHexColour(hex)) {
      final current = hexOfColour(_hsv.toColor());
      if (current != (hex as String).toUpperCase()) _hsv = HSVColor.fromColor(colourOfHex(hex));
      if (_hex.text.toUpperCase() != hex.toUpperCase()) _hex.text = hex.toUpperCase();
    }
  }

  @override
  void dispose() {
    _hex.dispose();
    super.dispose();
  }

  void _set(String field, Object? value) {
    final b = Map<String, dynamic>.from(widget.brush);
    if (value == null) {
      b.remove(field);
    } else {
      b[field] = value;
    }
    widget.onBrushChanged(b);
  }

  void _setColour(String hex) => _set('colour', hex.toUpperCase());

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ResizableToolPanel(
      title: widget.title,
      tooltip: widget.eyedropper
          ? 'Click a part to take its appearance into the brush'
          : 'Click a part to paint its body. Then pick what to paint below (hover to preview).',
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              _PreviewSwatch(key: const ValueKey('appearance-preview'), appearance: widget.brush),
              const SizedBox(width: 12),
              Expanded(child: Text(describeAppearance(widget.brush), key: const ValueKey('appearance-brush-summary'))),
              IconButton(
                key: const ValueKey('appearance-eyedropper'),
                tooltip: 'Eyedropper: the next click takes everything that face shows',
                isSelected: widget.eyedropper,
                icon: const Icon(Icons.colorize_outlined),
                selectedIcon: const Icon(Icons.colorize),
                onPressed: () => widget.onEyedropperChanged(!widget.eyedropper),
              ),
              if (widget.onUndo != null)
                IconButton(
                  key: const ValueKey('appearance-undo'),
                  tooltip: 'Undo the last paint',
                  icon: const Icon(Icons.undo),
                  onPressed: widget.busy ? null : widget.onUndo,
                ),
              IconButton(key: const ValueKey('appearance-close'), tooltip: 'Close', icon: const Icon(Icons.close), onPressed: widget.onClose),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              _ClearChip(selected: widget.brush.isEmpty, onTap: () => widget.onBrushChanged(const {})),
              for (final (name, hex) in [...kPaintPalette, for (final s in bodyColourSwatches) (s.label, s.hex)])
                _Dot(
                  key: ValueKey('appearance-swatch-$hex'),
                  hex: hex,
                  tooltip: name,
                  selected: (widget.brush['colour'] as String?)?.toUpperCase() == hex.toUpperCase(),
                  onTap: () => _setColour(hex),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _SvSquare(
                hsv: _hsv,
                onChanged: (hsv) {
                  setState(() => _hsv = hsv);
                  _setColour(hexOfColour(hsv.toColor()));
                },
              ),
              const SizedBox(width: 8),
              _HueBar(
                hue: _hsv.hue,
                onChanged: (h) {
                  final hsv = _hsv.withHue(h);
                  setState(() => _hsv = hsv);
                  _setColour(hexOfColour(hsv.toColor()));
                },
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Switch(
                          key: const ValueKey('appearance-switch-colour'),
                          value: widget.brush['colour'] != null,
                          onChanged: (on) => _set('colour', on ? hexOfColour(_hsv.toColor()) : null),
                        ),
                        const Text('Colour'),
                      ],
                    ),
                    TextField(
                      key: const ValueKey('appearance-hex'),
                      controller: _hex,
                      decoration: const InputDecoration(labelText: 'Hex', hintText: '#RRGGBB', isDense: true),
                      inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[#0-9A-Fa-f]')), LengthLimitingTextInputFormatter(7)],
                      onSubmitted: (text) {
                        final hex = text.startsWith('#') ? text : '#$text';
                        if (isHexColour(hex)) _setColour(hex);
                      },
                    ),
                    if (widget.recentColours.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text('Recent', style: theme.textTheme.labelSmall),
                      Wrap(spacing: 4, runSpacing: 4, children: [
                        for (final hex in widget.recentColours)
                          _Dot(key: ValueKey('appearance-recent-$hex'), hex: hex, tooltip: hex, size: 22, onTap: () => _setColour(hex)),
                      ]),
                    ],
                  ],
                ),
              ),
            ],
          ),
          for (final (label, field, lo, hi, inverted) in kBrushProperties)
            Row(
              children: [
                Switch(
                  key: ValueKey('appearance-switch-$field'),
                  value: widget.brush[field] != null,
                  onChanged: (on) => _set(field, on ? _values[field] : null),
                ),
                SizedBox(width: 64, child: Text(label)),
                Expanded(
                  child: Slider(
                    key: ValueKey('appearance-slider-$field'),
                    min: lo,
                    max: hi,
                    value: inverted ? 1.0 - _values[field]! : _values[field]!,
                    onChanged: (v) {
                      final stored = double.parse((inverted ? 1.0 - v : v).toStringAsFixed(3));
                      setState(() => _values[field] = stored);
                      _set(field, stored); // (moving a slider switches its property on)
                    },
                  ),
                ),
              ],
            ),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final (name, appearance) in [...kAppearancePresets, ...widget.savedAppearances])
                ActionChip(
                  key: ValueKey('appearance-saved-$name'),
                  label: Text(name),
                  onPressed: () => widget.onBrushChanged({...widget.brush, ...appearance}),
                ),
              ActionChip(
                key: const ValueKey('appearance-save-brush'),
                avatar: const Icon(Icons.bookmark_add_outlined, size: 18),
                label: const Text('Save brush...'),
                onPressed: widget.brush.isEmpty ? null : _askName,
              ),
            ],
          ),
          const Divider(height: 20),
          Text(widget.pickLabel == null ? 'Click a part to paint it' : 'Paint · ${widget.pickLabel}', style: theme.textTheme.titleSmall),
          for (final row in widget.rows)
            MouseRegion(
              key: ValueKey('appearance-row-${row.id}'),
              onEnter: (_) => widget.onPreviewRow(row),
              onExit: (_) => widget.onPreviewRow(null),
              child: ListTile(
                dense: true,
                enabled: !widget.busy,
                leading: _PreviewSwatch(appearance: row.swatch, size: 24),
                title: Text(row.label),
                subtitle: Text(row.setHere ? 'set here · ${describeAppearance(row.swatch)}' : describeAppearance(row.swatch)),
                trailing: row.setHere ? const Icon(Icons.brush, size: 16) : null,
                onTap: () => widget.onPaintRow(row),
                onLongPress: () => widget.onPreviewRow(row), // (touch: a long press previews, a tap paints)
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _askName() async {
    final name = await askSceneName(context, title: 'Save brush', fieldKey: 'appearance-save');
    if (name != null) widget.onSaveBrush(name);
  }
}

/// A round swatch of an appearance: its colour at its opacity over a checker, a highlight for shine, a ring for glow.
class _PreviewSwatch extends StatelessWidget {
  final Json appearance;
  final double size;

  const _PreviewSwatch({super.key, required this.appearance, this.size = 40});

  @override
  Widget build(BuildContext context) {
    final hex = appearance['colour'];
    final base = isHexColour(hex) ? colourOfHex(hex as String) : const Color(0xFFADB8C7);
    final opacity = ((appearance['opacity'] as num?) ?? 1.0).toDouble();
    final shine = 1.0 - ((appearance['roughness'] as num?) ?? 0.8).toDouble();
    final glow = ((appearance['emission_strength'] as num?) ?? (appearance['emission'] != null ? 1.0 : 0.0)).toDouble();
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: Theme.of(context).dividerColor),
        boxShadow: glow > 0 ? [BoxShadow(color: base.withValues(alpha: 0.8), blurRadius: 4 + glow * 2)] : null,
        gradient: RadialGradient(
          center: const Alignment(-0.4, -0.4),
          radius: 0.9,
          colors: [
            Color.lerp(base, Colors.white, 0.15 + shine * 0.6)!.withValues(alpha: opacity),
            base.withValues(alpha: opacity),
          ],
          stops: [0.0, 0.35 + (1 - shine) * 0.6],
        ),
      ),
      child: appearance.isEmpty ? Icon(Icons.block, size: size * 0.6) : null,
    );
  }
}

class _Dot extends StatelessWidget {
  final String hex;
  final String tooltip;
  final bool selected;
  final double size;
  final VoidCallback onTap;

  const _Dot({super.key, required this.hex, required this.tooltip, this.selected = false, this.size = 28, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: colourOfHex(hex),
            shape: BoxShape.circle,
            border: Border.all(color: selected ? Theme.of(context).colorScheme.primary : Theme.of(context).dividerColor, width: selected ? 3 : 1),
          ),
        ),
      ),
    );
  }
}

class _ClearChip extends StatelessWidget {
  final bool selected;
  final VoidCallback onTap;

  const _ClearChip({required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) => ChoiceChip(
        key: const ValueKey('appearance-clear'),
        label: const Text('Clear'),
        selected: selected,
        tooltip: "Painting Clear removes that level's own paint",
        onSelected: (_) => onTap(),
      );
}

/// Saturation (x) and value (y, top = bright) at the brush's hue.
class _SvSquare extends StatelessWidget {
  final HSVColor hsv;
  final ValueChanged<HSVColor> onChanged;
  static const double side = 120;

  const _SvSquare({required this.hsv, required this.onChanged});

  void _at(Offset p) {
    final s = (p.dx / side).clamp(0.0, 1.0);
    final v = 1.0 - (p.dy / side).clamp(0.0, 1.0);
    onChanged(hsv.withSaturation(s).withValue(v));
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      key: const ValueKey('appearance-sv'),
      onPanDown: (d) => _at(d.localPosition),
      onPanUpdate: (d) => _at(d.localPosition),
      child: SizedBox(
        width: side,
        height: side,
        child: CustomPaint(painter: _SvPainter(hsv)),
      ),
    );
  }
}

class _SvPainter extends CustomPainter {
  final HSVColor hsv;

  _SvPainter(this.hsv);

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(rect, Paint()..shader = LinearGradient(colors: [Colors.white, HSVColor.fromAHSV(1, hsv.hue, 1, 1).toColor()]).createShader(rect));
    canvas.drawRect(
      rect,
      Paint()..shader = const LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Colors.transparent, Colors.black]).createShader(rect),
    );
    final at = Offset(hsv.saturation * size.width, (1 - hsv.value) * size.height);
    canvas.drawCircle(at, 6, Paint()..style = PaintingStyle.stroke..strokeWidth = 2..color = hsv.value > 0.5 ? Colors.black : Colors.white);
  }

  @override
  bool shouldRepaint(_SvPainter old) => old.hsv != hsv;
}

class _HueBar extends StatelessWidget {
  final double hue;
  final ValueChanged<double> onChanged;
  static const double height = 120;

  const _HueBar({required this.hue, required this.onChanged});

  void _at(Offset p) => onChanged((p.dy / height).clamp(0.0, 1.0) * 359.9);

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      key: const ValueKey('appearance-hue'),
      onPanDown: (d) => _at(d.localPosition),
      onPanUpdate: (d) => _at(d.localPosition),
      child: SizedBox(width: 20, height: height, child: CustomPaint(painter: _HuePainter(hue))),
    );
  }
}

class _HuePainter extends CustomPainter {
  final double hue;

  _HuePainter(this.hue);

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [for (var h = 0; h <= 360; h += 60) HSVColor.fromAHSV(1, h % 360.0, 1, 1).toColor()],
        ).createShader(rect),
    );
    final y = hue / 360 * size.height;
    canvas.drawRect(Rect.fromLTWH(0, y - 2, size.width, 4), Paint()..style = PaintingStyle.stroke..strokeWidth = 2..color = Colors.black);
  }

  @override
  bool shouldRepaint(_HuePainter old) => old.hue != hue;
}
