import 'package:flutter/material.dart';

import '../api/document_api_client.dart';
import 'resizable_tool_panel.dart';

/// How each end of a Spring is finished - the backend's `SpringEnd` values.
const springEndLabels = {
  'open': 'Open',
  'closed': 'Closed',
  'closed_ground': 'Closed & ground',
};

/// The panel for creating or editing a Spring feature (owner's request: a dedicated Spring feature
/// with closed, ground-flat ends): a compression spring made from its numbers. Same "dumb display,
/// the caller does the API calls" shape and the same keyboard-safe [ResizableToolPanel] shell as
/// [CurvePanel]. The working pitch is worked out by the backend from the free length; an existing
/// spring's ([initial]) is shown read-only.
class SpringPanel extends StatefulWidget {
  final String title;

  /// Opens on an existing Spring's values (editing it); null starts from the defaults.
  final SpringDto? initial;

  /// When set, the spring stands on an already-selected plane or face (read-only "Axis: ..." row,
  /// as [CurvePanel.preSelectedAxisLabel]); null shows the XY / XZ / YZ dropdown.
  final String? preSelectedAxisLabel;

  /// Fired on every valid edit (every number parses and is positive, the mean diameter is bigger
  /// than the wire's): the values and the fixed plane picked in the dropdown.
  final void Function(SpringDto spring, String axisPlane)? onChanged;

  final VoidCallback onConfirm;
  final VoidCallback onCancel;

  const SpringPanel({
    super.key,
    this.title = 'Spring',
    this.initial,
    this.preSelectedAxisLabel,
    this.onChanged,
    required this.onConfirm,
    required this.onCancel,
  });

  @override
  State<SpringPanel> createState() => _SpringPanelState();
}

class _SpringPanelState extends State<SpringPanel> {
  late final TextEditingController _mean;
  late final TextEditingController _wire;
  late final TextEditingController _length;
  late final TextEditingController _coils;
  late String _startEnd;
  late String _finishEnd;
  late bool _rightHanded;
  String _axisPlane = 'XY';

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    _mean = TextEditingController(text: _format(initial?.meanDiameter ?? 10));
    _wire = TextEditingController(text: _format(initial?.wireDiameter ?? 1));
    _length = TextEditingController(text: _format(initial?.freeLength ?? 20));
    _coils = TextEditingController(text: _format(initial?.activeCoils ?? 5));
    _startEnd = initial?.startEnd ?? 'closed_ground';
    _finishEnd = initial?.finishEnd ?? 'closed_ground';
    _rightHanded = initial?.rightHanded ?? true;
  }

  static String _format(double value) {
    final rounded = double.parse(value.toStringAsFixed(6));
    return rounded == rounded.roundToDouble() ? rounded.toInt().toString() : rounded.toString();
  }

  @override
  void dispose() {
    _mean.dispose();
    _wire.dispose();
    _length.dispose();
    _coils.dispose();
    super.dispose();
  }

  double? _parse(TextEditingController controller) => double.tryParse(controller.text);

  /// Why the numbers cannot make a spring yet, or null when they can (the backend checks the rest,
  /// e.g. a free length too short for the coils, and says so on Confirm).
  String? get _problem {
    final mean = _parse(_mean), wire = _parse(_wire), length = _parse(_length), coils = _parse(_coils);
    if (mean == null || wire == null || length == null || coils == null) return 'Every value needs a number';
    if (wire <= 0 || length <= 0) return 'The wire diameter and free length must be more than 0';
    if (mean <= wire) return 'The mean diameter must be bigger than the wire diameter';
    if (coils < 1) return 'A spring needs at least 1 active coil';
    return null;
  }

  SpringDto? get _values {
    if (_problem != null) return null;
    return SpringDto(
      meanDiameter: _parse(_mean)!,
      wireDiameter: _parse(_wire)!,
      freeLength: _parse(_length)!,
      activeCoils: _parse(_coils)!,
      startEnd: _startEnd,
      finishEnd: _finishEnd,
      rightHanded: _rightHanded,
    );
  }

  void _emit() {
    setState(() {});
    final values = _values;
    if (values != null) widget.onChanged?.call(values, _axisPlane);
  }

  Widget _number(String key, TextEditingController controller, String label, {String? helper}) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: TextField(
          key: ValueKey('spring-$key'),
          controller: controller,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(labelText: label, helperText: helper),
          onChanged: (_) => _emit(),
        ),
      );

  Widget _endPicker(String key, String label, String value, ValueChanged<String> onChanged) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: DropdownButtonFormField<String>(
          key: ValueKey('spring-$key'),
          initialValue: value,
          decoration: InputDecoration(labelText: label),
          items: [
            for (final entry in springEndLabels.entries) DropdownMenuItem(value: entry.key, child: Text(entry.value)),
          ],
          onChanged: (picked) {
            if (picked == null) return;
            onChanged(picked);
            _emit();
          },
        ),
      );

  @override
  Widget build(BuildContext context) {
    final mean = _parse(_mean), wire = _parse(_wire);
    final sizes = mean != null && wire != null && mean > wire
        ? 'Outside ${(mean + wire).toStringAsFixed(2)}, inside ${(mean - wire).toStringAsFixed(2)}'
        : null;
    final problem = _problem;
    final initial = widget.initial;
    return Padding(
      // As CurvePanel: lifted by the keyboard so the field being typed in stays in view.
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: ResizableToolPanel(
        title: widget.title,
        defaultHeightFraction: 0.6,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.preSelectedAxisLabel != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text('Axis: ${widget.preSelectedAxisLabel}'),
              )
            else
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: DropdownButtonFormField<String>(
                  initialValue: _axisPlane,
                  decoration: const InputDecoration(labelText: 'Stands on plane'),
                  items: const [
                    DropdownMenuItem(value: 'XY', child: Text('XY')),
                    DropdownMenuItem(value: 'XZ', child: Text('XZ')),
                    DropdownMenuItem(value: 'YZ', child: Text('YZ')),
                  ],
                  onChanged: (value) {
                    if (value == null) return;
                    _axisPlane = value;
                    _emit();
                  },
                ),
              ),
            _number('mean', _mean, 'Mean diameter', helper: sizes ?? 'Through the wire centre'),
            _number('wire', _wire, 'Wire diameter'),
            _number('length', _length, 'Free length'),
            _number('coils', _coils, 'Active coils', helper: 'A closed end adds one dead coil'),
            _endPicker('start-end', 'Start end', _startEnd, (v) => _startEnd = v),
            _endPicker('finish-end', 'Finish end', _finishEnd, (v) => _finishEnd = v),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Right-handed'),
              value: _rightHanded,
              onChanged: (value) {
                _rightHanded = value;
                _emit();
              },
            ),
            if (initial?.activePitch != null)
              Text(
                'Working pitch ${initial!.activePitch!.toStringAsFixed(3)}, '
                '${initial.totalCoils?.toStringAsFixed(2) ?? '?'} coils in all, '
                'solid at ${initial.solidLength?.toStringAsFixed(2) ?? '?'}',
                key: const ValueKey('spring-readout'),
                style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 12),
              ),
            if (problem != null)
              Text(problem, style: TextStyle(color: Theme.of(context).colorScheme.error, fontSize: 12)),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(onPressed: widget.onCancel, child: const Text('Cancel')),
                const SizedBox(width: 8),
                FilledButton(onPressed: problem == null ? widget.onConfirm : null, child: const Text('Confirm')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
