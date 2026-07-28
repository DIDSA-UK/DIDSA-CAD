import 'package:flutter/material.dart';

/// Pattern/Mirror scoping's Phase 4 (`docs/pattern-mirror-scope.md`
/// §2.3/§4): Rectangular or Circular - mirrors [RevolveMode]'s own
/// `apiValue`/`fromApiValue` str-enum convention, matching the backend's
/// `PatternType` string values exactly.
enum PatternMode {
  rectangular,
  circular;

  String get apiValue => name;

  static PatternMode fromApiValue(String value) =>
      PatternMode.values.firstWhere((m) => m.apiValue == value, orElse: () => PatternMode.rectangular);
}

/// Pattern/Mirror scoping's Phase 2/4 (`docs/pattern-mirror-scope.md`
/// §2.2/§2.3/§4): the bottom-sheet-style panel [PartScreen] opens once a
/// single Body is picked for a Pattern - mirrors [FilletPanel]/
/// [RevolvePanel]'s Confirm/Cancel session shape and slide-up presentation.
///
/// [mode] picks between two entirely different field groups, mirroring
/// [RevolvePanel]'s own Boss/Cut `SegmentedButton` toggle:
/// - **Rectangular**: two independent, near-identical "direction" sections
///   (Direction 1 always required, Direction 2 optional, for a 2D grid).
///   A direction is picked by tapping a straight Body edge or a Sketch
///   Line in the viewport (driven by [PartScreen], mirroring
///   [RevolvePanel]'s own "picking happens behind this panel, hasAxis just
///   reports status" shape - a Sketch Line pick reuses the same live-tap
///   mechanism [RevolvePanel]'s own axis pick already uses, rather than a
///   separate dedicated Sketch-picker flow), or by tapping one of this
///   panel's own X/Y/Z buttons for a fixed world axis.
/// - **Circular**: one axis (a circular or straight Body edge, a
///   cylindrical Body face, or a Sketch Line, all tapped live in the
///   viewport - unlike Direction 1/2, there is no fixed-world-axis button
///   alternative, since a Circular Pattern needs a real pivot point a bare
///   world axis direction alone can't supply), `countAngular` instances
///   spread across `angleTotal` degrees, plus a reverse toggle.
///
/// [canChangeMode] is false while editing an *existing* PatternFeature
/// (`title` starts with `'Edit'`) - the backend never revises `pattern_type`
/// on update (see `PatternFeatureUpdate`'s own docstring: switching
/// Rectangular <-> Circular is a delete+recreate, not an edit), so the mode
/// toggle itself is hidden rather than offered and then rejected.
///
/// Because Direction 1 and Direction 2 can each independently come from an
/// edge tap, [activeDirectionSlot] (set by [PartScreen], changed here via
/// [onActiveDirectionSlotChanged]) says which of the two a viewport edge tap
/// currently fills - shown as a simple two-chip toggle once Direction 2 is
/// enabled (Direction 1 is the only possible target beforehand). Circular's
/// own single axis pick never needs this - only one thing can ever be live.
class PatternPanel extends StatefulWidget {
  /// 'Pattern' when creating a brand-new Feature (default), 'Edit Pattern'
  /// when [PartScreen] opened this to edit an already-existing one instead -
  /// purely a label, same convention as [FilletPanel.title].
  final String title;

  final PatternMode mode;
  final bool canChangeMode;
  final void Function(PatternMode mode) onModeChanged;

  /// Whether Direction 1 has been picked yet (an edge/Sketch-Line tap or
  /// an X/Y/Z button) - mirrors [RevolvePanel.hasAxis]'s live-read-every-
  /// build convention. Confirm is disabled until this is true (Rectangular
  /// mode only).
  final bool hasDirection1;

  /// A short human-readable summary of Direction 1's current pick - e.g.
  /// "Edge selected", "Sketch Line selected", or "X axis" - or null when
  /// nothing is picked yet.
  final String? direction1Summary;

  final void Function(String axis) onSetDirection1FixedAxis;

  final int initialCount1;
  final double initialSpacing1;
  final bool reverse1;
  final void Function(int count)? onCount1Changed;
  final void Function(double spacing)? onSpacing1Changed;
  final void Function(bool reverse)? onReverse1Changed;

