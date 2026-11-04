/// The mate-completeness report for an AI-built assembly (`docs/ai-modelling/16-assembly-mates-gaps-plan.md`,
/// Phase 2): per component, whether the mates hold it fully, or what it can still do, next to the motion the plan
/// declared intended (`intended_motion`). Pure: the screen fetches `getConstraintStatus` and `listOccurrences` and
/// hands them in. The free motions come from the backend (`free_motions_for_member`), in each component's own part
/// frame, so the report speaks the same coordinates as the part plans and the `face_selector`s.
library;

import '../api/document_api_client.dart';
import 'ai_plan.dart';

/// One component's row. [state] is null when the backend could not resolve its mates (it leaves such an occurrence out
/// of the status map rather than guess).
class ComponentCompleteness {
  final String occurrenceId;
  final String name;
  final ConstraintState? state;
  final int dof;
  final List<FreeMotionDto> freeMotions;

  /// The plan's own words for why it may move, when it declared one.
  final String? intendedMotion;

  const ComponentCompleteness({
    required this.occurrenceId,
    required this.name,
    required this.state,
    required this.dof,
    required this.freeMotions,
    this.intendedMotion,
  });

  bool get isUnderConstrained => state == ConstraintState.underConstrained;

  /// Free to move and nobody said it should: what the follow-up turn is for.
  bool get isUnintendedlyFree => isUnderConstrained && intendedMotion == null;
}

class AssemblyCompletenessReport {
  final List<ComponentCompleteness> rows;

  const AssemblyCompletenessReport(this.rows);

  List<ComponentCompleteness> get unintendedlyFree => [for (final r in rows) if (r.isUnintendedlyFree) r];
  List<ComponentCompleteness> get overConstrained => [for (final r in rows) if (r.state == ConstraintState.overConstrained) r];

  /// A follow-up mates turn is worth sending: some component is free and not declared as meant to move.
  /// (An over-constrained component cannot be fixed by adding mates, so it never triggers one on its own.)
  bool get needsFollowUp => unintendedlyFree.isNotEmpty;

  /// Nothing to report but good news: every component fixed, fully constrained, or free on purpose.
  bool get isComplete =>
      rows.every((r) => r.state == ConstraintState.fixed || r.state == ConstraintState.fullyConstrained || (r.isUnderConstrained && r.intendedMotion != null));
}

/// The names a component can be called in an `intended_motion` entry: its real id, its `existing:<id>` form, its name
/// override, and its file name with and without the extension.
Iterable<String> _aliases(OccurrenceDto o) sync* {
  yield o.id;
  yield 'existing:${o.id}';
  final name = o.nameOverride;
  if (name != null) yield name;
  final ref = o.externalRef;
  if (ref != null) {
    yield ref;
    final file = ref.split(RegExp(r'[/\\]')).last;
    yield file;
    final dot = file.lastIndexOf('.');
    if (dot > 0) yield file.substring(0, dot);
  }
}

String occurrenceDisplayName(OccurrenceDto o) => o.nameOverride ?? o.externalRef ?? o.id;

/// Builds the report. [intended] entries name a component by real id, `existing:<id>`, or name (case-insensitive);
/// an entry that matches no component is ignored (the model may name something that is not there).
AssemblyCompletenessReport buildCompletenessReport({
  required List<OccurrenceDto> occurrences,
  required Map<String, ConstraintStatusDto> status,
  List<AiIntendedMotion> intended = const [],
}) {
  final intendedById = <String, String>{};
  for (final entry in intended) {
    final wanted = entry.component.trim().toLowerCase();
    for (final o in occurrences) {
      if (_aliases(o).any((a) => a.toLowerCase() == wanted)) {
        intendedById.putIfAbsent(o.id, () => entry.motion);
        break;
      }
    }
  }
  return AssemblyCompletenessReport([
    for (final o in occurrences)
      ComponentCompleteness(
        occurrenceId: o.id,
        name: occurrenceDisplayName(o),
        state: status[o.id]?.state,
        dof: status[o.id]?.dof ?? 0,
        freeMotions: status[o.id]?.freeMotions ?? const [],
        intendedMotion: intendedById[o.id],
      ),
  ]);
}

