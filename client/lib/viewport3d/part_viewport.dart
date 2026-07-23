import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_gpu/gpu.dart' as gpu;
import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart' as vm;

import '../api/document_api_client.dart';
import '../sketch/sketch_controller.dart'
    show
        ConstraintOverlayItem,
        ConstraintAngleDimensionItem,
        ConstraintLineDistanceDimensionItem,
        ConstraintLinearDimensionItem,
        ConstraintRadialDimensionItem;
import 'create_plane_geometry_3d.dart';
import 'mesh_geometry.dart';
import 'orbit_camera.dart';
import 'reference_planes.dart';
import 'render_mode.dart';
import 'scene_preferences.dart';
import 'screen_projection.dart';
import 'selection_filter.dart';
import 'selection_hit_test.dart';
import 'sketch_constraint_overlay.dart';
import 'sketch_geometry_3d.dart';
import 'sketch_orientation_indicator.dart';
import 'sketch_plane_hit_test.dart';
import 'svg_icon.dart';
import 'triad.dart';
import 'view_preferences.dart';

/// The Stage 7 3D viewport: renders [mesh] (the placeholder Part mesh from
/// `/document/parts/{id}/mesh`) via `flutter_scene`'s default Unlit
/// material - no custom shaders, wireframes, or cross-sections, per the
/// project brief. Orbit/pan/zoom gestures mirror [SketchCanvas]'s
/// mouse-vs-touch handling: left-drag/single-finger-drag orbits,
/// right-drag/two-finger-drag pans, scroll wheel/pinch zooms.
///
/// Also renders the three fixed reference planes (see [ReferencePlaneKind])
/// and an orientation triad, and turns a tap (as opposed to a drag - see
/// [_tapTravelThreshold]) into a [ReferencePlaneKind] hit-test: [onPlaneTap]
/// fires for a tap that lands on a rendered plane rectangle, [onBackgroundTap]
/// for one that doesn't. [selectedPlane] only affects which plane (if any) is
/// drawn brighter - [PartScreen] owns the actual selection state, the same
/// controlled-widget pattern [FeatureTreePanel] already uses for
/// [selectedFeatureId].
class PartViewport extends StatefulWidget {
  /// Prompt A3: one entry per independently-tessellated Body (Prompt A1's
  /// `/mesh` array) - was a single `MeshDto? mesh` before this. Callers
  /// (see [PartScreen]) should only build a new `List` instance when the
  /// content actually changes (see [didUpdateWidget]), the same contract
  /// [sketchGeometries] below already documents for its own `Map`.
  final List<BodyMeshDto> bodies;

  /// On-device feedback ("Show reference body button in the sketcher
  /// should now toggle visibility of all bodies on/off to show user a
  /// clear view of the sketch"): true suppresses every rendered mesh/edge
  /// Node [bodies] would otherwise produce (see [_syncMeshNode]/
  /// [_syncEdgesNode]'s own gates) - a purely visual toggle, [bodies]
  /// itself stays fully intact for everything else that still needs it
  /// (real-Body hit-testing via [preferEntityPick]/`hitTestBodies`, camera
  /// framing via `boundsOfBodies`), so Convert Entities/Dimension/Offset
  /// mode's own Body-edge picking keeps working while bodies are hidden.
  final bool bodiesHidden;

  final ReferencePlaneKind? selectedPlane;
  final void Function(ReferencePlaneKind plane) onPlaneTap;
  final VoidCallback onBackgroundTap;

  /// Per-Feature 3D Sketch geometry (Lines/Circles already projected onto
  /// their plane, see [SketchGeometry3D]), keyed by Feature id - callers
  /// should omit hidden Features' entries entirely rather than passing
  /// [SketchGeometry3D.empty], and should only build a new `Map` instance
  /// when the content actually changes (see [didUpdateWidget]), since a new
  /// instance triggers a full GPU geometry rebuild of every entry.
  final Map<String, SketchGeometry3D> sketchGeometries;

  /// P23 (2D-sketcher feature parity): per-entity constraint-status colour
  /// override, keyed by entity id (Point/Line/Circle/Arc/Ellipse/Spline id -
  /// see [buildSketchGeometryNode]'s own `entityColors` parameter, which
  /// this is passed straight through to for every entry in
  /// [sketchGeometries]). Empty (the default) renders every entity at
  /// [sketchLineColor], the pre-P23 behaviour - `part_screen.dart` leaves
  /// this unset deliberately (see [buildSketchGeometryNode]'s own doc
  /// comment for why); only `sketch_screen.dart`'s Orbit View opts in.
  final Map<String, vm.Vector4> sketchEntityColors;

  /// C2: per-Feature resolved Create Plane geometry (null values omitted by
  /// callers - a Plane whose reference is currently unresolvable has
  /// nothing to render, same convention [sketchGeometries] uses for a
  /// Feature with no geometry at all), keyed by Feature id. Same "only
  /// build a new Map instance on genuine change" contract as
  /// [sketchGeometries].
  final Map<String, ResolvedPlaneGeometry> createPlanes;

  /// C3: fired for a tap that lands on a rendered created-Plane quad (see
  /// [createPlanes]/[hitTestCreatePlanes]) - checked after [onPlaneTap]'s
  /// fixed reference planes in [_handleTap], so a created Plane that happens
  /// to overlap one of the three fixed planes never shadows it (reference
  /// planes keep first claim on a tap, same precedence they already had
  /// before created Planes existed).
  final void Function(String featureId)? onCreatePlaneTap;

  /// C3: which created Plane (if any) renders with [ResolvedPlaneGeometry]'s
  /// brighter "selected" tint - mirrors [selectedPlane]'s own
  /// controlled-widget pattern for the three fixed planes.
  final String? selectedCreatePlaneFeatureId;

  /// Sketcher restructure Phase 2: when non-null, a tap that misses every
  /// reference/created plane above is tested against this arbitrary plane
  /// (the current Sketch's own basis - fixed or custom alike) via
  /// [hitTestSketchPlane], firing [onSketchPlaneTap] with the resolved
  /// world-space hit point instead of falling through to [onBackgroundTap].
  /// Checked last (after the fixed/created-plane checks), but in practice
  /// mutually exclusive with them - a Sketch's own embedded viewport passes
  /// `referencePlanesHidden: true` and no [createPlanes].
  final SketchPlaneBasis? sketchPlaneBasis;

  /// Bug fix (on-device feedback: "the hit radius for selecting an entity
  /// should match the hit radius for dynamic highlight") - [worldPoint]'s
  /// own local screen-pixels-per-sketch-unit ratio, same convention and
  /// same reasoning as [onDrawCursorCommit]'s own doc comment (this is that
  /// callback's own sibling for the non-cursor tap path).
  final void Function(vm.Vector3 worldPoint, double? localPixelsPerUnit)? onSketchPlaneTap;

  /// P16: mirrors [selectionMode]'s own cursor/hover/commit shape (see the
  /// "Stage 23 Items 2/3" section below), retargeted from entity-hover to a
  /// continuous [sketchPlaneBasis] raycast - a single-finger drag moves
  /// [_cursorPosition] instead of orbiting, exactly like [selectionMode]
  /// already trades off. Mutually exclusive with [selectionMode] in
  /// practice (never both true at once); kept as its own bool rather than
  /// overloading [selectionMode] itself since that field's
  /// [SelectionFilterState]/[SelectedEntities] semantics don't apply here -
  /// same "one SketchMode, one exclusive PartViewport interaction mode"
  /// pattern P10/P12 already established. Requires [sketchPlaneBasis] to be
  /// non-null to resolve to anything (see [_recomputeDrawCursor]).
  final bool drawCursorMode;

  /// P16/P17: fired with the resolved sketch-plane world point every time
  /// the draw cursor moves while [drawCursorMode] is true (not just on
  /// commit) - drives the live ghost-preview [SketchScreen] builds on top of
  /// this in P17. Null result (cursor off the plane, or [sketchPlaneBasis]
  /// unset) simply isn't fired; the caller keeps showing its last ghost.
  final void Function(vm.Vector3 worldPoint)? onDrawCursorMoved;

  /// P16: fired instead of [onSketchPlaneTap] when a genuine tap (not a
  /// cursor drag - same travel-threshold disambiguation [_commitSelection]
  /// already uses) commits while [drawCursorMode] is true and the cursor is
  /// currently resolving to a point on [sketchPlaneBasis].
  ///
  /// Bug fix (on-device feedback: "the hit radius for selecting an entity
  /// should match the hit radius for dynamic highlight - it occurred when
  /// selecting entities after starting the dimension tool"): [worldPoint]'s
  /// own local screen-pixels-per-sketch-unit ratio (this State's own camera/
  /// viewport, resolved via the same "project a synthetic point 1 sketch-
  /// unit away, measure the screen distance" technique
  /// `sketch_constraint_overlay.dart`'s dimension painters already use - no
  /// single global ratio exists in a perspective 3D view), null if it fails
  /// to resolve. The caller ([SketchScreen]'s own handler) had no way to
  /// convert its own [SketchController.minTapHitRadiusPixels] into a
  /// sketch-unit hit radius at all, so it was calling
  /// [SketchController.handleCanvasTap] with no radius argument, silently
  /// falling back to that method's own tiny, un-zoom-scaled
  /// [SketchController.snapRadius] default - completely different from (and
  /// almost always much smaller than) the properly screen-scaled radius the
  /// mesh-hover-driven "dynamic highlight" the user sees while aiming
  /// actually uses, so a tap could visibly miss whatever was just
  /// highlighted.
  final void Function(vm.Vector3 worldPoint, double? localPixelsPerUnit)? onDrawCursorCommit;

  /// P30: overrides the [drawCursorMode] crosshair's own hover colour
  /// (green by default) - [SketchScreen] passes red instead while
  /// [drawCursorMode] is active for a mode other than genuinely drawing
  /// (currently just Trim/Extend, since [drawCursorMode]'s own gate
  /// widened to cover it too), mirroring `sketch_canvas.dart`'s own
  /// mode-tinted cursor convention (green only for `SketchMode.draw`, red
  /// for everything else it ever tints). Null (the default) keeps the
  /// pre-P30 plain green.
  final Color? drawCursorHoverColor;

  /// On-device feedback ("when I grab something to perform a drag, the
  /// cursor should disappear and it should feel like I'm now moving the
  /// entity around. after dropping the entity, the cursor should reappear
  /// at the drop location"): true while [SketchScreen]'s own drag-mode has
  /// something actually grabbed - hides the [drawCursorMode] crosshair
  /// entirely for as long as this is true, so the moving entity itself
  /// (not a separate reticle riding alongside it) is what visually reads
  /// as "being dragged". [_cursorPosition] itself keeps updating
  /// throughout regardless (it drives [SketchController.
  /// updateGrabbedPosition] via [onDrawCursorMoved]), so the crosshair
  /// simply reappears wherever it already is - the drop location - the
  /// next time this flips back to `false`, with no extra plumbing needed.
  final bool suppressDrawCursor;

  /// P17: the active draw tool's live ghost preview (see
  /// `SketchController.activeDrawGhost`/`ghostPolylines`), already
  /// tessellated and mapped into world space by the caller
  /// (`sketch_screen.dart`, via `sketchPointToWorld` - see
  /// [buildSketchGhostNode]'s own doc comment for why this widget never
  /// takes a `DrawGhost` directly). Separate from [sketchGeometries] (which
  /// only ever holds *committed* geometry) since the ghost is transient,
  /// rebuilt on every cursor move rather than only when a Sketch's real
  /// entities change. Empty (the default) renders no ghost node at all.
  final List<List<vm.Vector3>> drawGhostPolylines;

  /// P20 follow-up: overrides [drawGhostPolylines]' own rendered colour -
  /// null (the default) means "use `buildSketchGhostNode`'s own default".
  /// [SketchScreen] sets this to green while
  /// `SketchController.activeLineSnapAxis` is non-null (Line's own
  /// horizontal/vertical auto-snap recolor - a 2D-sketcher feature this
  /// brings to the 3D-embedded one), null otherwise.
  final vm.Vector4? drawGhostColor;

  /// P20 follow-up: a second, independent ghost-polyline list rendered with
  /// its own fainter style (see `sketchGhostGuideColor`) - currently only
  /// ever Polygon's circumscribed/inscribed guide circles (see
  /// `ghostGuidePolylines` in `sketch_controller.dart`), but generalized the
  /// same way [drawGhostPolylines] itself is (plain world-space polylines,
  /// no `DrawGhost` dependency) in case a later tool wants its own guide
  /// geometry too. Empty (the default) renders nothing.
  final List<List<vm.Vector3>> drawGhostGuidePolylines;

  /// P20 follow-up: the 3D-embedded counterpart to `sketch_canvas.dart`'s
  /// in-progress-anchor/snap-candidate/midpoint point emphasis - see
  /// [DrawIndicatorMarker]'s own doc comment for the full rationale.
  /// [SketchScreen] recomputes this every `SketchController` notification,
  /// same "rebuilt on every relevant change, not just committed-geometry
  /// changes" convention [drawGhostPolylines] itself already uses. Empty
  /// (the default) renders no indicator node at all.
  final List<DrawIndicatorMarker> drawIndicatorMarkers;

  /// P31 (2D-sketcher feature parity): every closed-profile loop's own
  /// sketch-local outline (see [SketchController.profileLoopOutline]) -
  /// mode-independent (unlike [drawIndicatorMarkers], visible in every mode
  /// the same way `sketch_canvas.dart`'s own `_paintClosedProfileFill` is,
  /// not just while a draw tool is active), so a profile ready to Extrude
  /// reads as "closed" no matter what's currently selected/being edited.
  /// Empty (the default) renders no fill node at all.
  final List<List<(double, double)>> profileFillOutlines;

  /// P31: every Point [SketchController.profileBranchPointIds] found -
  /// rendered via the same [DrawIndicatorMarker]/[buildDrawIndicatorsNode]
  /// machinery as [drawIndicatorMarkers], but kept as a separate prop/node
  /// since its visibility isn't draw-mode-gated the way that list is.
  /// Empty (the default) renders no marker node at all.
  final List<DrawIndicatorMarker> profileBranchMarkers;

  /// P32 (2D-sketcher feature parity): every visible constraint's own
  /// label/glyph/dimension overlay (see [SketchController.constraintOverlayItems]) -
  /// rendered as a screen-space billboard overlay via [ConstraintOverlay],
  /// same "live inside this State's own build, not externally driven"
  /// requirement [sketchOrientationBasis] already has (see
  /// [SketchOrientationIndicator]'s own doc comment for why). Only rendered
  /// while [sketchPlaneBasis] is also set - a constraint anchor is
  /// meaningless without a plane to resolve its sketch-local coordinates
  /// against. Empty (the default) renders no overlay at all.
  final List<ConstraintOverlayItem> constraintOverlayItems;

  /// P41 (on-device feedback: "I can't grab them or pick a ghost
  /// dimension"): while true, [_commitDrawCursor] checks [constraintOverlayItems]'
  /// own rendered labels for a hit *before* resolving the ordinary
  /// [onDrawCursorCommit] world-point commit - mirrors `sketch_canvas.dart`'s
  /// own `_dispatchTap`/`_handleDragModeTap`, which only intercept a tap for
  /// a ghost/constraint-label hit while in [SketchMode.dimension] or drag
  /// mode respectively, never during ordinary drawing/selecting (a tap
  /// landing near an existing dimension must never block placing new
  /// geometry there). The caller ([SketchScreen]) computes this the same
  /// way, from its own [SketchController.mode]/drag-mode state.
  final bool preferConstraintOverlayHitOnCommit;

  /// P41: fired instead of [onDrawCursorCommit] when
  /// [preferConstraintOverlayHitOnCommit] is true and the commit lands on
  /// one of [constraintOverlayItems]' own rendered labels - `hitConstraintId`
  /// is that item's own [ConstraintOverlayItem.constraintId] (a live
  /// Constraint id or a [SketchController.ghosts] key, the caller's own job
  /// to tell apart - see [constraintOverlayItemAt]'s own doc comment), or
  /// null if [preferConstraintOverlayHitOnCommit] was on but the tap missed
  /// every label. Returns whether the tap was actually consumed (true skips
  /// the ordinary [onDrawCursorCommit] fallback entirely, matching
  /// `_dispatchTap`'s own "activeGhostKey set, tap misses everything -
  /// cancel the edit, still don't fall through to placing geometry"
  /// behaviour) - false (including when this callback is itself null) lets
  /// [onDrawCursorCommit] fire normally.
  final bool Function(String? hitConstraintId)? onConstraintOverlayItemTap;

  /// P41: while true, [_handleDrawCursorMove] feeds its own raw screen
  /// delta to [onConstraintLabelDragDelta] instead of resolving/reporting a
  /// world-plane hit - mirrors `sketch_canvas.dart`'s own
  /// `_feedMouseSwipeToGrabbedEntity`'s "a grabbed label's offset lives in
  /// screen space, not an absolute cursor position" branch exactly (see
  /// [SketchController.updateLabelDrag]'s own doc comment for why). The
  /// caller computes this from [SketchController.draggingLabelId] - dropping
  /// the grabbed label again is already handled entirely by the existing
  /// [onDrawCursorCommit]/drag-mode-commit path via
  /// [SketchController.dropGrabbedEntity] (already routes to
  /// [SketchController.endLabelDrag] on its own), so no separate "stop
  /// dragging a label" plumbing was needed here.
  final bool isDraggingConstraintLabel;

  /// P41: fired with this State's own already-sensitivity-scaled screen
  /// delta while [isDraggingConstraintLabel] is true, in place of
  /// [onDrawCursorMoved].
  final void Function(Offset delta)? onConstraintLabelDragDelta;

  /// P44f bug fix (on-device feedback: "the arrow should remain at the
  /// same angular position when orbiting" - a radial dimension's leader
  /// visibly drifted to a different point on the circle purely from
  /// orbiting the camera, without ever dragging again): [constraintOverlayItems]'
  /// own `constraintId` of whichever label is currently being dragged (the
  /// caller's own [SketchController.draggingLabelId]) - only needed so
  /// [_handleDrawCursorMove] can look the item back up (to check whether
  /// it's a radial dimension, which needs angle-based rather than
  /// pixel-delta-based drag handling - see [onRadialLabelAngleDragged]'s
  /// own doc comment for why). Null whenever [isDraggingConstraintLabel]
  /// is false.
  final String? draggingConstraintLabelId;

  /// P44f: fired in place of [onConstraintLabelDragDelta] whenever the
  /// entry [draggingConstraintLabelId] resolves to (in [constraintOverlayItems])
  /// is a [ConstraintRadialDimensionItem] - a screen-pixel delta
  /// ([onConstraintLabelDragDelta]'s own convention) is camera-frame
  /// dependent, so persisting *that* for a radial dimension's leader angle
  /// means the very next orbit re-interprets the same stored pixels
  /// through a different camera orientation and resolves to a different
  /// point on the circle (see [SketchController.setRadialAngleOffset]'s
  /// own doc comment). This fires with the resolved absolute angle
  /// instead (via [radialDimensionAngleDegrees], using this State's own
  /// live camera/projection - the one piece of context only [PartViewport]
  /// itself has), for the caller to persist directly, camera-independent.
  final void Function(double angleDegrees)? onRadialLabelAngleDragged;

  /// Bug fix (on-device feedback: "radius and diameter dimensions are
  /// locked a set distance from the arc or circle - I should be able to
  /// move them anywhere"): [onRadialLabelAngleDragged]'s own sibling for a
  /// radial dimension's *distance* from the circle - fires alongside it
  /// whenever [draggingConstraintLabelId] resolves to a
  /// [ConstraintRadialDimensionItem], with the resolved sketch-unit
  /// distance beyond the circle's rim, for the caller to persist via
  /// [SketchController.setRadialLegLength].
  final void Function(double legLength)? onRadialLabelDistanceDragged;

  /// P52 bug fix (on-device feedback: "when orbiting, linear dimensions
  /// slide along the line. they should stay in the same place on the
  /// line"), [onRadialLabelAngleDragged]'s exact sibling for a
  /// [ConstraintLinearDimensionItem]: fired in place of
  /// [onConstraintLabelDragDelta] whenever [draggingConstraintLabelId]
  /// resolves to one. Unlike radial's angle (which needs a screen-space
  /// resolve, see that field's own doc comment), a linear dimension's
  /// perpendicular offset is directly computable in sketch-local space with
  /// no camera-frame math at all - this State raycasts the live cursor
  /// onto [sketchPlaneBasis] (the same plane every other cursor-mode pick
  /// already uses) and reports the resulting sketch-unit perpendicular
  /// distance from the dimensioned line, for the caller to persist via
  /// [SketchController.setLinearOffsetDistance].
  final void Function(double distance)? onLinearLabelOffsetDragged;

  /// [onLinearLabelOffsetDragged]'s exact sibling for a
  /// [ConstraintLineDistanceDimensionItem] (a Line-to-Line perpendicular
  /// distance) - previously missing entirely, so this dimension kind fell
  /// through to the raw-pixel [onConstraintLabelDragDelta] path and visibly
  /// drifted on camera orbit despite already carrying a camera-independent
  /// `sketchLocalOffsetDistance` field with nothing to feed it.
  final void Function(double distance)? onLineDistanceLabelOffsetDragged;

