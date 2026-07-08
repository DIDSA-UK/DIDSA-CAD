import 'package:flutter/material.dart';

/// The "boss" or "cut" choice for an Extrude - mirrors the backend's
/// `extrude_type` string values exactly, so call sites can pass
/// [ExtrudeType.apiValue] straight into [DocumentApiClient] without a
/// separate mapping table.
enum ExtrudeType {
  boss,
  cut;

  String get apiValue => name;

  static ExtrudeType fromApiValue(String value) =>
      ExtrudeType.values.firstWhere((t) => t.apiValue == value, orElse: () => ExtrudeType.boss);
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

  final ExtrudeType initialType;
  final double initialStartDistance;
  final double initialEndDistance;

  /// Prompt A4: how many target bodies are currently picked in the 3D
  /// viewport (see [PartScreen]'s body-picking flow, driven independently
  /// of this panel's own fields) - read live on every build, unlike
  /// [initialType]/[initialStartDistance]/[initialEndDistance], which this
  /// widget only consults once to seed its own editable local state.
  /// Drives Cut's "requires 1+" rule below.
  final int targetBodyCount;

  final void Function(ExtrudeType type, double startDistance, double endDistance) onChanged;
  final VoidCallback onConfirm;
  final VoidCallback onCancel;

  const ExtrudePanel({
    super.key,
    this.title = 'Extrude',
    this.initialType = ExtrudeType.boss,
    this.initialStartDistance = 0.0,
    this.initialEndDistance = 10.0,
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
    _startController = TextEditingController(text: _formatDistance(widget.initialStartDistance));
    _endController = TextEditingController(text: _formatDistance(widget.initialEndDistance));
    _depth = widget.initialEndDistance - widget.initialStartDistance;
    // Without this, the live preview underneath this panel doesn't appear
    // until the user actually edits a field - onChanged was only ever wired
    // to the TextField/SegmentedButton callbacks, never fired for the
    // initial values this panel opens with.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onChanged(_type, widget.initialStartDistance, widget.initialEndDistance);
    });
  }

  @override
  void dispose() {
    _startController.dispose();
    _endController.dispose();
    super.dispose();
  }

  static String _formatDistance(double value) =>
      value == value.roundToDouble() ? value.toStringAsFixed(0) : value.toString();

  /// Confirm is disabled for an invalid depth (pre-existing rule) or, new in
  /// Prompt A4, for a Cut with nothing picked yet - Boss has no such
  /// requirement, 0 selected is exactly how a Boss starts a brand-new Body.
  bool get _canConfirm =>
      _depth != null && _depth! > 0 && !(_type == ExtrudeType.cut && widget.targetBodyCount == 0);

  void _emitChange() {
    final start = double.tryParse(_startController.text);
    final end = double.tryParse(_endController.text);
    setState(() => _depth = (start != null && end != null) ? end - start : null);
    if (start == null || end == null) return;
    widget.onChanged(_type, start, end);
  }

  void _onTypeChanged(ExtrudeType type) {
    setState(() => _type = type);
    _emitChange();
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
                SegmentedButton<ExtrudeType>(
                  segments: const [
                    ButtonSegment(value: ExtrudeType.boss, label: Text('Boss'), icon: Icon(Icons.add_box)),
                    ButtonSegment(
                      value: ExtrudeType.cut,
                      label: Text('Cut'),
                      icon: Icon(Icons.content_cut),
                    ),
                  ],
                  selected: {_type},
                  onSelectionChanged: (selection) => _onTypeChanged(selection.first),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _startController,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                        decoration: const InputDecoration(labelText: 'Start distance'),
                        onChanged: (_) => _emitChange(),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        controller: _endController,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
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
