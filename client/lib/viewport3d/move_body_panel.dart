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
/// v1 client scope: translate + copy only - no rotation UI yet. The
/// backend `MoveBodyFeature`/`resolve_move_body` already fully supports
/// `rotation_axis`/`rotation_angle_degrees` (reusing `PatternAxisRef`
/// verbatim), but picking a rotation axis in the viewport needs its own
/// mid-panel picking-step UI (the same shape Mirror's plane-picking stage
/// already has) - deliberately deferred as a fast follow rather than
/// risking that larger picking-flow addition in the same pass as this
/// panel's first ship. See `docs/direct-editing-scope.md`.
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

  /// Null once any of the three delta fields no longer parses as a number -
  /// mirrors [ExtrudePanel]'s own `_depth` null-on-invalid-input pattern.
  /// Unlike a radius/factor, a delta component of exactly 0 is perfectly
  /// valid (the common "only moving along one axis" case), so there is no
  /// additional `> 0` check here.
  (double, double, double)? _delta;

  @override
  void initState() {
    super.initState();
    _xController = TextEditingController(text: _formatDistance(widget.initialDeltaX));
    _yController = TextEditingController(text: _formatDistance(widget.initialDeltaY));
    _zController = TextEditingController(text: _formatDistance(widget.initialDeltaZ));
    _delta = (widget.initialDeltaX, widget.initialDeltaY, widget.initialDeltaZ);
    // Without this, the live preview underneath this panel doesn't appear
    // until the user actually edits a field - mirrors ExtrudePanel's
    // identical fix.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        widget.onDeltaChanged?.call(widget.initialDeltaX, widget.initialDeltaY, widget.initialDeltaZ);
      }
    });
  }

  @override
  void dispose() {
    _xController.dispose();
    _yController.dispose();
    _zController.dispose();
    super.dispose();
  }

  static String _formatDistance(double value) =>
      value == value.roundToDouble() ? value.toStringAsFixed(0) : value.toString();

  bool get _canConfirm => _delta != null;

  void _emitDeltaChange() {
    final x = double.tryParse(_xController.text);
    final y = double.tryParse(_yController.text);
    final z = double.tryParse(_zController.text);
    setState(() => _delta = (x != null && y != null && z != null) ? (x, y, z) : null);
    if (x == null || y == null || z == null) return;
    widget.onDeltaChanged?.call(x, y, z);
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
