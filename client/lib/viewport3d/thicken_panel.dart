import 'package:flutter/material.dart';

import 'resizable_tool_panel.dart';

/// Phase 2 surfacing package, first entry: the bottom-sheet-style panel
/// [PartScreen] opens once a single surface-producing Feature has been
/// picked as Thicken's source (see the backend `ThickenFeature`'s own
/// docstring - it always mints a brand-new, standalone solid Body, never a
/// Boss/Cut into an existing one). Mirrors [ScaleBodyPanel]'s own single-
/// field shape (a read-only source summary in place of that panel's target-
/// Body summary, plus a signed thickness field instead of a scale factor) -
/// the closest existing precedent for "one picked target, one live-preview-
/// driving numeric field, no further options".
///
/// Every valid thickness edit is reported immediately via [onThicknessChanged]
/// - debouncing the resulting create/PATCH and mesh refresh is [PartScreen]'s
/// job, not this widget's, same as [ScaleBodyPanel.onFactorChanged].
class ThickenPanel extends StatefulWidget {
  /// 'Thicken', or 'Edit Thicken' while editing an already-existing
  /// ThickenFeature - matches every other panel's `title` param.
  final String title;

  final String? tooltip;

  /// The source surface-producing Feature's own display name (e.g. "Loft
  /// Surface 1") - computed by [PartScreen] (it alone has the id-to-name
  /// map this needs), not this widget, mirrors [SplitPanel.toolSummary]'s
  /// own "caller decides the summary copy" split.
  final String sourceSummary;

  final double initialThickness;

  /// Fired on every valid, non-zero thickness edit - mirrors
  /// [MoveFacePanel.onOffsetChanged]'s own "must be non-zero" contract (the
  /// backend's `_validate_thickness_nonzero` rejects 0 outright).
  final void Function(double thickness)? onThicknessChanged;

  final VoidCallback onConfirm;
  final VoidCallback onCancel;

  const ThickenPanel({
    super.key,
    this.title = 'Thicken',
    this.tooltip,
    required this.sourceSummary,
    required this.initialThickness,
    this.onThicknessChanged,
    required this.onConfirm,
    required this.onCancel,
  });

  @override
  State<ThickenPanel> createState() => _ThickenPanelState();
}

class _ThickenPanelState extends State<ThickenPanel> {
  late final TextEditingController _thicknessController;

  /// Null once the thickness field no longer parses as a non-zero number -
  /// mirrors [MoveFacePanel._offset]'s own null-on-invalid-input pattern.
  double? _thickness;

  @override
  void initState() {
    super.initState();
    _thicknessController = TextEditingController(text: _formatNumber(widget.initialThickness));
    _thickness = widget.initialThickness != 0 ? widget.initialThickness : null;
    // Without this, the live preview underneath this panel doesn't appear
    // until the user actually edits the field - mirrors every other panel's
    // identical fix.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_thickness != null) widget.onThicknessChanged?.call(_thickness!);
    });
  }

  @override
  void dispose() {
    _thicknessController.dispose();
    super.dispose();
  }

  static String _formatNumber(double value) =>
      value == value.roundToDouble() ? value.toStringAsFixed(0) : value.toString();

  void _emitThicknessChange() {
    final value = double.tryParse(_thicknessController.text);
    final thickness = (value != null && value != 0) ? value : null;
    setState(() => _thickness = thickness);
    if (thickness != null) widget.onThicknessChanged?.call(thickness);
  }

  /// Mirrors [MoveFacePanel._flipDirectionDistance] - negates the field's
  /// sign in place, the same "Flip" convention every signed-distance field
  /// in this app already uses instead of a separate boolean.
  void _flipThickness() {
    final value = double.tryParse(_thicknessController.text);
    if (value == null) return;
    _thicknessController.text = _formatNumber(-value);
    _emitThicknessChange();
  }

  @override
  Widget build(BuildContext context) {
    return ResizableToolPanel(
      title: widget.title,
      tooltip: widget.tooltip,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.layers_outlined,
                size: 16,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'Thickening: ${widget.sourceSummary}',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    fontSize: 12,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _thicknessController,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                  decoration: const InputDecoration(labelText: 'Thickness'),
                  onChanged: (_) => _emitThicknessChange(),
                ),
              ),
              IconButton(
                tooltip: 'Flip side',
                onPressed: _flipThickness,
                icon: const Icon(Icons.swap_vert),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            _thickness == null
                ? 'Enter a non-zero thickness'
                : 'Thickened by ${_formatNumber(_thickness!)} along the surface\'s own normal',
            style: TextStyle(
              color: _thickness == null
                  ? Theme.of(context).colorScheme.error
                  : Theme.of(context).colorScheme.onSurfaceVariant,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(onPressed: widget.onCancel, child: const Text('Cancel')),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: _thickness != null ? widget.onConfirm : null,
                child: const Text('Confirm'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
