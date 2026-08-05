import 'package:flutter/material.dart';

import 'resizable_tool_panel.dart';
import 'svg_icon.dart';

/// The "boss" or "cut" choice for a Loft - Boss/Cut parity with
/// Extrude/Revolve/Sweep (this feature's own resolved decision) - mirrors
/// `sweep_panel.dart`'s [SweepMode] exactly, as its own separate enum
/// rather than a shared one, matching this codebase's "each Feature type
/// owns its own enum" convention.
enum LoftMode {
  boss,
  cut;

  String get apiValue => name;

  static LoftMode fromApiValue(String value) => LoftMode.values
      .firstWhere((m) => m.apiValue == value, orElse: () => LoftMode.boss);
}

/// The bottom-sheet-style panel [PartScreen] opens for Loft - structurally
/// mirrors [SweepPanel]'s Boss/Cut toggle + target-body-count session shape,
/// substituting a read-only section-count summary for the path summary and
/// adding a `Ruled` toggle plus an optional `Thickness` field. Both sections
/// are picked once, before this panel ever opens (see [PartScreen]'s own
/// section-picking flow) and never re-picked for the rest of the
/// create/edit session, same as Sweep's path.
///
/// [thickness] is what switches between the two Loft shapes the backend
/// supports: left blank (`null`), every section must be a closed Profile
/// and the Loft produces a solid directly; filled in, every section must
/// instead be a single open chain, and the lofted surface between them is
/// thickened by this signed value into a solid instead (see the backend
/// `LoftFeature.thickness`'s own docstring). This panel does not try to
/// detect which shape the picked sketches actually are - a mismatch (e.g.
/// closed profiles with a thickness set) is caught and reported by the
/// backend when Confirm is pressed, the same "resolvable parameters,
/// unresolvable geometry" 422 every other Loft validation failure already
/// is.
///
/// Every value change is reported immediately via [onChanged] - debouncing
/// the resulting PATCH/POST and mesh refresh is [PartScreen]'s job, not this
/// widget's, same as [SweepPanel].
class LoftPanel extends StatefulWidget {
  /// 'Loft' when creating a brand-new Feature (default), 'Edit Loft' when
  /// [PartScreen] opened this to edit an already-existing one instead -
  /// purely a label, same convention as [SweepPanel.title].
  final String title;

  final String? tooltip;

  final LoftMode initialMode;
  final bool initialRuled;
  final double? initialThickness;

  /// How many sections were picked - always 2 in this panel's v1 flow (see
  /// [PartScreen]'s own section-picking state), kept as a count rather than
  /// a hardcoded "2" so this panel's own summary line stays correct if a
  /// later revision lets a Loft take more than 2 sections without this file
  /// needing to change.
  final int sectionCount;

  /// How many target bodies are currently picked in the 3D viewport - same
  /// meaning and same live-read convention as [SweepPanel.targetBodyCount].
  final int targetBodyCount;

  final void Function(LoftMode mode, bool ruled, double? thickness) onChanged;
  final VoidCallback onConfirm;
  final VoidCallback onCancel;

  const LoftPanel({
    super.key,
    this.title = 'Loft',
    this.tooltip,
    this.initialMode = LoftMode.boss,
    this.initialRuled = false,
    this.initialThickness,
    required this.sectionCount,
    required this.targetBodyCount,
    required this.onChanged,
    required this.onConfirm,
    required this.onCancel,
  });

  @override
  State<LoftPanel> createState() => _LoftPanelState();
}

class _LoftPanelState extends State<LoftPanel> {
  late LoftMode _mode;
  late bool _ruled;
  late final TextEditingController _thicknessController;

  /// `true` once the thickness field either is empty (solid Loft between
  /// closed profiles - the default) or parses as a nonzero number (thin
  /// Loft between open chains) - mirrors [RevolvePanel]'s own null-on-
  /// invalid-input pattern, except a blank field is itself a valid,
  /// meaningful state here (unlike Revolve's angle), not an error.
  bool _thicknessValid = true;

