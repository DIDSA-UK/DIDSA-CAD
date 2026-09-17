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
/// place.
///
/// Phase 11 (`docs/assembly-scope.md` §6 `[7]`): `custom` closes this file's
/// own previously-noted v1 UI limitation ("the backend accepts any vector,
/// but this panel only ever offers the three world axes") - selecting it
/// reveals a free X/Y/Z entry instead of snapping to a world axis. The
/// resolved vector for `custom` lives alongside it (`customDirection`/
/// `customAxisDirection` below), not in this enum itself - an enum variant
/// can't carry a mutable payload.
enum ComponentPatternAxisPreset { x, y, z, custom }

List<double> componentPatternAxisPresetVector(ComponentPatternAxisPreset preset) => switch (preset) {
      ComponentPatternAxisPreset.x => const [1.0, 0.0, 0.0],
      ComponentPatternAxisPreset.y => const [0.0, 1.0, 0.0],
      ComponentPatternAxisPreset.z => const [0.0, 0.0, 1.0],
      // The caller is expected to use its own tracked custom vector instead
      // of this function for `custom` - see [resolveComponentPatternVector].
      ComponentPatternAxisPreset.custom => const [1.0, 0.0, 0.0],
    };

/// The vector a panel field should actually send to the API for [preset] -
/// one of the three world axes, or [custom] verbatim when [preset] is
/// [ComponentPatternAxisPreset.custom]. The single place both
/// `_confirmComponentPattern`'s direction and axis-direction resolution
/// (`part_screen.dart`) go through, so neither ever has to re-derive this
/// `switch` itself.
List<double> resolveComponentPatternVector(ComponentPatternAxisPreset preset, List<double> custom) =>
    preset == ComponentPatternAxisPreset.custom ? custom : componentPatternAxisPresetVector(preset);

/// The inverse of [resolveComponentPatternVector] - what `part_screen.dart`'s
/// own `_openComponentPatternForEdit` uses to pick which segment an
/// already-authored `ComponentPattern`'s own stored `direction`/`axis.
/// direction` should highlight when the edit panel opens: exactly `x`/`y`/`z`
/// when `vector` matches that world axis (within floating-point tolerance -
/// a value round-tripped through JSON/the API is never bit-exact), `custom`
/// otherwise.
ComponentPatternAxisPreset presetForVector(List<double> vector) {
  bool closeTo(List<double> preset) {
    const tolerance = 1e-9;
    for (var i = 0; i < 3; i++) {
      if ((vector[i] - preset[i]).abs() > tolerance) return false;
    }
    return true;
  }

  if (closeTo(const [1.0, 0.0, 0.0])) return ComponentPatternAxisPreset.x;
  if (closeTo(const [0.0, 1.0, 0.0])) return ComponentPatternAxisPreset.y;
  if (closeTo(const [0.0, 0.0, 1.0])) return ComponentPatternAxisPreset.z;
  return ComponentPatternAxisPreset.custom;
}

/// Phase 7: the bottom-sheet-style panel `PartScreen` opens to author a
/// `ComponentPattern` for an already-selected source Occurrence - mirrors
/// `MatePanel`'s own plain-data-plus-callbacks shape (no entity picking is
/// needed here, unlike Mate's face/edge/vertex pick, so there is no
/// selected-entities list to show - only the numeric pattern parameters
/// themselves).
class ComponentPatternPanel extends StatelessWidget {
  final ComponentPatternMode mode;
  final ValueChanged<ComponentPatternMode> onModeChanged;

  /// Phase 11 (`docs/assembly-scope.md` §6 `[7]`): every source Occurrence
  /// this pattern repeats, shown as removable chips - the backend already
  /// accepts multiple `source_occurrence_ids` (Phase 7's own multi-source
  /// widening), only this panel's own authoring UI was ever limited to one.
  final List<String> sourceOccurrenceNames;
  final ValueChanged<int> onRemoveSource;

  /// Toggles "pick more sources" mode - while `true`, tapping a Components
  /// row in [AssemblyTreePanel] adds/removes that Occurrence from this
  /// pattern's own source list instead of the ordinary select/focus
  /// behavior (`part_screen.dart`'s own `_onOccurrenceTap`). Deliberately
  /// panel-local, not a general cross-app multi-select mechanism - see this
  /// file's own module-level framing.
  final bool pickingMoreSources;
  final ValueChanged<bool> onPickingMoreSourcesChanged;

  // Linear:
  final ComponentPatternAxisPreset direction;
  final ValueChanged<ComponentPatternAxisPreset> onDirectionChanged;
  final List<double> customDirection;
  final ValueChanged<List<double>> onCustomDirectionChanged;
  final int count;
  final ValueChanged<int> onCountChanged;
  final double spacing;
  final ValueChanged<double> onSpacingChanged;
  final bool reverse;
  final ValueChanged<bool> onReverseChanged;