  /// Bug fix (on-device feedback: "the dimension...is restricted in
  /// movement. it moves left right. it can't be moved up down"):
  /// [onLineDistanceLabelOffsetDragged]'s own sibling for the label's
  /// position *along the dimension line itself* (the axis
  /// [onLineDistanceLabelOffsetDragged] doesn't cover) - fires alongside it
  /// whenever [draggingConstraintLabelId] resolves to a
  /// [ConstraintLineDistanceDimensionItem], for the caller to persist via
  /// [SketchController.setLineDistanceAlongOffset].
  final void Function(double along)? onLineDistanceLabelAlongDragged;

  /// Bug fix (on-device feedback: "dimensions should match technical
  /// drawing conventions" - an angle dimension used to be a plain floating
  /// text chip with no way to place it): fires in place of
  /// [onConstraintLabelDragDelta] whenever [draggingConstraintLabelId]
  /// resolves to a [ConstraintAngleDimensionItem], with the resolved
  /// sketch-unit arc radius (distance from the implied vertex), for the
  /// caller to persist via [SketchController.setAngleArcRadius].
  final void Function(double radius)? onAngleLabelRadiusDragged;

  /// P44b bug fix (on-device feedback: "when I click a ghost dimension to
  /// set its value, nothing happens"): the [constraintOverlayItems] entry
  /// this many-ID-spaces-removed caller currently wants a value-entry
  /// widget anchored to - a live `SketchController.activeGhostKey`, the
  /// same id [onConstraintOverlayItemTap] already reports back on tap.
  /// `sketch_canvas.dart`'s own flat 2D view has always rendered its own
  /// inline `_GhostValueEditor` the moment a ghost activates; the embedded
  /// Orbit View never had an equivalent at all - tapping a ghost here
  /// successfully called `SketchController.tapGhost` (so the ghost *did*
  /// highlight as active), but nothing ever appeared for the user to type
  /// a value into, which is exactly "the click doesn't register" from the
  /// user's own perspective. Both this and
  /// [activeConstraintOverlayItemBuilder] are null (the default) whenever
  /// nothing is active.
  final String? activeConstraintOverlayItemId;

  /// P44b: builds the value-entry widget for whichever
  /// [constraintOverlayItems] entry matches [activeConstraintOverlayItemId],
  /// given that item's own live screen-space anchor (this State's own
  /// [_camera]/[_viewportSize]/[sketchPlaneBasis], resolved the exact same
  /// way [_commitDrawCursor]'s own hit-test already does via
  /// [constraintOverlayItemLabelCenter] - kept a caller-supplied builder,
  /// not a hardcoded widget, so this generic 3D viewport stays unaware of
  /// `SketchController`/`DimensionGhost` specifics (confirm/cancel/current-
  /// value semantics) - mirrors [onConstraintOverlayItemTap]'s own
  /// delegate-everything-back-to-the-caller shape. The returned widget is
  /// expected to position itself (e.g. via [Positioned]) using the anchor
  /// it's given, the same convention `_GhostValueEditor` already follows.
  final Widget Function(Offset anchor)? activeConstraintOverlayItemBuilder;

  /// P8: colour/opacity of [sketchPlaneBasis]'s own rendered surface (see
  /// [buildSketchPlaneSurfaceNode]) - only rendered while [sketchPlaneBasis]
  /// is non-null. Unlike [bodyColourHex]/[bodyOpacity], there's no separate
  /// visibility flag - dialing [sketchPlaneSurfaceOpacity] to 0 already
  /// hides it, the same convention [bodyOpacity] itself uses.
  final String sketchPlaneSurfaceColourHex;
  final double sketchPlaneSurfaceOpacity;

  /// P9: grid lines across [sketchPlaneBasis] (see [buildSketchGridNode]) -
  /// only rendered while [sketchPlaneBasis] is non-null.
  final bool sketchPlaneGridVisible;

  /// P10: gates a new priority tier ahead of [sketchPlaneBasis]'s own plane
  /// hit, inside [_handleTap] - a tap that would otherwise place new
  /// geometry on the plane instead first checks for a real Body
  /// vertex/edge, for tools (starting with Dimension) that want to
  /// reference existing geometry rather than draw new geometry. Only
  /// meaningful while [sketchPlaneBasis] is also set; [SketchScreen]
  /// computes this from the active [SketchController.mode].
  final bool preferEntityPick;

  /// On-device feedback ("selecting a face brings in all the face edges as
  /// lines"): widens [preferEntityPick]'s own real-Body hit test to also
  /// consider a Face, not just vertex/edge - false (the pre-existing
  /// default) for every mode except Convert Entities, since a Face was
  /// never a meaningful pick target for Dimension mode (no
  /// `pickReferenceGhostFace`-equivalent exists there) - see
  /// [_handleTap]/[_commitDrawCursor]'s own `hitTestBodies` filter
  /// construction for exactly where this plugs in.
  final bool preferEntityPickIncludesFace;

  /// P10: fired instead of [onSketchPlaneTap] when [preferEntityPick] is
  /// true and the tap resolves to a real Body vertex/edge (via
  /// [hitTestBodies]) rather than landing near an existing Sketch entity
  /// (checked first via [hasEntityNearSketchTap] - a direct tap on the
  /// Sketch's own geometry always wins, mirroring the flat 2D canvas's own
  /// existing Dimension-mode priority order in `sketch_canvas.dart`'s
  /// `_dispatchTap`). The caller is expected to materialize the picked
  /// entity (see `SketchController.pickReferenceGhostVertex`/
  /// `pickReferenceGhostEdge`).
  final void Function(SelectionEntityRef entity)? onSketchEntityTap;

  /// P10: mirrors `SketchController.hasEntityNear` via callback, since this
  /// widget has no dependency on `sketch_controller.dart` - the same
  /// "backend-shaped predicate injected as a callback" pattern
  /// [sketchLineLoopGroup] already uses. Only consulted when
  /// [preferEntityPick] is true.
  final bool Function(double x, double y)? hasEntityNearSketchTap;

  /// True while [bodies] is an Extrude live preview (see [PartScreen]'s
  /// debounced create/update-then-refetch flow) rather than confirmed
  /// geometry - renders the mesh translucent and tinted so a preview solid
  /// is never mistaken for the Part's actual, saved shape.
  final bool isPreviewMesh;

  /// On-device feedback: a *per-Body* alternative to [isPreviewMesh] for
  /// Fillet (and, later, Chamfer - same mechanism; see
  /// `docs/live-preview-pattern.md` for the full decision tree on which of
  /// these two fields a new Feature type should use, and exactly what to
  /// mirror) - these two fields are already generic/reusable as-is, not
  /// Fillet-specific despite the name - a new Feature type wires its own
  /// preview body/mesh straight through the same pair, no `PartViewport`
  /// changes needed. [bodies] itself must stay the stable, *pre*-operation
  /// mesh for the whole live-edit session (hit-testing/edge-picking needs
  /// edge ids that
  /// never move out from under the user - see the "missing_reference"
  /// bug fix this follows), but the operation's actual current effect
  /// still needs to be *visible* somewhere, or the radius/edge-selection
  /// panel has no visual feedback at all. When [previewOverlayMesh] is
  /// non-null, [_syncMeshNode]/[_syncEdgesNode] substitute it (rendered
  /// with the same translucent tint [isPreviewMesh] uses) for the one Body
  /// in [bodies] whose id equals [previewOverlayBodyId] - every other Body,
  /// and [bodies] itself for hit-testing/selection purposes, is completely
  /// unaffected.
  final String? previewOverlayBodyId;
  final MeshDto? previewOverlayMesh;

  /// Stage 10b: globally hides all three reference planes - both their
  /// rendered geometry and their [onPlaneTap] hit-testing, so a tap where a
  /// hidden plane would be falls through to [onBackgroundTap] instead of
  /// silently selecting an invisible target. [PartScreen] owns the toggle
  /// (via [PartToolbar]'s "Hide/Show Reference Planes" entry), the same
  /// controlled-widget pattern [selectedPlane] already uses.
  final bool referencePlanesHidden;

  /// Stage 11: which of [ViewportRenderMode]'s three display modes is
  /// currently active - controls whether [bodies]' filled faces are drawn
  /// at all ([ViewportRenderMode.showsFilledFaces]) and whether their real
  /// OCCT edge polylines are drawn on top ([ViewportRenderMode.showsEdges]).
  /// [PartScreen] owns this, the same controlled-widget pattern
  /// [referencePlanesHidden] already uses.
  final ViewportRenderMode renderMode;

  /// Stage 18: the 3D viewport's appearance preferences (see
  /// [ViewPreferences]) - [PartScreen] owns these, the same controlled-
  /// widget pattern [renderMode] already uses. [bgColourHex] repaints the
  /// canvas background every frame (see [_ScenePainter.paint]); [bodyColourHex]/
  /// [bodyOpacity] only take effect on the next [_syncMeshNode] rebuild
  /// (see [didUpdateWidget]), since they're baked into each Body's [Node]
  /// material rather than read per-frame.
  final String bgColourHex;
  final String bodyColourHex;
  final double bodyOpacity;

  /// The `PhysicallyBasedMaterial`/lighting upgrade's own controls (see
  /// `ScenePreferences`) - same controlled-widget/next-rebuild-only
  /// convention as [bodyColourHex]/[bodyOpacity] just above for
  /// [roughness]/[emissiveIntensity] (baked into each Body's material);
  /// [lightIntensity] instead drives the single Scene-wide
  /// `Scene.directionalLight`, reapplied whenever it changes (see
  /// [didUpdateWidget]) rather than per Body.
  final double roughness;
  final double lightIntensity;
  final double emissiveIntensity;

  /// Stage 23: true while the viewport is in selection mode (as opposed to
  /// the default orbit mode) - [PartScreen] owns the toggle. Per Item 7 of
  /// the brief, this only ever gates the *new* cursor/hover/selection
  /// dispatch added below; it never alters what the existing orbit gesture
  /// handlers (`_handlePointerDown`/`_handlePointerMove`/`_handlePointerEnd`)
  /// do.
  final bool selectionMode;

  /// The currently-selected entities (Item 4/5) - [PartScreen] owns this set
  /// and decides add/remove-toggle semantics in [onSelectionToggle]; this
  /// widget only renders it (see [_syncSelectedEntityNodes]).
  final Set<SelectionEntityRef> selectedEntities;

  /// Fired when a tap (Fix 4) commits a non-empty hover hit - the caller
  /// (see [PartScreen]) decides whether this adds or removes the entity
  /// from [selectedEntities] (Item 4's toggle rule).
  final void Function(SelectionEntityRef entity)? onSelectionToggle;

  /// Fired when a tap (Fix 4) commits while the cursor is over empty space -
  /// Item 4's "clears entire selection set" rule.
  final VoidCallback? onClearSelection;

  /// P25 (2D-sketcher feature parity): the 3D-embedded counterpart of
  /// `sketch_canvas.dart`'s own long-press-then-drag marquee-select. Fired
  /// once the marquee gesture ends with a sketch-space bounding [Rect] -
  /// both corners are resolved via [hitTestSketchPlane] against
  /// [sketchPlaneBasis] (this widget's only concept of "the sketch's own 2D
  /// coordinate space" - see [_endMarquee]'s own doc comment for why an
  /// axis-aligned sketch-space bounding box, not a screen-space one, is
  /// what's produced), then converted with [worldPointToSketch] - the
  /// caller (`sketch_screen.dart`) is expected to feed this straight into
  /// [SketchController.selectInRect], the exact method
  /// `sketch_canvas.dart`'s own marquee already uses. Requires
  /// [sketchPlaneBasis] to resolve to anything (a marquee whose corners
  /// both miss the plane fires nothing). Only engages while [selectionMode]
  /// is true.
  final void Function(Rect sketchRect)? onMarqueeSelect;

  /// Prompt A2: which entity kinds [_recomputeHover] considers - [PartScreen]
  /// owns this (its View submenu toggles write it, plus any future
  /// push/pop override - see `OverrideStack`), same controlled-widget
  /// pattern [selectionMode] already uses.
  final SelectionFilterState selectionFilter;

  /// A4: true = perspective; false = orthographic (default). Passed to
  /// [OrbitCamera.isPerspective]; see [OrbitCamera.cameraFor] for the
  /// flutter_scene limitation note.
  final bool isPerspective;

  /// A3: far clip override from the View menu slider or the recentre auto-fit
  /// result - null means "let the camera's own setZoomBoundsForRadius manage
  /// it" (i.e. on cold start, before the user opens the slider or recentres).
  final double? farClip;

  /// A3: fired by the recentre button's auto-fit computation so [PartScreen]
  /// can update its slider to the new value.
  final void Function(double farClip)? onFarClipChanged;

  /// Prompt G: when non-null, expands a hovered `sketchLine` entity's
  /// highlight from "just this one Line" to every Line/Circle entity
  /// sharing a closed-loop profile with it - the profile-picking flow's
  /// "hover any line in a loop, the whole loop lights up" convenience,
  /// mirroring [PartScreen]'s existing "tap a face, select its whole
  /// boundary edge loop" convenience for Fillet/Chamfer, just at hover time
  /// rather than only on toggle. [PartScreen] owns the actual profile-loop
  /// data (fetched from the Sketch's Profile-detection response) and
  /// resolves the lookup; this widget stays opaque to what a "loop" even is,
  /// same "backend-shaped predicate injected as a callback" pattern
  /// `selection_actions.dart`'s `PointOnLineChecker` already uses. Returns
  /// the full set of `sketchEntityId`s sharing a loop with [sketchEntityId]
  /// (always including it itself), or null to fall back to the ordinary
  /// single-entity hover highlight (every other mode). Only ever consulted
  /// for the *hover* highlight ([_buildEntityHighlightNode] via
  /// [_syncHoverNode]) - the *selected* (picked) highlight already shows
  /// every constituent entity because [PartScreen] adds all of a picked
  /// loop's entities into [selectedEntities] at once (see
  /// [PartScreen._toggleProfileLoop]), needing no expansion here.
  final Set<String>? Function(String sketchFeatureId, String sketchEntityId)? sketchLineLoopGroup;

  /// If set, the [OrbitCamera]'s starting orientation faces this plane
  /// exactly (via [orientationFacingPlane]) instead of [OrbitCamera]'s own
  /// angled default - read once, in [PartViewportState.initState]. Used by
  /// [SketchScreen]'s Orbit View toggle so entering it from the flat 2D
  /// sketch canvas never visibly jumps the camera on entry; the view only
  /// changes once the user actually orbits it themselves.
  final ReferencePlaneKind? initialViewPlane;

  /// Bug fix: the Sketch's own [initialViewPlane]-relative orientation (see
  /// `SketchDto.flip`/`SketchDto.rotationQuarterTurns`) - defaults to the
  /// identity, but a caller entering an oriented Sketch's Orbit View should
  /// pass the real values, or the initial camera facing (and everything
  /// [syncToSketchViewport] frames against) disagrees with how that
  /// Sketch's own geometry is actually embedded.
  final bool initialViewFlip;
  final int initialViewRotationQuarterTurns;

  /// On-device feedback (bug fix): the same starting-orientation role as
  /// [initialViewPlane], generalized to a custom (Feature-anchored) plane -
  /// [initialViewPlane] only ever covers the three fixed [ReferencePlaneKind]s,
  /// which silently left Orbit View unreachable for any Sketch on a custom
  /// Plane (e.g. via "New Sketch on Face"). Already carries
  /// [initialViewFlip]/[initialViewRotationQuarterTurns] baked in (see
  /// [SketchPlaneBasis.oriented]/[SketchPlaneBasis.withOrientation]) - those
  /// two fields are ignored when this is set. Takes precedence over
  /// [initialViewPlane] if somehow both are given, though no caller does.
  final SketchPlaneBasis? initialViewBasis;

  /// New-sketch orientation confirm step (on-device feedback: the indicator
  /// must track the camera live as the user orbits, not just refresh on a
  /// flip/rotate tap) - non-null shows [SketchOrientationIndicator] for
  /// this basis, rendered inside this widget's own [build] (not as an
  /// external overlay in [PartScreen]) specifically so it repaints on every
  /// orbit/pan/zoom-triggered rebuild this State already does for itself,
  /// with no separate camera-change plumbing needed.
  final SketchPlaneBasis? sketchOrientationBasis;

  const PartViewport({
    super.key,
    this.bodies = const [],
    this.bodiesHidden = false,
    required this.selectedPlane,
    required this.onPlaneTap,
    required this.onBackgroundTap,
    this.sketchGeometries = const {},
    this.sketchEntityColors = const {},
    this.createPlanes = const {},
    this.onCreatePlaneTap,
    this.selectedCreatePlaneFeatureId,
    this.sketchPlaneBasis,
    this.onSketchPlaneTap,
    this.drawCursorMode = false,
    this.onDrawCursorMoved,
    this.onDrawCursorCommit,
    this.drawCursorHoverColor,
    this.suppressDrawCursor = false,
    this.drawGhostPolylines = const [],
    this.drawGhostColor,
    this.drawGhostGuidePolylines = const [],
    this.drawIndicatorMarkers = const [],
    this.profileFillOutlines = const [],
    this.profileBranchMarkers = const [],
    this.constraintOverlayItems = const [],
    this.preferConstraintOverlayHitOnCommit = false,
    this.onConstraintOverlayItemTap,
    this.isDraggingConstraintLabel = false,
    this.onConstraintLabelDragDelta,
    this.draggingConstraintLabelId,
    this.onRadialLabelAngleDragged,
    this.onRadialLabelDistanceDragged,
    this.onLinearLabelOffsetDragged,
    this.onLineDistanceLabelOffsetDragged,
    this.onLineDistanceLabelAlongDragged,
    this.onAngleLabelRadiusDragged,
    this.activeConstraintOverlayItemId,
    this.activeConstraintOverlayItemBuilder,
    this.sketchPlaneSurfaceColourHex = '#F2F2F2',
    this.sketchPlaneSurfaceOpacity = 0.18,
    this.sketchPlaneGridVisible = false,
    this.preferEntityPick = false,
    this.preferEntityPickIncludesFace = false,
    this.onSketchEntityTap,
    this.hasEntityNearSketchTap,
    this.isPreviewMesh = false,
    this.previewOverlayBodyId,
    this.previewOverlayMesh,
    this.referencePlanesHidden = false,
    this.renderMode = ViewportRenderMode.shaded,
    this.bgColourHex = ViewPreferences.defaultBgColourHex,
    this.bodyColourHex = ViewPreferences.defaultBodyColourHex,
    this.bodyOpacity = ViewPreferences.defaultBodyOpacity,
    this.roughness = ScenePreferences.defaultRoughness,
    this.lightIntensity = ScenePreferences.defaultLightIntensity,
    this.emissiveIntensity = ScenePreferences.defaultEmissiveIntensity,
    this.selectionMode = false,
    this.selectedEntities = const {},
    this.onSelectionToggle,
    this.onClearSelection,
    this.onMarqueeSelect,
    this.selectionFilter = SelectionFilterState.defaults,
    this.isPerspective = false,
    this.farClip,
    this.onFarClipChanged,
    this.sketchLineLoopGroup,
    this.initialViewPlane,
    this.initialViewFlip = false,
    this.initialViewRotationQuarterTurns = 0,
    this.initialViewBasis,
    this.sketchOrientationBasis,
  });

  @override
  State<PartViewport> createState() => PartViewportState();
}

class PartViewportState extends State<PartViewport> with TickerProviderStateMixin {
  final OrbitCamera _camera = OrbitCamera();

  /// On-device feedback: test-only window into the camera's real
  /// target/distance, for verifying [syncToSketchViewport]'s actual effect
  /// directly (the ghost-outline/backdrop mismatch investigation needs to
  /// see what the camera really ends up at, not just what the math is
  /// supposed to produce by hand).
  @visibleForTesting
  vm.Vector3 get debugCameraTarget => _camera.target;
  @visibleForTesting
  double get debugCameraDistance => _camera.distance;

  /// On-device feedback: "after selecting axis for revolve, 3d viewport
  /// moves and shouldn't" - [_syncMeshNode] used to re-center the camera
  /// target on every single mesh update, not just the first, so any live
  /// feature-preview refresh (Revolve's axis picker debounces a preview
  /// mesh fetch the moment an axis is picked; Extrude/Chamfer/Fillet do the
  /// same on their own inputs) silently snapped the view back to the
  /// updated body's new centre - disorienting mid-edit, and not how any
  /// real CAD tool behaves (auto-framing happens once per part/session;
  /// after that, the camera only moves because the user moved it, or via
  /// an explicit "Reset View" - see [OrbitCamera.reset]). Tracks whether
  /// that one-time auto-frame has already happened for this State's own
  /// lifetime - a genuinely new [PartViewport] (e.g. navigating to a
  /// different Part) gets a fresh [PartViewportState] and so a fresh,
  /// unframed camera, exactly as before this fix.
  bool _hasFramedCamera = false;

