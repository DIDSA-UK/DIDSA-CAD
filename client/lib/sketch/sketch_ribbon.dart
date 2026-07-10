import 'package:flutter/material.dart';

import 'sketch_controller.dart';

/// The contextual action panel for whatever is currently selected (one or
/// more entities, see [SketchController.selectionSet]), or for the idle
/// canvas itself when nothing is selected - slides in from the left edge
/// whenever a bare tap on the canvas (see
/// [SketchController.handleCanvasTap]) results in a selection, or lands on
/// blank idle-canvas space. A separate concern from [SketchSpeedDial]
/// (which chooses what to draw, not what to act on) - kept as its own
/// widget rather than merged into it.
class SketchRibbon extends StatelessWidget {
  final SketchController controller;

  const SketchRibbon({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        // Only pinned to the top-left corner (not stretched edge-to-edge
        // via top:0/bottom:0) so the panel shrink-wraps to its own content
        // height instead of covering the full canvas height.
        return Align(
          alignment: Alignment.topLeft,
          child: ClipRect(
            child: AnimatedSlide(
              offset: controller.ribbonVisible ? Offset.zero : const Offset(-1.05, 0),
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOut,
              child: SafeArea(
                bottom: false,
                child: Material(
                  elevation: 4,
                  borderRadius: const BorderRadius.only(
                    topRight: Radius.circular(12),
                    bottomRight: Radius.circular(12),
                  ),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minWidth: 220, maxWidth: 320),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _RibbonHeader(text: _heading(), onClose: controller.closeRibbon),
                          _body(context),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  String _heading() {
    final selectionSet = controller.selectionSet;
    if (selectionSet.isEmpty) return 'Sketch';
    if (selectionSet.length > 1) return '${selectionSet.length} selected';
    return switch (selectionSet.first.kind) {
      SelectionKind.point => 'Point selected',
      SelectionKind.line => 'Line selected',
      SelectionKind.circle => 'Circle selected',
      SelectionKind.arc => 'Arc selected',
      SelectionKind.constraint => 'Constraint selected',
    };
  }

  Widget _body(BuildContext context) {
    final selectionSet = controller.selectionSet;
    // Stage 23d: the ribbon can no longer be opened with an empty selection
    // (tapping blank canvas is now a no-op - see
    // SketchController._handleSelectTap), so this is unreachable in
    // practice. Exit Sketch now lives in the hamburger menu (Stage 23f).
    if (selectionSet.isEmpty) {
      return const SizedBox.shrink();
    }

    final blockedReason =
        selectionSet.length == 1 && selectionSet.first.kind == SelectionKind.point
            ? controller.selectedPointDeleteBlockedReason
            : null;
    final isConstruction = controller.selectedIsConstruction;

    final chips = <Widget>[
      // Stage 19b item 6: only meaningful for a single selected Line -
      // inserted first/leftmost per the brief, ahead of Make Construction.
      if (selectionSet.length == 1 && selectionSet.first.kind == SelectionKind.line)
        _RibbonActionChip(
          icon: Icons.straighten,
          label: 'Length',
          onTap: controller.busy
              ? null
              : () => _showSetLengthDialog(context, controller, selectionSet.first.id),
        ),
      if (isConstruction != null)
        _RibbonActionChip(
          icon: isConstruction ? Icons.architecture : Icons.architecture_outlined,
          label: isConstruction ? 'Make Solid' : 'Make Construction',
          onTap: controller.busy ? null : controller.toggleSelectedConstruction,
        ),
      for (final option in controller.availableConstraintOptions)
        _RibbonActionChip(
          icon: _iconFor(option.type),
          label: option.label,
          onTap: option.wired && !controller.busy
              ? () => controller.applyConstraintOption(option.type)
              : null,
        ),
      _RibbonActionChip(
        icon: Icons.delete_outline,
        label: 'Delete',
        tooltip: blockedReason,
        onTap: blockedReason == null && !controller.busy
            ? () => _confirmAndDelete(context, controller)
            : null,
      ),
    ];

    final chipRow = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(children: chips),
      ),
    );

    final radiusDiameterId = controller.selectedRadiusDiameterConstraintId;
    final content = !controller.selectedConstraintHasValue
        ? chipRow
        : Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (radiusDiameterId != null)
                _RadiusDiameterToggle(controller: controller, constraintId: radiusDiameterId),
              _ConstraintValueEditor(controller: controller),
              chipRow,
            ],
          );

    // Stage 23h: only once 2+ entities are actually selected - a lone
    // selection is already named by this panel's own heading (see
    // [_heading]), so a one-row list repeating it would be redundant.
    if (selectionSet.length < 2) return content;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _SelectedEntitiesList(controller: controller),
        const Divider(height: 1),
        content,
      ],
    );
  }