String _num(double v) {
  final text = v.toStringAsFixed(3);
  final trimmed = text.contains('.') ? text.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '') : text;
  return trimmed == '-0' ? '0' : trimmed;
}

String _vector(List<double> v) => '(${v.map(_num).join(', ')})';

/// `x`, `y` or `z` for a direction along a coordinate axis, else the vector.
String _axisName(List<double> v) {
  for (var i = 0; i < 3 && v.length == 3; i++) {
    if (v[i].abs() > 0.9999 && v[(i + 1) % 3].abs() < 1e-4 && v[(i + 2) % 3].abs() < 1e-4) return 'xyz'[i];
  }
  return _vector(v);
}

/// One free motion in words, in the component's own part frame: `slide along x`, `spin about z (through (7, 3, 0))`.
String describeFreeMotion(FreeMotionDto m) {
  switch (m.kind) {
    case 'slide':
      return 'slide along ${_axisName(m.direction ?? const [])}';
    case 'spin':
    case 'screw':
      final through = m.through;
      final nonOrigin = through != null && through.any((c) => c.abs() > 1e-6);
      final base = 'spin about ${_axisName(m.axis ?? const [])}${nonOrigin ? ' (through ${_vector(through)})' : ''}';
      return m.kind == 'screw' ? '${base.replaceFirst('spin', 'screw')}, ${_num(m.pitchPerTurn ?? 0)} per turn' : base;
  }
  return m.kind;
}

/// What one component can still do, or why there is nothing to say.
String describeComponentCompleteness(ComponentCompleteness c) {
  switch (c.state) {
    case null:
      return 'not checked (its mates could not be resolved)';
    case ConstraintState.fixed:
      return 'fixed';
    case ConstraintState.fullyConstrained:
      return 'fully constrained';
    case ConstraintState.overConstrained:
      return 'over-constrained (its mates contradict each other)';
    case ConstraintState.underConstrained:
      final intent = c.intendedMotion == null ? '' : ' (meant to move: "${c.intendedMotion}")';
      if (c.dof == 0) {
        return 'held against its neighbours but not to a fixed component, so the group can still move as a whole$intent';
      }
      if (c.freeMotions.isEmpty) return 'free to move (${c.dof} degrees of freedom)$intent';
      final motions = c.freeMotions.map(describeFreeMotion).join(', ');
      final lead = c.freeMotions.length == 1 ? 'free to $motions' : 'free to move: $motions (any mix)';
      return '$lead$intent';
  }
}

/// The per-component report as lines of text, for the progress panel. Every component gets a line when there are at
/// most [maxRows] of them; a larger assembly (a 36-component frame) lists only those that need attention - free,
/// over-constrained, unchecked - and counts the rest.
String formatCompletenessReport(AssemblyCompletenessReport report, {int maxRows = 12}) {
  bool held(ComponentCompleteness r) => r.state == ConstraintState.fixed || r.state == ConstraintState.fullyConstrained;
  final listAll = report.rows.length <= maxRows;
  final lines = [
    for (final r in report.rows)
      if (listAll || !held(r)) '- ${r.name}: ${describeComponentCompleteness(r)}',
  ];
  if (!listAll) {
    final heldCount = report.rows.where(held).length;
    lines.add('- $heldCount of ${report.rows.length} components are fixed or fully constrained.');
  }
  return lines.join('\n');
}

/// The components that can still move, as the follow-up mates turn lists them: `existing:<id> - name: free to ...`.
String formatFreeComponentsForPrompt(Iterable<ComponentCompleteness> rows) => [
      for (final r in rows) 'existing:${r.occurrenceId} - ${r.name}: ${describeComponentCompleteness(r)}',
    ].join('\n');