  /// Null until `flutter_scene`'s static resources (shaders, default
  /// textures) finish loading - [Scene.render] silently skips frames before
  /// that, so nothing is built until this is non-null.
  Scene? _scene;

  /// Prompt A3: one filled-faces [Node] per Body, keyed by
  /// [BodyMeshDto.bodyId] - was a single `Node? _meshNode` before A3's
  /// multi-body `/mesh` response, rebuilt wholesale on every
  /// [_syncMeshNode] call the same way [_planeNodes]/[_sketchNodes] already
  /// rebuild wholesale from their own source maps.
  Map<String, Node> _meshNodes = {};

  /// Stage 11: the Part's real OCCT edge polylines, one [Node] per Body
  /// (Prompt A3), rendered separately from [_meshNodes]' filled faces -
  /// present whenever [PartViewport.renderMode] has
  /// [ViewportRenderModeX.showsEdges] set, regardless of whether the faces
  /// themselves are also showing.
  Map<String, Node> _edgesNodes = {};
  Map<ReferencePlaneKind, Node> _planeNodes = {};
  Map<String, Node> _sketchNodes = {};
  Map<String, Node> _createPlaneNodes = {};

  /// P8/P9: unlike [_planeNodes]/[_sketchNodes]/[_createPlaneNodes], never
  /// more than one of each at a time - there's only ever one active Sketch
  /// plane in the embedded view.
  Node? _sketchPlaneSurfaceNode;
  Node? _sketchPlaneGridNode;

  /// P17: the live draw-cursor ghost preview - mirrors
  /// [_sketchPlaneGridNode]'s "single optional Node" shape, but rebuilt on
  /// every [PartViewport.drawGhostPolylines] change (i.e. every cursor
  /// move while draw-cursor mode is active), not just when the plane basis
  /// itself changes.
  Node? _drawGhostNode;

  /// P20 follow-up: mirrors [_drawGhostNode] for
  /// [PartViewport.drawGhostGuidePolylines].
  Node? _drawGhostGuideNode;

  /// P20 follow-up: mirrors [_drawGhostNode] for
  /// [PartViewport.drawIndicatorMarkers].
  Node? _drawIndicatorsNode;

  /// P31: mirrors [_drawIndicatorsNode]'s "single optional Node" shape for
  /// [PartViewport.profileFillOutlines]/[PartViewport.profileBranchMarkers].
  Node? _profileFillNode;
  Node? _profileBranchMarkersNode;

  /// Set if GPU/scene setup throws - without this, that failure would only
  /// ever reach the console (it happens inside an unawaited Future), leaving
  /// [build] stuck showing its loading spinner forever with no way for
  /// anyone looking at the screen to tell something went wrong.
  String? _error;

  /// Live touch pointers by id, for pinch-zoom/two-finger-pan - same
  /// approach as [SketchCanvas]'s `_activeTouches`.
  final Map<int, Offset> _activeTouches = {};

  /// The viewport's current size, refreshed every build - needed by
  /// [_handleTap] to build a [PerspectiveCamera.screenPointToRay] ray, which
  /// only ever runs later, from a pointer-up callback that has no [Size] of
  /// its own.
  Size _viewportSize = Size.zero;

  /// Cumulative pointer travel (pixels) since the current gesture's first
  /// pointer-down - mirrors [SketchCanvas]'s `_singleTouchTravel`, used the
  /// same way to tell a tap (plane selection) apart from an orbit/pan drag.
  double _gestureTravel = 0;

  /// Set once a second touch has joined the current gesture, so the tail end
  /// of a pinch (fingers lifting one by one) is never mistaken for a tap.
  bool _hadMultiTouch = false;

  static const double _tapTravelThreshold = 10.0;

  /// Fix 4: cumulative pointer travel since the current gesture's
  /// pointer-down, *while in selection mode* - the selection-mode
  /// equivalent of [_gestureTravel], kept as its own field rather than
  /// reusing [_gestureTravel] so this never interacts with the orbit
  /// handlers' own tap/drag bookkeeping (which only ever runs when selection
  /// mode is off). A gesture that stays under [_tapTravelThreshold] commits
  /// the current hover via [_commitSelection]; one that exceeds it was a
  /// cursor drag, not a tap.
  double _selectionGestureTravel = 0;

  /// P16: the draw cursor's own tap/drag travel tracker - the
  /// [PartViewport.drawCursorMode] equivalent of [_selectionGestureTravel],
  /// kept separate for the same reason that field is kept separate from
  /// [_gestureTravel].
  double _drawCursorGestureTravel = 0;

  /// P25 (2D-sketcher feature parity): mirrors `sketch_canvas.dart`'s own
  /// `_longPressDuration` - how long a stationary press on empty space (see
  /// [_maybeStartMarqueeLongPress]) must hold before growing into a marquee
  /// drag, distinguishing it from an ordinary cursor-drag.
  static const Duration _marqueeLongPressDuration = Duration(milliseconds: 500);

  /// P25: the pending long-press timer, non-null only between a qualifying
  /// pointer-down and either it firing (-> [_marqueeActive]) or being
  /// cancelled (too much travel, or the pointer lifting first).
  Timer? _marqueeLongPressTimer;

  /// P25: the screen position the pending long-press (or, once it fires,
  /// the active marquee) started at - one corner of the eventual marquee
  /// rect, mirroring `sketch_canvas.dart`'s own `_longPressDownScreen`.
  Offset? _marqueeDownScreen;

  /// P25: true once the long-press has fired and the gesture has committed
  /// to being a marquee drag - [_onPointerMove]/[_onPointerEnd]'s own
  /// selectionMode branches divert entirely to marquee handling while this
  /// is true, mirroring `sketch_canvas.dart`'s own `_marqueeActive`.
  bool _marqueeActive = false;

  /// P25: the live other corner of the marquee rect while [_marqueeActive] -
  /// null only in the instant between the long-press firing and the first
  /// subsequent pointer-move.
  Offset? _marqueeCurrentScreen;

  /// Stage 23 Item 2: the cursor's current screen position while
  /// [PartViewport.selectionMode] is true - null whenever selection mode is
  /// off (so the crosshair overlay in [build] hides entirely) or before the
  /// first `didUpdateWidget` entry into selection mode has had a chance to
  /// set it to the viewport centre.
  ///
  /// P43/P44 bug fix (on-device feedback: toggling the drag-mode FAB, or
  /// entering any tool, made the cursor visibly jump - "the cursor should
  /// not appear to change location to the user"): this used to be two
  /// separate fields, one for [PartViewport.selectionMode] and one for
  /// [PartViewport.drawCursorMode] (P16's own `_drawCursorPosition`) - since
  /// the two modes are always mutually exclusive (never both true at once;
  /// see [PartViewport.drawCursorMode]'s own doc comment for the full
  /// mode table), a *fresh-looking* jump was unavoidable with two separate
  /// fields no matter how carefully `didUpdateWidget` tried to hand a
  /// position across between them (a fallback chain between two stale
  /// values is still a jump the moment either value goes stale) - merged
  /// into this one field instead, so there is nothing to hand across at
  /// all: whichever mode is active just keeps reading/writing the same
  /// position the other one already left it at.
  Offset? _cursorPosition;

  /// P16: the draw cursor's current resolved hit on
  /// [PartViewport.sketchPlaneBasis] (via [hitTestSketchPlane]) - null if the
  /// cursor isn't over the plane, or [PartViewport.sketchPlaneBasis] itself
  /// is unset. The [HoverHit]-equivalent ground truth [_commitDrawCursor]
  /// commits and [PartViewport.onDrawCursorMoved] streams to the caller.
  vm.Vector3? _drawCursorWorldHit;

  /// Stage 23 Item 3: the nearest face/edge/vertex to [_cursorPosition],
  /// recomputed every time the cursor moves - null if nothing in
  /// [PartViewport.mesh] is within hit range and the cursor isn't over any
  /// face either.
  HoverHit? _hoverHit;

  /// How far (logical pixels) a single pointer-move event's `delta` moves
  /// [_cursorPosition] - less than 1:1 per Item 2's "sensitivity-scaled, not
  /// 1:1" requirement, so a full-viewport drag doesn't blow straight past
  /// the model.
  static const double _cursorDragSensitivity = 0.6;

  Node? _hoverNode;
  Node? _selectedFacesNode;
  Node? _selectedEdgesNode;
  Node? _selectedVerticesNode;

  static final vm.Vector4 _hoverColor = vector4FromHex('#FFC107', opacity: 0.55);
  static final vm.Vector4 _selectedColor = vector4FromHex('#2196F3', opacity: 0.85);

  /// On-device feedback ("when a face is selected, it isn't clear it's
  /// selected - the colour change should be higher contrast or brighter"):
  /// a selected Face used to share [_selectedColor] with a selected
  /// Vertex - kept that one unchanged (still used for vertices, see
  /// [_syncSelectedEntitiesNode]'s own vertex branch) and gave Face its
  /// own, brighter/more saturated palette instead, so this fix can't
  /// accidentally wash out vertex-selection contrast the same complaint
  /// wasn't about.
  ///
  /// P53 on-device feedback round 2 ("that's not what I meant [by 'glow'].
  /// a better description is 'lit up'. I think the problem was that the
  /// selected face colour was very similar to the body colour I had
  /// selected"): a pulsing-brightness animation (this field's own first
  /// draft) was the wrong fix entirely - the actual complaint was a plain
  /// contrast failure against whatever [PartViewport.bodyColourHex] the
  /// user has set, not a lack of motion. A single fixed highlight color
  /// (this field's very first version, `#2979FF`) can never guarantee
  /// contrast against an arbitrary user-chosen Body Colour - so this picks,
  /// fresh in [_syncSelectedEntityNodes] every time the selection changes,
  /// whichever of a small palette of mutually well-separated, highly
  /// saturated "signal" colors is furthest (by RGB distance - see
  /// [_highContrastFaceHighlightColor]) from the *current* body color,
  /// rather than a single hardcoded constant.
  static final List<vm.Vector4> _faceHighlightPalette = [
    vector4FromHex('#FFC400', opacity: 0.95), // amber
    vector4FromHex('#00E5FF', opacity: 0.95), // cyan
    vector4FromHex('#FF00E5', opacity: 0.95), // magenta
    vector4FromHex('#76FF03', opacity: 0.95), // lime
  ];

  vm.Vector4 _highContrastFaceHighlightColor() =>
      highContrastColorFrom(_faceHighlightPalette, vector4FromHex(widget.bodyColourHex));

  /// Darker than [_selectedColor] so a selected edge reads as visually
  /// distinct from a selected face's tint - Material Blue 900.
  static final vm.Vector4 _selectedEdgeColor = vector4FromHex('#0D47A1', opacity: 0.85);

  @override
  void initState() {
    super.initState();
    // A4: set initial projection mode from widget.
    _camera.isPerspective = widget.isPerspective;
    // A3: apply any initial far clip override; if null, setZoomBoundsForRadius
    // will manage it once the first mesh loads.
    if (widget.farClip != null) {
      _camera.farClip = widget.farClip!;
      _camera.nearClip = kDefaultNearClip;
    }
    // Orbit View entry fix: start facing the given plane exactly, rather
    // than OrbitCamera's own angled default - see [PartViewport.initialViewPlane]/
    // [PartViewport.initialViewBasis].
    final initialViewBasis = widget.initialViewBasis;
    if (initialViewBasis != null) {
      _camera.orientation = orientationFacingBasis(initialViewBasis);
    } else if (widget.initialViewPlane != null) {
      _camera.orientation = orientationFacingPlane(
        widget.initialViewPlane!,
        flip: widget.initialViewFlip,
        rotationQuarterTurns: widget.initialViewRotationQuarterTurns,
      );
    }
    debugPrint('[PartViewport] Scene.initializeStaticResources()...');
    Scene.initializeStaticResources().then((_) {
      debugPrint('[PartViewport] Scene.initializeStaticResources() done');
      // RenderDebug: if this device's Impeller backend can't report a real
      // combined depth+stencil format (defaultDepthStencilFormat reads as
      // PixelFormat.unknown, or MSAA support reads false where the device
      // should support it), depth testing may not actually be functioning
      // at all - which would explain a *constant* (not glancing-angle,
      // not selection-specific) failure to occlude hidden edges/faces
      // behind opaque geometry, a fundamentally different bug class from
      // everything investigated in this file's edge/highlight code so far.
      try {
        // Deliberately `print`, not `debugPrint`: this line fires once at
        // startup, but the rest of this file fires debugPrint on every
        // pointer move/frame sync, which floods debugPrint's default
        // throttled buffer (debugPrintThrottled) and can bury or indefinitely
        // delay a one-time line behind that backlog. `print` bypasses that
        // throttling entirely so this can't get lost in logcat capture.
        // ignore: avoid_print
        print(
          '[PartViewport][RenderDebug] GPU: defaultColorFormat=${gpu.gpuContext.defaultColorFormat} '
          'defaultStencilFormat=${gpu.gpuContext.defaultStencilFormat} '
          'defaultDepthStencilFormat=${gpu.gpuContext.defaultDepthStencilFormat} '
          'doesSupportOffscreenMSAA=${gpu.gpuContext.doesSupportOffscreenMSAA}',
        );
      } catch (error) {
        // ignore: avoid_print
        print('[PartViewport][RenderDebug] GPU capability query failed: $error');
      }
      if (!mounted) return;
      setState(() {
        _scene = Scene()
          // DIAGNOSTIC: on-device testing shows hidden edges/faces bleeding
          // through opaque bodies even after both were switched to
          // AlphaMode.opaque (see mesh_geometry.dart's doc comments on
          // buildMeshEdgesNode/buildHighlightFacesNode) - ruling out
          // "translucent pass only" as the cause, since opaque-vs-opaque
          // across separate Nodes is now failing too. MSAA's offscreen
          // depth-resolve step is a known category of Android GPU driver
          // bug for exactly this symptom (a resolved/multisampled depth
          // buffer not correctly available to later draws in the same
          // pass) - forcing it off here tests that theory directly. Revert
          // if this doesn't help; `Scene`'s default (`AntiAliasingMode.auto`)
          // already only enables MSAA when `doesSupportOffscreenMSAA` is
          // true, which this device does report.
          ..antiAliasingMode = AntiAliasingMode.none
          // Lighting/shading upgrade: a procedural, no-asset-required
          // ambient/IBL fill so a PhysicallyBasedMaterial's unlit side isn't
          // pure black - see ScenePreferences' own doc comment for why this
          // is unconditional/not a user-adjustable control.
          ..environment = EnvironmentMap.studio();
        _applyLighting();
        // See the `print` comment above: same reasoning applies here.
        // ignore: avoid_print
        print(
          '[PartViewport][RenderDebug] scene: antiAliasingMode=${_scene!.antiAliasingMode} '
          'effectiveAntiAliasingMode=${_scene!.effectiveAntiAliasingMode}',
        );
        _syncMeshNode();
        _syncEdgesNode();
        _syncReferencePlaneNodes();
        _syncSketchNodes();
        _syncCreatePlaneNodes();
        _syncSketchPlaneSurfaceNode();
        _syncSketchPlaneGridNode();
        _syncDrawGhostNode();
        _syncDrawGhostGuideNode();
        _syncDrawIndicatorsNode();
        _syncProfileFillNode();
        _syncProfileBranchMarkersNode();
      });
    }).catchError((Object error) {
      debugPrint('[PartViewport] GPU/scene setup failed: $error');
      if (!mounted) return;
      setState(() => _error = error.toString());
    });
  }

