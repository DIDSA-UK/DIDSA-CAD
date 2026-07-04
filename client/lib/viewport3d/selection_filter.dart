import 'package:flutter/foundation.dart';

/// Prompt A2: which selection-entity kinds the 3D viewport's hit-testing
/// (see `selection_hit_test.dart`'s `hitTestMeshEntities`) and its View
/// submenu toggles (see `PartToolbar`) should consider. `vertex`/`edge`/
/// `face` gate the existing vertex→edge→face hit-test priority hierarchy
/// directly; `body` exists so the toggle can be wired up now, but is
/// currently inert - there is no body-level hit-test yet (lands in Prompt
/// A3), so this field has no observable effect until then. Immutable value
/// type, same convention as `SelectionEntityRef` in `selection_hit_test.dart`.
@immutable
class SelectionFilterState {
  final bool vertex;
  final bool edge;
  final bool face;
  final bool body;

  /// Prompt C1: gate Sketch Points/Lines the same way `vertex`/`edge` gate
  /// Body vertices/edges - a separate pair rather than folding into
  /// `vertex`/`edge` themselves, since a Sketch entity and a Body sub-shape
  /// are different underlying things a picking mode may want to allow
  /// independently (e.g. C2's future "Point + Line only" mode).
  final bool sketchPoint;
  final bool sketchLine;

  const SelectionFilterState({
    required this.vertex,
    required this.edge,
    required this.face,
    required this.body,
    this.sketchPoint = true,
    this.sketchLine = true,
  });

  /// Matches hit-testing's behaviour from before this filter framework
  /// existed (vertex/edge/face always considered) - `body` starts off since
  /// there's nothing for it to do yet (see the class doc comment).
  /// `sketchPoint`/`sketchLine` start on, mirroring vertex/edge/face's own
  /// "always considered by default" precedent now that Sketch geometry is
  /// rendered and pickable in the 3D viewport (Prompt C1).
  static const defaults = SelectionFilterState(vertex: true, edge: true, face: true, body: false);

  SelectionFilterState copyWith({
    bool? vertex,
    bool? edge,
    bool? face,
    bool? body,
    bool? sketchPoint,
    bool? sketchLine,
  }) {
    return SelectionFilterState(
      vertex: vertex ?? this.vertex,
      edge: edge ?? this.edge,
      face: face ?? this.face,
      body: body ?? this.body,
      sketchPoint: sketchPoint ?? this.sketchPoint,
      sketchLine: sketchLine ?? this.sketchLine,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is SelectionFilterState &&
      other.vertex == vertex &&
      other.edge == edge &&
      other.face == face &&
      other.body == body &&
      other.sketchPoint == sketchPoint &&
      other.sketchLine == sketchLine;

  @override
  int get hashCode => Object.hash(vertex, edge, face, body, sketchPoint, sketchLine);

  @override
  String toString() =>
      'SelectionFilterState(vertex: $vertex, edge: $edge, face: $face, body: $body, '
      'sketchPoint: $sketchPoint, sketchLine: $sketchLine)';
}