  IconData _iconFor(ConstraintOptionType type) {
    return switch (type) {
      ConstraintOptionType.vertical => Icons.height,
      ConstraintOptionType.horizontal => Icons.swap_horiz,
      ConstraintOptionType.parallel => Icons.drag_handle,
      ConstraintOptionType.perpendicular => Icons.add,
      ConstraintOptionType.equalLength => Icons.straighten,
      ConstraintOptionType.coincident => Icons.join_full,
      ConstraintOptionType.collinear => Icons.linear_scale,
      ConstraintOptionType.concentric => Icons.adjust,
      ConstraintOptionType.equalRadius => Icons.radio_button_unchecked,
      ConstraintOptionType.tangent => Icons.circle,
    };
  }
}

/// Wraps [SketchController.deleteSelected] with a confirmation step
/// whenever the delete would cascade beyond what's directly selected -
/// deleting a still-referenced Point/Line no longer just fails/disallows,
/// it cascades to whatever depends on it (see
/// [SketchController.computeDeleteCascade]), so this is where the user
/// gets told what else is about to go, with a per-session opt-out
/// ([SketchController.suppressDeleteCascadeWarning]). A no-op dialog (skips
/// straight to deleting) whenever nothing extra would be removed, or the
/// user already opted out this session.
Future<void> _confirmAndDelete(BuildContext context, SketchController controller) async {
  final selection = controller.selectionSet;
  final cascade = controller.computeDeleteCascade(selection);
  final selectedLineIds =
      selection.where((s) => s.kind == SelectionKind.line).map((s) => s.id).toSet();
  final selectedCircleIds =
      selection.where((s) => s.kind == SelectionKind.circle).map((s) => s.id).toSet();
  final selectedArcIds = selection.where((s) => s.kind == SelectionKind.arc).map((s) => s.id).toSet();
  final selectedConstraintIds =
      selection.where((s) => s.kind == SelectionKind.constraint).map((s) => s.id).toSet();
  final extraLines = cascade.lines.difference(selectedLineIds).length;
  final extraCircles = cascade.circles.difference(selectedCircleIds).length;
  final extraArcs = cascade.arcs.difference(selectedArcIds).length;
  final extraConstraints = cascade.constraints.difference(selectedConstraintIds).length;
  final hasExtras = extraLines > 0 || extraCircles > 0 || extraArcs > 0 || extraConstraints > 0;

  if (hasExtras && !controller.suppressDeleteCascadeWarning) {
    final parts = [
      if (extraLines > 0) '$extraLines line${extraLines == 1 ? '' : 's'}',
      if (extraCircles > 0) '$extraCircles circle${extraCircles == 1 ? '' : 's'}',
      if (extraArcs > 0) '$extraArcs arc${extraArcs == 1 ? '' : 's'}',
      if (extraConstraints > 0) '$extraConstraints constraint${extraConstraints == 1 ? '' : 's'}',
    ];
    var dontWarnAgain = false;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: const Text('Delete dependent geometry?'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('This also deletes ${parts.join(', ')}, since they depend on what you selected.'),
              const SizedBox(height: 8),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                dense: true,
                title: const Text("Don't warn me again this session"),
                value: dontWarnAgain,
                onChanged: (value) => setDialogState(() => dontWarnAgain = value ?? false),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('Cancel')),
            FilledButton(
              onPressed: () {
                if (dontWarnAgain) controller.suppressDeleteCascadeWarning = true;
                Navigator.of(dialogContext).pop(true);
              },
              child: const Text('Delete'),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true) return;
  }
  await controller.deleteSelected();
}

/// Stage 19b item 6: prompts for a new length for the given Line, pre-filled
/// with its current length (2dp), then calls
/// [SketchController.setLineLength] - mirrors how the canvas's ghost-value
/// editor commits a typed dimension, but reachable directly from the ribbon
/// instead of requiring Dimension mode.
Future<void> _showSetLengthDialog(
  BuildContext context,
  SketchController controller,
  String lineId,
) async {
  final currentLength = controller.lineLength(lineId);
  final textController = TextEditingController(
    text: currentLength == null ? '' : currentLength.toStringAsFixed(2),
  );
  final value = await showDialog<double>(
    context: context,
    builder: (context) => _SetLengthDialog(textController: textController),
  );
  textController.dispose();
  // Stage 20 item 3: this is a freestanding function (not a State method),
  // so it has no `mounted` getter of its own - guard with `context.mounted`
  // before any further use of context-derived state, in case the ribbon
  // (and this function's caller) was torn down while the dialog was open.
  if (!context.mounted) return;
  if (value != null) {
    controller.setLineLength(lineId, value);
  }
}

