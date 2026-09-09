import 'package:flutter/material.dart';

import 'resizable_tool_panel.dart';

/// The bottom-sheet-style panel [PartScreen] opens for a Revolve Surface -
/// mirrors [RevolvePanel] exactly, minus the Boss/Cut segmented control and
/// target-body picking (a Revolve Surface never combines with an existing
/// Body - always a brand-new, standalone Surface, see the backend
/// `RevolveSurfaceFeature`'s own docstring). Just the axis-pick status line
/// and the angle field remain.
///
/// Every value change is reported immediately via [onChanged] - debouncing
/// the resulting PATCH/POST and mesh refresh is [PartScreen]'s job, not this
/// widget's, same as [RevolvePanel].
class RevolveSurfacePanel extends StatefulWidget {
  /// 'Revolve Surface' when creating a brand-new Feature (default), 'Edit
  /// Revolve Surface' when [PartScreen] opened this to edit an already-
  /// existing one instead.
  final String title;

  final String? tooltip;

  final double initialAngle;

  /// Mirrors [RevolvePanel.hasAxis] exactly.
  final bool hasAxis;

  final void Function(double angle) onChanged;
  final VoidCallback onConfirm;
  final VoidCallback onCancel;

  const RevolveSurfacePanel({
    super.key,
    this.title = 'Revolve Surface',
    this.tooltip,
    this.initialAngle = 180.0,
    required this.hasAxis,
    required this.onChanged,
    required this.onConfirm,
    required this.onCancel,
  });

  @override
  State<RevolveSurfacePanel> createState() => _RevolveSurfacePanelState();
}

class _RevolveSurfacePanelState extends State<RevolveSurfacePanel> {
  late final TextEditingController _angleController;

  /// Mirrors [RevolvePanel._angle] exactly.
  double? _angle;

  @override
  void initState() {
    super.initState();
    _angleController = TextEditingController(text: _formatAngle(widget.initialAngle));
    _angle = (widget.initialAngle > 0 && widget.initialAngle <= 360) ? widget.initialAngle : null;
    // Mirrors RevolvePanel's identical fix - without this, the live preview
    // underneath this panel doesn't appear until the user actually edits the
    // angle field.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _angle != null) widget.onChanged(_angle!);
    });
  }

  @override
  void dispose() {
    _angleController.dispose();
    super.dispose();
  }

  static String _formatAngle(double value) =>
      value == value.roundToDouble() ? value.toStringAsFixed(0) : value.toString();

  /// Confirm is disabled for an invalid angle or no axis picked yet -
  /// mirrors [RevolvePanel._canConfirm] minus the Cut target-body rule
  /// (there is no Boss/Cut here at all).
  bool get _canConfirm => _angle != null && widget.hasAxis;

  void _emitChange() {
    final value = double.tryParse(_angleController.text);
    final angle = (value != null && value > 0 && value <= 360) ? value : null;
    setState(() => _angle = angle);
    if (angle != null) widget.onChanged(angle);
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
            controller: _angleController,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: 'Angle (degrees)'),
            onChanged: (_) => _emitChange(),
          ),
          const SizedBox(height: 8),
          Text(
            _angle == null
                ? 'Enter an angle greater than 0 and at most 360'
                : 'Angle: ${_formatAngle(_angle!)}°',
            style: TextStyle(
              color: _angle == null
                  ? Theme.of(context).colorScheme.error
                  : Theme.of(context).colorScheme.onSurfaceVariant,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            widget.hasAxis ? 'Axis: selected' : 'Select an axis line in the viewport',
            style: TextStyle(
              color: widget.hasAxis
                  ? Theme.of(context).colorScheme.onSurfaceVariant
                  : Theme.of(context).colorScheme.error,
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
