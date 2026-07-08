import 'package:flutter/material.dart';

/// Prompt E: the bottom-sheet-style panel [PartScreen] opens once Chamfer is
/// enabled (one or more edges selected, all on the same Body - see
/// `selection_actions.dart`'s `contextActionsFor`) - structurally identical
/// to [FilletPanel], substituting a distance field for the radius field
/// (Chamfer has only the one construction method too, same as Fillet, so
/// there is no per-mode branching to do here either).
class ChamferPanel extends StatefulWidget {
  /// 'Chamfer' when creating a brand-new Feature (default), 'Edit Chamfer'
  /// when [PartScreen] opened this to edit an already-existing one instead -
  /// purely a label, same convention as [FilletPanel.title].
  final String title;

  final double initialDistance;

  /// Fired on every valid distance edit - same live-preview-drives-a-
  /// debounced-PATCH pattern [FilletPanel.onRadiusChanged] already uses.
  final void Function(double distance)? onDistanceChanged;

  final VoidCallback onConfirm;
  final VoidCallback onCancel;

  const ChamferPanel({
    super.key,
    this.title = 'Chamfer',
    required this.initialDistance,
    this.onDistanceChanged,
    required this.onConfirm,
    required this.onCancel,
  });

  @override
  State<ChamferPanel> createState() => _ChamferPanelState();
}

class _ChamferPanelState extends State<ChamferPanel> {
  late final TextEditingController _distanceController;

  /// Null once the distance field no longer parses as a positive number -
  /// mirrors [FilletPanel]'s own `_radius` null-on-invalid-input pattern. A
  /// distance of zero or less is treated the same as unparseable - the
  /// backend rejects it outright (`_validate_chamfer_distance`), so there is
  /// nothing valid to preview or confirm.
  double? _distance;

  @override
  void initState() {
    super.initState();
    _distanceController = TextEditingController(text: _formatDistance(widget.initialDistance));
    _distance = widget.initialDistance > 0 ? widget.initialDistance : null;
    // Without this, the live preview underneath this panel doesn't appear
    // until the user actually edits the distance field - onDistanceChanged
    // was only ever wired to that callback, never fired for the initial
    // value this panel opens with (mirrors ExtrudePanel's identical fix).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _distance != null) widget.onDistanceChanged?.call(_distance!);
    });
  }

  @override
  void dispose() {
    _distanceController.dispose();
    super.dispose();
  }

  static String _formatDistance(double value) =>
      value == value.roundToDouble() ? value.toStringAsFixed(0) : value.toString();

  bool get _canConfirm => _distance != null;

  void _emitDistanceChange() {
    final value = double.tryParse(_distanceController.text);
    final distance = (value != null && value > 0) ? value : null;
    setState(() => _distance = distance);
    if (distance != null) widget.onDistanceChanged?.call(distance);
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
                  controller: _distanceController,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(labelText: 'Distance'),
                  onChanged: (_) => _emitDistanceChange(),
                ),
                const SizedBox(height: 8),
                Text(
                  _distance == null
                      ? 'Enter a distance greater than 0'
                      : 'Distance: ${_formatDistance(_distance!)}',
                  style: TextStyle(
                    color: _distance == null
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
