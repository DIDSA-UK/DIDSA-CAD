import 'package:flutter/material.dart';

import 'resizable_tool_panel.dart';
import 'svg_icon.dart';

/// The "boss" or "cut" choice for an Extrude - mirrors the backend's
/// `extrude_type` string values exactly, so call sites can pass
/// [ExtrudeType.apiValue] straight into [DocumentApiClient] without a
/// separate mapping table.
enum ExtrudeType {
  boss,
  cut;

  String get apiValue => name;

  static ExtrudeType fromApiValue(String value) => ExtrudeType.values
      .firstWhere((t) => t.apiValue == value, orElse: () => ExtrudeType.boss);
}

/// On-device feedback ("add option to thicken in, out or from the
/// middle"): which side of the sketched wire a thin extrude's wall grows
/// on - mirrors the backend's `thickness_direction` string values exactly,
/// same `apiValue`/`fromApiValue` convention as [ExtrudeType].
enum ThicknessDirection {
  outward,
  inward,
  symmetric;

  String get apiValue => name;

  static ThicknessDirection fromApiValue(String value) => ThicknessDirection.values
      .firstWhere((d) => d.apiValue == value, orElse: () => ThicknessDirection.outward);
}

/// The bottom-sheet-style panel [PartScreen] opens via the long-press
/// "Extrude" context-menu action. Slides up from the bottom (same
/// [AnimatedSlide] pattern [FeatureTreePanel]/[PartToolbar] use for their own
/// slide-in, just along the opposite axis) rather than using
/// `showModalBottomSheet`, since a modal route would have to be popped and
/// re-pushed on every keystroke to keep the live mesh preview underneath it
/// visible and interactive.
///
/// Purely a form: every value change is reported immediately via
/// [onChanged] - debouncing the resulting PATCH/POST and mesh refresh is
/// [PartScreen]'s job, not this widget's, so this stays a dumb, easily
/// tested input panel.
class ExtrudePanel extends StatefulWidget {
  /// B4: 'Extrude' when creating a brand-new Feature (default, unchanged
  /// from before this prompt), 'Edit Extrude' when [PartScreen] opened this
  /// to edit an already-existing one instead - purely a label, doesn't
  /// affect any other behaviour of this panel.
  final String title;

  /// On-device feedback ("the tooltip at the top of the screen blocks the
  /// FABs"): the target-body-picking banner text - see
  /// [ResizableToolPanel]'s own doc comment for why this now lives in the
  /// title row instead of a separate floating banner. Null once nothing
  /// about that step needs saying.
  final String? tooltip;

  final ExtrudeType initialType;
  final double initialStartDistance;
  final double initialEndDistance;

  /// Thin extrude: `null` (default) is the ordinary solid extrude,
  /// unchanged. Set (and nonzero), the profile is prismed as a thin wall of
  /// this signed thickness instead - see the backend `ExtrudeFeature.
  /// thickness`'s own doc comment for the sign convention (which side of
  /// the wall gets material).
  final double? initialThickness;

  /// Which side of the sketched wire the thin wall grows on - meaningful
  /// only when [initialThickness] is set. Defaults to `outward`, matching
  /// the backend's own default (and this feature's pre-existing behavior
  /// for a positive thickness, before this field existed).
  final ThicknessDirection initialThicknessDirection;

  /// Prompt A4: how many target bodies are currently picked in the 3D
  /// viewport (see [PartScreen]'s body-picking flow, driven independently
  /// of this panel's own fields) - read live on every build, unlike
  /// [initialType]/[initialStartDistance]/[initialEndDistance], which this
  /// widget only consults once to seed its own editable local state.
  /// Drives Cut's "requires 1+" rule below.
  final int targetBodyCount;

  final void Function(ExtrudeType type, double startDistance,
      double endDistance, double? thickness, ThicknessDirection thicknessDirection) onChanged;
  final VoidCallback onConfirm;
  final VoidCallback onCancel;

  const ExtrudePanel({
    super.key,
    this.title = 'Extrude',
    this.tooltip,
    this.initialType = ExtrudeType.boss,
    this.initialStartDistance = 0.0,
    this.initialEndDistance = 10.0,
    this.initialThickness,
    this.initialThicknessDirection = ThicknessDirection.outward,
    required this.targetBodyCount,
    required this.onChanged,
    required this.onConfirm,
    required this.onCancel,
  });

  @override
  State<ExtrudePanel> createState() => _ExtrudePanelState();
}

class _ExtrudePanelState extends State<ExtrudePanel> {
  late ExtrudeType _type;
  late final TextEditingController _startController;
  late final TextEditingController _endController;
  late bool _isThin;
  late final TextEditingController _thicknessController;
  late ThicknessDirection _thicknessDirection;

  /// The depth implied by the current start/end fields - `null` once they
  /// no longer parse as numbers, so [build] can fall back to not showing a
  /// value rather than a stale one. Mirrors the backend's own validation
  /// (end_distance must exceed start_distance - see
  /// app.document.router._validate_extrude_distances) so the user sees why
  /// a Confirm/preview update would be rejected before they even try it,
  /// rather than only finding out from a rejected request.
  double? _depth;

