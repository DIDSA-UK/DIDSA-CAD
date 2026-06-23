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
  final ExtrudeType initialType;
  final double initialStartDistance;
  final double initialEndDistance;
  final void Function(ExtrudeType type, double startDistance, double endDistance) onChanged;
  final VoidCallback onConfirm;
  final VoidCallback onCancel;

  const ExtrudePanel({
    super.key,
    this.initialType = ExtrudeType.boss,
    this.initialStartDistance = 0.0,
    this.initialEndDistance = 10.0,
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

  @override
  void initState() {
    super.initState();
    _type = widget.initialType;
    _startController = TextEditingController(text: _formatDistance(widget.initialStartDistance));
    _endController = TextEditingController(text: _formatDistance(widget.initialEndDistance));
  }

  @override
  void dispose() {
    _startController.dispose();
    _endController.dispose();
    super.dispose();
  }

  static String _formatDistance(double value) =>
      value == value.roundToDouble() ? value.toStringAsFixed(0) : value.toString();

  void _emitChange() {
    final start = double.tryParse(_startController.text);
    final end = double.tryParse(_endController.text);
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
                const Text('Extrude', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
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
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(onPressed: widget.onCancel, child: const Text('Cancel')),
                    const SizedBox(width: 8),
                    FilledButton(onPressed: widget.onConfirm, child: const Text('Confirm')),
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