  /// Whether the optional second direction (a 2D grid pattern) is currently
  /// enabled - toggled via [onSecondDirectionToggled]. When false, every
  /// Direction-2-related field below is hidden entirely.
  final bool hasSecondDirection;
  final void Function(bool enabled) onSecondDirectionToggled;

  final bool hasDirection2;
  final String? direction2Summary;
  final void Function(String axis) onSetDirection2FixedAxis;
  final int initialCount2;
  final double initialSpacing2;
  final bool reverse2;
  final void Function(int count)? onCount2Changed;
  final void Function(double spacing)? onSpacing2Changed;
  final void Function(bool reverse)? onReverse2Changed;

  /// Which direction slot (`1` or `2`) the next viewport edge tap fills -
  /// see this class's own doc comment. Only ever shown/changeable once
  /// [hasSecondDirection] is true; always effectively `1` otherwise.
  final int activeDirectionSlot;
  final void Function(int slot) onActiveDirectionSlotChanged;

  /// Whether the Circular axis has been picked yet (an edge, cylindrical-
  /// face, or Sketch-Line tap in the viewport - see this class's own doc
  /// comment for why there is no fixed-axis button alternative here).
  /// Confirm is disabled until this is true (Circular mode only).
  final bool hasAxis;

  /// A short human-readable summary of the axis's current pick - e.g.
  /// "Edge selected", "Cylindrical face selected", or "Sketch Line
  /// selected" - or null when nothing is picked yet.
  final String? axisSummary;

  final int initialCountAngular;
  final double initialAngleTotal;
  final bool reverseAngular;
  final void Function(int count)? onCountAngularChanged;
  final void Function(double angle)? onAngleTotalChanged;
  final void Function(bool reverse)? onReverseAngularChanged;

  final VoidCallback onConfirm;
  final VoidCallback onCancel;

  const PatternPanel({
    super.key,
    this.title = 'Pattern',
    required this.mode,
    required this.canChangeMode,
    required this.onModeChanged,
    required this.hasDirection1,
    this.direction1Summary,
    required this.onSetDirection1FixedAxis,
    required this.initialCount1,
    required this.initialSpacing1,
    required this.reverse1,
    this.onCount1Changed,
    this.onSpacing1Changed,
    this.onReverse1Changed,
    required this.hasSecondDirection,
    required this.onSecondDirectionToggled,
    required this.hasDirection2,
    this.direction2Summary,
    required this.onSetDirection2FixedAxis,
    required this.initialCount2,
    required this.initialSpacing2,
    required this.reverse2,
    this.onCount2Changed,
    this.onSpacing2Changed,
    this.onReverse2Changed,
    required this.activeDirectionSlot,
    required this.onActiveDirectionSlotChanged,
    required this.hasAxis,
    this.axisSummary,
    required this.initialCountAngular,
    required this.initialAngleTotal,
    required this.reverseAngular,
    this.onCountAngularChanged,
    this.onAngleTotalChanged,
    this.onReverseAngularChanged,
    required this.onConfirm,
    required this.onCancel,
  });

  @override
  State<PatternPanel> createState() => _PatternPanelState();
}

class _PatternPanelState extends State<PatternPanel> {
  late final TextEditingController _count1Controller;
  late final TextEditingController _spacing1Controller;
  late final TextEditingController _count2Controller;
  late final TextEditingController _spacing2Controller;
  late final TextEditingController _countAngularController;
  late final TextEditingController _angleTotalController;

  int? _count1;
  double? _spacing1;
  int? _count2;
  double? _spacing2;
  int? _countAngular;
  double? _angleTotal;

