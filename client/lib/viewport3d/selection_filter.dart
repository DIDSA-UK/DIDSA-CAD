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

  /// On-device feedback: gates `SelectionEntityKind.sketchCircle` the same
  /// way `sketchLine` gates `SelectionEntityKind.sketchLine` - a separate
  /// field (not folded into `sketchLine`) since a picking mode may want a
  /// Sketch's Lines but not its Circles (e.g. Revolve's axis pick, which
  /// must stay a Line - see `PartScreen._revolveSelectionFilter`) or vice
  /// versa. Defaults to `true`, mirroring `sketchLine`'s own "always
  /// considered by default" precedent now that Circles are independently
  /// pickable (Prompt G follow-up).
  final bool sketchCircle;

  /// On-device feedback: gates `SelectionEntityKind.sketchArc`/
  /// `.sketchEllipse`/`.sketchSpline` the same way [sketchCircle] gates
  /// `.sketchCircle` - Circle selection shipped first, but Arc/Ellipse/
  /// Spline had no hit-testing at all until this same on-device round
  /// surfaced it (a Circle worked, its curved siblings silently didn't).
  /// All three default to `true`, same "always considered by default"
  /// precedent every other sketch-entity filter field already has.
  final bool sketchArc;
  final bool sketchEllipse;
  final bool sketchSpline;

  /// On-device feedback: gates both `SelectionEntityKind.referencePlane` and
  /// `.createPlane` hover/hit-testing (see `part_viewport.dart`'s
  /// `_hoverHitTestPlanes`) - a single field for both plane kinds, not a
  /// separate pair the way `vertex`/`edge`/`face` each get their own,
  /// since no picking mode so far has needed to tell them apart (C5's own
  /// `contextActionsFor` already treats them as one interchangeable
  /// "plane-like" category). Added after C5 shipped planes as a selectable
  /// kind with no filter field at all - every picking mode up to and
  /// including the "Add" FAB's Fillet entry, `PartScreen._filletSelectionFilter`,
  /// needs a real way to turn planes off, not just the mesh/sketch kinds
  /// above. Defaults to `true` (matches every plane being unconditionally
  /// hit-testable before this field existed) - no View-submenu toggle
  /// exists for this yet, same "wired up, no UI yet" precedent `body` once
  /// was before its own toggle shipped.
  final bool plane;

  const SelectionFilterState({
    required this.vertex,
    required this.edge,
    required this.face,
    required this.body,
    this.sketchPoint = true,
    this.sketchLine = true,
    this.sketchCircle = true,
    this.sketchArc = true,
    this.sketchEllipse = true,
    this.sketchSpline = true,
    this.plane = true,
  });

  /// Matches hit-testing's behaviour from before this filter framework
  /// existed (vertex/edge/face always considered) - `body` starts off since
  /// there's nothing for it to do yet (see the class doc comment).
  /// `sketchPoint`/`sketchLine` start on, mirroring vertex/edge/face's own
  /// "always considered by default" precedent now that Sketch geometry is
  /// rendered and pickable in the 3D viewport (Prompt C1). `plane` also
  /// starts on for the same reason.
  static const defaults = SelectionFilterState(vertex: true, edge: true, face: true, body: false);

  SelectionFilterState copyWith({
    bool? vertex,
    bool? edge,
    bool? face,
    bool? body,
    bool? sketchPoint,
    bool? sketchLine,
    bool? sketchCircle,
    bool? sketchArc,
    bool? sketchEllipse,
    bool? sketchSpline,
    bool? plane,
  }) {
    return SelectionFilterState(
      vertex: vertex ?? this.vertex,
      edge: edge ?? this.edge,
      face: face ?? this.face,
      body: body ?? this.body,
      sketchPoint: sketchPoint ?? this.sketchPoint,
      sketchLine: sketchLine ?? this.sketchLine,
      sketchCircle: sketchCircle ?? this.sketchCircle,
      sketchArc: sketchArc ?? this.sketchArc,
      sketchEllipse: sketchEllipse ?? this.sketchEllipse,
      sketchSpline: sketchSpline ?? this.sketchSpline,
      plane: plane ?? this.plane,
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
      other.sketchLine == sketchLine &&
      other.sketchCircle == sketchCircle &&
      other.sketchArc == sketchArc &&
      other.sketchEllipse == sketchEllipse &&
      other.sketchSpline == sketchSpline &&
      other.plane == plane;

  @override
  int get hashCode => Object.hash(
        vertex,
        edge,
        face,
        body,
        sketchPoint,
        sketchLine,
        sketchCircle,
        Object.hash(sketchArc, sketchEllipse, sketchSpline, plane),
      );

  @override
  String toString() =>
      'SelectionFilterState(vertex: $vertex, edge: $edge, face: $face, body: $body, '
      'sketchPoint: $sketchPoint, sketchLine: $sketchLine, sketchCircle: $sketchCircle, '
      'sketchArc: $sketchArc, sketchEllipse: $sketchEllipse, sketchSpline: $sketchSpline, plane: $plane)';
}
