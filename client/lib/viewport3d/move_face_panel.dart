import 'package:flutter/material.dart';

import 'resizable_tool_panel.dart';

/// Direct Editing family, fifth/last entry: the bottom-sheet-style panel
/// [PartScreen] opens once a single planar face is selected and "Move
/// Face" is chosen (see `selection_actions.dart`'s `contextActionsFor`
/// single-planar-face branch). Mirrors [ScaleBodyPanel]'s shape almost
/// exactly - a single numeric field, live-preview-drives-a-debounced-PATCH
/// - just "offset" (along the face's own outward normal) instead of
/// "factor". v1 client scope only exposes this one of the backend's three
/// modes (offset/delta/direction-of-edge) - see `docs/direct-editing-
/// scope.md` for why delta/direction have no UI yet, and why the face is
/// fixed once picked (no re-picking a different face mid-session).
class MoveFacePanel extends StatefulWidget {
  /// 'Move Face', or 'Edit Move Face' while editing an already-existing
  /// MoveFaceFeature - same convention as [ScaleBodyPanel.title].
  final String title;

  final String? tooltip;

  final double initialOffset;

  /// Fired on every valid offset edit - same live-preview-drives-a-
  /// debounced-PATCH pattern [ScaleBodyPanel.onFactorChanged] already
  /// uses. Unlike a factor, an offset of exactly 0 is not meaningful (no
  /// move at all - the backend rejects it outright, `_validate_move_face_
  /// payload`'s own `offset_distance` != 0 check), so this mirrors
  /// [FilletPanel.onRadiusChanged]'s "must be non-zero" contract instead,
  /// just allowing negative values too (an offset can push either
  /// direction along the face's own normal).
  final void Function(double offset)? onOffsetChanged;

  final VoidCallback onConfirm;
  final VoidCallback onCancel;

  const MoveFacePanel({
    super.key,
    this.title = 'Move Face',
    this.tooltip,
    required this.initialOffset,
    this.onOffsetChanged,
    required this.onConfirm,
    required this.onCancel,
  });

  @override
  State<MoveFacePanel> createState() => _MoveFacePanelState();
}

class _MoveFacePanelState extends State<MoveFacePanel> {
  late final TextEditingController _offsetController;

  /// Null once the offset field no longer parses as a non-zero number -
  /// mirrors [ScaleBodyPanel]'s own `_factor` null-on-invalid-input
  /// pattern, just allowing negative values (see [onOffsetChanged]'s own
  /// doc comment).
  double? _offset;

  @override
  void initState() {
    super.initState();
    _offsetController = TextEditingController(text: _formatOffset(widget.initialOffset));
    _offset = widget.initialOffset != 0 ? widget.initialOffset : null;
    // Without this, the live preview underneath this panel doesn't appear
    // until the user actually edits the offset field - mirrors
    // ScaleBodyPanel's identical fix.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _offset != null) widget.onOffsetChanged?.call(_offset!);
    });
  }

  @override
  void dispose() {
    _offsetController.dispose();
    super.dispose();
  }

  static String _formatOffset(double value) =>
      value == value.roundToDouble() ? value.toStringAsFixed(0) : value.toString();

  bool get _canConfirm => _offset != null;

  void _emitOffsetChange() {
    final value = double.tryParse(_offsetController.text);
    final offset = (value != null && value != 0) ? value : null;
    setState(() => _offset = offset);
    if (offset != null) widget.onOffsetChanged?.call(offset);
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
            controller: _offsetController,
            keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
            decoration: const InputDecoration(labelText: 'Offset'),
            onChanged: (_) => _emitOffsetChange(),
          ),
          const SizedBox(height: 8),
          Text(
            _offset == null ? 'Enter a non-zero offset' : 'Offset: ${_formatOffset(_offset!)}',
            style: TextStyle(
              color: _offset == null
                  ? Theme.of(context).colorScheme.error
                  : Theme.of(context).colorScheme.onSurfaceVariant,
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
