import 'package:flutter/material.dart';

import 'resizable_tool_panel.dart';

/// Direct Editing family, third entry ("Move/Copy Body" - SolidWorks/
/// Fusion 360's own naming, see `docs/direct-editing-scope.md`): the
/// bottom-sheet-style panel [PartScreen] opens once a single Body is
/// selected and "Move Body" is chosen (see `selection_actions.dart`'s
/// `contextActionsFor` body-only-selection branch). Three delta fields
/// mirror [ExtrudePanel]'s live multi-field `onChanged` shape; the Move/
/// Copy toggle mirrors [BooleanPanel]'s own Keep/Consume `SegmentedButton`
/// convention exactly (a two-state option owned by the parent, not local
/// widget state).
///
/// Rotation is optional, layered on top of translate - tap an edge,
/// cylindrical face, or Sketch Line in the viewport (driven by
/// [PartScreen], the same live-tap mechanism `PatternPanel`'s own Circular-
/// mode axis pick already uses - no separate "arm the picker" step, the
/// viewport is simply live for those entity kinds the whole time this
/// panel is open) to define [hasRotationAxis]/[rotationAxisSummary], then
/// set a non-zero [initialRotationAngleDegrees]. Picking nothing (or
/// leaving the angle at `0`) means "translate only", the common case -
/// mirrors how Pattern's own Direction 2 stays optional-until-enabled.
class MoveBodyPanel extends StatefulWidget {
  /// 'Move Body', or 'Edit Move Body' while editing an already-existing
  /// MoveBodyFeature - matches every other panel's `title` param.
  final String title;

  final String? tooltip;

  final double initialDeltaX;
  final double initialDeltaY;
  final double initialDeltaZ;

  /// Fired on every valid delta edit (all three fields parse as numbers) -
  /// same live-preview-drives-a-debounced-PATCH pattern
  /// [ExtrudePanel.onChanged] already uses for its own multi-field shape.
  final void Function(double dx, double dy, double dz)? onDeltaChanged;

  /// Whether this modifies the source Body in place (`false`, the default)
  /// or mints a brand-new Body alongside it (`true`) - owned by the parent
  /// (mirrors [BooleanPanel.consumeToolBodies]), not local widget state.
  final bool copy;
  final void Function(bool copy) onCopyChanged;

  /// Whether a rotation axis has been picked yet (an edge/cylindrical-face/
  /// Sketch-Line tap) - mirrors [PatternPanel.hasAxis]'s live-read-every-
  /// build convention. Unlike Circular Pattern, an axis pick is never
  /// required to confirm this panel (rotation is optional) - see this
  /// class's own doc comment.
  final bool hasRotationAxis;

  /// A short human-readable summary of the rotation axis's current pick -
  /// e.g. "Edge selected", "Cylindrical face selected", or "Sketch Line
  /// selected" - or null when nothing is picked yet. Mirrors
  /// [PatternPanel.axisSummary].
  final String? rotationAxisSummary;

  final double initialRotationAngleDegrees;

  /// Fired on every valid angle edit - same live-preview-drives-a-
  /// debounced-PATCH pattern [onDeltaChanged] already uses. Only
  /// meaningful once [hasRotationAxis] is true; the field itself stays
  /// disabled until then (see this class's own doc comment).
  final void Function(double angleDegrees)? onRotationAngleChanged;

  final VoidCallback onConfirm;
  final VoidCallback onCancel;

  const MoveBodyPanel({
    super.key,
    this.title = 'Move Body',
    this.tooltip,
    this.initialDeltaX = 0.0,
    this.initialDeltaY = 0.0,
    this.initialDeltaZ = 0.0,
    this.onDeltaChanged,
    required this.copy,
    required this.onCopyChanged,
    this.hasRotationAxis = false,
    this.rotationAxisSummary,
    this.initialRotationAngleDegrees = 0.0,
    this.onRotationAngleChanged,
    required this.onConfirm,
    required this.onCancel,
  });

  @override
  State<MoveBodyPanel> createState() => _MoveBodyPanelState();
}

class _MoveBodyPanelState extends State<MoveBodyPanel> {
  late final TextEditingController _xController;
  late final TextEditingController _yController;
  late final TextEditingController _zController;
  late final TextEditingController _angleController;

  /// Null once any of the three delta fields no longer parses as a number -
  /// mirrors [ExtrudePanel]'s own `_depth` null-on-invalid-input pattern.
  /// Unlike a radius/factor, a delta component of exactly 0 is perfectly
  /// valid (the common "only moving along one axis" case), so there is no
  /// additional `> 0` check here.
  (double, double, double)? _delta;

  /// Null once the angle field no longer parses as a number - `0` (the
  /// default) is valid, unlike [_delta]'s siblings there is no axis-picked
  /// requirement baked in here; that's [_canConfirm]'s own job (an axis is
  /// only required once this is non-zero).
  double? _angle;

