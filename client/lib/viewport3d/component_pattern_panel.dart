import 'package:flutter/material.dart';

import 'resizable_tool_panel.dart';

/// Phase 7 (`docs/assembly-scope.md` §3 item 7 / §2j): Linear or Circular -
/// mirrors `PatternMode`'s own `apiValue`/`fromApiValue` str-enum
/// convention, matching the backend's `ComponentPatternType` string values
/// exactly. Named `linear`, not `rectangular` like the body-level
/// `PatternMode` - a `ComponentPattern` only ever repeats along one
/// direction (see that dataclass's own docstring for why).
enum ComponentPatternMode {
  linear,
  circular;

  String get apiValue => name;

  static ComponentPatternMode fromApiValue(String value) => ComponentPatternMode.values.firstWhere(
        (m) => m.apiValue == value,
        orElse: () => ComponentPatternMode.linear,
      );
}

/// One of the three world axes, for the direction/axis-direction quick-pick
/// buttons this panel uses instead of `pattern_panel.dart`'s own live
/// viewport edge/face/Sketch-Line picking - a `ComponentPattern`'s
/// direction/axis are free world-space vectors, never resolved from Body/
/// Sketch geometry (`ComponentPatternAxis`'s own docstring), so there is
/// nothing to tap in the viewport for this panel to drive in the first
/// place. A known v1 UI limitation (see `docs/assembly-scope.md` §2j): the
/// backend accepts any vector, but this panel only ever offers the three
/// world axes, never an arbitrary custom direction.
enum ComponentPatternAxisPreset { x, y, z }

List<double> componentPatternAxisPresetVector(ComponentPatternAxisPreset preset) => switch (preset) {
      ComponentPatternAxisPreset.x => const [1.0, 0.0, 0.0],
      ComponentPatternAxisPreset.y => const [0.0, 1.0, 0.0],
      ComponentPatternAxisPreset.z => const [0.0, 0.0, 1.0],
    };

/// Phase 7: the bottom-sheet-style panel `PartScreen` opens to author a
/// `ComponentPattern` for an already-selected source Occurrence - mirrors
/// `MatePanel`'s own plain-data-plus-callbacks shape (no entity picking is
/// needed here, unlike Mate's face/edge/vertex pick, so there is no
/// selected-entities list to show - only the numeric pattern parameters
/// themselves).
class ComponentPatternPanel extends StatelessWidget {
  final ComponentPatternMode mode;
  final ValueChanged<ComponentPatternMode> onModeChanged;

  // Linear:
  final ComponentPatternAxisPreset direction;
  final ValueChanged<ComponentPatternAxisPreset> onDirectionChanged;
  final int count;
  final ValueChanged<int> onCountChanged;
  final double spacing;
  final ValueChanged<double> onSpacingChanged;
  final bool reverse;
  final ValueChanged<bool> onReverseChanged;

  // Circular:
  final List<double> axisOrigin;
  final ValueChanged<List<double>> onAxisOriginChanged;
  final ComponentPatternAxisPreset axisDirection;
  final ValueChanged<ComponentPatternAxisPreset> onAxisDirectionChanged;
  final int countAngular;
  final ValueChanged<int> onCountAngularChanged;
  final double angleTotal;
  final ValueChanged<double> onAngleTotalChanged;
  final bool reverseAngular;
  final ValueChanged<bool> onReverseAngularChanged;

  final bool saving;
  final String? error;

  final VoidCallback? onConfirm;
  final VoidCallback onCancel;

