import 'package:flutter/material.dart';

import 'resizable_tool_panel.dart';
import 'selection_hit_test.dart';
import 'svg_icon.dart';

/// Phase 6 (`docs/assembly-scope.md` §3): the five Mate types this app's
/// backend supports (`app.document.models.MateType`) - kept as a plain
/// `String` wire value directly (matching `MateDto.type`'s own shape)
/// rather than a Dart enum with its own to/from-wire mapping, since nothing
/// else client-side needs a richer type for this yet.
const List<String> kMateTypes = ['coincident', 'concentric', 'parallel', 'distance', 'angle'];

String mateTypeLabel(String type) => switch (type) {
      'coincident' => 'Coincident',
      'concentric' => 'Concentric',
      'parallel' => 'Parallel',
      'distance' => 'Distance',
      'angle' => 'Angle',
      _ => type,
    };

/// Whether [type] needs a numeric [MatePanel.value] - mirrors the backend's
/// own `_validate_mate_create` requirement (`distance`/`angle` reject a
/// missing `value` with a 422) exactly, so the Confirm button's own
/// `_canConfirm` never lets a request through the backend would reject
/// anyway.
bool mateTypeNeedsValue(String type) => type == 'distance' || type == 'angle';

/// Whether [type] has a meaningful `flipped` alignment choice -
/// `coincident`/`concentric` per `Mate.flipped`'s own docstring ("the
/// alignment flag COINCIDENT/CONCENTRIC mates need"), plus `angle` (this
/// app's own solver, `assembly_solver.py`, maps it to `addAngle`'s
/// `supplement` toggle - picking between an angle and its 180-degree
/// supplement, `py_slvs`'s own inherent ambiguity for that constraint).
/// `parallel`/`distance` ignore it - showing the toggle for those would
/// just be inert clutter.
bool mateTypeHasFlip(String type) => type == 'coincident' || type == 'concentric' || type == 'angle';

/// Phase 6: the bottom-sheet-style panel [PartScreen] opens while picking a
/// Mate's two references - structural clone of [FilletPanel]'s
/// Confirm/Cancel shape on the same [ResizableToolPanel] shell, with
/// [MeasurementPanel]'s own selected-entity list reused for showing which
/// two entities have been picked so far (0, 1, or 2 - [PartScreen.
/// _mateSelectionFilter] only ever allows vertex/edge/face entities,
/// including ones on a placed Occurrence via `hitTestComponentInstanceEntities`
/// - Phase 6a's own real prerequisite for this panel to exist at all).
class MatePanel extends StatelessWidget {
  final Set<SelectionEntityRef> selectedEntities;
  final Map<String, String> bodyNames;

  final String mateType;
  final double? value;
  final bool flipped;

  final ValueChanged<String> onMateTypeChanged;
  final ValueChanged<double?> onValueChanged;
  final ValueChanged<bool> onFlippedChanged;

  final bool saving;
  final String? error;

  final VoidCallback? onConfirm;
  final VoidCallback onCancel;

  const MatePanel({
    super.key,
    required this.selectedEntities,
    required this.bodyNames,
    required this.mateType,
    required this.value,
    required this.flipped,
    required this.onMateTypeChanged,
    required this.onValueChanged,
    required this.onFlippedChanged,
    required this.saving,
    required this.error,
    required this.onConfirm,
    required this.onCancel,
  });

  String? get _tooltip => switch (selectedEntities.length) {
        0 => 'Select a face, edge, or vertex for the first side of the mate',
        1 => 'Select a face, edge, or vertex for the second side of the mate',
        _ => null,
      };

  @override
  Widget build(BuildContext context) {
    return ResizableToolPanel(
      title: 'Add Mate',
      tooltip: _tooltip,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (selectedEntities.isNotEmpty) ..._selectionRows(context),
          const SizedBox(height: 8),
          DropdownButtonFormField<String>(
            initialValue: mateType,
            decoration: const InputDecoration(labelText: 'Mate type'),
            items: [
              for (final type in kMateTypes) DropdownMenuItem(value: type, child: Text(mateTypeLabel(type))),
            ],
            onChanged: (type) {
              if (type != null) onMateTypeChanged(type);
            },
          ),
          if (mateTypeNeedsValue(mateType)) ...[
            const SizedBox(height: 8),
            TextFormField(
              key: ValueKey('mate-value-$mateType'),
              initialValue: value?.toString() ?? '',
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(labelText: mateType == 'angle' ? 'Angle (degrees)' : 'Distance (mm)'),
              onChanged: (text) => onValueChanged(double.tryParse(text)),
            ),
          ],
          if (mateTypeHasFlip(mateType))
            CheckboxListTile(
              value: flipped,
              onChanged: (checked) => onFlippedChanged(checked ?? false),
              title: const Text('Flipped'),
              controlAffinity: ListTileControlAffinity.leading,
              contentPadding: EdgeInsets.zero,
              dense: true,
            ),
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

  // Same small private `_iconFor`/`_labelFor`/`_titleFor` subset
  // `measurement_panel.dart`'s own copy documents copying rather than
  // sharing - this one is narrower still (vertex/edge/face only, matching
  // `PartScreen._mateSelectionFilter`).
  List<Widget> _selectionRows(BuildContext context) => [
        for (final entity in selectedEntities)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              children: [
                SizedBox(width: 18, height: 18, child: _iconFor(entity.kind)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _titleFor(entity),
                    style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 13),
                  ),
                ),
              ],
            ),
          ),
      ];

  Widget _iconFor(SelectionEntityKind kind) => switch (kind) {
        SelectionEntityKind.face => const SvgIcon('assets/icons/viewport/selection_face.svg'),
        SelectionEntityKind.edge => const SvgIcon('assets/icons/viewport/selection_edge.svg'),
        SelectionEntityKind.vertex => const SvgIcon('assets/icons/viewport/selection_vertex.svg'),
        _ => const SizedBox.shrink(),
      };

  String _labelFor(SelectionEntityKind kind) => switch (kind) {
        SelectionEntityKind.face => 'Face',
        SelectionEntityKind.edge => 'Edge',
        SelectionEntityKind.vertex => 'Vertex',
        _ => 'Entity',
      };

  String _titleFor(SelectionEntityRef entity) {
    final bodyName = bodyNames[entity.bodyId] ?? 'Body';
    final owner = entity.occurrenceId.isEmpty ? bodyName : '$bodyName (component)';
    return '$owner - ${_labelFor(entity.kind)} #${entity.id}';
  }
}
