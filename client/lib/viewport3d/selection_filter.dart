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

  /// Pattern/Mirror roadmap follow-up: gates `SelectionEntityKind.
  /// sketchEllipseArc` the same way [sketchArc] gates `.sketchArc` -
  /// EllipseArc had no 3D-viewport hit-testing at all until this round.
  /// Defaults to `true`, same "always considered by default" precedent
  /// every sibling `sketchXxx` field here already has.
  final bool sketchEllipseArc;
  final bool sketchSpline;

  /// 3D-viewport Text tool round: gates `SelectionEntityKind.sketchText`
  /// the same way [sketchSpline] gates `.sketchSpline` - Text glyph
  /// outlines were rendered in the embedded 3D sketcher but never had a
  /// hit-test/filter entry of their own (see `selection_hit_test.dart`'s
  /// own doc comment on the enum value). Defaults to `true`, same
  /// "always considered by default" precedent every sibling `sketchXxx`
  /// field above already has.
  final bool sketchText;

  /// On-device feedback ("the patterned circle under the cursor is not
  /// highlighted and will not select"): gates
  /// `SelectionEntityKind.sketchPatternMirrorInstance` the same way
  /// [sketchLine] gates `.sketchLine` - a committed Pattern/Mirror
  /// instance's own derived (ghost) geometry, hit-tested in the embedded
  /// 3D (Orbit View) sketch editor. Defaults to `false`, unlike every
  /// sibling `sketchXxx` field above (which default `true`) - a synthetic
  /// copy should only ever be a valid pick target in Select mode (mirrors
  /// `SketchController._patternMirrorEntityAt`'s own Select/Dimension-only
  /// mode gate on the 2D-canvas side exactly; `sketchLine`/`sketchCircle`/
  /// etc default on because every *other* picking mode - Offset, Trim,
  /// Convert, Dimension's own target pick - genuinely does want real
  /// geometry hit-testable, but none of them should ever resolve a
  /// synthetic copy as if it were one).
  final bool sketchPatternMirrorInstance;

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
    this.sketchEllipseArc = true,
    this.sketchSpline = true,
    this.sketchText = true,
    this.plane = true,
    this.sketchPatternMirrorInstance = false,
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
    bool? sketchEllipseArc,
    bool? sketchSpline,
    bool? sketchText,
    bool? plane,
    bool? sketchPatternMirrorInstance,
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
      sketchEllipseArc: sketchEllipseArc ?? this.sketchEllipseArc,
      sketchSpline: sketchSpline ?? this.sketchSpline,
      sketchText: sketchText ?? this.sketchText,
      plane: plane ?? this.plane,
      sketchPatternMirrorInstance: sketchPatternMirrorInstance ?? this.sketchPatternMirrorInstance,
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
      other.sketchEllipseArc == sketchEllipseArc &&
      other.sketchSpline == sketchSpline &&
      other.sketchText == sketchText &&
      other.plane == plane &&
      other.sketchPatternMirrorInstance == sketchPatternMirrorInstance;

  @override
  int get hashCode => Object.hash(
        vertex,
        edge,
        face,
        body,
        sketchPoint,
        sketchLine,
        sketchCircle,
        Object.hash(
          sketchArc,
          sketchEllipse,
          sketchEllipseArc,
          sketchSpline,
          sketchText,
          plane,
          sketchPatternMirrorInstance,
        ),
      );

  @override
  String toString() =>
      'SelectionFilterState(vertex: $vertex, edge: $edge, face: $face, body: $body, '
      'sketchPoint: $sketchPoint, sketchLine: $sketchLine, sketchCircle: $sketchCircle, '
      'sketchArc: $sketchArc, sketchEllipse: $sketchEllipse, sketchEllipseArc: $sketchEllipseArc, '
      'sketchSpline: $sketchSpline, '
      'sketchText: $sketchText, plane: $plane, '
      'sketchPatternMirrorInstance: $sketchPatternMirrorInstance)';
}
