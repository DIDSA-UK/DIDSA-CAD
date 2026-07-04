import 'package:flutter/material.dart';

/// Which of the three v1 plane-construction flows [CreatePlanePanel] is
/// currently showing - decided by [PartScreen] from the selection that
/// enabled the Create Plane button (see `selection_actions.dart`'s
/// `contextActionsFor`), not by anything this panel picks itself.
///
/// C3 adds [midplane] (equidistant between two selected Faces) alongside
/// C2's original [offsetFace]/[normalToLineAtPoint].
enum CreatePlaneMode { offsetFace, normalToLineAtPoint, midplane }

/// The bottom-sheet-style panel [PartScreen] opens once Create Plane is
/// enabled (a single planar Body Face selected, two Faces selected, or a
/// Sketch Line plus the Point that's its own endpoint) - mirrors
/// [ExtrudePanel]'s Confirm/Cancel session shape and slide-up presentation.
///
/// [CreatePlaneMode.offsetFace] shows a numeric offset field (Confirm
/// enabled once it parses); [CreatePlaneMode.normalToLineAtPoint]/
/// [CreatePlaneMode.midplane] have no numeric input at all - both are fully
/// determined by the references alone, so Confirm is enabled
/// unconditionally (those refs are already guaranteed selected by the time
/// this panel is even open - `contextActionsFor` only enables the button
/// once they are).
class CreatePlanePanel extends StatefulWidget {
  /// 'Create Plane' when creating a brand-new Feature (default),
  /// 'Edit Plane' when [PartScreen] opened this to edit an already-existing
  /// one instead - purely a label, same convention as
  /// [ExtrudePanel.title].
  final String title;

  final CreatePlaneMode mode;
  final double initialOffset;

  /// Only meaningful (and only ever called) while [mode] is
  /// [CreatePlaneMode.offsetFace] - fired on every valid offset edit, same
  /// live-preview-drives-a-debounced-PATCH pattern [ExtrudePanel.onChanged]
  /// already uses.
  final void Function(double offset)? onOffsetChanged;

  final VoidCallback onConfirm;
  final VoidCallback onCancel;

  const CreatePlanePanel({
    super.key,
    this.title = 'Create Plane',
    required this.mode,
    this.initialOffset = 0.0,
    this.onOffsetChanged,
    required this.onConfirm,
    required this.onCancel,
  });

  @override
  State<CreatePlanePanel> createState() => _CreatePlanePanelState();
}

class _CreatePlanePanelState extends State<CreatePlanePanel> {
  late final TextEditingController _offsetController;

  /// Null once the offset field no longer parses as a number - mirrors
  /// [ExtrudePanel]'s own `_depth` null-on-invalid-input pattern. Always
  /// non-null (and never consulted by [_canConfirm]) for
  /// [CreatePlaneMode.normalToLineAtPoint].
  double? _offset;

  @override
  void initState() {
    super.initState();
    _offsetController = TextEditingController(text: _formatDistance(widget.initialOffset));
    _offset = widget.initialOffset;
  }

  @override
  void dispose() {
    _offsetController.dispose();
    super.dispose();
  }

  static String _formatDistance(double value) =>
      value == value.roundToDouble() ? value.toStringAsFixed(0) : value.toString();

  bool get _canConfirm => widget.mode != CreatePlaneMode.offsetFace || _offset != null;

  void _emitOffsetChange() {
    final value = double.tryParse(_offsetController.text);
    setState(() => _offset = value);
    if (value != null) widget.onOffsetChanged?.call(value);
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
                if (widget.mode == CreatePlaneMode.offsetFace) ...[
                  TextField(
                    controller: _offsetController,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                    decoration: const InputDecoration(labelText: 'Offset'),
                    onChanged: (_) => _emitOffsetChange(),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _offset == null ? 'Enter a valid offset' : 'Offset: ${_formatDistance(_offset!)}',
                    style: TextStyle(
                      color: _offset == null
                          ? Theme.of(context).colorScheme.error
                          : Theme.of(context).colorScheme.onSurfaceVariant,
                      fontSize: 12,
                    ),
                  ),
                ] else
                  Text(
                    widget.mode == CreatePlaneMode.midplane
                        ? 'Plane equidistant between the two selected faces'
                        : 'Plane normal to the selected line, through the selected point',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
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
          ),
        ),
      ),
    );
  }
}
