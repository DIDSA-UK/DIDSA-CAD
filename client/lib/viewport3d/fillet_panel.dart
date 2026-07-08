import 'package:flutter/material.dart';

/// Prompt D: the bottom-sheet-style panel [PartScreen] opens once Fillet is
/// enabled (one or more edges selected, all on the same Body - see
/// `selection_actions.dart`'s `contextActionsFor`) - mirrors
/// [CreatePlanePanel]'s Confirm/Cancel session shape and slide-up
/// presentation exactly, just always showing a numeric radius field (unlike
/// [CreatePlanePanel], Fillet has only the one construction method, so there
/// is no per-mode branching to do).
class FilletPanel extends StatefulWidget {
  /// 'Fillet' when creating a brand-new Feature (default), 'Edit Fillet'
  /// when [PartScreen] opened this to edit an already-existing one instead -
  /// purely a label, same convention as [CreatePlanePanel.title].
  final String title;

  final double initialRadius;

  /// Fired on every valid radius edit - same live-preview-drives-a-
  /// debounced-PATCH pattern [CreatePlanePanel.onOffsetChanged] already
  /// uses.
  final void Function(double radius)? onRadiusChanged;

  final VoidCallback onConfirm;
  final VoidCallback onCancel;

  const FilletPanel({
    super.key,
    this.title = 'Fillet',
    required this.initialRadius,
    this.onRadiusChanged,
    required this.onConfirm,
    required this.onCancel,
  });

  @override
  State<FilletPanel> createState() => _FilletPanelState();
}

class _FilletPanelState extends State<FilletPanel> {
  late final TextEditingController _radiusController;

  /// Null once the radius field no longer parses as a positive number -
  /// mirrors [CreatePlanePanel]'s own `_offset` null-on-invalid-input
  /// pattern. A radius of zero or less is treated the same as unparseable -
  /// the backend rejects it outright (`_validate_fillet_radius`), so there
  /// is nothing valid to preview or confirm.
  double? _radius;

  @override
  void initState() {
    super.initState();
    _radiusController = TextEditingController(text: _formatDistance(widget.initialRadius));
    _radius = widget.initialRadius > 0 ? widget.initialRadius : null;
    // Without this, the live preview underneath this panel doesn't appear
    // until the user actually edits the radius field - onRadiusChanged was
    // only ever wired to that callback, never fired for the initial value
    // this panel opens with (mirrors ExtrudePanel's identical fix).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _radius != null) widget.onRadiusChanged?.call(_radius!);
    });
  }

  @override
  void dispose() {
    _radiusController.dispose();
    super.dispose();
  }

  static String _formatDistance(double value) =>
      value == value.roundToDouble() ? value.toStringAsFixed(0) : value.toString();

  bool get _canConfirm => _radius != null;

  void _emitRadiusChange() {
    final value = double.tryParse(_radiusController.text);
    final radius = (value != null && value > 0) ? value : null;
    setState(() => _radius = radius);
    if (radius != null) widget.onRadiusChanged?.call(radius);
  }

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.bottomCenter,
      child: SafeArea(
        top: false,
        child: Material(
          elevation: 4,
          borderRadius: const BorderRadius.only(topLeft: Radius.circular(12), topRight: Radius.circular(12)),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(widget.title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                const SizedBox(height: 12),
                TextField(
                  controller: _radiusController,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(labelText: 'Radius'),
                  onChanged: (_) => _emitRadiusChange(),
                ),
                const SizedBox(height: 8),
                Text(
                  _radius == null ? 'Enter a radius greater than 0' : 'Radius: ${_formatDistance(_radius!)}',
                  style: TextStyle(
                    color: _radius == null
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
          ),
        ),
      ),
    );
  }
}