  /// Bug report (assembly testing): "add option for second direction when
  /// patterning a component in an assembly (similar to pattern body or
  /// feature in a part)" - mirrors `PatternPanel.hasSecondDirection`'s own
  /// shape exactly, one level up (a free world-axis-preset vector instead
  /// of a live viewport edge/Sketch-Line pick - this panel's own Direction
  /// 1 already uses that same preset-button shape, see this class's own
  /// module doc comment on why). When false, every Direction-2-related
  /// field below is hidden entirely, same "optional, off by default"
  /// convention.
  final bool hasSecondDirection;
  final ValueChanged<bool> onSecondDirectionToggled;

  final ComponentPatternAxisPreset direction2;
  final ValueChanged<ComponentPatternAxisPreset> onDirection2Changed;
  final List<double> customDirection2;
  final ValueChanged<List<double>> onCustomDirection2Changed;
  final int count2;
  final ValueChanged<int> onCount2Changed;
  final double spacing2;
  final ValueChanged<double> onSpacing2Changed;
  final bool reverse2;
  final ValueChanged<bool> onReverse2Changed;

  // Circular:
  final List<double> axisOrigin;
  final ValueChanged<List<double>> onAxisOriginChanged;
  final ComponentPatternAxisPreset axisDirection;
  final ValueChanged<ComponentPatternAxisPreset> onAxisDirectionChanged;
  final List<double> customAxisDirection;
  final ValueChanged<List<double>> onCustomAxisDirectionChanged;
  final int countAngular;
  final ValueChanged<int> onCountAngularChanged;
  final double angleTotal;
  final ValueChanged<double> onAngleTotalChanged;
  final bool reverseAngular;
  final ValueChanged<bool> onReverseAngularChanged;

  /// Phase 11 (`docs/assembly-scope.md` §6 `[8]`): `null` for a new pattern
  /// (the create flow, unchanged), the pattern's own id when this panel is
  /// editing an already-authored one - swaps the title/confirm label only,
  /// `part_screen.dart`'s `_confirmComponentPattern` is what actually
  /// branches create vs. update.
  final String? editingPatternId;

  final bool saving;
  final String? error;

  final VoidCallback? onConfirm;
  final VoidCallback onCancel;

