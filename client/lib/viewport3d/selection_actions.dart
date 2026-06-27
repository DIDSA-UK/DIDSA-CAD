import 'selection_hit_test.dart' show SelectionEntityKind, SelectionEntityRef;

/// One scaffolded operation offered by the Stage 23 context action panel
/// (Item 6) - [label] is shown on the button, [enabled] is always false for
/// now (no Chamfer/Fillet/Create Plane logic exists yet; wiring is a later
/// stage's job - see the `// TODO: wire up <action>` comment at each
/// button's callback site in `selection_context_panel.dart`).
class ContextAction {
  final String label;
  final bool enabled;

  const ContextAction(this.label, {this.enabled = false});

  @override
  bool operator ==(Object other) =>
      other is ContextAction && other.label == label && other.enabled == enabled;

  @override
  int get hashCode => Object.hash(label, enabled);

  @override
  String toString() => 'ContextAction($label)';
}

/// The Item 6 composition table: which scaffolded operations are offered for
/// a given selection, based purely on which [SelectionEntityKind]s it
/// contains - never on the entities' actual count or geometry. Labels for
/// mixed-kind combinations are static text describing the intended
/// operation, not dynamically computed from the selection.
List<ContextAction> contextActionsFor(Set<SelectionEntityRef> selection) {
  if (selection.isEmpty) return const [];

  final hasFace = selection.any((s) => s.kind == SelectionEntityKind.face);
  final hasEdge = selection.any((s) => s.kind == SelectionEntityKind.edge);
  final hasVertex = selection.any((s) => s.kind == SelectionEntityKind.vertex);

  if (hasEdge && hasFace) {
    // Mixed edges+faces (any vertices too) - the full operation set.
    return const [
      ContextAction('Create Plane'),
      ContextAction('Chamfer'),
      ContextAction('Fillet'),
    ];
  }
  if (hasEdge && hasVertex) {
    return const [ContextAction('Create Plane (Normal to Edge Through Vertex)')];
  }
  if (hasFace && hasVertex) {
    return const [ContextAction('Create Plane (Parallel to Face Through Vertex)')];
  }
  if (hasEdge) {
    return const [ContextAction('Chamfer'), ContextAction('Fillet')];
  }
  // hasFace || hasVertex, alone.
  return const [ContextAction('Create Plane')];
}
