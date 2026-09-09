import 'package:flutter/material.dart';

import 'resizable_tool_panel.dart';

/// Phase 2 surfacing package, fourth/last entry - which kind of source this
/// panel's Offset Surface reads from. Mirrors [MoveFaceMode]'s own
/// `apiValue`-free str-enum-by-label convention; matches the backend's own
/// `OffsetSourceRef` "exactly one of `face_ref`/`surface_feature_id`"
/// discriminant, per that ref type's own docstring.
enum OffsetSurfaceSourceKind {
  face,
  surface;

  String get label => switch (this) {
        OffsetSurfaceSourceKind.face => 'From Face',
        OffsetSurfaceSourceKind.surface => 'From Surface',
      };
}

/// Phase 2 surfacing package, fourth/last entry: the bottom-sheet-style panel
/// [PartScreen] opens for Offset Surface. Mirrors [SplitPanel]'s own multi-
/// kind-tool-picker precedent for the toggle between [OffsetSurfaceSourceKind]s
/// (a `SegmentedButton`, same shape [MoveFacePanel.mode] already uses) and
/// [MoveFacePanel]'s own offset-distance field for [distance] - "From Face"
/// reuses the viewport face-tap flow [MoveFacePanel] already uses (no tree
/// involvement, [PartScreen] reads the tap straight off [faceSummary]),
/// "From Surface" uses the same single-pick-from-tree flow [ThickenPanel]'s
/// own source picker uses, filtered to `produces == 'surface'`.
class OffsetSurfacePanel extends StatefulWidget {
  /// 'Offset Surface', or 'Edit Offset Surface' while editing an already-
  /// existing OffsetSurfaceFeature.
  final String title;

  final String? tooltip;

  final OffsetSurfaceSourceKind kind;
  final void Function(OffsetSurfaceSourceKind kind) onKindChanged;

  /// A short human-readable summary of the current source pick - e.g. "Tap
  /// a face in the viewport…", "Face selected", or a surface Feature's own
  /// display name - or null while [kind] is `face` and nothing has been
  /// tapped yet. Computed by [PartScreen] (it alone has the id-to-name map
  /// and current pick state this needs), not this widget.
  final String? sourceSummary;

  /// Whether a source (either kind) is currently resolved - gates Confirm
  /// alongside a valid [distance], mirrors [MoveFacePanel.hasDirection].
  final bool hasSource;

  /// "From Surface" mode's own "Pick"/"Change" affordance - starts (or
  /// restarts) the tree picker. Unused while [kind] is `face` (that mode's
  /// pick happens ambiently via a viewport face tap, same as
  /// [MoveFacePanel]'s Offset mode - no button needed to "start" it).
  final VoidCallback onPickSurface;

  final double initialDistance;

  /// Fired on every valid, non-zero distance edit - mirrors
  /// [MoveFacePanel.onOffsetChanged]'s own "must be non-zero" contract.
  final void Function(double distance)? onDistanceChanged;

  final VoidCallback onConfirm;
  final VoidCallback onCancel;

  const OffsetSurfacePanel({
    super.key,
    this.title = 'Offset Surface',
    this.tooltip,
    required this.kind,
    required this.onKindChanged,
    this.sourceSummary,
    required this.hasSource,
    required this.onPickSurface,
    required this.initialDistance,
    this.onDistanceChanged,
    required this.onConfirm,
    required this.onCancel,
  });

  @override
  State<OffsetSurfacePanel> createState() => _OffsetSurfacePanelState();
}

class _OffsetSurfacePanelState extends State<OffsetSurfacePanel> {
  late final TextEditingController _distanceController;

  /// Null once the distance field no longer parses as a non-zero number -
  /// mirrors [MoveFacePanel._offset]'s own null-on-invalid-input pattern.
  double? _distance;

  @override
  void initState() {
    super.initState();
    _distanceController = TextEditingController(text: _formatNumber(widget.initialDistance));
    _distance = widget.initialDistance != 0 ? widget.initialDistance : null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_distance != null) widget.onDistanceChanged?.call(_distance!);
    });
  }

  @override
  void dispose() {
    _distanceController.dispose();
    super.dispose();
  }

  static String _formatNumber(double value) =>
      value == value.roundToDouble() ? value.toStringAsFixed(0) : value.toString();

  void _emitDistanceChange() {
    final value = double.tryParse(_distanceController.text);
    final distance = (value != null && value != 0) ? value : null;
    setState(() => _distance = distance);
    if (distance != null) widget.onDistanceChanged?.call(distance);
  }

  void _flipDistance() {
    final value = double.tryParse(_distanceController.text);
    if (value == null) return;
    _distanceController.text = _formatNumber(-value);
    _emitDistanceChange();
  }

  bool get _canConfirm => widget.hasSource && _distance != null;

  @override
  Widget build(BuildContext context) {
    return ResizableToolPanel(
      title: widget.title,
      tooltip: widget.tooltip,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SegmentedButton<OffsetSurfaceSourceKind>(
            segments: [
              for (final kind in OffsetSurfaceSourceKind.values)
                ButtonSegment(value: kind, label: Text(kind.label)),
            ],
            selected: {widget.kind},
            onSelectionChanged: (selection) => widget.onKindChanged(selection.first),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: Text(
                  widget.sourceSummary ??
                      (widget.kind == OffsetSurfaceSourceKind.face
                          ? 'Tap a face in the viewport'
                          : 'Pick a surface from the Build Tree'),
                  style: TextStyle(
                    color: widget.hasSource
                        ? Theme.of(context).colorScheme.onSurfaceVariant
                        : Theme.of(context).colorScheme.error,
                    fontSize: 12,
                  ),
                ),
              ),
              if (widget.kind == OffsetSurfaceSourceKind.surface)
                TextButton(
                  onPressed: widget.onPickSurface,
                  child: Text(widget.hasSource ? 'Change' : 'Pick'),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _distanceController,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                  decoration: const InputDecoration(labelText: 'Distance (along outward normal)'),
                  onChanged: (_) => _emitDistanceChange(),
                ),
              ),
              IconButton(
                tooltip: 'Flip direction',
                onPressed: _flipDistance,
                icon: const Icon(Icons.swap_vert),
              ),
            ],
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