  const ComponentPatternPanel({
    super.key,
    required this.mode,
    required this.onModeChanged,
    required this.direction,
    required this.onDirectionChanged,
    required this.count,
    required this.onCountChanged,
    required this.spacing,
    required this.onSpacingChanged,
    required this.reverse,
    required this.onReverseChanged,
    required this.axisOrigin,
    required this.onAxisOriginChanged,
    required this.axisDirection,
    required this.onAxisDirectionChanged,
    required this.countAngular,
    required this.onCountAngularChanged,
    required this.angleTotal,
    required this.onAngleTotalChanged,
    required this.reverseAngular,
    required this.onReverseAngularChanged,
    required this.saving,
    required this.error,
    required this.onConfirm,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    return ResizableToolPanel(
      title: 'Pattern Component',
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SegmentedButton<ComponentPatternMode>(
            segments: const [
              ButtonSegment(value: ComponentPatternMode.linear, label: Text('Linear')),
              ButtonSegment(value: ComponentPatternMode.circular, label: Text('Circular')),
            ],
            selected: {mode},
            onSelectionChanged: (selection) => onModeChanged(selection.first),
          ),
          const SizedBox(height: 12),
          if (mode == ComponentPatternMode.linear) ..._linearFields(context) else ..._circularFields(context),
          if (saving) const Padding(padding: EdgeInsets.only(top: 8), child: LinearProgressIndicator()),
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(error!, style: TextStyle(color: Theme.of(context).colorScheme.error, fontSize: 13)),
            ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(onPressed: saving ? null : onCancel, child: const Text('Cancel')),
              const SizedBox(width: 8),
              FilledButton(onPressed: saving ? null : onConfirm, child: const Text('Confirm')),
            ],
          ),
        ],
      ),
    );
  }

  List<Widget> _linearFields(BuildContext context) => [
        const Text('Direction', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        _axisPresetButtons(direction, onDirectionChanged),
        const SizedBox(height: 8),
        _numberField('Count', count.toString(), (text) {
          final parsed = int.tryParse(text);
          if (parsed != null) onCountChanged(parsed);
        }),
        const SizedBox(height: 8),
        _numberField('Spacing (mm)', spacing.toString(), (text) {
          final parsed = double.tryParse(text);
          if (parsed != null) onSpacingChanged(parsed);
        }),
        CheckboxListTile(
          value: reverse,
          onChanged: (checked) => onReverseChanged(checked ?? false),
          title: const Text('Reverse'),
          controlAffinity: ListTileControlAffinity.leading,
          contentPadding: EdgeInsets.zero,
          dense: true,
        ),
      ];

  List<Widget> _circularFields(BuildContext context) => [
        const Text('Axis origin', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        Row(
          children: [
            for (var i = 0; i < 3; i++) ...[
              if (i > 0) const SizedBox(width: 8),
              Expanded(
                child: _numberField(['X', 'Y', 'Z'][i], axisOrigin[i].toString(), (text) {
                  final parsed = double.tryParse(text);
                  if (parsed == null) return;
                  final updated = [...axisOrigin];
                  updated[i] = parsed;
                  onAxisOriginChanged(updated);
                }),
              ),
            ],
          ],
        ),
        const SizedBox(height: 8),
        const Text('Axis direction', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        _axisPresetButtons(axisDirection, onAxisDirectionChanged),
        const SizedBox(height: 8),
        _numberField('Instance count', countAngular.toString(), (text) {
          final parsed = int.tryParse(text);
          if (parsed != null) onCountAngularChanged(parsed);
        }),
        const SizedBox(height: 8),
        _numberField('Total angle (degrees)', angleTotal.toString(), (text) {
          final parsed = double.tryParse(text);
          if (parsed != null) onAngleTotalChanged(parsed);
        }),
        CheckboxListTile(
          value: reverseAngular,
          onChanged: (checked) => onReverseAngularChanged(checked ?? false),
          title: const Text('Reverse'),
          controlAffinity: ListTileControlAffinity.leading,
          contentPadding: EdgeInsets.zero,
          dense: true,
        ),
      ];

  Widget _axisPresetButtons(
    ComponentPatternAxisPreset selected,
    ValueChanged<ComponentPatternAxisPreset> onChanged,
  ) {
    return SegmentedButton<ComponentPatternAxisPreset>(
      segments: const [
        ButtonSegment(value: ComponentPatternAxisPreset.x, label: Text('X')),
        ButtonSegment(value: ComponentPatternAxisPreset.y, label: Text('Y')),
        ButtonSegment(value: ComponentPatternAxisPreset.z, label: Text('Z')),
      ],
      selected: {selected},
      onSelectionChanged: (selection) => onChanged(selection.first),
    );
  }

  Widget _numberField(String label, String initialValue, ValueChanged<String> onChanged) {
    return TextFormField(
      key: ValueKey('component-pattern-field-$label'),
      initialValue: initialValue,
      keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
      decoration: InputDecoration(labelText: label),
      onChanged: onChanged,
    );
  }
}