  @override
  void initState() {
    super.initState();
    _xController = TextEditingController(text: _formatDistance(widget.initialDeltaX));
    _yController = TextEditingController(text: _formatDistance(widget.initialDeltaY));
    _zController = TextEditingController(text: _formatDistance(widget.initialDeltaZ));
    _angleController = TextEditingController(text: _formatDistance(widget.initialRotationAngleDegrees));
    _delta = (widget.initialDeltaX, widget.initialDeltaY, widget.initialDeltaZ);
    _angle = widget.initialRotationAngleDegrees;
    // Without this, the live preview underneath this panel doesn't appear
    // until the user actually edits a field - mirrors ExtrudePanel's
    // identical fix.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        widget.onDeltaChanged?.call(widget.initialDeltaX, widget.initialDeltaY, widget.initialDeltaZ);
        widget.onRotationAngleChanged?.call(widget.initialRotationAngleDegrees);
      }
    });
  }

  @override
  void dispose() {
    _xController.dispose();
    _yController.dispose();
    _zController.dispose();
    _angleController.dispose();
    super.dispose();
  }

  static String _formatDistance(double value) =>
      value == value.roundToDouble() ? value.toStringAsFixed(0) : value.toString();

  // An axis pick is only required once the angle is actually non-zero -
  // rotation is optional, layered on top of translate (see this widget's
  // own doc comment).
  bool get _canConfirm =>
      _delta != null && _angle != null && (_angle == 0 || widget.hasRotationAxis);

  void _emitDeltaChange() {
    final x = double.tryParse(_xController.text);
    final y = double.tryParse(_yController.text);
    final z = double.tryParse(_zController.text);
    setState(() => _delta = (x != null && y != null && z != null) ? (x, y, z) : null);
    if (x == null || y == null || z == null) return;
    widget.onDeltaChanged?.call(x, y, z);
  }

  void _emitAngleChange() {
    final value = double.tryParse(_angleController.text);
    setState(() => _angle = value);
    if (value != null) widget.onRotationAngleChanged?.call(value);
  }

  Widget _deltaField(TextEditingController controller, String label) {
    return Expanded(
      child: TextField(
        controller: controller,
        keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
        decoration: InputDecoration(labelText: label),
        onChanged: (_) => _emitDeltaChange(),
      ),
    );
  }

  /// Bug fix precedent this mirrors verbatim: [PatternPanel]'s own
  /// `_pickAffordanceButton` - tapping this doesn't itself pick anything
  /// (there's no separate "arm the picker" step, the viewport is always
  /// live for an edge/cylindrical-face/Sketch-Line tap while this panel is
  /// open) - it just surfaces the hint text as a visible, tappable prompt.
  Widget _pickAffordanceButton() => IconButton(
        tooltip: 'Tap an edge, cylindrical face, or Sketch Line to define a rotation axis',
        onPressed: () => ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Tap an edge, cylindrical face, or Sketch Line to define a rotation axis'),
            duration: Duration(seconds: 3),
          ),
        ),
        icon: const Icon(Icons.touch_app_outlined, size: 20),
      );

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
              _deltaField(_xController, 'Delta X'),
              const SizedBox(width: 8),
              _deltaField(_yController, 'Delta Y'),
              const SizedBox(width: 8),
              _deltaField(_zController, 'Delta Z'),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            _delta == null ? 'Enter a valid X/Y/Z delta' : 'Delta: $_delta',
            style: TextStyle(
              color: _delta == null
                  ? Theme.of(context).colorScheme.error
                  : Theme.of(context).colorScheme.onSurfaceVariant,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 12),
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: false, label: Text('Move')),
              ButtonSegment(value: true, label: Text('Copy')),
            ],
            selected: {widget.copy},
            onSelectionChanged: (selection) => widget.onCopyChanged(selection.first),
          ),
          const SizedBox(height: 12),
          Text('Rotation (optional)', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: Text(
                  widget.hasRotationAxis
                      ? (widget.rotationAxisSummary ?? 'Rotation axis selected')
                      : 'Tap an edge, cylindrical face, or Sketch Line to pick a rotation axis',
                  style: TextStyle(
                    color: widget.hasRotationAxis
                        ? Theme.of(context).colorScheme.onSurfaceVariant
                        : Theme.of(context).colorScheme.error,
                    fontSize: 12,
                  ),
                ),
              ),
              _pickAffordanceButton(),
            ],
          ),
          const SizedBox(height: 6),
          TextField(
            controller: _angleController,
            enabled: widget.hasRotationAxis,
            keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
            decoration: const InputDecoration(labelText: 'Rotation angle (degrees)'),
            onChanged: (_) => _emitAngleChange(),
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
