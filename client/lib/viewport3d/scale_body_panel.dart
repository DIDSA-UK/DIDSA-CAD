import 'package:flutter/material.dart';

import 'resizable_tool_panel.dart';

/// Direct Editing family, second entry: the bottom-sheet-style panel
/// [PartScreen] opens once a single Body is selected and "Scale" is chosen
/// (see `selection_actions.dart`'s `contextActionsFor` body-only-selection
/// branch). Mirrors [FilletPanel]'s shape almost exactly - a single numeric
/// field, live-preview-drives-a-debounced-PATCH - just "factor" instead of
/// "radius", and (v1 scope, see `docs/direct-editing-scope.md`) always
/// uniform/about the Body's own bounding-box centre, so there is no
/// per-axis or origin-picking UI to build yet.
class ScaleBodyPanel extends StatefulWidget {
  /// 'Scale' when creating a brand-new Feature (default), 'Edit Scale' when
  /// [PartScreen] opened this to edit an already-existing one instead -
  /// same convention as [FilletPanel.title].
  final String title;

  final String? tooltip;

  final double initialFactor;

  /// Fired on every valid factor edit - same live-preview-drives-a-
  /// debounced-PATCH pattern [FilletPanel.onRadiusChanged] already uses.
  final void Function(double factor)? onFactorChanged;

  final VoidCallback onConfirm;
  final VoidCallback onCancel;

  const ScaleBodyPanel({
    super.key,
    this.title = 'Scale',
    this.tooltip,
    required this.initialFactor,
    this.onFactorChanged,
    required this.onConfirm,
    required this.onCancel,
  });

  @override
  State<ScaleBodyPanel> createState() => _ScaleBodyPanelState();
}

class _ScaleBodyPanelState extends State<ScaleBodyPanel> {
  late final TextEditingController _factorController;

  /// Null once the factor field no longer parses as a positive number -
  /// mirrors [FilletPanel]'s own `_radius` null-on-invalid-input pattern. A
  /// factor of zero or less is treated the same as unparseable - the
  /// backend rejects it outright (`_validate_scale_body_factor`), so there
  /// is nothing valid to preview or confirm.
  double? _factor;

  @override
  void initState() {
    super.initState();
    _factorController = TextEditingController(text: _formatFactor(widget.initialFactor));
    _factor = widget.initialFactor > 0 ? widget.initialFactor : null;
    // Without this, the live preview underneath this panel doesn't appear
    // until the user actually edits the factor field - onFactorChanged was
    // only ever wired to that callback, never fired for the initial value
    // this panel opens with (mirrors FilletPanel's identical fix).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _factor != null) widget.onFactorChanged?.call(_factor!);
    });
  }

  @override
  void dispose() {
    _factorController.dispose();
    super.dispose();
  }

  static String _formatFactor(double value) =>
      value == value.roundToDouble() ? value.toStringAsFixed(0) : value.toString();

  bool get _canConfirm => _factor != null;

  void _emitFactorChange() {
    final value = double.tryParse(_factorController.text);
    final factor = (value != null && value > 0) ? value : null;
    setState(() => _factor = factor);
    if (factor != null) widget.onFactorChanged?.call(factor);
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
          TextField(
            controller: _factorController,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: 'Factor'),
            onChanged: (_) => _emitFactorChange(),
          ),
          const SizedBox(height: 8),
          Text(
            _factor == null ? 'Enter a factor greater than 0' : 'Factor: ${_formatFactor(_factor!)}',
            style: TextStyle(
              color: _factor == null
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
                onPressed: _canConfirm ? widget.onConfirm : null,
                child: const Text('Confirm'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