  const ComponentPatternPanel({
    super.key,
    required this.mode,
    required this.onModeChanged,
    required this.sourceOccurrenceNames,
    required this.onRemoveSource,
    required this.pickingMoreSources,
    required this.onPickingMoreSourcesChanged,
    required this.direction,
    required this.onDirectionChanged,
    required this.customDirection,
    required this.onCustomDirectionChanged,
    required this.count,
    required this.onCountChanged,
    required this.spacing,
    required this.onSpacingChanged,
    required this.reverse,
    required this.onReverseChanged,
    required this.hasSecondDirection,
    required this.onSecondDirectionToggled,
    required this.direction2,
    required this.onDirection2Changed,
    required this.customDirection2,
    required this.onCustomDirection2Changed,
    required this.count2,
    required this.onCount2Changed,
    required this.spacing2,
    required this.onSpacing2Changed,
    required this.reverse2,
    required this.onReverse2Changed,
    required this.axisOrigin,
    required this.onAxisOriginChanged,
    required this.axisDirection,
    required this.onAxisDirectionChanged,
    required this.customAxisDirection,
    required this.onCustomAxisDirectionChanged,
    required this.countAngular,
    required this.onCountAngularChanged,
    required this.angleTotal,
    required this.onAngleTotalChanged,
    required this.reverseAngular,
    required this.onReverseAngularChanged,
    this.editingPatternId,
    required this.saving,
    required this.error,
    required this.onConfirm,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    return ResizableToolPanel(
      title: editingPatternId == null ? 'Pattern Component' : 'Edit Pattern',
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _sourceChips(context),
          const SizedBox(height: 12),
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
              FilledButton(
                onPressed: saving ? null : onConfirm,
                child: Text(editingPatternId == null ? 'Confirm' : 'Save'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Phase 11 (`docs/assembly-scope.md` §6 `[7]`): one chip per current
  /// `sourceOccurrenceNames` entry (deletable, unless it's the only one left
  /// - `ComponentPatternCreate.source_occurrence_ids` requires at least one),
  /// plus an "Add source" toggle chip driving [pickingMoreSources].
  Widget _sourceChips(BuildContext context) {
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        const Text('Sources', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
        for (var i = 0; i < sourceOccurrenceNames.length; i++)
          Chip(
            label: Text(sourceOccurrenceNames[i], style: const TextStyle(fontSize: 12)),
            visualDensity: VisualDensity.compact,
            onDeleted: sourceOccurrenceNames.length > 1 ? () => onRemoveSource(i) : null,
          ),
        ChoiceChip(
          label: const Text('+ Add source', style: TextStyle(fontSize: 12)),
          visualDensity: VisualDensity.compact,
          selected: pickingMoreSources,
          onSelected: onPickingMoreSourcesChanged,
        ),
        if (pickingMoreSources)
          Text(
            'Tap a component in the tree to add it',
            style: TextStyle(fontSize: 11, color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
      ],
    );
  }

  List<Widget> _linearFields(BuildContext context) => [
        const Text('Direction', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        _axisPresetButtons(direction, onDirectionChanged),
        if (direction == ComponentPatternAxisPreset.custom) ...[
          const SizedBox(height: 8),
          _vectorFields(customDirection, onCustomDirectionChanged),
        ],
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
        const SizedBox(height: 8),
        if (hasSecondDirection) ...[
          const Divider(),
          const Text('Direction 2', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          _axisPresetButtons(direction2, onDirection2Changed),
          if (direction2 == ComponentPatternAxisPreset.custom) ...[
            const SizedBox(height: 8),
            _vectorFields(customDirection2, onCustomDirection2Changed, keyPrefix: 'direction2-'),
          ],
          const SizedBox(height: 8),
          _numberField(
            'Count',
            count2.toString(),
            (text) {
              final parsed = int.tryParse(text);
              if (parsed != null) onCount2Changed(parsed);
            },
            fieldKey: const ValueKey('component-pattern-field-direction2-Count'),
          ),
          const SizedBox(height: 8),
          _numberField(
            'Spacing (mm)',
            spacing2.toString(),
            (text) {
              final parsed = double.tryParse(text);
              if (parsed != null) onSpacing2Changed(parsed);
            },
            fieldKey: const ValueKey('component-pattern-field-direction2-Spacing (mm)'),
          ),
          CheckboxListTile(
            value: reverse2,
            onChanged: (checked) => onReverse2Changed(checked ?? false),
            title: const Text('Reverse'),
            controlAffinity: ListTileControlAffinity.leading,
            contentPadding: EdgeInsets.zero,
            dense: true,
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => onSecondDirectionToggled(false),
              icon: const Icon(Icons.remove_circle_outline),
              label: const Text('Remove second direction'),
            ),
          ),
        ] else
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => onSecondDirectionToggled(true),
              icon: const Icon(Icons.add),
              label: const Text('Add second direction'),
            ),
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
        if (axisDirection == ComponentPatternAxisPreset.custom) ...[
          const SizedBox(height: 8),
          _vectorFields(customAxisDirection, onCustomAxisDirectionChanged),
        ],
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
        ButtonSegment(value: ComponentPatternAxisPreset.custom, label: Text('Custom')),
      ],
      selected: {selected},
      onSelectionChanged: (selection) => onChanged(selection.first),
    );
  }

  /// Phase 11 (`docs/assembly-scope.md` §6 `[7]`): the free X/Y/Z entry
  /// [ComponentPatternAxisPreset.custom] reveals - mirrors [_circularFields]'
  /// own `axisOrigin` 3-field row exactly (same layout, same per-component
  /// `_numberField` reuse), just for a direction vector instead of a point.
  // Bug report (assembly testing): `keyPrefix` disambiguates Direction 2's
  // own X/Y/Z fields from Direction 1's identically-labeled ones - see
  // [_numberField]'s own `fieldKey` doc comment. Every pre-existing call
  // site leaves this at its default `''`, so its own keys stay exactly the
  // bare `X`/`Y`/`Z` ones they always were.
  Widget _vectorFields(List<double> vector, ValueChanged<List<double>> onChanged, {String keyPrefix = ''}) {
    return Row(
      children: [
        for (var i = 0; i < 3; i++) ...[
          if (i > 0) const SizedBox(width: 8),
          Expanded(
            child: _numberField(
              ['X', 'Y', 'Z'][i],
              vector[i].toString(),
              (text) {
                final parsed = double.tryParse(text);
                if (parsed == null) return;
                final updated = [...vector];
                updated[i] = parsed;
                onChanged(updated);
              },
              fieldKey: ValueKey('component-pattern-field-$keyPrefix${['X', 'Y', 'Z'][i]}'),
            ),
          ),
        ],
      ],
    );
  }

  // Bug report (assembly testing): `fieldKey` lets a caller override the
  // default `label`-derived key - needed once Direction 2's own "Count"/
  // "Spacing (mm)"/X/Y/Z fields could be mounted alongside Direction 1's
  // identically-labeled ones (both visible at once whenever
  // [hasSecondDirection] is true), which would otherwise collide (two
  // sibling widgets under the same [ValueKey] - Flutter rejects that).
  // Every pre-existing call site leaves this `null`, so its own key stays
  // exactly the bare `label`-derived one it always was.
  Widget _numberField(String label, String initialValue, ValueChanged<String> onChanged, {Key? fieldKey}) {
    return TextFormField(
      key: fieldKey ?? ValueKey('component-pattern-field-$label'),
      initialValue: initialValue,
      keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
      decoration: InputDecoration(labelText: label),
      onChanged: onChanged,
    );
  }
}