  @override
  void dispose() {
    // P25: an already-scheduled (but not yet fired) long-press timer must
    // not fire after this State is torn down - it would call setState on a
    // disposed Element.
    _marqueeLongPressTimer?.cancel();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant PartViewport oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.bodies != oldWidget.bodies ||
        widget.isPreviewMesh != oldWidget.isPreviewMesh ||
        widget.previewOverlayBodyId != oldWidget.previewOverlayBodyId ||
        widget.previewOverlayMesh != oldWidget.previewOverlayMesh ||
        widget.renderMode != oldWidget.renderMode ||
        widget.bodyColourHex != oldWidget.bodyColourHex ||
        widget.bodyOpacity != oldWidget.bodyOpacity ||
        widget.roughness != oldWidget.roughness ||
        widget.emissiveIntensity != oldWidget.emissiveIntensity ||
        // On-device feedback ("the eye ball FAB that should hide/show all
        // bodies currently does nothing"): _syncMeshNode/_syncEdgesNode are
        // the only things that actually read bodiesHidden (see their own
        // gates) - without this, flipping the toggle updated the widget's
        // own prop but never re-ran either sync method, so the already-
        // built mesh/edge Nodes in the Scene just sat there unchanged.
        widget.bodiesHidden != oldWidget.bodiesHidden) {
      setState(_syncMeshNode);
    }
    if (widget.lightIntensity != oldWidget.lightIntensity) {
      setState(_applyLighting);
    }
    if (widget.bodies != oldWidget.bodies ||
        widget.previewOverlayBodyId != oldWidget.previewOverlayBodyId ||
        widget.previewOverlayMesh != oldWidget.previewOverlayMesh ||
        widget.renderMode != oldWidget.renderMode ||
        widget.bodiesHidden != oldWidget.bodiesHidden) {
      setState(_syncEdgesNode);
    }
    if (widget.selectedPlane != oldWidget.selectedPlane ||
        widget.referencePlanesHidden != oldWidget.referencePlanesHidden ||
        widget.selectedEntities != oldWidget.selectedEntities) {
      setState(_syncReferencePlaneNodes);
    }
    if (widget.sketchGeometries != oldWidget.sketchGeometries ||
        widget.sketchEntityColors != oldWidget.sketchEntityColors) {
      setState(_syncSketchNodes);
    }
    if (widget.createPlanes != oldWidget.createPlanes ||
        widget.selectedCreatePlaneFeatureId != oldWidget.selectedCreatePlaneFeatureId ||
        widget.selectedEntities != oldWidget.selectedEntities) {
      setState(_syncCreatePlaneNodes);
    }
    if (widget.sketchPlaneBasis != oldWidget.sketchPlaneBasis ||
        widget.sketchPlaneSurfaceColourHex != oldWidget.sketchPlaneSurfaceColourHex ||
        widget.sketchPlaneSurfaceOpacity != oldWidget.sketchPlaneSurfaceOpacity) {
      setState(_syncSketchPlaneSurfaceNode);
    }
    if (widget.sketchPlaneBasis != oldWidget.sketchPlaneBasis ||
        widget.sketchPlaneGridVisible != oldWidget.sketchPlaneGridVisible) {
      setState(_syncSketchPlaneGridNode);
    }
    if (widget.drawGhostPolylines != oldWidget.drawGhostPolylines ||
        widget.drawGhostColor != oldWidget.drawGhostColor) {
      setState(_syncDrawGhostNode);
    }
    if (widget.drawGhostGuidePolylines != oldWidget.drawGhostGuidePolylines) {
      setState(_syncDrawGhostGuideNode);
    }
    if (widget.drawIndicatorMarkers != oldWidget.drawIndicatorMarkers) {
      setState(_syncDrawIndicatorsNode);
    }
    if (widget.profileFillOutlines != oldWidget.profileFillOutlines ||
        widget.sketchPlaneBasis != oldWidget.sketchPlaneBasis) {
      setState(_syncProfileFillNode);
    }
    if (widget.profileBranchMarkers != oldWidget.profileBranchMarkers) {
      setState(_syncProfileBranchMarkersNode);
    }
    if (widget.selectionMode != oldWidget.selectionMode) {
      setState(() {
        if (widget.selectionMode) {
          // P34/P44 fix (on-device feedback: toggling the Orbit/Cursor FAB
          // made the cursor visibly jump): [_cursorPosition] is now the
          // single field shared with [PartViewport.drawCursorMode] (see its
          // own field doc comment for why the merge is safe - the two modes
          // are always mutually exclusive), so entering selection mode just
          // keeps reading whatever position the other mode already left it
          // at; only ever defaults to viewport centre the very first time
          // either mode is activated. Re-clamped in case the viewport was
          // resized (e.g. a rotation) while the cursor was hidden.
          _cursorPosition = _clampToViewport(_cursorPosition ?? _viewportCenter());
          _recomputeHover();
        } else {
          // Item 1: leaving selection mode still hides the crosshair
          // (gated on `widget.selectionMode` at the paint site, not on
          // `_cursorPosition` itself, so leaving the position set here is
          // enough) and clears the hover highlight.
          _hoverHit = null;
          // P25: a marquee gesture (or pending long-press) mid-flight when
          // selectionMode turns off would otherwise leave its overlay
          // stuck on-screen forever, since _onPointerMove/_onPointerEnd's
          // own marquee handling only runs from the selectionMode branch.
          _cancelMarqueeLongPress();
          _marqueeActive = false;
          _marqueeCurrentScreen = null;
        }
        _syncHoverNode();
      });
    }
    if (widget.drawCursorMode != oldWidget.drawCursorMode) {
      setState(() {
        if (widget.drawCursorMode) {
          // P34/P44 fix: mirrors the selectionMode block above - reads the
          // same shared `_cursorPosition` field, so entering any tool (or
          // drag mode) keeps the cursor exactly where selection mode left
          // it instead of jumping.
          _cursorPosition = _clampToViewport(_cursorPosition ?? _viewportCenter());
          _recomputeDrawCursor();
          // P46: entering a tool should show the entity hover-highlight
          // straight away, at wherever the cursor already is - not just
          // wait for the first move/hover event.
          _recomputeHover();
        } else {
          _drawCursorWorldHit = null;
          // Guarded on `!widget.selectionMode`: when a tool hands off
          // straight to Select mode (both flags flip in the same
          // didUpdateWidget pass), the selectionMode block above already
          // ran first and computed the correct hover for its own mode -
          // clearing it here unconditionally would stomp that.
          if (!widget.selectionMode) _hoverHit = null;
        }
        _syncHoverNode();
      });
    }
    if (widget.selectedEntities != oldWidget.selectedEntities) {
      // Fix 2: re-adding the hover node *after* the selected nodes (rather
      // than leaving it wherever it last landed in the Scene's node list)
      // keeps the hover highlight rendering on top of a newly-selected
      // entity at the same position, per the brief's required paint order
      // (base mesh -> selected -> hover).
      setState(() {
        _syncSelectedEntityNodes();
        _syncHoverNode();
      });
    }
    if (widget.bodies != oldWidget.bodies && widget.selectionMode) {
      // The mesh's entity ids are only stable within one response (see
      // MeshDto's doc comments) - a hover/selection computed against the
      // old mesh could point at ids that no longer exist, so both are
      // recomputed/resynced from the new mesh too.
      setState(() {
        _recomputeHover();
        _syncHoverNode();
        _syncSelectedEntityNodes();
      });
    }
    // A4: sync the perspective flag from the parent.
    if (widget.isPerspective != oldWidget.isPerspective) {
      _camera.isPerspective = widget.isPerspective;
    }
    // A3: apply a far-clip change from the View menu slider. Near clip stays
    // at kDefaultNearClip — it is never auto-adjusted by the slider.
    if (widget.farClip != null && widget.farClip != oldWidget.farClip) {
      setState(() {
        _camera.farClip = widget.farClip!;
        _camera.nearClip = kDefaultNearClip;
      });
    }
  }

  /// Sets the Scene's single directional "sun" light from
  /// [PartViewport.lightIntensity] - the "mid lighting" control. A fixed
  /// direction/colour is used (not user-adjustable - the user asked for a
  /// lighting *intensity* control, not a full light-rig editor); the
  /// default direction/colour below matches `DirectionalLight`'s own
  /// constructor defaults per the real `flutter_scene` source consulted for
  /// this upgrade.
  ///
  /// FLAGGED FOR ON-DEVICE VERIFICATION: `PhysicallyBasedMaterial`/
  /// `DirectionalLight`/`EnvironmentMap` (all three genuinely new to this
  /// codebase - every prior use of `flutter_scene` here was `UnlitMaterial`
  /// only) were confirmed to exist and confirmed their field/constructor
  /// shapes against real `flutter_scene` 0.18.1 source, but *not* confirmed
  /// to be exported from the `package:flutter_scene/scene.dart` barrel
  /// import already used throughout this file (as opposed to needing a more
  /// specific import path) - this sandbox has no Flutter SDK, so nothing in
  /// this upgrade has actually been compiled. The mesh viewer's own
  /// `PhysicallyBasedMaterial`/lighting adoption (`mesh_viewer_render.dart`)
  /// shares this exact same risk; if either fails to compile, it's very
  /// likely the same fix in both places.
  void _applyLighting() {
    final scene = _scene;
    if (scene == null) return;
    scene.directionalLight = DirectionalLight(
      direction: vm.Vector3(-0.3, -1.0, -0.2),
      color: vm.Vector3(1, 1, 1),
      intensity: widget.lightIntensity,
    );
  }

  void _syncMeshNode() {
    final scene = _scene;
    if (scene == null) return;
    for (final node in _meshNodes.values) {
      scene.remove(node);
    }
    _meshNodes = {};
    final bodies = widget.bodies;
    if (bodies.isEmpty) {
      debugPrint('[PartViewport] _syncMeshNode: no bodies yet');
      if (!_hasFramedCamera) {
        _camera.setTarget(vm.Vector3.zero());
        _camera.setZoomBoundsForRadius(0);
      }
      return;
    }
    // Stage 11: in wireframe mode, the filled-faces Nodes are skipped
    // entirely (only the edges Nodes built by _syncEdgesNode are shown) -
    // but the camera target/zoom bounds below are still derived from the
    // real mesh data either way, so switching modes never moves the camera.
    // On-device feedback ("Show reference body button... should now toggle
    // visibility of all bodies on/off to show user a clear view of the
    // sketch"): skips only the Node-creation loop below, not the camera-
    // bounds computation just past it (bodies staying hidden shouldn't
    // also make the camera re-target/re-zoom) or anything `widget.bodies`
    // itself still feeds elsewhere (hitTestBodies/boundsOfBodies) - hiding
    // is purely a rendering concern, real-Body picking (Convert Entities/
    // Dimension mode's own preferEntityPick) stays fully working while
    // bodies are hidden.
    if (widget.renderMode.showsFilledFaces && !widget.bodiesHidden) {
      for (final body in bodies) {
        // On-device feedback: if this is the one Body [previewOverlayMesh]
        // targets, render *that* mesh (the operation's actual current
        // effect) instead of this stable Body's own - [bodies] itself stays
        // untouched (hit-testing/edge ids below still come from the real
        // `body.mesh`), only the rendered geometry for this one Node swaps.
        final isPreviewOverlay =
            widget.previewOverlayMesh != null && body.bodyId == widget.previewOverlayBodyId;
        // Deliberately *not* renderMirrorCorrectedMesh (on-device feedback,
        // 2026-07-21 follow-up round): that correction was applied
        // uniformly to every Body source, but a controlled on-device test
        // (fresh Boss along +Z) showed hitTestBodies/boundsOfBodies - both
        // still reading `body.mesh` raw, unmodified - land exactly where
        // the user actually expected the body to be, while this
        // render-only correction shifted the *visible* mesh to the
        // opposite side, so a tap on the visible (wrong-side) geometry hit
        // nothing and the real hit-test highlights appeared on the empty
        // (correct-side) space instead. Since no on-device report ever
        // flagged Extrude/Revolve/Sweep rendering mirrored before today,
        // the original labeled-reference-file finding this correction was
        // built from most likely implicates Import specifically, not every
        // Body source uniformly - reverted here pending a properly
        // source-scoped re-diagnosis (see mesh_geometry.dart's
        // renderMirrorCorrectedMesh doc comment).
        final mesh = isPreviewOverlay ? widget.previewOverlayMesh! : body.mesh;
        if (mesh.vertices.isEmpty) {
          // flutter_scene's UnskinnedGeometry.uploadVertexData allocates a
          // GPU device buffer sized off the vertex/index data - a
          // zero-length buffer throws "DeviceBuffer creation failed"
          // rather than just rendering nothing, so skip this Body's Node
          // entirely rather than risk that (shouldn't happen in practice -
          // the backend only ever includes a Body in the array once it has
          // real geometry - but stays defensive, matching the pre-A3 check
          // this replaces).
          debugPrint(
            '[PartViewport] _syncMeshNode: body ${body.bodyId} has no vertices, skipping geometry',
          );
          continue;
        }
        debugPrint(
          '[PartViewport] _syncMeshNode: geometryFromMesh(${body.bodyId}, '
          '${mesh.vertices.length} verts)...',
        );
        // Face-culling bug fix: any translucent material below (preview
        // overlays are always translucent; a confirmed Body is translucent
        // whenever bodyOpacity < 1.0) needs double-sided-winding geometry,
        // or flutter_scene back-face-culls it regardless of the material's
        // own doubleSided flag - see geometryFromMesh's doc comment.
        final isTranslucent = widget.isPreviewMesh || isPreviewOverlay || widget.bodyOpacity < 1.0;
        final geometry = geometryFromMesh(mesh, doubleSidedWinding: isTranslucent);
        // Live-operation preview overlays stay a flat, translucent tint -
        // they're meant to read as a distinct "in-progress" indicator, not
        // real lit geometry, so they're deliberately left on UnlitMaterial.
        final material = (widget.isPreviewMesh || isPreviewOverlay)
            ? (UnlitMaterial()
              ..alphaMode = AlphaMode.blend
              ..baseColorFactor = vm.Vector4(1.0, 0.65, 0.0, 0.45))
            // Lighting/shading upgrade: a confirmed Body now gets a real,
            // lit PBR material (see ScenePreferences/_applyLighting) instead
            // of a flat UnlitMaterial tint - metallicFactor is fixed at
            // ScenePreferences.fixedMetallic (see its own doc comment for
            // why this isn't a user-adjustable slider). doubleSided: real
            // on-device testing showed the exact same "one side opaque, the
            // other see-through" backface-culling symptom the mesh viewer
            // hit (see mesh_viewer_render.dart's buildMeshViewerMaterial) -
            // this disproves this file's own earlier assumption that real
            // OCCT-tessellated geometry's winding is always culling-safe;
            // apparently it isn't always, so the same fix applies here too.
            : (PhysicallyBasedMaterial()
              ..alphaMode = widget.bodyOpacity < 1.0 ? AlphaMode.blend : AlphaMode.opaque
              ..baseColorFactor = vector4FromHex(widget.bodyColourHex, opacity: widget.bodyOpacity)
              ..roughnessFactor = widget.roughness
              ..metallicFactor = ScenePreferences.fixedMetallic
              ..emissiveFactor = vm.Vector4(
                widget.emissiveIntensity,
                widget.emissiveIntensity,
                widget.emissiveIntensity,
                1,
              )
              ..doubleSided = true);
        final node = Node(mesh: Mesh(geometry, material));
        scene.add(node);
        _meshNodes[body.bodyId] = node;
      }
      debugPrint(
        '[PartViewport] _syncMeshNode: ${_meshNodes.length}/${bodies.length} body Node(s) '
        'added to Scene (isPreviewMesh=${widget.isPreviewMesh} bodyOpacity=${widget.bodyOpacity})',
      );
    }
    final bounds = boundsOfBodies(bodies);
    if (!_hasFramedCamera) {
      _camera.setTarget(bounds?.center ?? vm.Vector3.zero());
      _hasFramedCamera = true;
    }
    // Near/far clip and min/max zoom bounds still track the current
    // geometry on every update (a body that's grown significantly must not
    // get far-clipped) - only the target (see above) and, via that, the
    // camera's overall framing stay put after the first sync.
    _camera.setZoomBoundsForRadius(bounds?.boundingSphereRadius ?? 0);
    debugPrint(
      '[PartViewport][RenderDebug] bounds: center=${bounds?.center} '
      'boundingSphereRadius=${bounds?.boundingSphereRadius} cameraDistance=${_camera.distance}',
    );
  }

  /// Stage 11: rebuilds [_edgesNodes] from [PartViewport.bodies]' real OCCT
  /// edge polylines (see [edgeSegmentsFromMesh]) whenever
  /// [ViewportRenderModeX.showsEdges] is set - independent of whether the
  /// filled-faces Nodes above are also present, since `wireframe` mode shows
  /// edges with no faces at all. In `shadedWithEdges` mode the segments are
  /// biased towards the current camera position (see [kEdgeDepthBias]'s doc
  /// comment for why towards-camera, and C3's status doc for the
  /// alternatives this replaced/rejected) to keep them from z-fighting
  /// against the filled faces underneath; `wireframe` mode has no faces to
  /// fight, so it skips this.
  ///
  /// C3: since this bias depends on the *current* camera position, this is
  /// re-run (not just on mesh/render-mode change, as before) whenever the
  /// camera itself moves - see the `setState(_syncEdgesNode)` calls in
  /// `_onPointerEnd`/`_onPointerSignal`/`_doRecentre`/`animateToPlane`. Those
  /// all resync once a gesture/animation *completes* rather than on every
  /// intermediate frame, trading a small amount of staleness while
  /// orbiting for not rebuilding every `PolylineGeometry` primitive on
  /// every pointer-move delta.
  void _syncEdgesNode() {
    final scene = _scene;
    if (scene == null) return;
    for (final node in _edgesNodes.values) {
      scene.remove(node);
    }
    _edgesNodes = {};
    if (!widget.renderMode.showsEdges) return;
    // On-device feedback: see _syncMeshNode's identical bodiesHidden gate.
    if (widget.bodiesHidden) return;
    final biased = widget.renderMode == ViewportRenderMode.shadedWithEdges;
    var totalSegments = 0;
    for (final body in widget.bodies) {
      // See _syncMeshNode's identical substitution for why - keeps the
      // wireframe/shaded-with-edges overlay consistent with whichever mesh
      // (stable or preview) that Body's filled faces are actually showing.
      // Deliberately not renderMirrorCorrectedMesh - see _syncMeshNode's
      // identical reversion for why.
      final mesh = (widget.previewOverlayMesh != null && body.bodyId == widget.previewOverlayBodyId)
          ? widget.previewOverlayMesh!
          : body.mesh;
      var segments = edgeSegmentsFromMesh(mesh);
      if (segments.isEmpty) continue;
      if (biased) {
        segments = biasSegmentsTowardCamera(segments, _camera.position, kEdgeDepthBias);
      }
      final node = buildMeshEdgesNode(segments, color: widget.renderMode.edgeColor);
      scene.add(node);
      _edgesNodes[body.bodyId] = node;
      totalSegments += segments.length;
    }
    debugPrint(
      '[PartViewport][RenderDebug] edges: renderMode=${widget.renderMode} biased=$biased '
      'kEdgeDepthBias=$kEdgeDepthBias segments=$totalSegments bodies=${_edgesNodes.length} '
      'cameraPosition=${_camera.position} cameraDistance=${_camera.distance}',
    );
  }

  /// C5: true if [plane] is highlighted - either the single "just tapped,
  /// its context sheet is open" plane ([PartViewport.selectedPlane], the
  /// pre-C5 controlled-widget flow), or a `referencePlane` entry in
  /// [PartViewport.selectedEntities] (the Selection-mode multi-select flow -
  /// see [PartScreen._onPlaneTap]'s own doc comment for which of the two
  /// applies when).
  bool _isPlaneSelected(ReferencePlaneKind plane) =>
      plane == widget.selectedPlane ||
      widget.selectedEntities.any(
        (e) => e.kind == SelectionEntityKind.referencePlane && e.referencePlaneKind == plane,
      );

  /// C5: mirrors [_isPlaneSelected] for a created Plane's own Feature id.
  bool _isCreatePlaneSelected(String featureId) =>
      featureId == widget.selectedCreatePlaneFeatureId ||
      widget.selectedEntities.any(
        (e) => e.kind == SelectionEntityKind.createPlane && e.planeFeatureId == featureId,
      );

  /// Rebuilds all three reference-plane nodes from scratch - cheap enough
  /// (three small rectangles) to redo wholesale on every selection change,
  /// rather than reaching into [UnlitMaterial] to mutate an existing node's
  /// tint in place.
  void _syncReferencePlaneNodes() {
    final scene = _scene;
    if (scene == null) return;
    for (final node in _planeNodes.values) {
      scene.remove(node);
    }
    if (widget.referencePlanesHidden) {
      _planeNodes = {};
      return;
    }
    _planeNodes = {
      for (final plane in ReferencePlaneKind.values)
        plane: buildReferencePlaneNode(plane, selected: _isPlaneSelected(plane)),
    };
    for (final node in _planeNodes.values) {
      scene.add(node);
    }
  }

  /// Mirrors [_syncReferencePlaneNodes]: rebuilds every Sketch's geometry
  /// node from scratch from [PartViewport.sketchGeometries] - relies on the
  /// widget's own contract (see its doc comment) that a new `Map` instance
  /// only arrives when content genuinely changed, so this never runs more
  /// often than that.
  void _syncSketchNodes() {
    final scene = _scene;
    if (scene == null) return;
    for (final node in _sketchNodes.values) {
      scene.remove(node);
    }
    _sketchNodes = {
      for (final entry in widget.sketchGeometries.entries)
        if (!entry.value.isEmpty)
          entry.key: buildSketchGeometryNode(entry.key, entry.value, entityColors: widget.sketchEntityColors),
    };
    for (final node in _sketchNodes.values) {
      scene.add(node);
    }
  }

  /// C2: mirrors [_syncSketchNodes] for [PartViewport.createPlanes] - one
  /// [Node] per resolvable CreatePlaneFeature, rebuilt wholesale on every
  /// genuine content change per the widget's own contract.
  void _syncCreatePlaneNodes() {
    final scene = _scene;
    if (scene == null) return;
    for (final node in _createPlaneNodes.values) {
      scene.remove(node);
    }
    _createPlaneNodes = {
      for (final entry in widget.createPlanes.entries)
        entry.key: buildCreatePlaneNode(
          entry.key,
          entry.value.origin,
          entry.value.xAxis,
          entry.value.yAxis,
          entry.value.normal,
          selected: _isCreatePlaneSelected(entry.key),
        ),
    };
    for (final node in _createPlaneNodes.values) {
      scene.add(node);
    }
  }

  /// P8: mirrors [_syncReferencePlaneNodes]'s remove-then-rebuild shape for
  /// the single active-Sketch-plane surface - null [PartViewport.sketchPlaneBasis]
  /// (not embedded-sketching) means no node at all, same "null is hidden"
  /// convention [sketchPlaneBasis] itself already uses.
  void _syncSketchPlaneSurfaceNode() {
    final scene = _scene;
    if (scene == null) return;
    final oldNode = _sketchPlaneSurfaceNode;
    if (oldNode != null) scene.remove(oldNode);
    final basis = widget.sketchPlaneBasis;
    if (basis == null) {
      _sketchPlaneSurfaceNode = null;
      return;
    }
    final node = buildSketchPlaneSurfaceNode(
      basis,
      color: vector4FromHex(widget.sketchPlaneSurfaceColourHex, opacity: widget.sketchPlaneSurfaceOpacity),
    );
    _sketchPlaneSurfaceNode = node;
    scene.add(node);
  }

  /// P9: mirrors [_syncSketchPlaneSurfaceNode] for the grid - additionally
  /// gated on [PartViewport.sketchPlaneGridVisible].
  void _syncSketchPlaneGridNode() {
    final scene = _scene;
    if (scene == null) return;
    final oldNode = _sketchPlaneGridNode;
    if (oldNode != null) scene.remove(oldNode);
    final basis = widget.sketchPlaneBasis;
    if (basis == null || !widget.sketchPlaneGridVisible) {
      _sketchPlaneGridNode = null;
      return;
    }
    final node = buildSketchGridNode(basis);
    _sketchPlaneGridNode = node;
    scene.add(node);
  }

  /// P17: mirrors [_syncSketchPlaneGridNode]'s remove-then-rebuild shape,
  /// but keyed on [PartViewport.drawGhostPolylines] directly rather than
  /// the plane basis - [buildSketchGhostNode] already returns null for an
  /// empty list, so an inactive/absent ghost renders no node, same "null is
  /// hidden" convention every other optional node here uses.
  void _syncDrawGhostNode() {
    final scene = _scene;
    if (scene == null) return;
    final oldNode = _drawGhostNode;
    if (oldNode != null) scene.remove(oldNode);
    final node = buildSketchGhostNode(widget.drawGhostPolylines, color: widget.drawGhostColor);
    _drawGhostNode = node;
    if (node != null) scene.add(node);
  }

  /// P20 follow-up: mirrors [_syncDrawGhostNode] for
  /// [PartViewport.drawGhostGuidePolylines] - styled with
  /// `sketchGhostGuideColor` (fainter than the primary ghost) rather than
  /// [PartViewport.drawGhostColor], which is Line-snap-specific and doesn't
  /// apply to guide geometry.
  void _syncDrawGhostGuideNode() {
    final scene = _scene;
    if (scene == null) return;
    final oldNode = _drawGhostGuideNode;
    if (oldNode != null) scene.remove(oldNode);
    final node = buildSketchGhostNode(widget.drawGhostGuidePolylines, color: sketchGhostGuideColor);
    _drawGhostGuideNode = node;
    if (node != null) scene.add(node);
  }

  /// P20 follow-up: mirrors [_syncDrawGhostNode] for
  /// [PartViewport.drawIndicatorMarkers].
  void _syncDrawIndicatorsNode() {
    final scene = _scene;
    if (scene == null) return;
    final oldNode = _drawIndicatorsNode;
    if (oldNode != null) scene.remove(oldNode);
    final node = buildDrawIndicatorsNode(widget.drawIndicatorMarkers);
    _drawIndicatorsNode = node;
    if (node != null) scene.add(node);
  }

  /// P31: mirrors [_syncDrawGhostNode]'s shape for
  /// [PartViewport.profileFillOutlines] - null [PartViewport.sketchPlaneBasis]
  /// (needed to resolve sketch-local outlines to world space) means no node,
  /// same "null is hidden" convention every other basis-gated node here uses.
  void _syncProfileFillNode() {
    final scene = _scene;
    if (scene == null) return;
    final oldNode = _profileFillNode;
    if (oldNode != null) scene.remove(oldNode);
    final basis = widget.sketchPlaneBasis;
    if (basis == null) {
      _profileFillNode = null;
      return;
    }
    final node = buildProfileFillNode(basis, widget.profileFillOutlines);
    _profileFillNode = node;
    if (node != null) scene.add(node);
  }

  /// P31: mirrors [_syncDrawIndicatorsNode] for
  /// [PartViewport.profileBranchMarkers].
  void _syncProfileBranchMarkersNode() {
    final scene = _scene;
    if (scene == null) return;
    final oldNode = _profileBranchMarkersNode;
    if (oldNode != null) scene.remove(oldNode);
    final node = buildDrawIndicatorsNode(widget.profileBranchMarkers);
    _profileBranchMarkersNode = node;
    if (node != null) scene.add(node);
  }

  /// Animates the camera to look straight down at [plane], per the brief's
  /// camera-animation-into-Sketch feature - smoothly interpolating
  /// [OrbitCamera.orientation] via quaternion `slerp` (never Euler angles, so
  /// there's no risk of gimbal-lock artifacts mid-animation) over
  /// [duration]. Callers (see `PartScreen`) await this and only navigate to
  /// the 2D canvas once it completes.
  ///
  /// 400ms with [Curves.easeInOut] is this implementation's own judgment
  /// call, within the brief's specified 300-500ms range - worth confirming
  /// on a real device that it doesn't feel too slow/fast.
  ///
  /// Needs [TickerProviderStateMixin], not [SingleTickerProviderStateMixin]:
  /// this is called once per "enter a Sketch" action over this State's
  /// whole lifetime, and `SingleTickerProviderStateMixin` only permits
  /// `createTicker` to succeed once ever (even after the prior
  /// `AnimationController` is disposed) - every call past the first would
  /// throw on `AnimationController(vsync: this, ...)` below, silently
  /// rejecting this method's Future before `_openSketch` ever runs.
  /// Bug fix: [flip]/[rotationQuarterTurns] default to the identity - a
  /// caller entering a Sketch that has its own non-default orientation
  /// (see `SketchDto.flip`/`SketchDto.rotationQuarterTurns`) should pass it
  /// through, or the camera frames the plane's raw/unoriented basis while
  /// the Sketch's own geometry - and its Extrude - is actually embedded via
  /// the oriented one, a real mismatch, not just a cosmetic one.
  Future<void> animateToPlane(
    ReferencePlaneKind plane, {
    Duration duration = const Duration(milliseconds: 400),
    bool flip = false,
    int rotationQuarterTurns = 0,
  }) {
    final basis = SketchPlaneBasis.oriented(plane, flip: flip, rotationQuarterTurns: rotationQuarterTurns);
    return _animateOrientationTo(orientationFacingBasis(basis), toTarget: basis.origin, duration: duration);
  }

  /// On-device feedback (new sketch-start camera sequence): animates to the
  /// plane-independent isometric preset ([OrbitCamera.isometricOrientation])
  /// - used for the sketch-orientation-definition step, before the user has
  /// confirmed which plane/flip/rotation they're actually defining, so
  /// there's no single "facing" view yet the way [animateToPlane] has.
  Future<void> animateToIsometric({Duration duration = const Duration(milliseconds: 400)}) {
    return _animateOrientationTo(OrbitCamera.isometricOrientation(), duration: duration);
  }

  /// On-device feedback (bug fix): [animateToPlane]'s own generalization to
  /// a custom (Feature-anchored) Plane, mirroring [PartViewport.
  /// initialViewBasis]'s relationship to [PartViewport.initialViewPlane] -
  /// [basis] already carries whatever flip/rotation the Sketch itself is
  /// oriented with (see [SketchPlaneBasis.oriented]/[SketchPlaneBasis.
  /// withOrientation]), so there's no separate flip/rotationQuarterTurns
  /// parameter here the way [animateToPlane] has.
  Future<void> animateToBasis(
    SketchPlaneBasis basis, {
    Duration duration = const Duration(milliseconds: 400),
  }) {
    return _animateOrientationTo(orientationFacingBasis(basis), toTarget: basis.origin, duration: duration);
  }

  /// Shared slerp-tween machinery [animateToPlane]/[animateToIsometric] both
  /// drive - factored out so the "swings through the back of the target
  /// mid-transition" double-cover fix (see the comment on the hemisphere
  /// check below) and the edge-overlay resync only need to exist once.
  ///
  /// On-device feedback (bug fix): [toTarget], when given, also animates
  /// [OrbitCamera.target] back to the plane's own origin alongside the
  /// orientation slerp - this used to only ever touch orientation, so
  /// "face the plane" was only true about *which way* the camera looked,
  /// not *where* it was actually centered. Nothing else in this class ever
  /// resets [OrbitCamera.target] on its own (only an explicit pan/
  /// [OrbitCamera.setTarget]/[OrbitCamera.reset] does), so if the user had
  /// panned at all before calling [animateToPlane]/[animateToBasis] - e.g.
  /// while exploring the part before confirming a new Sketch's orientation,
  /// or while orbiting a Sketch's own Orbit View before "Return to Default
  /// View" - the orientation alone would resolve to the mathematically
  /// correct facing direction while still being centered on wherever the
  /// user last panned to, which reads as "doesn't align to the sketch
  /// plane" even though the underlying quaternion math was never wrong.
  /// [animateToIsometric] passes no target - during orientation-definition
  /// the user is still free-orbiting to get their bearings, with no single
  /// "correct" center yet the way a resolved plane already has one.
  Future<void> _animateOrientationTo(
    vm.Quaternion to, {
    vm.Vector3? toTarget,
    required Duration duration,
  }) async {
    final from = _camera.orientation;
    // On-device feedback: the camera-into-sketch animation sometimes swung
    // through the *back* of the target plane mid-transition, even though the
    // final resting orientation (checked statically by
    // test/orientation_facing_plane_test.dart) was correct - a quaternion
    // and its negation represent the exact same static rotation (mathematically
    // indistinguishable, which is exactly why that test couldn't catch this),
    // but slerp-ing *towards* the "wrong-signed" copy of an otherwise-correct
    // target takes the long way around instead of the short one. Forcing
    // `to` onto the same hemisphere as `from` (equivalent to negating - a
    // quaternion and its negation are the same rotation, so this changes
    // nothing about where the animation ends, only the path it takes) is the
    // standard fix for this "double cover" quaternion interpolation pitfall.
    if (from.x * to.x + from.y * to.y + from.z * to.z + from.w * to.w < 0) {
      to = vm.Quaternion(-to.x, -to.y, -to.z, -to.w);
    }
    final fromTarget = _camera.target;
    final controller = AnimationController(vsync: this, duration: duration);
    final curved = CurvedAnimation(parent: controller, curve: Curves.easeInOut);
    void tick() {
      if (!mounted) return;
      setState(() {
        _camera.orientation = from.slerp(to, curved.value);
        if (toTarget != null) {
          _camera.target = fromTarget + (toTarget - fromTarget) * curved.value;
        }
      });
    }

    controller.addListener(tick);
    try {
      await controller.forward();
    } finally {
      controller.removeListener(tick);
      controller.dispose();
      // C3: the camera orientation just changed - resync the edge overlay's
      // towards-camera bias (see [_syncEdgesNode]) for the new view.
      if (mounted) setState(_syncEdgesNode);
    }
  }

  /// On-device feedback: matches this camera's target/distance to exactly
  /// what a 2D `SketchViewport` is currently showing, so a locked,
  /// non-interactive backdrop (`SketchScreen`'s shaded-body backdrop) stays
  /// visually in sync with the flat 2D canvas above it as it's panned/
  /// zoomed - unlike [animateToPlane], this only ever makes sense for a
  /// [PartViewport] built with a fixed [PartViewport.initialViewPlane], and
  /// jumps immediately rather than animating (called continuously as the
  /// 2D canvas moves, so an animated tween here would always be chasing a
  /// moving target).
  ///
  /// [pixelsPerUnit]/[panOffsetPx] mirror `SketchViewport`'s own
  /// `basePixelsPerUnit * zoom`/`panOffset` fields exactly; [canvasSize] is
  /// that same canvas's current render size. The math: the sketch-space
  /// point currently at the *centre* of the 2D canvas is derived by
  /// inverting `ViewTransform.sketchToScreen` at the canvas's own centre,
  /// then mapped into world space via [plane]'s basis (`sketchPointToWorld`,
  /// the same projection every other 3D-sketch-geometry consumer already
  /// uses) to become the new camera target; the distance is solved so the
  /// camera's vertical field of view exactly spans `canvasSize.height /
  /// pixelsPerUnit` world units at that target, matching flutter_scene's
  /// fixed `kCameraVerticalFovRadians` perspective FOV. This specific
  /// backdrop-sync computation assumes a perspective FOV match and hasn't
  /// been revisited for [OrbitCamera.isPerspective]'s now-real orthographic
  /// case (Phase 2 of the sketcher restructure) - flagged, not fixed, since
  /// this method is a locked-camera-sync special case, not the general
  /// [OrbitCamera.cameraFor] path every other caller goes through.
  /// Bug fix: [flip]/[rotationQuarterTurns] default to the identity - a
  /// caller syncing an oriented Sketch's own backdrop should pass the real
  /// values (see `SketchDto.flip`/`SketchDto.rotationQuarterTurns`), or the
  /// backdrop's camera target is derived from the plane's raw/unoriented
  /// basis while the ghost-outline overlay drawn on top of it (and the
  /// Sketch's own eventual Extrude) both use the oriented one - the two
  /// visibly drift out of registration with each other whenever orientation
  /// isn't the default.
  void syncToSketchViewport({
    required ReferencePlaneKind plane,
    required double pixelsPerUnit,
    required Offset panOffsetPx,
    required Size canvasSize,
    bool flip = false,
    int rotationQuarterTurns = 0,
  }) {
    if (pixelsPerUnit <= 0 || canvasSize.isEmpty) return;
    final basis = SketchPlaneBasis.oriented(plane, flip: flip, rotationQuarterTurns: rotationQuarterTurns);
    // Inverse of ViewTransform.sketchToScreen at screen-centre (originScreen
    // = screenCentre + panOffsetPx): the sketch-space point currently
    // rendered at the canvas's own centre.
    //
    // On-device feedback (round 3): reverted round 2's un-negated sketchX -
    // that was an unverified compensating guess made before
    // `test/orientation_facing_plane_test.dart` existed. That test now
    // proves `orientationFacingPlane`'s right/up/direction already matched
    // `SketchPlaneBasis` exactly for XZ at the time of round 2 (YZ was the
    // one genuinely wrong - see that function's own doc comment), so
    // negating sketchX here (the direct, provable inverse of
    // ViewTransform.sketchToScreen) was correct all along; the round-2 flip
    // introduced a real static mismatch between this backdrop and its own
    // (unrelated, always-correct) ghost-outline projection instead of
    // fixing anything.
    final sketchX = -panOffsetPx.dx / pixelsPerUnit;
    final sketchY = panOffsetPx.dy / pixelsPerUnit;
    final target = sketchPointToWorld(basis, sketchX, sketchY);
    final visibleWorldHeight = canvasSize.height / pixelsPerUnit;
    final distance = visibleWorldHeight / (2 * math.tan(kCameraVerticalFovRadians / 2));
    // No "did this actually change" guard here (vector_math's Vector3
    // doesn't override ==, so a same-value check would just always be
    // false) - the caller (SketchCanvas's onViewportChanged) already only
    // fires when its own pan/zoom/size genuinely changed, so this is
    // already called no more often than necessary.
    setState(() {
      _camera.target = target;
      _camera.distance = distance;
    });
  }

  void _handlePointerDown(PointerDownEvent event) {
    _gestureTravel = 0;
    if (event.kind == PointerDeviceKind.mouse) return;
    _activeTouches[event.pointer] = event.localPosition;
    _hadMultiTouch = _activeTouches.length > 1;
  }

  void _handlePointerMove(PointerMoveEvent event) {
    _gestureTravel += event.delta.distance;
    if (event.kind == PointerDeviceKind.mouse) {
      if (event.buttons & kPrimaryMouseButton != 0) {
        setState(() => _camera.orbitByScreenDelta(event.delta.dx, event.delta.dy));
      } else if (event.buttons & kSecondaryMouseButton != 0) {
        setState(() => _camera.panByScreenDelta(event.delta.dx, event.delta.dy));
      }
      return;
    }

    if (_activeTouches.length < 2) {
      setState(() => _camera.orbitByScreenDelta(event.delta.dx, event.delta.dy));
      return;
    }

    _hadMultiTouch = true;
    final before = Map<int, Offset>.from(_activeTouches);
    _activeTouches[event.pointer] = event.localPosition;
    _applyPinchPan(before, _activeTouches);
  }

  void _handlePointerEnd(PointerEvent event) {
    final wasTap = event is PointerUpEvent && !_hadMultiTouch && _gestureTravel < _tapTravelThreshold;
    if (event.kind != PointerDeviceKind.mouse) {
      _activeTouches.remove(event.pointer);
      if (_activeTouches.isEmpty) _hadMultiTouch = false;
    }
    if (wasTap) {
      _handleTap(event.localPosition);
    }
  }

  /// Converts a confirmed tap into a [ReferencePlaneKind] hit-test, via the
  /// same [PerspectiveCamera.screenPointToRay] `flutter_scene` already
  /// builds for its own picking/`raycast.dart` - reused here rather than
  /// reimplementing screen-to-world unprojection by hand.
  void _handleTap(Offset localPosition) {
    final ray = _camera.cameraFor(_viewportSize).screenPointToRay(localPosition, _viewportSize);
    final hit = widget.referencePlanesHidden ? null : hitTestReferencePlanes(ray);
    if (hit != null) {
      widget.onPlaneTap(hit.plane);
      return;
    }
    // C3: checked after the three fixed reference planes so those keep
    // first claim on a tap (see [PartViewport.onCreatePlaneTap]'s own doc
    // comment).
    final createPlaneHit = hitTestCreatePlanes(ray, widget.createPlanes);
    if (createPlaneHit != null) {
      widget.onCreatePlaneTap?.call(createPlaneHit.featureId);
      return;
    }
    // Sketcher restructure Phase 2: the embedded 3D sketcher's own plane -
    // see [PartViewport.sketchPlaneBasis]'s own doc comment for why this is
    // checked last but is, in practice, mutually exclusive with the checks
    // above.
    final sketchPlaneBasis = widget.sketchPlaneBasis;
    if (sketchPlaneBasis != null) {
      final sketchHit = hitTestSketchPlane(ray, sketchPlaneBasis);
      if (sketchHit != null) {
        if (widget.preferEntityPick) {
          final (localX, localY) = worldPointToSketch(sketchPlaneBasis, sketchHit.$1);
          final nearExisting = widget.hasEntityNearSketchTap?.call(localX, localY) ?? false;
          if (!nearExisting) {
            // vertex/edge only by default - a face isn't a valid dimension
            // target (no `pickReferenceGhostFace`-equivalent exists there),
            // and leaving `filter.face` at its default `true` would
            // otherwise swallow the tap silently (onSketchEntityTap fired
            // with a `.face` kind widget.onSketchEntityTap has no case for)
            // instead of correctly falling through to the ordinary
            // plane-tap miss behavior below. On-device feedback: Convert
            // Entities widens this via [preferEntityPickIncludesFace].
            final bodyHit = hitTestBodies(
              ray: ray,
              viewportSize: _viewportSize,
              bodies: widget.bodies,
              filter: SelectionFilterState(
                vertex: true,
                edge: true,
                face: widget.preferEntityPickIncludesFace,
                body: false,
              ),
              facesOccludeOtherHits: widget.renderMode.showsFilledFaces && !widget.bodiesHidden,
            );
            if (bodyHit != null) {
              widget.onSketchEntityTap?.call(bodyHit.entity);
              return;
            }
          }
        }
        widget.onSketchPlaneTap?.call(sketchHit.$1, _localPixelsPerSketchUnit(sketchHit.$1, sketchPlaneBasis));
        return;
      }
    }
    widget.onBackgroundTap();
  }

  void _handlePointerSignal(PointerSignalEvent event) {
    if (event is PointerScrollEvent) {
      // Scrolling "down" (positive dy) zooms out - same convention as
      // SketchCanvas, but inverted in effect since a bigger `distance`
      // (unlike a bigger sketch `zoom`) means further away/more zoomed out.
      final scaleFactor = event.scrollDelta.dy > 0 ? 1.1 : 1 / 1.1;
      setState(() => _camera.zoomByFactor(scaleFactor));
    }
  }

  void _applyPinchPan(Map<int, Offset> before, Map<int, Offset> after) {
    final beforeCentroid = _centroidOf(before.values);
    final afterCentroid = _centroidOf(after.values);
    final beforeSpread = _averageSpread(before.values, beforeCentroid);
    final afterSpread = _averageSpread(after.values, afterCentroid);
    final panDelta = afterCentroid - beforeCentroid;

    setState(() {
      _camera.panByScreenDelta(panDelta.dx, panDelta.dy);
      if (beforeSpread > 1e-6) {
        _camera.zoomByFactor(beforeSpread / afterSpread);
      }
    });
  }

  Offset _centroidOf(Iterable<Offset> points) {
    var sum = Offset.zero;
    for (final point in points) {
      sum += point;
    }
    return sum / points.length.toDouble();
  }

  double _averageSpread(Iterable<Offset> points, Offset centroid) {
    if (points.length < 2) return 0;
    var total = 0.0;
    for (final point in points) {
      total += (point - centroid).distance;
    }
    return total / points.length;
  }

  // --- Stage 23 Items 2/3: selection-mode cursor/hover dispatch -----------
  //
  // Everything below is purely additive on top of the existing
  // orbit/pan/zoom/tap gesture handlers above - none of those methods are
  // modified by a single line, per Item 7's "do not touch the existing
  // orbit logic in any way". These wrappers only decide, per pointer event,
  // whether to forward to the existing orbit handler (selection mode off)
  // or to the new selection-mode cursor logic (selection mode on); orbit
  // mode's own behaviour is unreachable from here.

  Offset _viewportCenter() => Offset(_viewportSize.width / 2, _viewportSize.height / 2);

  void _onPointerDown(PointerDownEvent event) {
    if (widget.selectionMode) {
      // P25: mirrors sketch_canvas.dart's own "the marquee gesture only
      // ever tracks one pointer - a second finger touching down mid-drag
      // is ignored outright" - never reaches _handlePointerDown at all
      // while a marquee is already active.
      if (_marqueeActive) return;
      // Fix 4: starts the tap/drag disambiguation for this gesture, mirroring
      // the orbit handler's own _gestureTravel reset in _handlePointerDown.
      _selectionGestureTravel = 0;
      // Bug-fix round: also feeds this pointer into the same _activeTouches
      // bookkeeping orbit mode uses, by calling _handlePointerDown itself
      // (unmodified - it's pure bookkeeping, no camera side effect) rather
      // than duplicating it - so a second finger touching down while
      // selecting is recognised for pinch-zoom/two-finger-pan below,
      // exactly like orbit mode already gets for free.
      _handlePointerDown(event);
      // P25: a second finger joining cancels any pending long-press -
      // becomes a pinch/pan gesture instead, never a marquee.
      if (_activeTouches.length > 1) {
        _cancelMarqueeLongPress();
      } else {
        _maybeStartMarqueeLongPress(event.localPosition);
      }
      return;
    }
    if (widget.drawCursorMode) {
      // P16: same tap/drag disambiguation reset as the selectionMode branch
      // above, for the draw cursor's own gesture.
      _drawCursorGestureTravel = 0;
      _handlePointerDown(event);
      return;
    }
    _handlePointerDown(event);
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (widget.selectionMode) {
      if (_marqueeActive) {
        setState(() => _marqueeCurrentScreen = event.localPosition);
        return;
      }
      if (_marqueeLongPressTimer != null) {
        final down = _marqueeDownScreen;
        if (down != null && (event.localPosition - down).distance > _tapTravelThreshold) {
          _cancelMarqueeLongPress();
        }
      }
      _selectionGestureTravel += event.delta.distance;
      if (event.kind == PointerDeviceKind.mouse) {
        _handleSelectionPointerHover(event.localPosition);
        return;
      }
      if (_activeTouches.length < 2) {
        _handleSelectionPointerMove(event.delta);
        return;
      }
      // Bug-fix round: pinch-zoom/two-finger-pan must still work while
      // selecting - reuses _applyPinchPan (the same method orbit mode's own
      // _handlePointerMove calls) directly, without editing that method or
      // _handlePointerMove's body at all.
      _hadMultiTouch = true;
      final before = Map<int, Offset>.from(_activeTouches);
      _activeTouches[event.pointer] = event.localPosition;
      _applyPinchPan(before, _activeTouches);
      return;
    }
    if (widget.drawCursorMode) {
      // P16: mirrors the selectionMode branch above exactly, retargeted to
      // the draw cursor's own move/hover handlers.
      _drawCursorGestureTravel += event.delta.distance;
      if (event.kind == PointerDeviceKind.mouse) {
        _handleDrawCursorHover(event.localPosition);
        return;
      }
      if (_activeTouches.length < 2) {
        _handleDrawCursorMove(event.delta);
        return;
      }
      _hadMultiTouch = true;
      final before = Map<int, Offset>.from(_activeTouches);
      _activeTouches[event.pointer] = event.localPosition;
      _applyPinchPan(before, _activeTouches);
      return;
    }
    _handlePointerMove(event);
  }

  void _onPointerEnd(PointerEvent event) {
    if (widget.selectionMode) {
      if (_marqueeActive) {
        if (event.kind != PointerDeviceKind.mouse) {
          _activeTouches.remove(event.pointer);
          if (_activeTouches.isEmpty) _hadMultiTouch = false;
        }
        setState(() {
          _endMarquee();
          _syncEdgesNode();
        });
        return;
      }
      // A pending (not yet fired) long-press timer never gets the chance to
      // fire if its pointer lifts first - mirrors sketch_canvas.dart's own
      // _cancelLongPress call at the same point.
      _cancelMarqueeLongPress();
      // Fix 4: tap-to-select - a pointer-up that stayed within the tap
      // travel threshold commits the current hover, the same logic the
      // removed "Select" button used to call. A drag that moved the cursor
      // (PointerCancel, or PointerUp past the threshold) commits nothing -
      // nor does the tail end of a pinch (fingers lifting one at a time),
      // per [_hadMultiTouch] below, mirroring orbit mode's own
      // _handlePointerEnd exactly.
      final wasTap = event is PointerUpEvent &&
          !_hadMultiTouch &&
          _selectionGestureTravel < _tapTravelThreshold;
      if (event.kind != PointerDeviceKind.mouse) {
        _activeTouches.remove(event.pointer);
        if (_activeTouches.isEmpty) _hadMultiTouch = false;
      }
      if (wasTap) _commitSelection();
      // C3: a two-finger pinch-zoom/pan (_applyPinchPan) can still move the
      // camera while selecting - resync the edge overlay's towards-camera
      // bias the same as the orbit-mode path below does.
      setState(_syncEdgesNode);
      return;
    }
    if (widget.drawCursorMode) {
      // P16: same tap-vs-drag commit logic as the selectionMode branch
      // above, firing onDrawCursorCommit instead of onSelectionToggle.
      final wasTap = event is PointerUpEvent &&
          !_hadMultiTouch &&
          _drawCursorGestureTravel < _tapTravelThreshold;
      if (event.kind != PointerDeviceKind.mouse) {
        _activeTouches.remove(event.pointer);
        if (_activeTouches.isEmpty) _hadMultiTouch = false;
      }
      if (wasTap) _commitDrawCursor();
      setState(_syncEdgesNode);
      return;
    }
    _handlePointerEnd(event);
    // C3: the orbit/pan/zoom gesture that just ended may have moved the
    // camera - resync the edge overlay's towards-camera bias (see
    // [_syncEdgesNode]) once per completed gesture, not on every
    // intermediate pointer-move delta.
    setState(_syncEdgesNode);
  }

  void _onPointerHover(PointerHoverEvent event) {
    if (widget.selectionMode) {
      _handleSelectionPointerHover(event.localPosition);
      return;
    }
    if (widget.drawCursorMode) {
      _handleDrawCursorHover(event.localPosition);
      return;
    }
    // No orbit-mode hover handling exists.
  }

  /// Item 2: "Drag moves cursor relatively (sensitivity-scaled, not 1:1);
  /// lifting/re-touching doesn't jump cursor" - reusing Flutter's own
  /// per-event [delta] (rather than tracking a touch-start position the way
  /// the orbit handlers do) means a finger lifting and a different finger
  /// touching back down never causes a jump, since neither event carries a
  /// delta of its own.
  void _handleSelectionPointerMove(Offset delta) {
    final current = _cursorPosition ?? _viewportCenter();
    setState(() {
      _cursorPosition = _clampToViewport(current + delta * _cursorDragSensitivity);
      _recomputeHover();
      _syncHoverNode();
    });
  }

  /// Item 2: "Desktop mouse move drives cursor" - absolute, not delta-based,
  /// since a real mouse's position is meaningful on its own.
  void _handleSelectionPointerHover(Offset localPosition) {
    setState(() {
      _cursorPosition = _clampToViewport(localPosition);
      _recomputeHover();
      _syncHoverNode();
    });
  }

  Offset _clampToViewport(Offset position) {
    if (_viewportSize.isEmpty) return position;
    return Offset(
      position.dx.clamp(0.0, _viewportSize.width),
      position.dy.clamp(0.0, _viewportSize.height),
    );
  }

  /// Item 3's hover hit-test, run from [_cursorPosition] - null result
  /// clears any prior hover (cursor moved over empty background).
  ///
  /// C5: also competes a reference-plane/created-Plane hit (see
  /// [_hoverHitTestPlanes]) against the mesh/sketch hit, by [HoverHit.rayT] -
  /// planes are now selectable in Selection mode via this same cursor/hover/
  /// commit pipeline (never via [onPlaneTap]/[onCreatePlaneTap], which - see
  /// [_onPointerEnd] - are only ever reached in Orbit mode).
  void _recomputeHover() {
    final cursor = _cursorPosition;
    if (cursor == null) {
      _hoverHit = null;
      return;
    }
    final ray = _camera.cameraFor(_viewportSize).screenPointToRay(cursor, _viewportSize);
    // Prompt C1: previously gated on `widget.bodies.isEmpty` alone, which
    // skipped hit-testing entirely for a Part with no Bodies yet (e.g. a
    // bare Sketch with no Extrude) - now also runs whenever there's Sketch
    // geometry to test, since that's real pickable content on its own.
    final meshHit = (widget.bodies.isEmpty && widget.sketchGeometries.isEmpty)
        ? null
        : hitTestBodies(
            ray: ray,
            viewportSize: _viewportSize,
            bodies: widget.bodies,
            sketchGeometries: widget.sketchGeometries,
            filter: widget.selectionFilter,
            facesOccludeOtherHits: widget.renderMode.showsFilledFaces && !widget.bodiesHidden,
          );
    final planeHit = _hoverHitTestPlanes(ray);
    if (meshHit == null) {
      _hoverHit = planeHit;
    } else if (planeHit == null) {
      _hoverHit = meshHit;
    } else {
      _hoverHit = meshHit.rayT <= planeHit.rayT ? meshHit : planeHit;
    }
  }

  /// C5: hit-tests reference planes then created planes (same precedence
  /// [_handleTap] already used for the pre-C5 Orbit-mode-only tap path -
  /// see [hitTestCreatePlanes]'s own doc comment for why reference planes
  /// keep first claim), wrapped as a [HoverHit] so [_recomputeHover] can
  /// depth-compare it against a mesh/sketch hit along the same ray.
  ///
  /// On-device feedback: gated on [SelectionFilterState.plane] - C5 shipped
  /// this hit-test with no filter check at all, so a picking mode that
  /// turns every other kind off (e.g. Fillet's edge/face-only filter) still
  /// left planes selectable regardless, since there was nothing here to
  /// turn off in the first place.
  HoverHit? _hoverHitTestPlanes(vm.Ray ray) {
    if (!widget.selectionFilter.plane) return null;
    final referenceHit = widget.referencePlanesHidden ? null : hitTestReferencePlanes(ray);
    if (referenceHit != null) {
      return HoverHit(
        entity: SelectionEntityRef(
          kind: SelectionEntityKind.referencePlane,
          referencePlaneKind: referenceHit.plane,
        ),
        rayT: referenceHit.rayT,
      );
    }
    final createHit = hitTestCreatePlanes(ray, widget.createPlanes);
    if (createHit == null) return null;
    return HoverHit(
      entity: SelectionEntityRef(kind: SelectionEntityKind.createPlane, planeFeatureId: createHit.featureId),
      rayT: createHit.rayT,
    );
  }

  /// Fix 4 (Item 4): fired by a tap (as opposed to a cursor-drag - see
  /// [_onPointerEnd]) in selection mode. Commits the current hover (if any)
  /// as a toggle, or clears the whole selection set if the cursor is over
  /// empty space - [PartScreen] (which owns the actual selection set)
  /// decides add-vs-remove via [PartViewport.onSelectionToggle].
  ///
  /// P44e bug fix (on-device feedback: "I can't select a dimension,
  /// clicking the dimension does nothing" / "I can't select a constraint
  /// by clicking its glyph"): a plain Select-mode tap never checked
  /// [widget.constraintOverlayItems] at all - only [_commitDrawCursor]
  /// (Dimension mode / drag mode) did, gated on [widget.
  /// preferConstraintOverlayHitOnCommit], which is false in plain Select
  /// mode. Mirrors `sketch_canvas.dart`'s own `_dispatchTap`, which always
  /// checks `_constraintIdAt` first while `mode == SketchMode.select`,
  /// ahead of its ordinary entity hit-test - reuses [_cursorPosition] (now
  /// valid in this mode too, since [PartViewport.selectionMode] and
  /// [PartViewport.drawCursorMode] share the one field - see that field's
  /// own doc comment) the exact same way [_commitDrawCursor] already does.
  void _commitSelection() {
    if (widget.onConstraintOverlayItemTap != null) {
      final basis = widget.sketchPlaneBasis;
      final cursor = _cursorPosition;
      final hitId = (basis != null && cursor != null)
          ? constraintOverlayItemAt(_camera.cameraFor(_viewportSize), _viewportSize, basis, widget.constraintOverlayItems, cursor)
          : null;
      if (hitId != null && widget.onConstraintOverlayItemTap!(hitId)) return;
    }
    final hit = _hoverHit;
    if (hit == null) {
      widget.onClearSelection?.call();
    } else {
      widget.onSelectionToggle?.call(hit.entity);
    }
  }

  // ---- P25: marquee-select (long-press-then-drag, selection mode only) ---

  /// A one-off probe mirroring [_recomputeHover]'s own hit-test, but at an
  /// arbitrary [screenPosition] rather than [_cursorPosition], and without
  /// mutating [_hoverHit] - used by [_maybeStartMarqueeLongPress] to decide
  /// whether a press landed on existing geometry (which should behave like
  /// an ordinary press-and-hold, never growing into a marquee) or genuinely
  /// empty space, mirroring `sketch_canvas.dart`'s own `hasEntityNear`
  /// check in `_maybeStartLongPress`.
  bool _hasEntityNearScreenPoint(Offset screenPosition) {
    final ray = _camera.cameraFor(_viewportSize).screenPointToRay(screenPosition, _viewportSize);
    final meshHit = (widget.bodies.isEmpty && widget.sketchGeometries.isEmpty)
        ? null
        : hitTestBodies(
            ray: ray,
            viewportSize: _viewportSize,
            bodies: widget.bodies,
            sketchGeometries: widget.sketchGeometries,
            filter: widget.selectionFilter,
            facesOccludeOtherHits: widget.renderMode.showsFilledFaces && !widget.bodiesHidden,
          );
    return meshHit != null || _hoverHitTestPlanes(ray) != null;
  }

  /// Starts the long-press timer when [downScreen] lands on genuinely empty
  /// space while in selection mode - mirrors `sketch_canvas.dart`'s own
  /// `_maybeStartLongPress` exactly (same duration, same "only from blank
  /// canvas" rule via [_hasEntityNearScreenPoint]).
  void _maybeStartMarqueeLongPress(Offset downScreen) {
    if (_hasEntityNearScreenPoint(downScreen)) return;
    _marqueeDownScreen = downScreen;
    _marqueeLongPressTimer?.cancel();
    _marqueeLongPressTimer = Timer(_marqueeLongPressDuration, () => _startMarquee(downScreen));
  }

  /// Fires once [_marqueeLongPressDuration] elapses without the pointer
  /// travelling far enough to cancel (see [_onPointerMove]'s own
  /// selectionMode branch) - switches the gesture state machine over to
  /// marquee-drag mode.
  void _startMarquee(Offset downScreen) {
    _marqueeLongPressTimer = null;
    setState(() {
      _marqueeActive = true;
      _marqueeDownScreen = downScreen;
      _marqueeCurrentScreen = downScreen;
    });
  }

  /// Cancels a pending (not yet fired) long-press timer - does not affect
  /// an already-active marquee, which only ends via [_endMarquee].
  void _cancelMarqueeLongPress() {
    _marqueeLongPressTimer?.cancel();
    _marqueeLongPressTimer = null;
    _marqueeDownScreen = null;
  }

  /// Ends the active marquee on pointer-up/-cancel - resolves both
  /// screen-space corners onto [PartViewport.sketchPlaneBasis] via
  /// [hitTestSketchPlane], builds their sketch-space axis-aligned bounding
  /// [Rect] (not a literal projection of the screen rectangle, which -
  /// unless the camera happens to be looking straight at the plane -
  /// wouldn't be a rectangle in sketch space at all; a bounding box around
  /// both resolved corners is a reasonable, honest approximation for an
  /// oblique view, consistent with this whole feature's "close enough, not
  /// pixel-perfect" spirit), then fires [PartViewport.onMarqueeSelect]. A
  /// long-press that never actually dragged (both corners resolve to the
  /// same point) still fires, with a zero-area Rect - matching
  /// `sketch_canvas.dart`'s own "selects nothing" outcome for that case
  /// (`SketchController.selectInRect`'s own "fully inside" rule excludes
  /// everything from a zero-area rect).
  void _endMarquee() {
    final anchor = _marqueeDownScreen;
    final current = _marqueeCurrentScreen;
    _marqueeActive = false;
    _marqueeDownScreen = null;
    _marqueeCurrentScreen = null;
    final basis = widget.sketchPlaneBasis;
    if (anchor == null || current == null || basis == null) return;
    final camera = _camera.cameraFor(_viewportSize);
    final anchorHit = hitTestSketchPlane(camera.screenPointToRay(anchor, _viewportSize), basis);
    final currentHit = hitTestSketchPlane(camera.screenPointToRay(current, _viewportSize), basis);
    if (anchorHit == null || currentHit == null) return;
    final (anchorX, anchorY) = worldPointToSketch(basis, anchorHit.$1);
    final (currentX, currentY) = worldPointToSketch(basis, currentHit.$1);
    widget.onMarqueeSelect?.call(Rect.fromPoints(Offset(anchorX, anchorY), Offset(currentX, currentY)));
  }

  // ---- P16: draw-cursor mode's own cursor/raycast/commit dispatch --------
  //
  // Mirrors the selection-mode block above exactly, retargeted from
  // entity-hover to a continuous [PartViewport.sketchPlaneBasis] raycast via
  // [hitTestSketchPlane] instead of [hitTestBodies].

  /// Mirrors [_handleSelectionPointerMove]. Notifies
  /// [PartViewport.onDrawCursorMoved] *after* [setState] (not from inside
  /// [_recomputeDrawCursor] itself - see that method's own doc comment for
  /// why), same as every other genuinely pointer-event-driven entry point
  /// into this State.
  void _handleDrawCursorMove(Offset delta) {
    final scaledDelta = delta * _cursorDragSensitivity;
    final current = _cursorPosition ?? _viewportCenter();
    setState(() {
      _cursorPosition = _clampToViewport(current + scaledDelta);
      _recomputeDrawCursor();
      // P46 bug fix (on-device feedback: "when i enter the dimension tool,
      // dynamic highlight stops working"): drawCursorMode never ran an
      // entity-level hover-hit-test at all (only the plane raycast above,
      // for placing/picking a point on the sketch plane itself) - reuses
      // [_recomputeHover]/[_syncHoverNode] exactly as selectionMode already
      // does (see [_handleSelectionPointerMove]), safe now that both modes
      // share the same [_cursorPosition] field.
      _recomputeHover();
      _syncHoverNode();
    });
    // P41: a grabbed constraint label's own offset lives in screen space,
    // not an absolute world/sketch position - see
    // [PartViewport.isDraggingConstraintLabel]'s own doc comment.
    if (widget.isDraggingConstraintLabel) {
      // P44f bug fix (on-device feedback: "the arrow should remain at the
      // same angular position when orbiting"): a radial dimension's own
      // leader angle can't safely be persisted as a screen-pixel delta
      // (see [PartViewport.onRadialLabelAngleDragged]'s own doc comment) -
      // resolved here instead, since this State alone has the live camera
      // needed to convert the cursor's current screen position into a
      // camera-independent sketch-local angle.
      ConstraintRadialDimensionItem? radialItem;
      for (final candidate in widget.constraintOverlayItems) {
        if (candidate.constraintId == widget.draggingConstraintLabelId &&
            candidate is ConstraintRadialDimensionItem) {
          radialItem = candidate;
          break;
        }
      }
      final basis = widget.sketchPlaneBasis;
      final cursor = _cursorPosition;
      if (radialItem != null && basis != null && cursor != null) {
        final projected =
            projectRadialDimensionBasis(_camera.cameraFor(_viewportSize), _viewportSize, basis, radialItem);
        if (projected != null) {
          final (centerScreen, rimScreen, perpScreen) = projected;
          final desiredDelta = cursor - centerScreen;
          if (desiredDelta.distance > 1e-6) {
            final angle = radialDimensionAngleDegrees(
              centerScreen: centerScreen,
              rimScreen: rimScreen,
              perpScreen: perpScreen,
              desiredDirection: desiredDelta / desiredDelta.distance,
            );
            if (angle != null) {
              widget.onRadialLabelAngleDragged?.call(angle);
              // Bug fix (on-device feedback: "radius and diameter
              // dimensions are locked a set distance from the arc or
              // circle"): [onRadialLabelDistanceDragged]'s own doc comment
              // covers why - resolved here since [radiusPixels]/
              // [pixelsPerUnit] need the same live camera/projection the
              // angle resolve above already has.
              final rimSketchDx = radialItem.rim.$1 - radialItem.center.$1;
              final rimSketchDy = radialItem.rim.$2 - radialItem.center.$2;
              final rimSketchDistance = math.sqrt(rimSketchDx * rimSketchDx + rimSketchDy * rimSketchDy);
              if (rimSketchDistance > 1e-9) {
                final pixelsPerUnit = (rimScreen - centerScreen).distance / rimSketchDistance;
                final radiusPixels = radialItem.radius * pixelsPerUnit;
                final legPixels = desiredDelta.distance - radiusPixels;
                widget.onRadialLabelDistanceDragged?.call(legPixels / pixelsPerUnit);
              }
              return;
            }
          }
        }
      }
      // P52 bug fix (on-device feedback: "when orbiting, linear dimensions
      // slide along the line") - [onLinearLabelOffsetDragged]'s own doc
      // comment covers why.
      ConstraintLinearDimensionItem? linearItem;
      for (final candidate in widget.constraintOverlayItems) {
        if (candidate.constraintId == widget.draggingConstraintLabelId &&
            candidate is ConstraintLinearDimensionItem) {
          linearItem = candidate;
          break;
        }
      }
      if (linearItem != null && basis != null && cursor != null) {
        // Bug fix (on-device feedback: "vertical dimension can't be dragged
        // left/right, up/down is inverted"): an axis-locked orientation is
        // handled entirely in sketch-local coordinates, matching
        // [_axisLockedDimensionEndpoints]'s own reconstruction exactly (see
        // that function's own doc comment) - no normal/dot-product needed,
        // just the sketch-local cursor hit's own coordinate along the
        // locked axis.
        if (linearItem.orientation == 'vertical' || linearItem.orientation == 'horizontal') {
          final ray = _camera.cameraFor(_viewportSize).screenPointToRay(cursor, _viewportSize);
          final hit = hitTestSketchPlane(ray, basis);
          if (hit != null) {
            final (cursorX, cursorY) = worldPointToSketch(basis, hit.$1);
            final vertical = linearItem.orientation == 'vertical';
            final cursorAxis = vertical ? cursorX : cursorY;
            final reference = vertical
                ? math.max(linearItem.pointA.$1, linearItem.pointB.$1)
                : math.max(linearItem.pointA.$2, linearItem.pointB.$2);
            widget.onLinearLabelOffsetDragged?.call(cursorAxis - reference);
            return;
          }
        } else {
          // Bug fix (on-device feedback: same bug class as
          // [canonicalPerpendicular]'s own doc comment, just never applied
          // to this drag-side computation): mirrors
          // [_ConstraintOverlayPainter._paintLinearDimension]'s `default:`
          // branch exactly - the same screen-projected points, the same
          // [canonicalPerpendicular] sign canonicalization - so drag-write
          // and paint-read can never disagree on sign regardless of which
          // constrained Point the backend happened to store as A vs B.
          final camera = _camera.cameraFor(_viewportSize);
          final aScreen = worldToScreen(camera, _viewportSize, sketchPointToWorld(basis, linearItem.pointA.$1, linearItem.pointA.$2));
          final bScreen = worldToScreen(camera, _viewportSize, sketchPointToWorld(basis, linearItem.pointB.$1, linearItem.pointB.$2));
          if (aScreen != null && bScreen != null) {
            final screenDelta = bScreen - aScreen;
            final screenLength = screenDelta.distance;
            if (screenLength > 1e-6) {
              final normal = canonicalPerpendicular(screenDelta);
              final dx = linearItem.pointB.$1 - linearItem.pointA.$1;
              final dy = linearItem.pointB.$2 - linearItem.pointA.$2;
              final sketchLength = math.sqrt(dx * dx + dy * dy);
              final ratio = sketchLength > 1e-9 ? sketchLength / screenLength : 1.0;
              final cursorDelta = cursor - aScreen;
              final screenMagnitude = cursorDelta.dx * normal.dx + cursorDelta.dy * normal.dy;
              widget.onLinearLabelOffsetDragged?.call(screenMagnitude * ratio);
              return;
            }
          }
        }
      }
      // Bug fix (on-device feedback: same "locked/drifts on orbit" bug
      // class as the radial/linear fixes above, just for a Line-to-Line
      // distance dimension - this drag branch never existed at all, so the
      // dimension fell through to the raw-pixel [onConstraintLabelDragDelta]
      // path below despite [ConstraintLineDistanceDimensionItem] already
      // carrying a working, camera-independent `sketchLocalOffsetDistance`
      // field with nothing to feed it) - mirrors
      // [_ConstraintOverlayPainter._paintLineDistanceDimension]'s own
      // `alongA` direction exactly, entirely in sketch-local space.
      ConstraintLineDistanceDimensionItem? lineDistanceItem;
      for (final candidate in widget.constraintOverlayItems) {
        if (candidate.constraintId == widget.draggingConstraintLabelId &&
            candidate is ConstraintLineDistanceDimensionItem) {
          lineDistanceItem = candidate;
          break;
        }
      }
      if (lineDistanceItem != null && basis != null && cursor != null) {
        final ray = _camera.cameraFor(_viewportSize).screenPointToRay(cursor, _viewportSize);
        final hit = hitTestSketchPlane(ray, basis);
        if (hit != null) {
          final (cursorX, cursorY) = worldPointToSketch(basis, hit.$1);
          final dx = lineDistanceItem.line1End.$1 - lineDistanceItem.line1Start.$1;
          final dy = lineDistanceItem.line1End.$2 - lineDistanceItem.line1Start.$2;
          final lengthA = math.sqrt(dx * dx + dy * dy);
          if (lengthA > 1e-9) {
            final alongX = dx / lengthA;
            final alongY = dy / lengthA;
            final midAx = (lineDistanceItem.line1Start.$1 + lineDistanceItem.line1End.$1) / 2;
            final midAy = (lineDistanceItem.line1Start.$2 + lineDistanceItem.line1End.$2) / 2;
            final distance = (cursorX - midAx) * alongX + (cursorY - midAy) * alongY;
            widget.onLineDistanceLabelOffsetDragged?.call(distance);
            // Bug fix (on-device feedback: "the dimension...is restricted
            // in movement. it moves left right. it can't be moved up
            // down"): [distance] above only ever moves the label along the
            // two Lines' own shared direction (left/right, for two
            // horizontal Lines) - this mirrors
            // [_ConstraintOverlayPainter._paintLineDistanceDimension]'s own
            // `perpToA`/`midB` construction to also resolve the label's
            // position along the dimension line itself (up/down, for the
            // same two horizontal Lines), entirely in sketch-local space.
            final perpX = -alongY;
            final perpY = alongX;
            final toLineBx = lineDistanceItem.line2Start.$1 - midAx;
            final toLineBy = lineDistanceItem.line2Start.$2 - midAy;
            final t = toLineBx * perpX + toLineBy * perpY;
            final midBx = midAx + perpX * t;
            final midBy = midAy + perpY * t;
            final dimAnchorX = (midAx + midBx) / 2;
            final dimAnchorY = (midAy + midBy) / 2;
            final along = (cursorX - dimAnchorX) * perpX + (cursorY - dimAnchorY) * perpY;
            widget.onLineDistanceLabelAlongDragged?.call(along);
            return;
          }
        }
      }
      // Bug fix (on-device feedback: "dimensions should match technical
      // drawing conventions" - an angle dimension used to be a plain
      // floating chip with no way to place it): what the user actually
      // drags for an angle dimension is the arc's own distance from the
      // implied vertex (see [angleDimensionVertexAndRays]'s own doc
      // comment), a plain sketch-unit distance - no screen-space normal
      // needed, mirroring [onLinearLabelOffsetDragged]'s axis-locked branch
      // above.
      ConstraintAngleDimensionItem? angleItem;
      for (final candidate in widget.constraintOverlayItems) {
        if (candidate.constraintId == widget.draggingConstraintLabelId &&
            candidate is ConstraintAngleDimensionItem) {
          angleItem = candidate;
          break;
        }
      }
      if (angleItem != null && basis != null && cursor != null) {
        final vertexAndRays = angleDimensionVertexAndRays(angleItem);
        if (vertexAndRays != null) {
          final (vertex, _, _) = vertexAndRays;
          final ray = _camera.cameraFor(_viewportSize).screenPointToRay(cursor, _viewportSize);
          final hit = hitTestSketchPlane(ray, basis);
          if (hit != null) {
            final (cursorX, cursorY) = worldPointToSketch(basis, hit.$1);
            final dx = cursorX - vertex.$1;
            final dy = cursorY - vertex.$2;
            final radius = math.sqrt(dx * dx + dy * dy);
            if (radius > 1e-6) {
              widget.onAngleLabelRadiusDragged?.call(radius);
              return;
            }
          }
        }
      }
      widget.onConstraintLabelDragDelta?.call(scaledDelta);
      return;
    }
    final resolved = _drawCursorWorldHit;
    if (resolved != null) widget.onDrawCursorMoved?.call(resolved);
  }

  /// Mirrors [_handleSelectionPointerHover] - see [_handleDrawCursorMove]'s
  /// own doc comment for why the callback fires here, not inside
  /// [_recomputeDrawCursor].
  void _handleDrawCursorHover(Offset localPosition) {
    setState(() {
      _cursorPosition = _clampToViewport(localPosition);
      _recomputeDrawCursor();
      // P46: see [_handleDrawCursorMove]'s own doc comment on this pair.
      _recomputeHover();
      _syncHoverNode();
    });
    final resolved = _drawCursorWorldHit;
    if (resolved != null) widget.onDrawCursorMoved?.call(resolved);
  }

  /// Mirrors [_recomputeHover], raycasting against
  /// [PartViewport.sketchPlaneBasis] via [hitTestSketchPlane] instead of
  /// [hitTestBodies]. Purely an internal state update (unlike an earlier
  /// version of this method) - it must never itself invoke
  /// [PartViewport.onDrawCursorMoved], because [didUpdateWidget]'s own
  /// `drawCursorMode` transition block (below) calls this synchronously
  /// during the framework's build/update phase; that callback ends up
  /// calling `SketchController.notifyListeners()` (via `sketch_screen.dart`'s
  /// `_handleDrawCursorMoved` -> `moveCursorToSketchPoint`), which the
  /// `AnimatedBuilder` wrapping this whole viewport listens to - triggering
  /// "setState() or markNeedsBuild() called during build" the moment
  /// drawCursorMode first turns on. Confirmed via a real on-device/test
  /// crash, not hypothetical - fixed by only ever firing the callback from
  /// the genuinely pointer-event-driven callers above, which run outside
  /// any build phase.
  void _recomputeDrawCursor() {
    final cursor = _cursorPosition;
    final basis = widget.sketchPlaneBasis;
    if (cursor == null || basis == null) {
      _drawCursorWorldHit = null;
      return;
    }
    final ray = _camera.cameraFor(_viewportSize).screenPointToRay(cursor, _viewportSize);
    final hit = hitTestSketchPlane(ray, basis);
    _drawCursorWorldHit = hit?.$1;
  }

  /// Mirrors [_commitSelection] - fired by a genuine tap (see
  /// [_onPointerEnd]), commits the current [_drawCursorWorldHit] if the
  /// cursor is actually resolving to a point on the plane.
  void _commitDrawCursor() {
    if (widget.preferConstraintOverlayHitOnCommit && widget.onConstraintOverlayItemTap != null) {
      final basis = widget.sketchPlaneBasis;
      final cursor = _cursorPosition;
      final hitId = (basis != null && cursor != null)
          ? constraintOverlayItemAt(_camera.cameraFor(_viewportSize), _viewportSize, basis, widget.constraintOverlayItems, cursor)
          : null;
      final consumed = widget.onConstraintOverlayItemTap!(hitId);
      if (consumed) return;
    }
    final hit = _drawCursorWorldHit;
    if (hit == null) return;
    // On-device feedback ("clicking an edge of a previously created body
    // should allow dimensions to be created from this edge... it doesn't
    // look like it's working"): [PartViewport.preferEntityPick]'s own
    // real-Body vertex/edge pick - mirrors [_handleTap]'s identical branch
    // exactly. Dimension mode's own `drawCursorMode` gate (added later, to
    // give it the same cursor-precision model Draw/Trim already had) meant
    // every tap in Orbit View started routing through *this* method
    // instead of [_handleTap] - which was never taught to also consult
    // [preferEntityPick]/[hasEntityNearSketchTap]/[hitTestBodies], silently
    // making [PartViewport.onSketchEntityTap] unreachable dead code for
    // Dimension (and, since this session, Convert Entities/Offset) mode
    // the moment `drawCursorMode` started covering them too.
    if (widget.preferEntityPick) {
      final basis = widget.sketchPlaneBasis;
      final cursor = _cursorPosition;
      if (basis != null && cursor != null) {
        final (localX, localY) = worldPointToSketch(basis, hit);
        final nearExisting = widget.hasEntityNearSketchTap?.call(localX, localY) ?? false;
        if (!nearExisting) {
          // Same filter as [_handleTap]'s own branch - see that branch's
          // own comment for why a face is excluded by default and how
          // [preferEntityPickIncludesFace] widens it.
          final ray = _camera.cameraFor(_viewportSize).screenPointToRay(cursor, _viewportSize);
          final bodyHit = hitTestBodies(
            ray: ray,
            viewportSize: _viewportSize,
            bodies: widget.bodies,
            filter: SelectionFilterState(
              vertex: true,
              edge: true,
              face: widget.preferEntityPickIncludesFace,
              body: false,
            ),
            facesOccludeOtherHits: widget.renderMode.showsFilledFaces && !widget.bodiesHidden,
          );
          if (bodyHit != null) {
            widget.onSketchEntityTap?.call(bodyHit.entity);
            return;
          }
        }
      }
    }
    final commitBasis = widget.sketchPlaneBasis;
    widget.onDrawCursorCommit?.call(hit, commitBasis == null ? null : _localPixelsPerSketchUnit(hit, commitBasis));
  }

  /// Bug fix (on-device feedback: "the hit radius for selecting an entity
  /// should match the hit radius for dynamic highlight") - see
  /// [PartViewport.onDrawCursorCommit]'s own doc comment for the bug this
  /// closes. No single global screen-pixels-per-sketch-unit ratio exists in
  /// a perspective 3D view (it varies with camera distance/angle) -
  /// approximated locally by projecting a synthetic point 1 sketch-unit
  /// away from [worldPoint] (assumed to already lie on [basis]'s own
  /// sketch plane) and measuring the screen distance, the exact technique
  /// `sketch_constraint_overlay.dart`'s dimension painters already use
  /// (e.g. `_paintRadialDimension`). Returns null if either point fails to
  /// project (behind the camera, degenerate).
  double? _localPixelsPerSketchUnit(vm.Vector3 worldPoint, SketchPlaneBasis basis) {
    final camera = _camera.cameraFor(_viewportSize);
    final origin = worldToScreen(camera, _viewportSize, worldPoint);
    if (origin == null) return null;
    final (sketchX, sketchY) = worldPointToSketch(basis, worldPoint);
    final stepWorld = sketchPointToWorld(basis, sketchX + 1.0, sketchY);
    final step = worldToScreen(camera, _viewportSize, stepWorld);
    if (step == null) return null;
    return (step - origin).distance;
  }

  // ---- A3: recentre + auto-fit far clip ---------------------------------

  /// Called by the "Reset view" button: resets the camera and, if a mesh is
  /// loaded, auto-fits the far clip to `max(kDefaultFarClip, 2 * diagonal)`.
  void _doRecentre() {
    _camera.reset();
    // C3: "Reset view" moves the camera - resync the edge overlay's
    // towards-camera bias (see [_syncEdgesNode]) for the new position.
    _syncEdgesNode();
    double minX = double.infinity, maxX = double.negativeInfinity;
    double minY = double.infinity, maxY = double.negativeInfinity;
    double minZ = double.infinity, maxZ = double.negativeInfinity;
    var hasVertex = false;
    for (final body in widget.bodies) {
      for (final v in body.mesh.vertices) {
        hasVertex = true;
        if (v[0] < minX) minX = v[0]; if (v[0] > maxX) maxX = v[0];
        if (v[1] < minY) minY = v[1]; if (v[1] > maxY) maxY = v[1];
        if (v[2] < minZ) minZ = v[2]; if (v[2] > maxZ) maxZ = v[2];
      }
    }
    if (!hasVertex) return;
    final dx = maxX - minX, dy = maxY - minY, dz = maxZ - minZ;
    final diagonal = math.sqrt(dx * dx + dy * dy + dz * dz);
    final newFarClip = math.max(kDefaultFarClip, 2.0 * diagonal);
    _camera.farClip = newFarClip;
    _camera.nearClip = kDefaultNearClip;
    widget.onFarClipChanged?.call(newFarClip);
    // On-device feedback: "Reset view" alone left the camera at a fixed
    // distance tuned only for the reference planes' own size, too close to
    // show a body significantly larger than that - frame the real geometry
    // instead (half the diagonal is the same bounding-sphere-radius
    // approximation `boundsOfMesh`/`boundsOfBodies` already use elsewhere).
    _camera.frameRadius(diagonal / 2, _viewportSize);
  }

  // -----------------------------------------------------------------------

  /// Rebuilds [_hoverNode] from [_hoverHit] - one of vertex/edge/face
  /// highlight geometry depending on [_hoverHit]'s kind (Item 3: "hovered
  /// face = subtle tint; hovered edge = colour change + thickness increase;
  /// hovered vertex = small filled circle").
  void _syncHoverNode() {
    final scene = _scene;
    if (scene == null) return;
    if (_hoverNode != null) {
      scene.remove(_hoverNode!);
      _hoverNode = null;
    }
    final hit = _hoverHit;
    if (hit == null) return;
    final node = _buildEntityHighlightNode(hit.entity, _hoverColor);
    if (node == null) return;
    scene.add(node);
    _hoverNode = node;
    debugPrint(
      '[PartViewport][RenderDebug] hover: ${hit.entity.kind}#${hit.entity.id} '
      'body=${hit.entity.bodyId} cameraPosition=${_camera.position} '
      'cameraDistance=${_camera.distance}',
    );
  }

  /// Prompt A3: looks up which [BodyMeshDto] in [PartViewport.bodies] owns
  /// [bodyId] - null if it no longer exists (e.g. a stale hover/selection
  /// against a Body a recompute just removed).
  BodyMeshDto? _bodyFor(String bodyId) {
    for (final body in widget.bodies) {
      if (body.bodyId == bodyId) return body;
    }
    return null;
  }

  /// Rebuilds all three selected-entity highlight nodes (one per kind, each
  /// combining every currently-selected entity of that kind) from
  /// [PartViewport.selectedEntities] - Item 3: "selected entities = distinct
  /// 'selected' colour (not just hover colour)".
  void _syncSelectedEntityNodes() {
    final scene = _scene;
    if (scene == null) return;
    for (final node in [_selectedFacesNode, _selectedEdgesNode, _selectedVerticesNode]) {
      if (node != null) scene.remove(node);
    }
    _selectedFacesNode = null;
    _selectedEdgesNode = null;
    _selectedVerticesNode = null;

    final faceTriangles = <(vm.Vector3, vm.Vector3, vm.Vector3)>[];
    final edgeSegments = <(vm.Vector3, vm.Vector3)>[];
    final vertexPositions = <vm.Vector3>[];
    // Prompt C1: sketchPoint/sketchLine entities feed the same
    // vertexPositions/edgeSegments accumulators as Body vertices/edges -
    // the final highlight [Node]s (buildVertexMarkersNode/buildMeshEdgesNode)
    // don't care whether a point/segment came from mesh or Sketch geometry.
    for (final entity in widget.selectedEntities) {
      switch (entity.kind) {
        case SelectionEntityKind.face:
          final body = _bodyFor(entity.bodyId);
          if (body != null) faceTriangles.addAll(faceTrianglesForId(body.mesh, entity.id));
        case SelectionEntityKind.edge:
          final body = _bodyFor(entity.bodyId);
          if (body != null) edgeSegments.addAll(edgeSegmentsForId(body.mesh, entity.id));
        case SelectionEntityKind.vertex:
          final body = _bodyFor(entity.bodyId);
          final position = body == null ? null : vertexPositionForId(body.mesh, entity.id);
          if (position != null) vertexPositions.add(position);
        case SelectionEntityKind.body:
          // Prompt A3: a Body selection highlights every one of its faces,
          // not just one - reuses the same "selected faces" Node/colour
          // rather than introducing a fourth highlight Node type.
          final body = _bodyFor(entity.bodyId);
          if (body != null) faceTriangles.addAll(trianglesFromMesh(body.mesh));
        case SelectionEntityKind.sketchPoint:
          final geometry = widget.sketchGeometries[entity.sketchFeatureId];
          final index = geometry?.pointIds.indexOf(entity.sketchEntityId) ?? -1;
          if (geometry != null && index != -1) vertexPositions.add(geometry.points[index]);
        case SelectionEntityKind.sketchLine:
          final geometry = widget.sketchGeometries[entity.sketchFeatureId];
          if (geometry != null) {
            for (var i = 0; i < geometry.lineIds.length; i++) {
              if (geometry.lineIds[i] == entity.sketchEntityId) {
                edgeSegments.add(geometry.lineSegments[i]);
              }
            }
          }
        case SelectionEntityKind.sketchCircle:
          final geometry = widget.sketchGeometries[entity.sketchFeatureId];
          if (geometry != null) {
            for (var i = 0; i < geometry.circleIds.length; i++) {
              if (geometry.circleIds[i] == entity.sketchEntityId) {
                edgeSegments.addAll(_polygonSegments(geometry.circlePolygons[i]));
              }
            }
          }
        case SelectionEntityKind.sketchArc:
          final geometry = widget.sketchGeometries[entity.sketchFeatureId];
          if (geometry != null) {
            for (var i = 0; i < geometry.arcIds.length; i++) {
              if (geometry.arcIds[i] == entity.sketchEntityId) {
                edgeSegments.addAll(_polygonSegments(geometry.arcPolylines[i]));
              }
            }
          }
        case SelectionEntityKind.sketchEllipse:
          final geometry = widget.sketchGeometries[entity.sketchFeatureId];
          if (geometry != null) {
            for (var i = 0; i < geometry.ellipseIds.length; i++) {
              if (geometry.ellipseIds[i] == entity.sketchEntityId) {
                edgeSegments.addAll(_polygonSegments(geometry.ellipsePolygons[i]));
              }
            }
          }
        case SelectionEntityKind.sketchSpline:
          final geometry = widget.sketchGeometries[entity.sketchFeatureId];
          if (geometry != null) {
            for (var i = 0; i < geometry.splineIds.length; i++) {
              if (geometry.splineIds[i] == entity.sketchEntityId) {
                edgeSegments.addAll(_polygonSegments(geometry.splinePolylines[i]));
              }
            }
          }
        case SelectionEntityKind.referencePlane:
        case SelectionEntityKind.createPlane:
          // C5: a selected plane's highlight is its own quad rendering
          // straight from [widget.selectedEntities] (see
          // [_syncReferencePlaneNodes]/[_syncCreatePlaneNodes]'s own
          // `selected:` check), not one of this method's three overlay
          // Nodes - nothing to accumulate here.
          break;
      }
    }

    if (faceTriangles.isNotEmpty) {
      // On-device feedback ("dynamic face[s] hilight is not working"): see
      // [biasTrianglesTowardCamera]'s own doc comment - the embedded 3D
      // sketcher's Body opacity defaults below 100%, which routes the
      // Body's own material onto the translucent pass and its unreliable
      // depth test, so an un-biased highlight sitting exactly on the
      // Body's own surface can get redrawn over.
      final biasedTriangles = biasTrianglesTowardCamera(faceTriangles, _camera.position, kEdgeDepthBias);
      final node = buildHighlightFacesNode(biasedTriangles, color: _highContrastFaceHighlightColor());
      scene.add(node);
      _selectedFacesNode = node;
      debugPrint(
        '[PartViewport][RenderDebug] selected faces: triangles=${faceTriangles.length} '
        'cameraDistance=${_camera.distance}',
      );
    }
    if (edgeSegments.isNotEmpty) {
      final node = buildMeshEdgesNode(
        edgeSegments,
        color: _selectedEdgeColor,
        width: kHighlightEdgeStrokeWidth,
      );
      scene.add(node);
      _selectedEdgesNode = node;
    }
    if (vertexPositions.isNotEmpty) {
      final node = buildVertexMarkersNode(vertexPositions, color: _selectedColor);
      scene.add(node);
      _selectedVerticesNode = node;
    }
  }

  /// Consecutive-pair segments making up a rendered Circle outline (see
  /// `sketch_geometry_3d.dart`'s `circlePolygons`) - the same shape
  /// [buildMeshEdgesNode]/[edgeSegments] elsewhere in this file expect,
  /// since a Circle has no single `(start, end)` segment of its own the way
  /// a Line does.
  static List<(vm.Vector3, vm.Vector3)> _polygonSegments(List<vm.Vector3> polygon) => [
        for (var i = 0; i < polygon.length - 1; i++) (polygon[i], polygon[i + 1]),
      ];

  /// Resolves one [SelectionEntityRef] (any kind) into its highlight [Node],
  /// shared by [_syncHoverNode] - a single entity's worth of whichever of
  /// [buildHighlightFacesNode]/[buildMeshEdgesNode]/[buildVertexMarkersNode]
  /// matches its kind, or null if [entity]'s Body/Sketch/id no longer exists.
  ///
  /// Prompt C1: sketchPoint/sketchLine entities resolve against
  /// [PartViewport.sketchGeometries] (keyed by Feature id via
  /// [SelectionEntityRef.sketchFeatureId]) instead of [_bodyFor] - mirrors
  /// [_syncSelectedEntityNodes]'s own per-case lookup.
  Node? _buildEntityHighlightNode(SelectionEntityRef entity, vm.Vector4 color) {
    switch (entity.kind) {
      case SelectionEntityKind.face:
        final body = _bodyFor(entity.bodyId);
        if (body == null) return null;
        final triangles = faceTrianglesForId(body.mesh, entity.id);
        if (triangles.isEmpty) return null;
        // On-device feedback ("dynamic face[s] hilight is not working") -
        // see [biasTrianglesTowardCamera]'s own doc comment.
        return buildHighlightFacesNode(
          biasTrianglesTowardCamera(triangles, _camera.position, kEdgeDepthBias),
          color: color,
        );
      case SelectionEntityKind.edge:
        final body = _bodyFor(entity.bodyId);
        if (body == null) return null;
        final segments = edgeSegmentsForId(body.mesh, entity.id);
        if (segments.isEmpty) return null;
        return buildMeshEdgesNode(segments, color: color, width: kHighlightEdgeStrokeWidth);
      case SelectionEntityKind.vertex:
        final body = _bodyFor(entity.bodyId);
        if (body == null) return null;
        final position = vertexPositionForId(body.mesh, entity.id);
        if (position == null) return null;
        return buildVertexMarkersNode([position], color: color);
      case SelectionEntityKind.body:
        // Prompt A3: whole-Body highlight - same as a Body-kind selection
        // (see _syncSelectedEntityNodes), just for the hover case.
        final body = _bodyFor(entity.bodyId);
        if (body == null) return null;
        final triangles = trianglesFromMesh(body.mesh);
        if (triangles.isEmpty) return null;
        return buildHighlightFacesNode(
          biasTrianglesTowardCamera(triangles, _camera.position, kEdgeDepthBias),
          color: color,
        );
      case SelectionEntityKind.sketchPoint:
        final geometry = widget.sketchGeometries[entity.sketchFeatureId];
        if (geometry == null) return null;
        final index = geometry.pointIds.indexOf(entity.sketchEntityId);
        if (index == -1) return null;
        return buildVertexMarkersNode([geometry.points[index]], color: color);
      case SelectionEntityKind.sketchLine:
        final geometry = widget.sketchGeometries[entity.sketchFeatureId];
        if (geometry == null) return null;
        // Prompt G: expands to the whole containing loop when
        // [sketchLineLoopGroup] is supplied (the profile-picking flow) -
        // see that field's own doc comment.
        final group = widget.sketchLineLoopGroup?.call(entity.sketchFeatureId, entity.sketchEntityId);
        final entityIds = group ?? {entity.sketchEntityId};
        final segments = [
          for (var i = 0; i < geometry.lineIds.length; i++)
            if (entityIds.contains(geometry.lineIds[i])) geometry.lineSegments[i],
        ];
        if (segments.isEmpty) return null;
        return buildMeshEdgesNode(segments, color: color, width: kHighlightEdgeStrokeWidth);
      case SelectionEntityKind.sketchCircle:
        final geometry = widget.sketchGeometries[entity.sketchFeatureId];
        if (geometry == null) return null;
        // On-device feedback: mirrors the sketchLine case above - a Circle
        // is a single-entity "loop" of its own (see
        // `app.sketch.profile._circle_profile`), so [sketchLineLoopGroup]
        // never expands it to anything wider than itself, but the same
        // callback is still consulted for consistency.
        final group = widget.sketchLineLoopGroup?.call(entity.sketchFeatureId, entity.sketchEntityId);
        final entityIds = group ?? {entity.sketchEntityId};
        final circleSegments = <(vm.Vector3, vm.Vector3)>[
          for (var i = 0; i < geometry.circleIds.length; i++)
            if (entityIds.contains(geometry.circleIds[i])) ..._polygonSegments(geometry.circlePolygons[i]),
        ];
        if (circleSegments.isEmpty) return null;
        return buildMeshEdgesNode(circleSegments, color: color, width: kHighlightEdgeStrokeWidth);
      case SelectionEntityKind.sketchArc:
        final geometry = widget.sketchGeometries[entity.sketchFeatureId];
        if (geometry == null) return null;
        final index = geometry.arcIds.indexOf(entity.sketchEntityId);
        if (index == -1) return null;
        final segments = _polygonSegments(geometry.arcPolylines[index]);
        if (segments.isEmpty) return null;
        return buildMeshEdgesNode(segments, color: color, width: kHighlightEdgeStrokeWidth);
      case SelectionEntityKind.sketchEllipse:
        final geometry = widget.sketchGeometries[entity.sketchFeatureId];
        if (geometry == null) return null;
        final index = geometry.ellipseIds.indexOf(entity.sketchEntityId);
        if (index == -1) return null;
        final segments = _polygonSegments(geometry.ellipsePolygons[index]);
        if (segments.isEmpty) return null;
        return buildMeshEdgesNode(segments, color: color, width: kHighlightEdgeStrokeWidth);
      case SelectionEntityKind.sketchSpline:
        final geometry = widget.sketchGeometries[entity.sketchFeatureId];
        if (geometry == null) return null;
        final index = geometry.splineIds.indexOf(entity.sketchEntityId);
        if (index == -1) return null;
        final segments = _polygonSegments(geometry.splinePolylines[index]);
        if (segments.isEmpty) return null;
        return buildMeshEdgesNode(segments, color: color, width: kHighlightEdgeStrokeWidth);
      case SelectionEntityKind.referencePlane:
        final plane = entity.referencePlaneKind;
        if (plane == null) return null;
        return _buildPlaneHighlightNode(plane.localTransform, referencePlaneSize / 2, color);
      case SelectionEntityKind.createPlane:
        final geometry = widget.createPlanes[entity.planeFeatureId];
        if (geometry == null) return null;
        return _buildPlaneHighlightNode(
          createPlaneTransform(geometry.origin, geometry.xAxis, geometry.yAxis, geometry.normal),
          createPlaneSize / 2,
          color,
        );
    }
  }

  /// C5: a flat, single-color quad at [transform] - the hover-highlight
  /// counterpart to [buildReferencePlaneNode]/[buildCreatePlaneNode] (which
  /// only ever render their own fixed unselected/selected tints, not an
  /// arbitrary [color]), reusing the same [doubleSidedQuadBuffers] geometry
  /// those build from.
  Node _buildPlaneHighlightNode(vm.Matrix4 transform, double halfSize, vm.Vector4 color) {
    final material = UnlitMaterial()
      ..alphaMode = AlphaMode.blend
      ..baseColorFactor = color;
    final buffers = doubleSidedQuadBuffers(halfSize);
    final geometry = MeshGeometry.fromArrays(
      positions: buffers.positions,
      normals: buffers.normals,
      indices: buffers.indices,
    );
    return Node(
      name: 'plane-highlight',
      localTransform: transform,
      mesh: Mesh.primitives(primitives: [MeshPrimitive(geometry, material)]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final error = _error;
    if (error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            'Could not start the 3D viewport: $error',
            style: TextStyle(color: Theme.of(context).colorScheme.error),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    final scene = _scene;
    if (scene == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        _viewportSize = size;
        return Stack(
          children: [
            Listener(
              onPointerDown: _onPointerDown,
              onPointerMove: _onPointerMove,
              onPointerUp: _onPointerEnd,
              onPointerCancel: _onPointerEnd,
              onPointerHover: _onPointerHover,
              onPointerSignal: _onPointerSignal,
              child: CustomPaint(
                size: size,
                painter: _ScenePainter(
                  scene: scene,
                  camera: _camera,
                  size: size,
                  backgroundColor: colorFromHex(widget.bgColourHex),
                  polylineCarryingNodes: [
                    ..._planeNodes.values,
                    if (_sketchPlaneSurfaceNode != null) _sketchPlaneSurfaceNode!,
                    if (_sketchPlaneGridNode != null) _sketchPlaneGridNode!,
                    if (_drawGhostGuideNode != null) _drawGhostGuideNode!,
                    if (_drawGhostNode != null) _drawGhostNode!,
                    if (_drawIndicatorsNode != null) _drawIndicatorsNode!,
                    if (_profileFillNode != null) _profileFillNode!,
                    if (_profileBranchMarkersNode != null) _profileBranchMarkersNode!,
                    ..._sketchNodes.values,
                    ..._createPlaneNodes.values,
                    ..._edgesNodes.values,
                    if (_hoverNode != null) _hoverNode!,
                    if (_selectedEdgesNode != null) _selectedEdgesNode!,
                    if (_selectedVerticesNode != null) _selectedVerticesNode!,
                  ],
                ),
              ),
            ),
            // top-right, not top-left, so it doesn't collide with
            // PartScreen's feature-tree toolbar toggle button which lives
            // in that corner.
            Positioned(
              top: 8,
              right: 8,
              child: IconButton.filled(
                tooltip: 'Reset view',
                icon: const SvgIcon('assets/icons/viewport/viewport_reset_view.svg'),
                // A3: also auto-fits farClip to the current mesh's AABB.
                onPressed: () => setState(_doRecentre),
              ),
            ),
            // P41 (on-device feedback: "the cursor goes behind dimensions
            // and constraint glyphs and I can't grab them or pick a ghost
            // dimension"): moved ahead of both cursor crosshairs below (was
            // the very last child, drawing on top of and visually
            // swallowing them) - the crosshair itself is IgnorePointer'd
            // regardless of draw order, so this reordering only changes who
            // paints on top, never who receives a tap.
            if (widget.sketchPlaneBasis != null && widget.constraintOverlayItems.isNotEmpty)
              ConstraintOverlay(
                camera: _camera.cameraFor(size),
                viewportSize: size,
                basis: widget.sketchPlaneBasis!,
                items: widget.constraintOverlayItems,
              ),
            // P44b (on-device feedback: "when I click a ghost dimension to
            // set its value, nothing happens"): the embedded view never had
            // any widget rendering an active ghost's value-entry box at all
            // - resolves the same live anchor [_commitDrawCursor]'s own
            // hit-test uses, then hands off to the caller's own builder
            // (see [PartViewport.activeConstraintOverlayItemBuilder]'s own
            // doc comment for why this stays a builder rather than a
            // hardcoded `SketchController`-aware widget here).
            if (widget.sketchPlaneBasis != null &&
                widget.activeConstraintOverlayItemId != null &&
                widget.activeConstraintOverlayItemBuilder != null)
              Builder(builder: (context) {
                ConstraintOverlayItem? item;
                for (final candidate in widget.constraintOverlayItems) {
                  if (candidate.constraintId == widget.activeConstraintOverlayItemId) {
                    item = candidate;
                    break;
                  }
                }
                if (item == null) return const SizedBox.shrink();
                final anchor = constraintOverlayItemLabelCenter(
                  _camera.cameraFor(size),
                  size,
                  widget.sketchPlaneBasis!,
                  item,
                );
                if (anchor == null) return const SizedBox.shrink();
                return widget.activeConstraintOverlayItemBuilder!(anchor);
              }),
            if (widget.selectionMode && _cursorPosition != null)
              IgnorePointer(
                child: CustomPaint(
                  size: size,
                  painter: _CursorCrosshairPainter(position: _cursorPosition!, hasHover: _hoverHit != null),
                ),
              ),
            // P25: the marquee's own screen-space rectangle outline, live
            // while dragging - mirrors `sketch_canvas.dart`'s own marquee
            // rendering (minus its decorative swell-and-pop long-press
            // circle, which is cosmetic, not functional).
            if (_marqueeActive && _marqueeDownScreen != null && _marqueeCurrentScreen != null)
              IgnorePointer(
                child: CustomPaint(
                  size: size,
                  painter: _MarqueeRectPainter(
                    corner1: _marqueeDownScreen!,
                    corner2: _marqueeCurrentScreen!,
                  ),
                ),
              ),
            // P16: mirrors the selectionMode crosshair above - hasHover
            // (via _drawCursorWorldHit) previews whether a tap right now
            // would actually resolve to a point on the sketch plane. P20
            // follow-up: green instead of selection's blue while hovering -
            // mirrors `sketch_canvas.dart`'s own mode-tinted crosshair
            // (green for SketchMode.draw, red for select - only the
            // "hovering something valid" shade differs between the two
            // modes here, not the neutral/no-hover white). P30: the caller
            // can override this green default (see
            // [PartViewport.drawCursorHoverColor]'s own doc comment - Trim/
            // Extend now shares this same crosshair but with 2D's own
            // red-for-non-draw tint instead).
            if (widget.drawCursorMode && _cursorPosition != null && !widget.suppressDrawCursor)
              IgnorePointer(
                child: CustomPaint(
                  size: size,
                  painter: _CursorCrosshairPainter(
                    position: _cursorPosition!,
                    hasHover: _drawCursorWorldHit != null,
                    hoverColor: widget.drawCursorHoverColor ?? const Color(0xFF4CAF50),
                  ),
                ),
              ),
            // On-device feedback: rendered as part of this State's own
            // build (not an external overlay driven by a stale snapshot -
            // see [PartViewport.sketchOrientationBasis]'s own doc comment)
            // so it repaints with a fresh [_camera]/[size] on every
            // orbit/pan/zoom this State already triggers a rebuild for.
            if (widget.sketchOrientationBasis != null)
              Positioned.fill(
                child: SketchOrientationIndicator(
                  camera: _camera.cameraFor(size),
                  viewportSize: size,
                  basis: widget.sketchOrientationBasis!,
                ),
              ),
            if (ViewPreferences.debugShowCameraOrientation)
              DebugCameraOrientationOverlay(camera: _camera.cameraFor(size)),
          ],
        );
      },
    );
  }

  // A4: wrapper for the scroll-wheel signal event. The orbit handler body
  // (_handlePointerSignal) is unchanged; the wrapper exists so orthographic-
  // specific behaviour (e.g. adjusting ortho scale without moving the
  // camera) could be added here without touching the orbit body - not yet
  // needed, since scroll-wheel zoom still just changes OrbitCamera.distance
  // either way, and orthographicCameraFor derives its half-height from that
  // same distance every rebuild.
  void _onPointerSignal(PointerSignalEvent event) {
    _handlePointerSignal(event);
    // C3: a scroll-wheel zoom moves the camera - resync the edge overlay's
    // towards-camera bias (see [_syncEdgesNode]).
    setState(_syncEdgesNode);
  }
}

/// Stage 23 Item 2: the persistent selection-mode cursor - a simple
/// screen-space crosshair, mirroring [SketchCanvas]'s own cursor look.
/// [hasHover] swaps it to the "selected" colour when something's under it,
/// the same colour [PartViewportState._selectedColor] uses, so the cursor
/// itself previews what a tap (Fix 4) is about to commit.
class _CursorCrosshairPainter extends CustomPainter {
  final Offset position;
  final bool hasHover;

  /// P20 follow-up: the colour while [hasHover] is true - defaults to
  /// selection's own blue; [PartViewportState.build]'s draw-cursor crosshair
  /// passes green instead, mirroring `sketch_canvas.dart`'s own mode-tinted
  /// cursor (see that call site's own doc comment).
  final Color hoverColor;

  const _CursorCrosshairPainter({
    required this.position,
    required this.hasHover,
    this.hoverColor = const Color(0xFF2196F3),
  });

  static const double _armLength = 12;

  @override
  void paint(Canvas canvas, Size size) {
    final h = Offset(_armLength, 0);
    final v = Offset(0, _armLength);
    // Dark outline drawn first for visibility on light backgrounds.
    final outlinePaint = Paint()
      ..color = const Color(0xCC000000)
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.square;
    canvas.drawLine(position - h, position + h, outlinePaint);
    canvas.drawLine(position - v, position + v, outlinePaint);
    // Coloured inner stroke on top.
    final innerPaint = Paint()
      ..color = hasHover ? hoverColor : const Color(0xFFFFFFFF)
      ..strokeWidth = 1.25;
    canvas.drawLine(position - h, position + h, innerPaint);
    canvas.drawLine(position - v, position + v, innerPaint);
  }

  @override
  bool shouldRepaint(covariant _CursorCrosshairPainter oldDelegate) =>
      oldDelegate.position != position ||
      oldDelegate.hasHover != hasHover ||
      oldDelegate.hoverColor != hoverColor;
}

/// P25 (2D-sketcher feature parity): the marquee gesture's own live
/// screen-space rectangle outline - a plain translucent-fill, solid-border
/// rect between [corner1]/[corner2] (whichever order), mirroring
/// `sketch_canvas.dart`'s own marquee look closely enough to read as "the
/// same feature", without replicating its decorative swell-and-pop
/// long-press circle (cosmetic, not functional).
class _MarqueeRectPainter extends CustomPainter {
  final Offset corner1;
  final Offset corner2;

  const _MarqueeRectPainter({required this.corner1, required this.corner2});

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromPoints(corner1, corner2);
    canvas.drawRect(rect, Paint()..color = const Color(0x332196F3));
    canvas.drawRect(
      rect,
      Paint()
        ..color = const Color(0xFF2196F3)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
  }

  @override
  bool shouldRepaint(covariant _MarqueeRectPainter oldDelegate) =>
      oldDelegate.corner1 != corner1 || oldDelegate.corner2 != corner2;
}

class _ScenePainter extends CustomPainter {
  final Scene scene;
  final OrbitCamera camera;
  final Size size;
  final Color backgroundColor;

  /// Every [Node] (reference planes, Sketch geometry) whose [Mesh] may
  /// contain a [PolylineGeometry] primitive - each such primitive's
  /// camera-facing strip must be rebuilt via `updateForCamera` every frame
  /// before [Scene.render], per [PolylineGeometry]'s own contract.
  final List<Node> polylineCarryingNodes;

  /// `paint` runs every frame, so this guards [paint]'s diagnostic logging to
  /// fire only once - the first call already proves `scene.render` (the
  /// flutter_scene GPU call) didn't hang, which is all the logging is for.
  static bool _loggedFirstPaint = false;

  _ScenePainter({
    required this.scene,
    required this.camera,
    required this.size,
    required this.backgroundColor,
    this.polylineCarryingNodes = const [],
  });

  /// Distance of the triad's center from each edge of the viewport - large
  /// enough that its arms (see [paintTriad]'s `armLength`) and axis labels
  /// never clip against the corner.
  static const double _triadMargin = 44;

  @override
  void paint(Canvas canvas, Size canvasSize) {
    final isFirstPaint = !_loggedFirstPaint;
    if (isFirstPaint) {
      _loggedFirstPaint = true;
      debugPrint('[PartViewport] _ScenePainter.paint: first frame, calling scene.render()...');
    }
    canvas.drawRect(Offset.zero & canvasSize, Paint()..color = backgroundColor);
    final perspectiveCamera = camera.cameraFor(size);
    for (final node in polylineCarryingNodes) {
      for (final primitive in node.mesh?.primitives ?? const []) {
        final geometry = primitive.geometry;
        if (geometry is PolylineGeometry) {
          geometry.updateForCamera(perspectiveCamera, canvasSize);
        }
      }
    }
    scene.render(perspectiveCamera, canvas, viewport: Offset.zero & canvasSize);
    if (isFirstPaint) {
      debugPrint('[PartViewport] _ScenePainter.paint: first frame, scene.render() returned');
    }
    // Bottom-left, per the project brief's own stated preference - drawn
    // last so it stays on top of the rendered scene.
    final triadCenter = Offset(_triadMargin, canvasSize.height - _triadMargin);
    paintTriad(canvas, triadCenter, triadAxes(perspectiveCamera));
  }

  @override
  bool shouldRepaint(covariant _ScenePainter oldDelegate) => true;
}