  @override
  void initState() {
    super.initState();
    _mode = widget.initialMode;
    _ruled = widget.initialRuled;
    _thicknessController = TextEditingController(
      text: widget.initialThickness == null ? '' : _formatThickness(widget.initialThickness!),
    );
    // Without this, the live preview underneath this panel doesn't appear
    // until the user actually edits a field - onChanged was only ever wired
    // to this panel's own callbacks, never fired for the initial values
    // this panel opens with (mirrors SweepPanel/RevolvePanel's identical
    // fix).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onChanged(_mode, _ruled, widget.initialThickness);
    });
  }

  @override
  void dispose() {
    _thicknessController.dispose();
    super.dispose();
  }

  static String _formatThickness(double value) => value == value.roundToDouble()
      ? value.toStringAsFixed(0)
      : value.toString();

  /// Confirm is disabled for an invalid (nonzero-but-unparseable, or
  /// literally `0`) thickness, or (mirrors [SweepPanel]'s own Cut rule) for
  /// a Cut with nothing picked yet.
  bool get _canConfirm =>
      _thicknessValid && !(_mode == LoftMode.cut && widget.targetBodyCount == 0);

  void _emitChange() {
    final text = _thicknessController.text.trim();
    double? thickness;
    bool valid;
    if (text.isEmpty) {
      thickness = null;
      valid = true;
    } else {
      final value = double.tryParse(text);
      valid = value != null && value != 0;
      thickness = valid ? value : null;
    }
    setState(() => _thicknessValid = valid);
    if (valid) widget.onChanged(_mode, _ruled, thickness);
  }

  void _onModeChanged(LoftMode mode) {
    setState(() => _mode = mode);
    if (_thicknessValid) widget.onChanged(mode, _ruled, _currentThickness());
  }

  void _onRuledChanged(bool ruled) {
    setState(() => _ruled = ruled);
    if (_thicknessValid) widget.onChanged(_mode, ruled, _currentThickness());
  }

  double? _currentThickness() {
    final text = _thicknessController.text.trim();
    return text.isEmpty ? null : double.tryParse(text);
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
          SegmentedButton<LoftMode>(
            segments: const [
              ButtonSegment(
                value: LoftMode.boss,
                label: Text('Boss'),
                icon: SvgIcon('assets/icons/feature/feature_boss.svg'),
              ),
              ButtonSegment(
                value: LoftMode.cut,
                label: Text('Cut'),
                icon: SvgIcon('assets/icons/feature/feature_cut.svg'),
              ),
            ],
            selected: {_mode},
            onSelectionChanged: (selection) => _onModeChanged(selection.first),
          ),
          const SizedBox(height: 12),
          Text(
            'Sections: ${widget.sectionCount}',
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _thicknessController,
            keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
            decoration: const InputDecoration(
              labelText: 'Thickness (optional)',
              helperText: 'Leave blank to loft two closed profiles into a solid.'
                  ' Set a thickness to loft two open profiles into a thin shell.',
              helperMaxLines: 2,
            ),
            onChanged: (_) => _emitChange(),
          ),
          if (!_thicknessValid)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                'Thickness must be a nonzero number',
                style: TextStyle(color: Theme.of(context).colorScheme.error, fontSize: 12),
              ),
            ),
          const SizedBox(height: 8),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: const Text('Ruled'),
            subtitle: const Text('Straight-line transitions instead of a smooth blend'),
            value: _ruled,
            onChanged: _onRuledChanged,
          ),
          // Mirrors SweepPanel's own Cut target-body status line - picking
          // itself happens in the 3D viewport behind this panel, driven by
          // PartScreen, not by any field in here.
          if (_mode == LoftMode.cut)
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
              TextButton(
                  onPressed: widget.onCancel, child: const Text('Cancel')),
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
