import 'package:flutter/material.dart';

/// The "boss" or "cut" choice for a Revolve - Boss/Cut parity with Extrude
/// (Prompt F's own resolved decision) - mirrors `extrude_panel.dart`'s
/// [ExtrudeType] exactly, as its own separate enum rather than a shared one,
/// matching this codebase's "each Feature type owns its own enum" convention
/// (`ExtrudeType`/`RevolveMode` share identical values but are never the same
/// Dart type, same as the backend's `ExtrudeType`/`RevolveMode`).
enum RevolveMode {
  boss,
  cut;

  String get apiValue => name;

  static RevolveMode fromApiValue(String value) =>
      RevolveMode.values.firstWhere((m) => m.apiValue == value, orElse: () => RevolveMode.boss);
}

/// The bottom-sheet-style panel [PartScreen] opens for Revolve - structurally
/// mirrors [ExtrudePanel]'s Boss/Cut toggle + target-body-count session shape
/// exactly, substituting an angle field for start/end distance and adding an
/// axis-Line-picking status line in place of Extrude's profile picking (a
/// Revolve's Profile comes from the Sketch that opened this panel, same as
/// Extrude's does - only the axis is picked live while this panel is open).
///
/// Every value change is reported immediately via [onChanged] - debouncing
/// the resulting PATCH/POST and mesh refresh is [PartScreen]'s job, not this
/// widget's, same as [ExtrudePanel].
class RevolvePanel extends StatefulWidget {
  /// 'Revolve' when creating a brand-new Feature (default), 'Edit Revolve'
  /// when [PartScreen] opened this to edit an already-existing one instead -
  /// purely a label, same convention as [ExtrudePanel.title].
  final String title;

  final RevolveMode initialMode;
  final double initialAngle;

  /// Whether an axis Line is currently picked in the viewport (see
  /// [PartScreen]'s own axis-picking selection filter) - read live on every
  /// build, same as [ExtrudePanel.targetBodyCount] reads live rather than
  /// being seeded once. Drives both the status line and Confirm-enablement.
  final bool hasAxis;

  /// How many target bodies are currently picked in the 3D viewport - same
  /// meaning and same live-read convention as [ExtrudePanel.targetBodyCount].
  /// Drives Cut's "requires 1+" rule below.
  final int targetBodyCount;

  final void Function(RevolveMode mode, double angle) onChanged;
  final VoidCallback onConfirm;
  final VoidCallback onCancel;

  const RevolvePanel({
    super.key,
    this.title = 'Revolve',
    this.initialMode = RevolveMode.boss,
    this.initialAngle = 180.0,
    required this.hasAxis,
    required this.targetBodyCount,
    required this.onChanged,
    required this.onConfirm,
    required this.onCancel,
  });

  @override
  State<RevolvePanel> createState() => _RevolvePanelState();
}

class _RevolvePanelState extends State<RevolvePanel> {
  late RevolveMode _mode;
  late final TextEditingController _angleController;

  /// Null once the angle field no longer parses as a number in `(0, 360]` -
  /// mirrors [ExtrudePanel]'s own `_depth` null-on-invalid-input pattern,
  /// matching the backend's own validation (`_validate_revolve_angle`) so
  /// the user sees why a Confirm/preview update would be rejected before
  /// they even try it.
  double? _angle;

  @override
  void initState() {
    super.initState();
    _mode = widget.initialMode;
    _angleController = TextEditingController(text: _formatAngle(widget.initialAngle));
    _angle = (widget.initialAngle > 0 && widget.initialAngle <= 360) ? widget.initialAngle : null;
    // Without this, the live preview underneath this panel doesn't appear
    // until the user actually edits the angle field or mode - onChanged was
    // only ever wired to those callbacks, never fired for the initial value
    // this panel opens with (mirrors ExtrudePanel's identical fix).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _angle != null) widget.onChanged(_mode, _angle!);
    });
  }

  @override
  void dispose() {
    _angleController.dispose();
    super.dispose();
  }

  static String _formatAngle(double value) =>
      value == value.roundToDouble() ? value.toStringAsFixed(0) : value.toString();

  /// Confirm is disabled for an invalid angle, for no axis picked yet, or
  /// (mirrors [ExtrudePanel]'s own Cut rule) for a Cut with nothing picked
  /// yet - Boss has no target-body requirement, 0 selected is exactly how a
  /// Boss starts a brand-new Body.
  bool get _canConfirm =>
      _angle != null &&
      widget.hasAxis &&
      !(_mode == RevolveMode.cut && widget.targetBodyCount == 0);

  void _emitChange() {
    final value = double.tryParse(_angleController.text);
    final angle = (value != null && value > 0 && value <= 360) ? value : null;
    setState(() => _angle = angle);
    if (angle != null) widget.onChanged(_mode, angle);
  }

  void _onModeChanged(RevolveMode mode) {
    setState(() => _mode = mode);
    if (_angle != null) widget.onChanged(mode, _angle!);
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
                SegmentedButton<RevolveMode>(
                  segments: const [
                    ButtonSegment(value: RevolveMode.boss, label: Text('Boss'), icon: Icon(Icons.add_box)),
                    ButtonSegment(
                      value: RevolveMode.cut,
                      label: Text('Cut'),
                      icon: Icon(Icons.content_cut),
                    ),
                  ],
                  selected: {_mode},
                  onSelectionChanged: (selection) => _onModeChanged(selection.first),
                ),
                const SizedBox(height: 12),
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
                // Mirrors ExtrudePanel's own Cut target-body status line -
                // picking itself happens in the 3D viewport behind this
                // panel, driven by PartScreen, not by any field in here.
                if (_mode == RevolveMode.cut)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      widget.targetBodyCount == 0
                          ? 'Select at least one target body in the viewport'
                          : '${widget.targetBodyCount} target body/bodies selected',
                      style: TextStyle(
                        color: widget.targetBodyCount == 0
                            ? Theme.of(context).colorScheme.error
                            : Theme.of(context).colorScheme.onSurfaceVariant,
                        fontSize: 12,
                      ),
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