  @override
  void initState() {
    super.initState();
    _count1 = widget.initialCount1 >= 1 ? widget.initialCount1 : null;
    _spacing1 = widget.initialSpacing1 > 0 ? widget.initialSpacing1 : null;
    _count2 = widget.initialCount2 >= 1 ? widget.initialCount2 : null;
    _spacing2 = widget.initialSpacing2 > 0 ? widget.initialSpacing2 : null;
    _countAngular = widget.initialCountAngular >= 1 ? widget.initialCountAngular : null;
    _angleTotal =
        (widget.initialAngleTotal > 0 && widget.initialAngleTotal <= 360) ? widget.initialAngleTotal : null;
    _count1Controller = TextEditingController(text: widget.initialCount1.toString());
    _spacing1Controller = TextEditingController(text: _formatNumber(widget.initialSpacing1));
    _count2Controller = TextEditingController(text: widget.initialCount2.toString());
    _spacing2Controller = TextEditingController(text: _formatNumber(widget.initialSpacing2));
    _countAngularController = TextEditingController(text: widget.initialCountAngular.toString());
    _angleTotalController = TextEditingController(text: _formatNumber(widget.initialAngleTotal));
    // Mirrors FilletPanel/RevolvePanel's identical fix: without this, the
    // live preview underneath this panel doesn't appear until the user
    // actually edits a field, since onXChanged is only ever wired to field
    // edits, never fired for the initial values this panel opens with.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_count1 != null) widget.onCount1Changed?.call(_count1!);
      if (_spacing1 != null) widget.onSpacing1Changed?.call(_spacing1!);
      if (_countAngular != null) widget.onCountAngularChanged?.call(_countAngular!);
      if (_angleTotal != null) widget.onAngleTotalChanged?.call(_angleTotal!);
    });
  }

  @override
  void dispose() {
    _count1Controller.dispose();
    _spacing1Controller.dispose();
    _count2Controller.dispose();
    _spacing2Controller.dispose();
    _countAngularController.dispose();
    _angleTotalController.dispose();
    super.dispose();
  }

  static String _formatNumber(double value) =>
      value == value.roundToDouble() ? value.toStringAsFixed(0) : value.toString();

  bool get _canConfirm {
    if (widget.mode == PatternMode.circular) {
      return widget.hasAxis && _countAngular != null && _countAngular! >= 2 && _angleTotal != null;
    }
    if (!widget.hasDirection1 || _count1 == null || _spacing1 == null) return false;
    if (widget.hasSecondDirection) {
      if (!widget.hasDirection2 || _count2 == null || _spacing2 == null) return false;
    }
    final count2 = widget.hasSecondDirection ? (_count2 ?? 1) : 1;
    return (_count1! * count2) >= 2;
  }

  void _emitCount1() {
    final value = int.tryParse(_count1Controller.text);
    final count = (value != null && value >= 1) ? value : null;
    setState(() => _count1 = count);
    if (count != null) widget.onCount1Changed?.call(count);
  }

  void _emitSpacing1() {
    final value = double.tryParse(_spacing1Controller.text);
    final spacing = (value != null && value > 0) ? value : null;
    setState(() => _spacing1 = spacing);
    if (spacing != null) widget.onSpacing1Changed?.call(spacing);
  }

  void _emitCount2() {
    final value = int.tryParse(_count2Controller.text);
    final count = (value != null && value >= 1) ? value : null;
    setState(() => _count2 = count);
    if (count != null) widget.onCount2Changed?.call(count);
  }

  void _emitSpacing2() {
    final value = double.tryParse(_spacing2Controller.text);
    final spacing = (value != null && value > 0) ? value : null;
    setState(() => _spacing2 = spacing);
    if (spacing != null) widget.onSpacing2Changed?.call(spacing);
  }

  void _emitCountAngular() {
    final value = int.tryParse(_countAngularController.text);
    final count = (value != null && value >= 1) ? value : null;
    setState(() => _countAngular = count);
    if (count != null) widget.onCountAngularChanged?.call(count);
  }

  void _emitAngleTotal() {
    final value = double.tryParse(_angleTotalController.text);
    final angle = (value != null && value > 0 && value <= 360) ? value : null;
    setState(() => _angleTotal = angle);
    if (angle != null) widget.onAngleTotalChanged?.call(angle);
  }

  Widget _axisButton(String axis, void Function(String) onSetFixedAxis) => OutlinedButton(
        onPressed: () => onSetFixedAxis(axis),
        style: OutlinedButton.styleFrom(minimumSize: const Size(40, 36), padding: EdgeInsets.zero),
        child: Text(axis.toUpperCase()),
      );

  Widget _directionSection({
    required String label,
    required bool hasDirection,
    required String? summary,
    required void Function(String) onSetFixedAxis,
    required TextEditingController countController,
    required TextEditingController spacingController,
    required bool reverse,
    required void Function() onEmitCount,
    required void Function() onEmitSpacing,
    required void Function(bool)? onReverseChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(label, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(
              child: Text(
                hasDirection
                    ? (summary ?? 'Direction selected')
                    : 'Tap an edge or Sketch Line, or pick a fixed axis',
                style: TextStyle(
                  color: hasDirection
                      ? Theme.of(context).colorScheme.onSurfaceVariant
                      : Theme.of(context).colorScheme.error,
                  fontSize: 12,
                ),
              ),
            ),
            _axisButton('x', onSetFixedAxis),
            const SizedBox(width: 4),
            _axisButton('y', onSetFixedAxis),
            const SizedBox(width: 4),
            _axisButton('z', onSetFixedAxis),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: countController,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Count'),
                onChanged: (_) => onEmitCount(),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: spacingController,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: 'Spacing'),
                onChanged: (_) => onEmitSpacing(),
              ),
            ),
            const SizedBox(width: 4),
            IconButton(
              tooltip: 'Reverse direction',
              isSelected: reverse,
              onPressed: onReverseChanged == null ? null : () => onReverseChanged(!reverse),
              icon: const Icon(Icons.flip),
            ),
          ],
        ),
      ],
    );
  }

  Widget _rectangularFields() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.hasSecondDirection)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: SegmentedButton<int>(
              segments: const [
                ButtonSegment(value: 1, label: Text('Direction 1')),
                ButtonSegment(value: 2, label: Text('Direction 2')),
              ],
              selected: {widget.activeDirectionSlot},
              onSelectionChanged: (selection) => widget.onActiveDirectionSlotChanged(selection.first),
            ),
          ),
        _directionSection(
          label: 'Direction 1',
          hasDirection: widget.hasDirection1,
          summary: widget.direction1Summary,
          onSetFixedAxis: widget.onSetDirection1FixedAxis,
          countController: _count1Controller,
          spacingController: _spacing1Controller,
          reverse: widget.reverse1,
          onEmitCount: _emitCount1,
          onEmitSpacing: _emitSpacing1,
          onReverseChanged: widget.onReverse1Changed,
        ),
        const SizedBox(height: 12),
        if (widget.hasSecondDirection) ...[
          _directionSection(
            label: 'Direction 2',
            hasDirection: widget.hasDirection2,
            summary: widget.direction2Summary,
            onSetFixedAxis: widget.onSetDirection2FixedAxis,
            countController: _count2Controller,
            spacingController: _spacing2Controller,
            reverse: widget.reverse2,
            onEmitCount: _emitCount2,
            onEmitSpacing: _emitSpacing2,
            onReverseChanged: widget.onReverse2Changed,
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => widget.onSecondDirectionToggled(false),
              icon: const Icon(Icons.remove_circle_outline),
              label: const Text('Remove second direction'),
            ),
          ),
        ] else
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => widget.onSecondDirectionToggled(true),
              icon: const Icon(Icons.add),
              label: const Text('Add second direction'),
            ),
          ),
      ],
    );
  }

  Widget _circularFields() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Axis', style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
        const SizedBox(height: 6),
        Text(
          widget.hasAxis
              ? (widget.axisSummary ?? 'Axis selected')
              : 'Tap an edge, a cylindrical face, or a Sketch Line for the axis',
          style: TextStyle(
            color: widget.hasAxis
                ? Theme.of(context).colorScheme.onSurfaceVariant
                : Theme.of(context).colorScheme.error,
            fontSize: 12,
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _countAngularController,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Count'),
                onChanged: (_) => _emitCountAngular(),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: _angleTotalController,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: 'Angle (degrees)'),
                onChanged: (_) => _emitAngleTotal(),
              ),
            ),
            const SizedBox(width: 4),
            IconButton(
              tooltip: 'Reverse direction',
              isSelected: widget.reverseAngular,
              onPressed: widget.onReverseAngularChanged == null
                  ? null
                  : () => widget.onReverseAngularChanged!(!widget.reverseAngular),
              icon: const Icon(Icons.flip),
            ),
          ],
        ),
      ],
    );
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
          child: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(widget.title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                  const SizedBox(height: 12),
                  if (widget.canChangeMode)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: SegmentedButton<PatternMode>(
                        segments: const [
                          ButtonSegment(value: PatternMode.rectangular, label: Text('Rectangular')),
                          ButtonSegment(value: PatternMode.circular, label: Text('Circular')),
                        ],
                        selected: {widget.mode},
                        onSelectionChanged: (selection) => widget.onModeChanged(selection.first),
                      ),
                    ),
                  if (widget.mode == PatternMode.circular) _circularFields() else _rectangularFields(),
                  const SizedBox(height: 8),
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
      ),
    );
  }
}
