import 'package:flutter/material.dart';

/// Pattern/Mirror scoping's Phase 2 (`docs/pattern-mirror-scope.md`
/// §2.2/§4): the bottom-sheet-style panel [PartScreen] opens once a single
/// Body is picked for a Rectangular Pattern - mirrors [FilletPanel]/
/// [RevolvePanel]'s Confirm/Cancel session shape and slide-up presentation,
/// generalized to two independent, near-identical "direction" sections
/// (Direction 1 always required, Direction 2 optional, for a 2D grid).
///
/// Client v1 scope (deliberate, matching this project's "narrowest correct
/// slice first" convention): a direction is picked either by tapping a
/// straight Body edge in the viewport (driven by [PartScreen], mirroring
/// [RevolvePanel]'s own "picking happens behind this panel, hasAxis just
/// reports status" shape) or by tapping one of this panel's own X/Y/Z
/// buttons for a fixed world axis - Sketch-Line-driven directions are fully
/// supported by the backend (`PatternDirectionRef.sketch_line_ref`) but not
/// yet exposed by this panel, since a Sketch Line usable as a pattern
/// direction isn't guaranteed to already be visible in the viewport the way
/// a Body edge always is (Revolve's own axis-Sketch-Line picker solves this
/// with a dedicated Sketch-picker flow this panel doesn't yet reuse) -
/// tracked as a fast-follow, not silently dropped.
///
/// Because Direction 1 and Direction 2 can each independently come from an
/// edge tap, [activeDirectionSlot] (set by [PartScreen], changed here via
/// [onActiveDirectionSlotChanged]) says which of the two a viewport edge tap
/// currently fills - shown as a simple two-chip toggle once Direction 2 is
/// enabled (Direction 1 is the only possible target beforehand).
class PatternPanel extends StatefulWidget {
  /// 'Pattern' when creating a brand-new Feature (default), 'Edit Pattern'
  /// when [PartScreen] opened this to edit an already-existing one instead -
  /// purely a label, same convention as [FilletPanel.title].
  final String title;

  /// Whether Direction 1 has been picked yet (an edge tap or an X/Y/Z
  /// button) - mirrors [RevolvePanel.hasAxis]'s live-read-every-build
  /// convention. Confirm is disabled until this is true.
  final bool hasDirection1;

  /// A short human-readable summary of Direction 1's current pick - e.g.
  /// "Edge selected" or "X axis" - or null when nothing is picked yet.
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

  final VoidCallback onConfirm;
  final VoidCallback onCancel;

  const PatternPanel({
    super.key,
    this.title = 'Pattern',
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

  int? _count1;
  double? _spacing1;
  int? _count2;
  double? _spacing2;

  @override
  void initState() {
    super.initState();
    _count1 = widget.initialCount1 >= 1 ? widget.initialCount1 : null;
    _spacing1 = widget.initialSpacing1 > 0 ? widget.initialSpacing1 : null;
    _count2 = widget.initialCount2 >= 1 ? widget.initialCount2 : null;
    _spacing2 = widget.initialSpacing2 > 0 ? widget.initialSpacing2 : null;
    _count1Controller = TextEditingController(text: widget.initialCount1.toString());
    _spacing1Controller = TextEditingController(text: _formatDistance(widget.initialSpacing1));
    _count2Controller = TextEditingController(text: widget.initialCount2.toString());
    _spacing2Controller = TextEditingController(text: _formatDistance(widget.initialSpacing2));
    // Mirrors FilletPanel/RevolvePanel's identical fix: without this, the
    // live preview underneath this panel doesn't appear until the user
    // actually edits a field, since onXChanged is only ever wired to field
    // edits, never fired for the initial values this panel opens with.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_count1 != null) widget.onCount1Changed?.call(_count1!);
      if (_spacing1 != null) widget.onSpacing1Changed?.call(_spacing1!);
    });
  }

  @override
  void dispose() {
    _count1Controller.dispose();
    _spacing1Controller.dispose();
    _count2Controller.dispose();
    _spacing2Controller.dispose();
    super.dispose();
  }

  static String _formatDistance(double value) =>
      value == value.roundToDouble() ? value.toStringAsFixed(0) : value.toString();

  bool get _canConfirm {
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
                hasDirection ? (summary ?? 'Direction selected') : 'Tap an edge, or pick a fixed axis',
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
                  if (widget.hasSecondDirection)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: SegmentedButton<int>(
                        segments: const [
                          ButtonSegment(value: 1, label: Text('Direction 1')),
                          ButtonSegment(value: 2, label: Text('Direction 2')),
                        ],
                        selected: {widget.activeDirectionSlot},
                        onSelectionChanged: (selection) =>
                            widget.onActiveDirectionSlotChanged(selection.first),
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