  @override
  void initState() {
    super.initState();
    _type = widget.initialType;
    _startController = TextEditingController(
        text: _formatDistance(widget.initialStartDistance));
    _endController =
        TextEditingController(text: _formatDistance(widget.initialEndDistance));
    _depth = widget.initialEndDistance - widget.initialStartDistance;
    _isThin = widget.initialThickness != null;
    _thicknessController = TextEditingController(
        text: widget.initialThickness == null ? '' : _formatDistance(widget.initialThickness!));
    _thicknessDirection = widget.initialThicknessDirection;
    // Without this, the live preview underneath this panel doesn't appear
    // until the user actually edits a field - onChanged was only ever wired
    // to the TextField/SegmentedButton callbacks, never fired for the
    // initial values this panel opens with.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        widget.onChanged(_type, widget.initialStartDistance, widget.initialEndDistance,
            widget.initialThickness, _thicknessDirection);
      }
    });
  }

  @override
  void dispose() {
    _startController.dispose();
    _endController.dispose();
    _thicknessController.dispose();
    super.dispose();
  }

  static String _formatDistance(double value) => value == value.roundToDouble()
      ? value.toStringAsFixed(0)
      : value.toString();

  /// Confirm is disabled for an invalid depth (pre-existing rule) or, new in
  /// Prompt A4, for a Cut with nothing picked yet - Boss has no such
  /// requirement, 0 selected is exactly how a Boss starts a brand-new Body.
  /// The current thin-wall thickness, or `null` when [_isThin] is off or
  /// the field doesn't parse as a nonzero number yet.
  double? get _thickness {
    if (!_isThin) return null;
    final value = double.tryParse(_thicknessController.text);
    return (value == null || value == 0) ? null : value;
  }

  bool get _canConfirm =>
      _depth != null &&
      _depth! > 0 &&
      !(_type == ExtrudeType.cut && widget.targetBodyCount == 0) &&
      (!_isThin || _thickness != null);

  void _emitChange() {
    final start = double.tryParse(_startController.text);
    final end = double.tryParse(_endController.text);
    setState(
        () => _depth = (start != null && end != null) ? end - start : null);
    if (start == null || end == null) return;
    widget.onChanged(_type, start, end, _thickness, _thicknessDirection);
  }

  void _onTypeChanged(ExtrudeType type) {
    setState(() => _type = type);
    _emitChange();
  }

  void _onThinToggled(bool value) {
    setState(() => _isThin = value);
    _emitChange();
  }

  void _onDirectionChanged(ThicknessDirection direction) {
    setState(() => _thicknessDirection = direction);
    _emitChange();
  }

  /// On-device feedback ("add flip button to extrude to reverse
  /// direction"): `start_distance`/`end_distance` are already signed
  /// offsets from the sketch plane (see [ExtrudePanel.initialStartDistance]'s
  /// own doc comment), so reversing the extrude's direction is just
  /// negating both and swapping which is "start" vs "end" - a plain
  /// per-field negate would leave `end <= start` whenever the span doesn't
  /// straddle zero symmetrically, tripping the same depth validation
  /// [_canConfirm]/the backend both enforce; swapping first keeps
  /// `end > start` automatically (it held before negation, so it still
  /// holds after negating and swapping the pair).
  void _flipDirection() {
    final start = double.tryParse(_startController.text);
    final end = double.tryParse(_endController.text);
    if (start == null || end == null) return;
    _startController.text = _formatDistance(-end);
    _endController.text = _formatDistance(-start);
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
          Row(
            children: [
              Expanded(
                child: SegmentedButton<ExtrudeType>(
                  segments: const [
                    ButtonSegment(
                      value: ExtrudeType.boss,
                      label: Text('Boss'),
                      icon: SvgIcon('assets/icons/feature/feature_boss.svg'),
                    ),
                    ButtonSegment(
                      value: ExtrudeType.cut,
                      label: Text('Cut'),
                      icon: SvgIcon('assets/icons/feature/feature_cut.svg'),
                    ),
                  ],
                  selected: {_type},
                  onSelectionChanged: (selection) => _onTypeChanged(selection.first),
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
          const SizedBox(height: 4),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            title: const Text('Thin extrude'),
            value: _isThin,
            onChanged: (value) => _onThinToggled(value ?? false),
          ),
          if (_isThin) ...[
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: TextField(
                controller: _thicknessController,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true, signed: true),
                decoration: const InputDecoration(labelText: 'Wall thickness'),
                onChanged: (_) => _emitChange(),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: SegmentedButton<ThicknessDirection>(
                segments: const [
                  ButtonSegment(value: ThicknessDirection.outward, label: Text('Out')),
                  ButtonSegment(value: ThicknessDirection.inward, label: Text('In')),
                  ButtonSegment(value: ThicknessDirection.symmetric, label: Text('Middle')),
                ],
                selected: {_thicknessDirection},
                onSelectionChanged: (selection) => _onDirectionChanged(selection.first),
              ),
            ),
          ],
          // Prompt A4: Cut requires 1+ target bodies (Boss doesn't -
          // zero is a valid "start a new body" pick) - picking itself
          // happens in the 3D viewport behind this panel, driven by
          // [PartScreen], not by any field in here.
          if (_type == ExtrudeType.cut)
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
