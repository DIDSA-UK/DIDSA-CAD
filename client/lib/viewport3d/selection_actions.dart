import 'selection_hit_test.dart' show SelectionEntityKind, SelectionEntityRef;

/// One scaffolded operation offered by the Stage 23 context action panel
/// (Item 6) - [label] is shown on the button, [enabled] is always false for
/// now (no Chamfer/Fillet/Create Plane logic exists yet; wiring is a later
/// stage's job - see the `// TODO: wire up <action>` comment at each
/// button's callback site in `selection_context_panel.dart`).
class SelectionContextAction {
  final String label;
  final bool enabled;

  const SelectionContextAction(this.label, {this.enabled = false});

  @override
  bool operator ==(Object other) =>
      other is SelectionContextAction && other.label == label && other.enabled == enabled;

  @override
  int get hashCode => Object.hash(label, enabled);

  @override
  String toString() => 'SelectionContextAction($label)';
}

/// The Item 6 composition table: which scaffolded operations are offered for
/// a given selection, based purely on which [SelectionEntityKind]s it
/// contains - never on the entities' actual count or geometry. Labels for
/// mixed-kind combinations are static text describing the intended
/// operation, not dynamically computed from the selection.
List<SelectionContextAction> contextActionsFor(Set<SelectionEntityRef> selection) {
  if (selection.isEmpty) return const [];

  // Prompt A3: none of Create Plane/Chamfer/Fillet make sense against a
  // whole-Body selection - without this guard, a Body-only selection would
  // fall through every branch below to the final "alone" case and
  // nonsensically offer "Create Plane". Body selections don't compose with
  // vertex/edge/face ones in the same table below; this deliberately
  // suppresses every action rather than picking one arbitrarily.
  if (selection.any((s) => s.kind == SelectionEntityKind.body)) return const [];

  // Prompt C1: a selection made up of Sketch Point/Line entities doesn't
  // compose with this table's vertex/edge/face-based rules either - without
  // this guard, a lone sketchPoint (say) would fall through every branch
  // below to the final "alone" case and nonsensically offer "Create Plane",
  // since hasFace/hasEdge/hasVertex would all be false. Wiring the real
  // sketch-entity combos (e.g. Create Plane's "Normal to Line at Point") is
  // explicitly C2's job, not this prompt's - see its own scope doc.
  if (selection.any(
    (s) => s.kind == SelectionEntityKind.sketchPoint || s.kind == SelectionEntityKind.sketchLine,
  )) {
    return const [];
  }

  final hasFace = selection.any((s) => s.kind == SelectionEntityKind.face);
  final hasEdge = selection.any((s) => s.kind == SelectionEntityKind.edge);
  final hasVertex = selection.any((s) => s.kind == SelectionEntityKind.vertex);

  if (hasEdge && hasFace) {
    // Mixed edges+faces (any vertices too) - the full operation set.
    return const [
      SelectionContextAction('Create Plane'),
      SelectionContextAction('Chamfer'),
      SelectionContextAction('Fillet'),
    ];
  }
  if (hasEdge && hasVertex) {
    return const [SelectionContextAction('Create Plane (Normal to Edge Through Vertex)')];
  }
  if (hasFace && hasVertex) {
    return const [SelectionContextAction('Create Plane (Parallel to Face Through Vertex)')];
  }
  if (hasEdge) {
    return const [SelectionContextAction('Chamfer'), SelectionContextAction('Fillet')];
  }
  // hasFace || hasVertex, alone.
  return const [SelectionContextAction('Create Plane')];
}
