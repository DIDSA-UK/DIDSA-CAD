import 'package:flutter/material.dart';

import 'field_help_icon.dart';

/// `docs/gear-design/00-conventions.md`'s field input style: "dropdown of
/// standard values... with a 'custom' option revealing free text" - shared
/// by every gear-type entry form's module/pressure-angle fields
/// (`docs/gear-design/08-entry-screen-and-preview.md`). A plain, dumb input
/// widget - like [ExtrudePanel]/[FilletPanel], every edit reports
/// immediately via [onChanged]; debouncing the resulting preview/PATCH call
/// is the caller's job.
class StandardValueField extends StatefulWidget {
  final String label;
  final List<double> standardValues;
  final double value;
  final ValueChanged<double> onChanged;

  /// Appended to every displayed value, e.g. `'°'` for a pressure-angle
  /// field - empty (the default) for a bare number like module.
  final String suffix;

  /// Shown behind a tappable "?" (see [fieldHelpIcon]) next to the
  /// dropdown - null omits the icon entirely.
  final String? helpText;

  const StandardValueField({
    super.key,
    required this.label,
    required this.standardValues,
    required this.value,
    required this.onChanged,
    this.suffix = '',
    this.helpText,
  });

  @override
  State<StandardValueField> createState() => _StandardValueFieldState();
}

class _StandardValueFieldState extends State<StandardValueField> {
  late bool _isCustom;
  late final TextEditingController _customController;

  @override
  void initState() {
    super.initState();
    _isCustom = !widget.standardValues.contains(widget.value);
    _customController = TextEditingController(text: _format(widget.value));
  }

  @override
  void didUpdateWidget(covariant StandardValueField oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The caller reset the value out from under this field (e.g. switching
    // gear type reseeds a default) rather than the user editing it - follow
    // along rather than showing a stale dropdown/custom-field selection.
    if (oldWidget.value != widget.value && double.tryParse(_customController.text) != widget.value) {
      _isCustom = !widget.standardValues.contains(widget.value);
      _customController.text = _format(widget.value);
    }
  }

  @override
  void dispose() {
    _customController.dispose();
    super.dispose();
  }

  static String _format(double value) =>
      value == value.roundToDouble() ? value.toStringAsFixed(0) : value.toString();

  void _onCustomTextChanged(String text) {
    final parsed = double.tryParse(text);
    if (parsed != null && parsed > 0) widget.onChanged(parsed);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        DropdownButtonFormField<double?>(
          decoration: InputDecoration(
            labelText: widget.label,
            suffixIcon: widget.helpText == null ? null : fieldHelpIcon(widget.helpText!),
          ),
          initialValue: _isCustom ? null : widget.value,
          items: [
            for (final standardValue in widget.standardValues)
              DropdownMenuItem(
                value: standardValue,
                child: Text('${_format(standardValue)}${widget.suffix}'),
              ),
            const DropdownMenuItem(value: null, child: Text('Custom')),
          ],
          onChanged: (selected) {
            setState(() => _isCustom = selected == null);
            if (selected != null) {
              _customController.text = _format(selected);
              widget.onChanged(selected);
            } else {
              _onCustomTextChanged(_customController.text);
            }
          },
        ),
        if (_isCustom)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: TextField(
              controller: _customController,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                labelText: 'Custom ${widget.label.toLowerCase()}',
                suffixText: widget.suffix.isEmpty ? null : widget.suffix,
              ),
              onChanged: _onCustomTextChanged,
            ),
          ),
      ],
    );
  }
}