class _SetLengthDialog extends StatefulWidget {
  final TextEditingController textController;

  const _SetLengthDialog({required this.textController});

  @override
  State<_SetLengthDialog> createState() => _SetLengthDialogState();
}

class _SetLengthDialogState extends State<_SetLengthDialog> {
  String? _error;
  final FocusNode _focusNode = FocusNode();

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  void _submit() {
    final value = double.tryParse(widget.textController.text);
    if (value == null || value <= 0) {
      setState(() => _error = 'Enter a positive number');
      return;
    }
    _dismiss(value);
  }

  void _cancel() => _dismiss(null);

  // Stage 23a's fix (unfocus() immediately before pop()) still reproduced
  // the `_dependents.isEmpty` crash on a real device: unfocus() only
  // *schedules* the focus change - FocusManager applies it during the next
  // frame's pre-build phase, so popping the route synchronously in the same
  // frame can still tear down the focused TextField's Element subtree before
  // that application runs. Deferring the actual pop to a post-frame callback
  // guarantees a full frame (and the focus-change application within it)
  // elapses first.
  void _dismiss(double? value) {
    _focusNode.unfocus();
    final navigator = Navigator.of(context);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (navigator.mounted) navigator.pop(value);
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Set Length'),
      content: TextField(
        controller: widget.textController,
        focusNode: _focusNode,
        autofocus: true,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: InputDecoration(
          suffixText: 'mm',
          errorText: _error,
          border: const OutlineInputBorder(),
        ),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: _cancel,
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _submit,
          child: const Text('Set'),
        ),
      ],
    );
  }
}

/// The panel's top row: a bold heading plus an explicit close button - an
/// always-available way to dismiss the ribbon, alongside tapping blank
/// idle canvas space (see [SketchController.handleCanvasTap]).
class _RibbonHeader extends StatelessWidget {
  final String text;
  final VoidCallback onClose;

  const _RibbonHeader({required this.text, required this.onClose});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 4, 8),
      child: Row(
        children: [
          Expanded(
            child: Text(text, style: const TextStyle(fontWeight: FontWeight.bold)),
          ),
          IconButton(
            tooltip: 'Close',
            icon: const Icon(Icons.close, size: 20),
            onPressed: onClose,
          ),
        ],
      ),
    );
  }
}

/// Stage 23h: lists every entity currently in [SketchController.selectionSet]
/// by its session-only auto-name (see [SketchController.selectionLabel]),
/// each with a × that deselects just that one entity (via
/// [SketchController.deselect]) without touching the rest - shown above the
/// usual chip row whenever 2+ entities are selected (see
/// [SketchRibbon._body]). Capped to a scrollable height rather than growing
/// the panel unboundedly for a very large marquee selection.
class _SelectedEntitiesList extends StatelessWidget {
  final SketchController controller;

  const _SelectedEntitiesList({required this.controller});

  @override
  Widget build(BuildContext context) {
    final selectionSet = controller.selectionSet;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 160),
      child: ListView.builder(
        shrinkWrap: true,
        padding: EdgeInsets.zero,
        itemCount: selectionSet.length,
        itemBuilder: (context, index) {
          final selection = selectionSet[index];
          return ListTile(
            dense: true,
            visualDensity: VisualDensity.compact,
            contentPadding: const EdgeInsets.only(left: 16, right: 4),
            title: Text(controller.selectionLabel(selection)),
            trailing: IconButton(
              icon: const Icon(Icons.close, size: 18),
              tooltip: 'Remove from selection',
              onPressed: controller.busy ? null : () => controller.deselect(selection),
            ),
          );
        },
      ),
    );
  }
}

/// One action button in the flyout's horizontally-scrolling action row -
/// an icon over a small label, greyed out (and non-tappable) when [onTap]
/// is null, which is how unwired [ConstraintOption]s and blocked actions
/// (e.g. Delete on a still-referenced Point) render per Stage 13 item 6.
class _RibbonActionChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final String? tooltip;

  const _RibbonActionChip({
    required this.icon,
    required this.label,
    required this.onTap,
    this.tooltip,
  });

  @override
  Widget build(BuildContext context) {
    final disabled = onTap == null;
    final color = disabled ? Colors.grey : null;
    final column = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(icon: Icon(icon, color: color), onPressed: onTap),
        Text(label, style: TextStyle(fontSize: 11, color: color)),
      ],
    );
    if (tooltip == null) return column;
    return Tooltip(message: tooltip!, child: column);
  }
}

