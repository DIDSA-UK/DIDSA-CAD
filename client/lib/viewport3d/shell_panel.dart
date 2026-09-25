import 'package:flutter/material.dart';

import 'extrude_panel.dart' show ThicknessDirection;
import 'resizable_tool_panel.dart';

/// The bottom-sheet-style panel [PartScreen] opens once Shell is chosen
/// (one or more faces of the same solid Body selected - see
/// `selection_actions.dart`'s `contextActionsFor`). Structurally mirrors
/// [ChamferPanel] (one live-previewed numeric field plus Cancel/Confirm),
/// substituting a wall Thickness field for Chamfer's Distance, plus the
/// same Out/In/Middle [ThicknessDirection] [SegmentedButton] thin-wall
/// Extrude's [ExtrudePanel] uses. The picked faces (the Shell's open
/// faces) are chosen in the viewport behind this panel, not in here -
/// [faceCount] just reports them, same as [DeleteFacePanel.faceCount].
///
/// v1: one uniform thickness for every wall - no per-face overrides.
class ShellPanel extends StatefulWidget {
  /// 'Shell' when creating a brand-new Feature (default), 'Edit Shell' when
  /// [PartScreen] opened this to edit an already-existing one instead -
  /// same convention as [ChamferPanel.title].
  final String title;

  /// See [ChamferPanel.tooltip].
  final String? tooltip;

  final double initialThickness;
  final ThicknessDirection initialThicknessDirection;

  /// The live count of faces currently picked to be opened - updates as
  /// the user taps faces in the viewport.
  final int faceCount;

  /// Fired on every valid thickness/direction edit (and once for the
  /// initial values, post-frame) - same live-preview-drives-a-debounced-
  /// PATCH pattern [ChamferPanel.onDistanceChanged] uses.
  final void Function(double thickness, ThicknessDirection direction)? onChanged;

  final VoidCallback onConfirm;
  final VoidCallback onCancel;

  const ShellPanel({
    super.key,
    this.title = 'Shell',
    this.tooltip,
    required this.initialThickness,
    this.initialThicknessDirection = ThicknessDirection.outward,
    required this.faceCount,
    this.onChanged,
    required this.onConfirm,
    required this.onCancel,
  });

  @override
  State<ShellPanel> createState() => _ShellPanelState();
}

class _ShellPanelState extends State<ShellPanel> {
  late final TextEditingController _thicknessController;
  late ThicknessDirection _thicknessDirection;

  /// Null once the thickness field no longer parses as a positive number -
  /// mirrors [ChamferPanel]'s own null-on-invalid-input pattern (the
  /// backend rejects `thickness <= 0` outright - `_validate_shell_
  /// thickness`).
  double? _thickness;

  @override
  void initState() {
    super.initState();
    _thicknessController =
        TextEditingController(text: _formatThickness(widget.initialThickness));
    _thickness = widget.initialThickness > 0 ? widget.initialThickness : null;
    _thicknessDirection = widget.initialThicknessDirection;
    // Mirrors ChamferPanel's own initial-value post-frame emit, so the live
    // preview appears without the user first having to touch a field.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _thickness != null) {
        widget.onChanged?.call(_thickness!, _thicknessDirection);
      }
    });
  }

  @override
  void dispose() {
    _thicknessController.dispose();
    super.dispose();
  }

  static String _formatThickness(double value) => value == value.roundToDouble()
      ? value.toStringAsFixed(0)
      : value.toString();

  bool get _canConfirm => _thickness != null && widget.faceCount > 0;

  void _emitThicknessChange() {
    final value = double.tryParse(_thicknessController.text);
    final thickness = (value != null && value > 0) ? value : null;
    setState(() => _thickness = thickness);
    if (thickness != null) widget.onChanged?.call(thickness, _thicknessDirection);
  }

  void _onDirectionChanged(ThicknessDirection direction) {
    setState(() => _thicknessDirection = direction);
    final thickness = _thickness;
    if (thickness != null) widget.onChanged?.call(thickness, direction);
  }

  @override
  Widget build(BuildContext context) {
    final faceCount = widget.faceCount;
    return ResizableToolPanel(
      title: widget.title,
      tooltip: widget.tooltip,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _thicknessController,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: 'Thickness'),
            onChanged: (_) => _emitThicknessChange(),
          ),
          const SizedBox(height: 8),
          SegmentedButton<ThicknessDirection>(
            segments: const [
              ButtonSegment(value: ThicknessDirection.outward, label: Text('Out')),
              ButtonSegment(value: ThicknessDirection.inward, label: Text('In')),
              ButtonSegment(value: ThicknessDirection.symmetric, label: Text('Middle')),
            ],
            selected: {_thicknessDirection},
            onSelectionChanged: (selection) => _onDirectionChanged(selection.first),
          ),
          const SizedBox(height: 8),
          Text(
            _thickness == null
                ? 'Enter a thickness greater than 0'
                : faceCount == 0
                    ? 'Tap one or more faces of the same body to open'
                    : 'Opening $faceCount ${faceCount == 1 ? 'face' : 'faces'}',
            style: TextStyle(
              color: _canConfirm
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
