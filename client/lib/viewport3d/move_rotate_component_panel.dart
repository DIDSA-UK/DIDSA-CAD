import 'package:flutter/material.dart';

import 'resizable_tool_panel.dart';

/// [MoveRotateComponentPanel]'s own two tabs - which set of Delta X/Y/Z
/// fields (and which axis meaning, distance vs. degrees) is currently shown.
enum MoveRotateComponentMode { move, rotate }

/// Bug fix ("the Move/Rotate tool has no collapsible toolbar of its own, so
/// the user has no indication they're in the tool"): the standard
/// [ResizableToolPanel] shell every other tool already gets, for the
/// Move/Rotate gizmo (`component_gizmo.dart`) - `PartScreen` opens this once
/// [PartScreen._onOccurrenceLongPress]'s own Move/Rotate menu entry is
/// chosen (see `_moveRotateComponentActive`'s own doc comment there).
///
/// Two panels, [move]/[rotate], toggled by [mode] - a typed alternative to
/// dragging one of the gizmo's own six handles, not a replacement for it
/// (the gizmo itself, and this panel, both stay live and agree on the same
/// underlying Occurrence transform the whole time the tool is open). Each
/// panel has its own Delta X/Y/Z fields - translation along, or rotation
/// (degrees) about, the selected Occurrence's own current local axes,
/// exactly the axes the gizmo's own arrows/rings are drawn along
/// (`ComponentGizmoBasis`) - and its own Apply button, which commits the
/// typed delta immediately (mirrors a gizmo drag's own drag-end PATCH) and
/// resets the fields back to zero, rather than accumulating: each Apply is
/// its own independent nudge, the same way dragging a handle, releasing,
/// then dragging it again applies two independent deltas rather than one
/// combined one.
class MoveRotateComponentPanel extends StatefulWidget {
  final String title;

  final MoveRotateComponentMode mode;
  final ValueChanged<MoveRotateComponentMode> onModeChanged;

  /// Fired by the Move panel's Apply button - [dx]/[dy]/[dz] are a world-
  /// distance delta along the target's own local X/Y/Z axes respectively.
  final void Function(double dx, double dy, double dz) onApplyMove;

  /// Fired by the Rotate panel's Apply button - [dx]/[dy]/[dz] are a delta
  /// angle in degrees about the target's own local X/Y/Z axes respectively.
  final void Function(double dx, double dy, double dz) onApplyRotate;

  final VoidCallback onDone;

  const MoveRotateComponentPanel({
    super.key,
    this.title = 'Move / Rotate',
    required this.mode,
    required this.onModeChanged,
    required this.onApplyMove,
    required this.onApplyRotate,
    required this.onDone,
  });

  @override
  State<MoveRotateComponentPanel> createState() => _MoveRotateComponentPanelState();
}

class _MoveRotateComponentPanelState extends State<MoveRotateComponentPanel> {
  late final TextEditingController _xController;
  late final TextEditingController _yController;
  late final TextEditingController _zController;

  /// Null once any of the three fields no longer parses as a number -
  /// mirrors [MoveBodyPanel]'s own `_delta` null-on-invalid-input pattern.
  (double, double, double)? _delta;

  @override
  void initState() {
    super.initState();
    _xController = TextEditingController(text: '0');
    _yController = TextEditingController(text: '0');
    _zController = TextEditingController(text: '0');
    _delta = (0.0, 0.0, 0.0);
  }

  @override
  void didUpdateWidget(covariant MoveRotateComponentPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Move's and Rotate's fields have entirely different units/meaning
    // (world distance vs. degrees) - carrying a typed-but-not-yet-applied
    // value across the tab switch would silently reinterpret it as the
    // other unit, so switching tabs always starts from a clean zero.
    if (widget.mode != oldWidget.mode) _resetFields();
  }

  @override
  void dispose() {
    _xController.dispose();
    _yController.dispose();
    _zController.dispose();
    super.dispose();
  }

  void _resetFields() {
    _xController.text = '0';
    _yController.text = '0';
    _zController.text = '0';
    setState(() => _delta = (0.0, 0.0, 0.0));
  }

  void _emitDeltaChange() {
    final x = double.tryParse(_xController.text);
    final y = double.tryParse(_yController.text);
    final z = double.tryParse(_zController.text);
    setState(() => _delta = (x != null && y != null && z != null) ? (x, y, z) : null);
  }

  void _apply() {
    final delta = _delta;
    if (delta == null) return;
    final (dx, dy, dz) = delta;
    if (widget.mode == MoveRotateComponentMode.move) {
      widget.onApplyMove(dx, dy, dz);
    } else {
      widget.onApplyRotate(dx, dy, dz);
    }
    _resetFields();
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
    final isMove = widget.mode == MoveRotateComponentMode.move;
    return ResizableToolPanel(
      title: widget.title,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SegmentedButton<MoveRotateComponentMode>(
            segments: const [
              ButtonSegment(
                value: MoveRotateComponentMode.move,
                label: Text('Move'),
                icon: Icon(Icons.open_with),
              ),
              ButtonSegment(
                value: MoveRotateComponentMode.rotate,
                label: Text('Rotate'),
                icon: Icon(Icons.rotate_right),
              ),
            ],
            selected: {widget.mode},
            onSelectionChanged: (selection) => widget.onModeChanged(selection.first),
          ),
          const SizedBox(height: 12),
          Text(
            isMove
                ? 'Translates the component along its own local X/Y/Z axes'
                : 'Rotates the component about its own local X/Y/Z axes (degrees)',
            style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 8),
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
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(onPressed: widget.onDone, child: const Text('Done')),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: _delta == null ? null : _apply,
                child: const Text('Apply'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
