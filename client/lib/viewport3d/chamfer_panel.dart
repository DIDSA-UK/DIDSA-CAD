import 'package:flutter/material.dart';

import 'resizable_tool_panel.dart';

/// Prompt E: the bottom-sheet-style panel [PartScreen] opens once Chamfer is
/// enabled (one or more edges selected, all on the same Body - see
/// `selection_actions.dart`'s `contextActionsFor`) - structurally identical
/// to [FilletPanel], substituting a distance field for the radius field
/// (Chamfer has only the one construction method too, same as Fillet, so
/// there is no per-mode branching to do here either).
///
/// Feature 3: an "Angle" checkbox (mirroring [ExtrudePanel]'s thin-wall
/// gating) reveals an Angle field and a Flip toggle - a distance-angle
/// chamfer, distance measured along the reference face and angle from it;
/// Flip swaps which of each edge's two adjacent faces is the reference.
/// v1 applies one angle/flip uniformly to every selected edge.
class ChamferPanel extends StatefulWidget {
  /// 'Chamfer' when creating a brand-new Feature (default), 'Edit Chamfer'
  /// when [PartScreen] opened this to edit an already-existing one instead -
  /// purely a label, same convention as [FilletPanel.title].
  final String title;

  /// On-device feedback ("the tooltip at the top of the screen blocks the
  /// FABs"): see [ResizableToolPanel]'s own doc comment - the guided-entry
  /// "select edges (or a face)" banner text, now shown in the title row
  /// instead of a separate floating banner. Null once at least one edge is
  /// picked (this panel's own fields already guide the user from there).
  final String? tooltip;

  final double initialDistance;

  /// Feature 3 (Chamfer angle + flip): the angle (degrees) this panel opens
  /// with - null opens with the Angle toggle off (a plain symmetric
  /// distance chamfer, the pre-Feature-3 behaviour).
  final double? initialAngle;

  /// Feature 3: whether the Flip toggle opens already on.
  final bool initialFlip;

  /// Fired on every valid distance edit - same live-preview-drives-a-
  /// debounced-PATCH pattern [FilletPanel.onRadiusChanged] already uses.
  final void Function(double distance)? onDistanceChanged;

  /// Feature 3: fired whenever the Angle toggle, Angle field or Flip toggle
  /// changes to a *valid* state - `angle` is null when the Angle toggle is
  /// off (symmetric chamfer), otherwise a value strictly inside (0, 180)
  /// degrees (the backend's `_validate_chamfer_edge_options` range). Not
  /// fired while the Angle field holds an invalid value (Confirm is
  /// disabled instead). In v1 [PartScreen] applies the result uniformly to
  /// every selected edge.
  final void Function(double? angle, bool flip)? onAngleChanged;

  final VoidCallback onConfirm;
  final VoidCallback onCancel;

  const ChamferPanel({
    super.key,
    this.title = 'Chamfer',
    this.tooltip,
    required this.initialDistance,
    this.initialAngle,
    this.initialFlip = false,
    this.onDistanceChanged,
    this.onAngleChanged,
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

  /// Feature 3: whether the Angle toggle is on - mirrors [ExtrudePanel]'s
  /// `_isThin` gating (a checkbox that reveals extra fields).
  late bool _useAngle;
  late final TextEditingController _angleController;
  late bool _flip;

  static const double _defaultAngle = 45;

  @override
  void initState() {
    super.initState();
    _distanceController =
        TextEditingController(text: _formatDistance(widget.initialDistance));
    _distance = widget.initialDistance > 0 ? widget.initialDistance : null;
    _useAngle = widget.initialAngle != null;
    _angleController =
        TextEditingController(text: _formatDistance(widget.initialAngle ?? _defaultAngle));
    _flip = widget.initialFlip;
    // Without this, the live preview underneath this panel doesn't appear
    // until the user actually edits the distance field - onDistanceChanged
    // was only ever wired to that callback, never fired for the initial
    // value this panel opens with (mirrors ExtrudePanel's identical fix).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _distance != null) {
        widget.onDistanceChanged?.call(_distance!);
      }
    });
  }

  @override
  void dispose() {
    _distanceController.dispose();
    _angleController.dispose();
    super.dispose();
  }

  static String _formatDistance(double value) => value == value.roundToDouble()
      ? value.toStringAsFixed(0)
      : value.toString();

  /// Feature 3: the Angle field's value when it parses and lies strictly
  /// inside (0, 180) degrees, else null. Only meaningful while [_useAngle].
  double? get _angle {
    final value = double.tryParse(_angleController.text);
    return (value != null && value > 0 && value < 180) ? value : null;
  }

  bool get _canConfirm => _distance != null && (!_useAngle || _angle != null);

  void _emitDistanceChange() {
    final value = double.tryParse(_distanceController.text);
    final distance = (value != null && value > 0) ? value : null;
    setState(() => _distance = distance);
    if (distance != null) widget.onDistanceChanged?.call(distance);
  }

  void _emitAngleChange() {
    setState(() {});
    if (!_useAngle) {
      widget.onAngleChanged?.call(null, _flip);
      return;
    }
    final angle = _angle;
    if (angle != null) widget.onAngleChanged?.call(angle, _flip);
  }

  void _onAngleToggled(bool value) {
    _useAngle = value;
    _emitAngleChange();
  }

  void _onFlipToggled() {
    _flip = !_flip;
    _emitAngleChange();
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
          const SizedBox(height: 4),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            title: const Text('Angle'),
            value: _useAngle,
            onChanged: (value) => _onAngleToggled(value ?? false),
          ),
          if (_useAngle) ...[
            Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const ValueKey('chamfer-angle-field'),
                    controller: _angleController,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(labelText: 'Angle (°)'),
                    onChanged: (_) => _emitAngleChange(),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  key: const ValueKey('chamfer-flip-button'),
                  tooltip: 'Flip reference face',
                  isSelected: _flip,
                  icon: const Icon(Icons.swap_horiz),
                  selectedIcon: const Icon(Icons.swap_horiz),
                  style: IconButton.styleFrom(
                    backgroundColor: _flip ? Theme.of(context).colorScheme.secondaryContainer : null,
                  ),
                  onPressed: _onFlipToggled,
                ),
              ],
            ),
            if (_angle == null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'Enter an angle between 0 and 180',
                  style: TextStyle(color: Theme.of(context).colorScheme.error, fontSize: 12),
                ),
              ),
          ],
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