/// New work package item 3's "change value" editor: shown above the chip
/// row whenever exactly one value-bearing Constraint (Distance or Angle) is
/// selected. Mirrors the canvas's ghost-dimension value editor, but PATCHes
/// an existing constraint via [SketchController.updateSelectedConstraintValue]
/// instead of creating a new one.
class _ConstraintValueEditor extends StatefulWidget {
  final SketchController controller;

  const _ConstraintValueEditor({required this.controller});

  @override
  State<_ConstraintValueEditor> createState() => _ConstraintValueEditorState();
}

class _ConstraintValueEditorState extends State<_ConstraintValueEditor> {
  late final TextEditingController _textController;

  /// On-device feedback: a circle's radius/diameter dimension always stores
  /// the *radius* value (see [SketchController.confirmGhostValue]'s
  /// `distanceValue`), so editing it while [SketchController.
  /// showsDiameterFor] is true must show/accept the *diameter* the label
  /// itself displays, not the raw stored radius the user never sees -
  /// tracked here (rather than read fresh in [_submit]) so
  /// [didUpdateWidget] can tell whether the R/⌀ toggle flipped mid-edit and
  /// re-sync the displayed text to match.
  bool _showsDiameter = false;

  bool _computeShowsDiameter() {
    final id = widget.controller.selectedRadiusDiameterConstraintId;
    return id != null && widget.controller.showsDiameterFor(id);
  }

  double? _displayValue() {
    final raw = widget.controller.selectedConstraintValue;
    if (raw == null) return null;
    return _showsDiameter ? raw * 2 : raw;
  }

  @override
  void initState() {
    super.initState();
    _showsDiameter = _computeShowsDiameter();
    _textController = TextEditingController(text: _formatValue(_displayValue()));
  }

  @override
  void didUpdateWidget(covariant _ConstraintValueEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    final nowShowsDiameter = _computeShowsDiameter();
    if (nowShowsDiameter != _showsDiameter) {
      _showsDiameter = nowShowsDiameter;
      _textController.text = _formatValue(_displayValue());
    }
  }

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  String _formatValue(double? value) {
    if (value == null) return '';
    return value.toStringAsFixed(2);
  }

  void _submit() {
    final value = double.tryParse(_textController.text);
    if (value == null) return;
    widget.controller.updateSelectedConstraintValue(_showsDiameter ? value / 2 : value);
  }

  @override
  Widget build(BuildContext context) {
    final isRadiusDiameter = widget.controller.selectedRadiusDiameterConstraintId != null;
    final suffix = widget.controller.selectedConstraintIsAngle
        ? '°'
        : isRadiusDiameter
            ? (_showsDiameter ? 'mm ⌀' : 'mm R')
            : 'mm';
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _textController,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                isDense: true,
                suffixText: suffix,
                border: const OutlineInputBorder(),
              ),
              onSubmitted: (_) => _submit(),
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            tooltip: 'Apply',
            icon: const Icon(Icons.check),
            onPressed: widget.controller.busy ? null : _submit,
          ),
        ],
      ),
    );
  }
}

/// On-device feedback: "when the dimension is selected there should be a
/// toggle to switch between the two [radius and diameter]" - a circle's
/// dimension always stores the *radius* value (see [SketchController.
/// confirmGhostValue]), so this only ever changes how it's *labeled* on
/// canvas and *edited* in [_ConstraintValueEditor] (see
/// [SketchController.showsDiameterFor]'s own doc comment), never the
/// underlying constraint - a purely client-side display preference, so
/// toggling is instant with no backend round-trip.
class _RadiusDiameterToggle extends StatelessWidget {
  final SketchController controller;
  final String constraintId;

  const _RadiusDiameterToggle({required this.controller, required this.constraintId});

  @override
  Widget build(BuildContext context) {
    final showsDiameter = controller.showsDiameterFor(constraintId);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Row(
        children: [
          Expanded(
            child: ChoiceChip(
              label: const Text('Radius (R)'),
              selected: !showsDiameter,
              onSelected: (_) {
                if (showsDiameter) controller.toggleRadiusDiameterDisplay(constraintId);
              },
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: ChoiceChip(
              label: const Text('Diameter (⌀)'),
              selected: showsDiameter,
              onSelected: (_) {
                if (!showsDiameter) controller.toggleRadiusDiameterDisplay(constraintId);
              },
            ),
          ),
        ],
      ),
    );
  }
}
