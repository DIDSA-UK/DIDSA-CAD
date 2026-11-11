import 'package:material_ui/material_ui.dart';

import 'resizable_tool_panel.dart';
import 'svg_icon.dart';
import 'keyboard_shortcuts.dart';
import 'thin_wall_controls.dart';

export 'thin_wall_controls.dart' show ThicknessDirection;

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

  static RevolveMode fromApiValue(String value) => RevolveMode.values
      .firstWhere((m) => m.apiValue == value, orElse: () => RevolveMode.boss);
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

  /// On-device feedback ("the tooltip at the top of the screen blocks the
  /// FABs"): see [ResizableToolPanel]'s own doc comment - the axis/target-
  /// body-picking banner text, now shown in the title row instead of a
  /// separate floating banner.
  final String? tooltip;

  final RevolveMode initialMode;
  final double initialAngle;

  /// Thin revolve (Flutter-testing feedback 2026-11-11, item 5): the stored wall thickness when editing a thin Revolve (null: a
  /// solid one), and its direction.
  final double? initialThickness;
  final ThicknessDirection initialThicknessDirection;

  /// The Sketch has no closed profile but a single open chain (a cup, bowl or bell wall): it can only be revolved as a thin wall, so
  /// Thin is on and locked, with a hint, and the direction reads against the axis ("Away from axis / Toward axis / Both sides").
  final bool openProfile;

  /// Whether an axis Line is currently picked in the viewport (see
  /// [PartScreen]'s own axis-picking selection filter) - read live on every
  /// build, same as [ExtrudePanel.targetBodyCount] reads live rather than
  /// being seeded once. Drives both the status line and Confirm-enablement.
  final bool hasAxis;

  /// How many target bodies are currently picked in the 3D viewport - same
  /// meaning and same live-read convention as [ExtrudePanel.targetBodyCount].
  /// Drives Cut's "requires 1+" rule below.
  final int targetBodyCount;

  /// [thickness] is null for a solid revolve; [thicknessDirection] only matters when it is set.
  final void Function(RevolveMode mode, double angle, double? thickness, ThicknessDirection thicknessDirection) onChanged;
  final VoidCallback onConfirm;
  final VoidCallback onCancel;

  const RevolvePanel({
    super.key,
    this.title = 'Revolve',
    this.tooltip,
    this.initialMode = RevolveMode.boss,
    this.initialAngle = 180.0,
    this.initialThickness,
    this.initialThicknessDirection = ThicknessDirection.outward,
    this.openProfile = false,
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
  late final TextEditingController _thicknessController;
  late bool _isThin;
  late ThicknessDirection _thicknessDirection;

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
    _angleController =
        TextEditingController(text: _formatAngle(widget.initialAngle));
    _angle = (widget.initialAngle > 0 && widget.initialAngle <= 360)
        ? widget.initialAngle
        : null;
    _isThin = widget.openProfile || widget.initialThickness != null;
    _thicknessDirection = widget.initialThicknessDirection;
    _thicknessController = TextEditingController(text: _formatAngle(widget.initialThickness ?? 2.0));
    // Without this, the live preview underneath this panel doesn't appear
    // until the user actually edits the angle field or mode - onChanged was
    // only ever wired to those callbacks, never fired for the initial value
    // this panel opens with (mirrors ExtrudePanel's identical fix).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _angle != null && (!_isThin || _thickness != null)) widget.onChanged(_mode, _angle!, _thickness, _thicknessDirection);
    });
  }

  @override
  void dispose() {
    _angleController.dispose();
    _thicknessController.dispose();
    super.dispose();
  }

  static String _formatAngle(double value) => value == value.roundToDouble()
      ? value.toStringAsFixed(0)
      : value.toString();

  /// Confirm is disabled for an invalid angle, for no axis picked yet, or
  /// (mirrors [ExtrudePanel]'s own Cut rule) for a Cut with nothing picked
  /// yet - Boss has no target-body requirement, 0 selected is exactly how a
  /// Boss starts a brand-new Body.
  /// The wall thickness while Thin is on (an open profile is always thin), or null when it is off or does not parse as a number > 0.
  double? get _thickness {
    if (!_isThin) return null;
    final value = double.tryParse(_thicknessController.text);
    return (value == null || value <= 0) ? null : value;
  }

  bool get _canConfirm =>
      _angle != null &&
      (!_isThin || _thickness != null) &&
      widget.hasAxis &&
      !(_mode == RevolveMode.cut && widget.targetBodyCount == 0);

  void _emitChange() {
    final value = double.tryParse(_angleController.text);
    final angle = (value != null && value > 0 && value <= 360) ? value : null;
    setState(() => _angle = angle);
    // While Thin is on with an invalid thickness, no preview update is sent (Confirm is disabled): it would silently turn solid.
    if (angle != null && (!_isThin || _thickness != null)) widget.onChanged(_mode, angle, _thickness, _thicknessDirection);
  }

  void _onModeChanged(RevolveMode mode) {
    setState(() => _mode = mode);
    _emitChange();
  }

  void _onThinToggled(bool value) {
    setState(() => _isThin = value);
    _emitChange();
  }

  void _onThicknessDirectionChanged(ThicknessDirection direction) {
    setState(() => _thicknessDirection = direction);
    _emitChange();
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
          SegmentedButton<RevolveMode>(
            segments: const [
              ButtonSegment(
                value: RevolveMode.boss,
                label: Text('Boss'),
                icon: SvgIcon('assets/icons/feature/feature_boss.svg'),
              ),
              ButtonSegment(
                value: RevolveMode.cut,
                label: Text('Cut'),
                icon: SvgIcon('assets/icons/feature/feature_cut.svg'),
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
          ThinWallControls(
            title: 'Thin wall',
            isThin: _isThin,
            onThinChanged: _onThinToggled,
            locked: widget.openProfile,
            lockedHint: 'An open profile revolves as a thin wall',
            openProfile: widget.openProfile,
            controller: _thicknessController,
            direction: _thicknessDirection,
            onDirectionChanged: _onThicknessDirectionChanged,
            onChanged: _emitChange,
          ),
          if (_isThin && !widget.openProfile)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                'Holes in the profile are not thinned.',
                style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 12),
              ),
            ),
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
            widget.hasAxis
                ? 'Axis: selected'
                : 'Select an axis line in the viewport',
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
              ToolPanelKeys(onConfirm: _canConfirm ? widget.onConfirm : null, onCancel: widget.onCancel),
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
