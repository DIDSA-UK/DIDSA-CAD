import 'package:flutter/material.dart';

import '../api/document_api_client.dart';
import 'resizable_tool_panel.dart';

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

  /// How many entities are currently selected (0, 1, or 2) - drives the
  /// guided-entry [ResizableToolPanel.tooltip], same "guide the user
  /// through picking" convention [FilletPanel.tooltip] already uses.
  final int selectedCount;

  final VoidCallback onDone;

  const MeasurementPanel({
    super.key,
    required this.result,
    required this.loading,
    required this.error,
    required this.selectedCount,
    required this.onDone,
  });

  String? get _tooltip => switch (selectedCount) {
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
