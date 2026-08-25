import 'package:flutter/material.dart';

import 'resizable_tool_panel.dart';

/// The bottom-sheet-style panel [PartScreen] opens for the guided "Add >
/// Feature > Reference > Surface" flow - "Extrude but a shell instead of a
/// solid" (see the backend `SurfaceFeature`'s own docstring): mirrors
/// [ExtrudePanel]'s start/end-distance fields closely (same signed-distance
/// convention, same flip-direction affordance), minus the Boss/Cut choice
/// and target-body picking, which a Surface has no concept of at all.
///
/// Purely a form: every value change is reported immediately via
/// [onChanged] - debouncing the resulting PATCH/POST and mesh refresh is
/// [PartScreen]'s job, not this widget's, so this stays a dumb, easily
/// tested input panel (same discipline [ExtrudePanel] follows).
class SurfacePanel extends StatefulWidget {
  /// 'Surface' when creating a brand-new Feature (default), 'Edit Surface'
  /// when [PartScreen] opened this to edit an already-existing one instead -
  /// purely a label, doesn't affect any other behaviour of this panel.
  final String title;

  final String? tooltip;

  final double initialStartDistance;
  final double initialEndDistance;

  /// `null` (the default) means "normal to the backing Sketch's own host
  /// plane" - matches the backend `SurfaceFeature.direction_ref`'s own
  /// default. `'x'`/`'y'`/`'z'` names a fixed world axis override instead
  /// (`PatternDirectionRef.fixed_axis`) - the only direction-override
  /// method this panel exposes (v1, minimal scope): picking a Body edge or
  /// Sketch Line as the direction isn't wired up here, unlike
  /// [PatternPanel]'s own richer direction picker.
  final String? initialFixedAxis;

  /// [fixedAxis] is `null`/`'x'`/`'y'`/`'z'`, same convention as
  /// [initialFixedAxis].
  final void Function(
      double startDistance, double endDistance, String? fixedAxis) onChanged;
  final VoidCallback onConfirm;
  final VoidCallback onCancel;

  const SurfacePanel({
    super.key,
    this.title = 'Surface',
    this.tooltip,
    this.initialStartDistance = 0.0,
    this.initialEndDistance = 10.0,
    this.initialFixedAxis,
    required this.onChanged,
    required this.onConfirm,
    required this.onCancel,
  });

  @override
  State<SurfacePanel> createState() => _SurfacePanelState();
}

class _SurfacePanelState extends State<SurfacePanel> {
  late final TextEditingController _startController;
  late final TextEditingController _endController;
  late String? _fixedAxis;

  /// Mirrors [ExtrudePanel._depth]'s identical role - `null` once the
  /// start/end fields no longer both parse as numbers, so [build] can fall
  /// back to not showing a value rather than a stale one.
  double? _depth;

  @override
  void initState() {
    super.initState();
    _startController =
        TextEditingController(text: _formatDistance(widget.initialStartDistance));
    _endController =
        TextEditingController(text: _formatDistance(widget.initialEndDistance));
    _fixedAxis = widget.initialFixedAxis;
    _depth = widget.initialEndDistance - widget.initialStartDistance;
    // Mirrors ExtrudePanel's identical fix - without this, the live preview
    // underneath this panel doesn't appear until the user actually edits a
    // field.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        widget.onChanged(widget.initialStartDistance, widget.initialEndDistance, _fixedAxis);
      }
    });
  }

  @override
  void dispose() {
    _startController.dispose();
    _endController.dispose();
    super.dispose();
  }

  static String _formatDistance(double value) => value == value.roundToDouble()
      ? value.toStringAsFixed(0)
      : value.toString();

  bool get _canConfirm => _depth != null && _depth! > 0;

  void _emitChange() {
    final start = double.tryParse(_startController.text);
    final end = double.tryParse(_endController.text);
    setState(
        () => _depth = (start != null && end != null) ? end - start : null);
    if (start == null || end == null) return;
    widget.onChanged(start, end, _fixedAxis);
  }

  /// Mirrors [ExtrudePanel._flipDirection]'s identical reasoning - negating
  /// and swapping (rather than negating each field independently) keeps
  /// `end > start` automatically, whatever direction this Surface actually
  /// extrudes along.
  void _flipDirection() {
    final start = double.tryParse(_startController.text);
    final end = double.tryParse(_endController.text);
    if (start == null || end == null) return;
    _startController.text = _formatDistance(-end);
    _endController.text = _formatDistance(-start);
    _emitChange();
  }

  void _onFixedAxisChanged(String? axis) {
    setState(() => _fixedAxis = axis);
    final start = double.tryParse(_startController.text);
    final end = double.tryParse(_endController.text);
    if (start == null || end == null) return;
    widget.onChanged(start, end, axis);
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
            children: [
              Expanded(
                child: DropdownButtonFormField<String?>(
                  initialValue: _fixedAxis,
                  decoration: const InputDecoration(labelText: 'Direction'),
                  items: const [
                    DropdownMenuItem(value: null, child: Text('Normal to sketch plane')),
                    DropdownMenuItem(value: 'x', child: Text('World X')),
                    DropdownMenuItem(value: 'y', child: Text('World Y')),
                    DropdownMenuItem(value: 'z', child: Text('World Z')),
                  ],
                  onChanged: _onFixedAxisChanged,
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                tooltip: 'Flip direction',
                icon: const Icon(Icons.swap_vert),
                onPressed: _flipDirection,
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _startController,
                  keyboardType: const TextInputType.numberWithOptions(
                      decimal: true, signed: true),
                  decoration:
                      const InputDecoration(labelText: 'Start distance'),
                  onChanged: (_) => _emitChange(),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: _endController,
                  keyboardType: const TextInputType.numberWithOptions(
                      decimal: true, signed: true),
                  decoration: const InputDecoration(labelText: 'End distance'),
                  onChanged: (_) => _emitChange(),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            _depth == null
                ? 'Enter valid numbers for both distances'
                : _depth! > 0
                    ? 'Depth: ${_formatDistance(_depth!)}'
                    : 'End distance must be greater than start distance',
            style: TextStyle(
              color: (_depth == null || _depth! <= 0)
                  ? Theme.of(context).colorScheme.error
                  : Theme.of(context).colorScheme.onSurfaceVariant,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                  onPressed: widget.onCancel, child: const Text('Cancel')),
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
