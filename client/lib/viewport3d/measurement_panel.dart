import 'package:flutter/material.dart';

import '../api/document_api_client.dart';
import 'resizable_tool_panel.dart';
import 'selection_hit_test.dart';
import 'svg_icon.dart';

/// Measure tool: the bottom-sheet-style panel [PartScreen] opens while
/// [PartScreen._measureActive] - structural clone of [FilletPanel] built on
/// the same [ResizableToolPanel] shell, minus any editable field: unlike
/// every other tool panel in this app, Measure never creates or mutates
/// anything, so there is no Confirm/Cancel split - just a read-only result
/// display and a single "Done" button that exits the tool.
class MeasurementPanel extends StatelessWidget {
  final MeasurementResultDto? result;
  final bool loading;
  final String? error;

  /// The vertex/edge/face entities currently selected for measurement (0,
  /// 1, or 2 - [PartScreen._measureSelectionFilter] only ever allows those
  /// three kinds). Bug report ("the list of selected entities should be
  /// visible in the measure tool so the user can see what's selected"):
  /// this used to arrive as a bare `selectedCount` int, so the panel could
  /// say *how many* things were picked but never *which* ones - listed
  /// below the guided-entry tooltip, same small per-row shape
  /// [SelectionListDrawer]/`showSelectOtherSheet` already use elsewhere.
  final Set<SelectionEntityRef> selectedEntities;

  /// Resolves a Body/Surface id to its display name for [_titleFor] - same
  /// `PartScreen._selectionBodyNames` map [SelectionListDrawer] is fed.
  final Map<String, String> bodyNames;

  final VoidCallback onDone;

  const MeasurementPanel({
    super.key,
    required this.result,
    required this.loading,
    required this.error,
    required this.selectedEntities,
    required this.bodyNames,
    required this.onDone,
  });

  String? get _tooltip => switch (selectedEntities.length) {
        0 => 'Select a vertex, edge, or face to measure',
        1 => 'Select a second entity to compare, or view this measurement alone',
        _ => null,
      };

  @override
  Widget build(BuildContext context) {
    return ResizableToolPanel(
      title: 'Measure',
      tooltip: _tooltip,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (selectedEntities.isNotEmpty) ..._selectionRows(context),
          if (loading) const Padding(padding: EdgeInsets.only(bottom: 8), child: LinearProgressIndicator()),
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(error!, style: TextStyle(color: Theme.of(context).colorScheme.error, fontSize: 13)),
            ),
          if (result != null) ..._resultRows(context, result!),
          if (result == null && error == null && !loading)
            Text(
              'No measurements yet',
              style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 12),
            ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [FilledButton(onPressed: onDone, child: const Text('Done'))],
          ),
        ],
      ),
    );
  }

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
        const SizedBox(height: 8),
      ];

  // Small private copy of SelectionListDrawer's/showSelectOtherSheet's own
  // `_iconFor`/`_labelFor`/`_titleFor` - same "lean subset, never shown
  // side by side" precedent select_other_sheet.dart's own copy already
  // documents, narrowed further here since Measure only ever selects
  // vertex/edge/face entities.
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
    return '$bodyName - ${_labelFor(entity.kind)} #${entity.id}';
  }

  /// Named two-entity results ([MeasurementResultDto.axisDistance]/
  /// [MeasurementResultDto.normalDistance]) are listed ahead of the generic
  /// [MeasurementResultDto.distance] fallback - both are always shown when
  /// present, never one instead of the other, since the generic distance
  /// remains a meaningful number (e.g. the gap between two coaxial
  /// cylindrical faces) even once a named relationship is also detected.
  List<Widget> _resultRows(BuildContext context, MeasurementResultDto r) {
    final rows = <Widget>[];
    void row(String label, String value) => rows.add(_ResultRow(label: label, value: value));

    if (r.length != null) row('Length', _fmt(r.length!));
    if (r.diameter != null) row('Diameter', _fmt(r.diameter!));
    if (r.radius != null) row('Radius', _fmt(r.radius!));
    if (r.area != null) row('Area', _fmt(r.area!));
    if (r.point != null) row('Point', _fmtVec(r.point!));

    if (r.axisDistance != null) row('Axis distance', _fmt(r.axisDistance!));
    if (r.normalDistance != null) row('Normal distance', _fmt(r.normalDistance!));
    if (r.distance != null) row('Distance', _fmt(r.distance!));
    if (r.delta != null) row('ΔX, ΔY, ΔZ', _fmtVec(r.delta!));

    return rows;
  }

  static String _fmt(double value) =>
      value == value.roundToDouble() ? value.toStringAsFixed(0) : value.toStringAsFixed(3);

  static String _fmtVec(List<double> v) => v.map(_fmt).join(', ');
}

class _ResultRow extends StatelessWidget {
  final String label;
  final String value;

  const _ResultRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Text(label, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 13)),
          const Spacer(),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
        ],
      ),
    );
  }
}
