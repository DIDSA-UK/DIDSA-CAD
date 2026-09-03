import 'dart:math' as math;
import 'dart:ui' show Size;

import 'package:vector_math/vector_math.dart' as vm;

import '../api/document_api_client.dart';
import 'mesh_geometry.dart' show edgeSegmentsFromMesh;
import 'reference_planes.dart' show ReferencePlaneKind;
import 'selection_filter.dart';
import 'sketch_geometry_3d.dart' show SketchGeometry3D;

/// flutter_scene's `PerspectiveCamera` only exposes `fovNear`/`fovFar` (the
/// near/far *clip* distances, see `OrbitCamera.cameraFor`) - there's no
/// getter for the actual field-of-view angle it renders with. [OrbitCamera]
/// already documents the same fixed assumption ("flutter_scene's 45-degree
/// default vertical FOV") for its own zoom-distance tuning, so this reuses
/// that exact assumption rather than inventing a second one.
const double kCameraVerticalFovRadians = math.pi / 4;

/// Hit-test radius (screen dp) for edges in selection mode (Item 3 of the
/// Stage 23 brief; see [kVertexSelectionHitRadiusPixels] for vertices) -
/// deliberately smaller than, and independent of, the sketcher's own
/// `SketchController.minTapHitRadiusPixels` (22.0): that is a 2D sketch's
/// primary tap-to-select radius, this is a 3D hover/pick radius that always
/// has a face fallback when nothing edge/vertex-like is near enough.
///
/// Bug-fix round: this used to be smaller than [kVertexSelectionHitRadiusPixels]
/// (9px vs. 16px) so a vertex - a single point target vs. an edge's full
/// line segment - had extra forgiveness. On-device testing found the gap
/// between the two made hit-testing feel inconsistent (generous near a
/// corner, tight along an edge) and, worse, meant the actual selectable
/// area no longer matched the hover highlight it's driven from (both read
/// off the same [HoverHit] - see [hitTestMeshEntities] - so hover and
/// selection were never actually different targets, just an oversized one
/// for vertices specifically). Both constants are now equal, at the
/// midpoint of the old 9px/16px values.
const double kSelectionHitRadiusPixels = 12.5;

/// See [kSelectionHitRadiusPixels]'s doc comment - equal to it as of the
/// bug-fix round (previously wider, at 16px, to give a vertex - a single
/// point target - extra forgiveness over an edge's full line segment).
const double kVertexSelectionHitRadiusPixels = kSelectionHitRadiusPixels;

/// Prompt A3 added `body` - a whole Body (Prompt A1), selected as a unit
/// rather than one of its individual faces/edges/vertices. Prompt C1 added
/// `sketchPoint`/`sketchLine` - a Sketch's own Point/Line entities, rendered
/// and pickable in the 3D viewport alongside Body geometry (see
/// `sketch_geometry_3d.dart`). C5 added `referencePlane`/`createPlane` - one
/// of the three fixed reference planes, or an existing CreatePlaneFeature's
/// own rendered quad, so either can now feed a Create Plane operation as a
/// `PlaneRefDto` (an offset from, or a midplane against, a plane instead of
/// only a Body face) exactly like every other selectable entity kind - see
/// `PartScreen._onPlaneTap`/`_onCreatePlaneFeatureTap`, which toggle these
/// into the selection set while in Selection mode instead of always opening
/// their own context sheet. On-device feedback added `sketchCircle` - a
/// Sketch's own Circle entities, previously drawn (see
/// `sketch_geometry_3d.dart`'s `circlePolygons`) but never independently
/// tappable, even though a Circle can be its own closed Profile exactly
/// like a Line-chain loop (see `app.sketch.profile._circle_profile`) and so
/// needs to participate in Prompt G's profile-picking flow the same way.
enum SelectionEntityKind {
  face,
  edge,
  vertex,
  body,
  sketchPoint,
  sketchLine,
  sketchCircle,
  sketchArc,
  sketchEllipse,

  /// Pattern/Mirror roadmap follow-up: gates `sketch_geometry_3d.dart`'s
  /// `ellipseArcPolylines` the same way [sketchArc] gates `arcPolylines` -
  /// a partial ellipse had no 3D-viewport hit-test of its own at all until
  /// this round, mirroring [sketchArc]'s/[sketchEllipse]'s own "missing
  /// entirely, not just gated off" history.
  sketchEllipseArc,
  sketchSpline,

  /// On-device feedback (3D-viewport Text tool round: "text is not
  /// selectable with cursor only with drag box select and 'select
  /// all'"): a Sketch's own Text entities were rendered in the
  /// 3D-embedded viewport (`sketch_geometry_3d.dart`'s `textPolygons`)
  /// but never wired into this ray-hit-testing/hover-highlight pipeline
  /// at all - the same gap Circle/Arc/Ellipse/Spline each had to have
  /// separately closed for themselves (see this enum's own doc comment
  /// above and [sketchArc]'s sibling comments) - box-select/"select all"
  /// still worked because those go through [SketchController]'s own
  /// entity-map iteration, a completely different, filter-agnostic path.
  sketchText,
  referencePlane,
  createPlane,

  /// On-device feedback ("the patterned circle under the cursor is not
  /// highlighted and will not select" - reported against the embedded 3D
  /// (Orbit View) sketch editor, a separate rendering/hit-test pipeline
  /// from `sketch_canvas.dart`'s own flat 2D canvas, which had already been
  /// fixed for the identical complaint there): a committed Pattern/Mirror
  /// instance's own derived (ghost) geometry, hit-tested and highlighted as
  /// a single unit - [SelectionEntityRef.sketchEntityId] is the *owning
  /// instance's* own id, never an individual derived copy's, mirroring
  /// `SketchController._patternMirrorEntityAt`'s identical "whole owning
  /// instance, never a copy" contract on the 2D-canvas side.
  sketchPatternMirrorInstance,
}

/// Identifies one selectable mesh entity - a [SelectionEntityKind] plus the
/// stable id `MeshDto.faceIds`/`edgeIds`/`topologyVertexIds` assigns it.
/// Equality/hashCode are value-based so this can be used as a `Set` element
/// (the selection set) or a `Map` key.
///
/// Prompt A3: [bodyId] identifies which Body this entity belongs to -
/// required because those `MeshDto` ids are only unique *within* one
/// Body's own tessellation (Prompt A1), not globally across a Part's whole
/// `/mesh` response. Defaults to `''` for the single-mesh-scoped functions
/// below ([hitTestVertices]/[hitTestEdges]/[hitTestFaces]/
/// [hitTestMeshEntities]), which predate A3 and have no Body concept of
/// their own - only [hitTestBodies] (the real multi-body entry point
/// [PartViewport] uses) ever produces a meaningful, non-empty [bodyId].
/// For a [SelectionEntityKind.body] entity, [bodyId] alone is the whole
/// identity - [id] is always `0` and carries no meaning.
///
/// Prompt C1: [sketchFeatureId]/[sketchEntityId] identify a
/// [SelectionEntityKind.sketchPoint]/[SelectionEntityKind.sketchLine] entity
/// instead - [bodyId]/[id] carry no meaning for those two kinds, the same
/// way [bodyId] carries no meaning for mesh kinds and vice versa. A separate
/// pair (rather than reusing [bodyId]/[id]) because Sketch Point/Line ids
/// are real backend UUID strings (`Point.id`/`SketchEntity.id`), not the
/// small dense ints `MeshDto` assigns its own entities - [sketchFeatureId]
/// is the owning Feature's id (matching `PartViewport.sketchGeometries`'
/// own keying), not the Sketch's own id, so this stays resolvable the same
/// way `_bodyFor`/`PartViewport.sketchGeometries` already key by Feature id.
class SelectionEntityRef {
  final SelectionEntityKind kind;
  final String bodyId;
  final int id;
  final String sketchFeatureId;
  final String sketchEntityId;

  /// C5: which fixed reference plane this is, for a [SelectionEntityKind.
  /// referencePlane] entity - null (and meaningless) for every other kind,
  /// the same "carries no meaning outside its own kind" convention
  /// [bodyId]/[id] and [sketchFeatureId]/[sketchEntityId] already use for
  /// each other's kinds.
  final ReferencePlaneKind? referencePlaneKind;

  /// C5: the CreatePlaneFeature's own id, for a [SelectionEntityKind.
  /// createPlane] entity - meaningless for every other kind. A separate
  /// field from [sketchFeatureId] even though both are "a Feature id
  /// string", since a `createPlane` entity *is* that Feature (identifies
  /// it directly), whereas [sketchFeatureId] names the Feature a
  /// sketchPoint/sketchLine entity merely *belongs to*.
  final String planeFeatureId;

  const SelectionEntityRef({
    required this.kind,
    this.bodyId = '',
    this.id = 0,
    this.sketchFeatureId = '',
    this.sketchEntityId = '',
    this.referencePlaneKind,
    this.planeFeatureId = '',
  });

  @override
  bool operator ==(Object other) =>
      other is SelectionEntityRef &&
      other.kind == kind &&
      other.bodyId == bodyId &&
      other.id == id &&
      other.sketchFeatureId == sketchFeatureId &&
      other.sketchEntityId == sketchEntityId &&
      other.referencePlaneKind == referencePlaneKind &&
      other.planeFeatureId == planeFeatureId;

  @override
  int get hashCode => Object.hash(
        kind,
        bodyId,
        id,
        sketchFeatureId,
        sketchEntityId,
        referencePlaneKind,
        planeFeatureId,
      );

  @override
  String toString() => switch (kind) {
        SelectionEntityKind.sketchPoint ||
        SelectionEntityKind.sketchLine ||
        SelectionEntityKind.sketchCircle ||
        SelectionEntityKind.sketchArc ||
        SelectionEntityKind.sketchEllipse ||
        SelectionEntityKind.sketchEllipseArc ||
        SelectionEntityKind.sketchSpline ||
        SelectionEntityKind.sketchText ||
        SelectionEntityKind.sketchPatternMirrorInstance =>
          'SelectionEntityRef($kind, sketchFeatureId: $sketchFeatureId, $sketchEntityId)',
        SelectionEntityKind.referencePlane => 'SelectionEntityRef($kind, $referencePlaneKind)',
        SelectionEntityKind.createPlane => 'SelectionEntityRef($kind, planeFeatureId: $planeFeatureId)',
        _ => 'SelectionEntityRef($kind, bodyId: $bodyId, $id)',
      };
}

/// A hit-test result: which entity, how far along the ray it was found (for
/// depth-based reasoning), and - for edge/vertex hits only - how many
/// screen pixels away from the ray it actually was (used to pick the
/// nearer of a vertex/edge tie; always null for a face hit, since faces
/// have no hit-radius concept - see [hitTestFaces]).
class HoverHit {
  final SelectionEntityRef entity;
  final double rayT;
  final double? pixelDistance;

  const HoverHit({required this.entity, required this.rayT, this.pixelDistance});
}

/// World-space size of one screen pixel at [depth] (distance along the
/// camera's forward ray) - lets a 3D world-space distance be compared
/// against a screen-space pixel radius without needing the full
/// view/projection matrix `flutter_scene`'s `PerspectiveCamera` builds
/// internally (mirrors `hitTestReferencePlanes`'s choice to stay off
/// `flutter_scene`'s own `raycast.dart`, for the same "stay pure and
/// unit-testable" reason).
///
/// Bug fix (on-device feedback: "when in orthographic view looking
/// directly at the canvas, picking an arc picks its chord instead;
/// picking a circle errors - rotating the camera away fixes it"): this
/// always used the perspective-FOV-based formula below, even when the ray
/// actually came from an `OrthographicCamera` - under orthographic
/// projection, world-units-per-pixel is *constant* regardless of depth
/// (`OrthographicProjection.halfHeight`'s own doc comment: "the
/// orthographic equivalent of `PerspectiveProjection.fovRadiansY`" - not
/// depth-scaled at all), but this function scaled it with depth anyway, as
/// if every camera were perspective. Two edges that nearly overlap in
/// screen space - which only happens when the camera looks straight down
/// the axis separating them, e.g. straight-on at the sketch plane - could
/// then rank in the wrong order purely because they sit at different
/// depths along that same ray: whichever is farther along the ray got an
/// inflated (too generous) effective pixel radius, whichever is nearer got
/// a shrunk (too strict) one - exactly the kind of tie a curved edge's own
/// chord (which shares both endpoints with the real arc, so sits very
/// close to it in screen space from a straight-on view) would win purely
/// by depth-scaling luck. From any other camera angle the two candidates
/// are already separated in screen space and this depth-dependent error
/// stops mattering - matching the reported "rotate away and it picks
/// correctly" behaviour exactly.
///
/// [orthographicHalfHeight], when passed (the calling camera's own
/// `OrthographicCamera.halfHeight`), switches to the correct
/// depth-independent formula instead; null (every call site that hasn't
/// opted in, and every perspective camera) keeps the original formula
/// unchanged.
double _worldUnitsPerPixelAtDepth(double depth, Size viewportSize, {double? orthographicHalfHeight}) {
  if (viewportSize.height <= 0) return double.infinity;
  final worldHeightAtDepth = orthographicHalfHeight != null
      ? 2 * orthographicHalfHeight
      : 2 * depth * math.tan(kCameraVerticalFovRadians / 2);
  return worldHeightAtDepth / viewportSize.height;
}

/// Below this many screen pixels apart, two hit candidates are treated as
/// landing on the same screen spot - [_isCloserHit] then breaks the tie by
/// depth ([HoverHit.rayT]) instead of pixel distance. Small enough to never
/// affect two genuinely distinguishable picks (a hundredth of a pixel is
/// imperceptible), comfortably above the floating-point noise two
/// independently-evaluated OCCT curves can differ by.
const double kPixelDistanceTieEpsilon = 1e-6;

/// Bug fix (on-device feedback: "in orthographic view looking directly at
/// the canvas, picking an arc picks the chord instead; picking a circle
/// errors - rotating the camera away fixes it" - live-reproduced as a
/// third, distinct cause from the two already fixed for this same report,
/// see [_worldUnitsPerPixelAtDepth]'s and [_closestRaySegmentDistance]'s
/// own doc comments): every hit-test loop below used to keep its very first
/// in-range candidate on an exact pixel-distance tie (`<` never re-fires for
/// an equal value). A straight prism - any Body extruded from a profile
/// with a curved boundary, not just a fillet - has that same curve repeated
/// on its near and far face (e.g. a rounded corner's top and bottom rim).
/// Under an orthographic ray looking exactly down the extrusion axis, a
/// point on the near curve and the corresponding point on the identical far
/// curve sit at the *same* screen position - genuinely zero world-space
/// ray-to-segment distance for both, confirmed live against a real filleted
/// Body's mesh data, not merely close. [_worldUnitsPerPixelAtDepth]'s own
/// orthographic fix does not resolve this: both candidates already compute
/// zero raw distance, so no depth-dependent scaling could ever separate
/// them. Whichever of the two came first in `MeshDto.edgeIds`/a Sketch
/// entity id list won by accident of iteration order - for the reported
/// case, the *far* (bottom) rim happened to iterate before the *near* (top)
/// one, so the top rim's own arc reliably lost to its own far-side twin.
/// From any other camera angle the near/far copies project to visibly
/// different screen positions and this tie stops arising - matching the
/// reported "rotate away and it picks correctly" behaviour exactly, same as
/// the other two causes.
///
/// A user aiming at a specific screen spot means the nearest (smallest
/// [HoverHit.rayT]) geometry there, exactly like [hitTestBodies]' own
/// `facesOccludeOtherHits` already assumes for vertex/edge-vs-face - so a
/// pixel-distance tie is now broken the same way, rather than left to
/// accidental array order.
bool _isCloserHit(double candidatePixelDistance, double candidateRayT, double bestPixelDistance, double bestRayT) {
  final delta = candidatePixelDistance - bestPixelDistance;
  if (delta.abs() > kPixelDistanceTieEpsilon) return delta < 0;
  return candidateRayT < bestRayT;
}

/// Nearest of [vertices] (ids parallel in [ids]) to [ray], in screen space,
/// within [radiusPixels] - or null if none are that close. A vertex behind
/// the camera (`t <= 0`) is never considered.
HoverHit? hitTestVertices(
  vm.Ray ray,
  Size viewportSize,
  List<vm.Vector3> vertices,
  List<int> ids, {
  double radiusPixels = kSelectionHitRadiusPixels,
  double? orthographicHalfHeight,
}) {
  final direction = ray.direction.normalized();
  HoverHit? best;
  for (var i = 0; i < vertices.length; i++) {
    final toPoint = vertices[i] - ray.origin;
    final t = toPoint.dot(direction);
    if (t <= 0) continue;
    final closestOnRay = ray.origin + direction * t;
    final worldDistance = (vertices[i] - closestOnRay).length;
    final pixelDistance = worldDistance /
        _worldUnitsPerPixelAtDepth(t, viewportSize, orthographicHalfHeight: orthographicHalfHeight);
    if (pixelDistance > radiusPixels) continue;
    if (best == null || _isCloserHit(pixelDistance, t, best.pixelDistance!, best.rayT)) {
      best = HoverHit(
        entity: SelectionEntityRef(kind: SelectionEntityKind.vertex, id: ids[i]),
        rayT: t,
        pixelDistance: pixelDistance,
      );
    }
  }
  return best;
}

/// Closest approach between [ray] (treated as starting at [rayOrigin],
/// unit-length [rayDirection], extending only forward) and the finite
/// segment [segStart]-[segEnd] - the standard closest-point-between-two-
/// lines formula, with the segment parameter clamped to `[0, 1]` so the
/// result respects the segment's actual endpoints rather than its infinite
/// extension. Returns `(t along the ray, world-space distance)`, or null if
/// the segment's closest point would be behind the camera (`t <= 0`), or if
/// the segment is (numerically) exactly parallel to the ray - see below.
///
/// Bug fix (on-device feedback: "in orthographic view looking directly at
/// the canvas, picking an arc picks the chord instead; picking a circle
/// errors - rotating the camera away fixes it" - a second, distinct cause
/// from the one already fixed for this same report, see
/// [_worldUnitsPerPixelAtDepth]'s own doc comment): live-reproduced against
/// a real filleted Body (a box with one vertical corner rounded) - a
/// rounded corner's fillet surface isn't always one continuous curved
/// panel; OCCT frequently splits it into two, joined by a real, internal
/// B-Rep edge running along the panel seam, radially inward from
/// (typically) the sweep's own angular midpoint - i.e. running exactly
/// parallel to the sketch plane's normal. A full circular Body edge (e.g. a
/// cylinder's rim) has the same shape of seam edge for the same reason
/// (`GCPnts`/OCCT's own closed-curve convention needs a parametric start/end
/// somewhere), which is exactly the edge `degenerate_edge` (Router's own
/// doc comment: "both endpoints the same Body vertex") fires for once
/// picked and converted - a real edge, just not the one the tap meant.
///
/// A ray looking anywhere else has this seam edge projecting to a short
/// but nonzero on-screen segment, clearly separated from the curve beside
/// it, same as any other edge - no different from the general case. Only
/// an orthographic ray looking *exactly* along the sketch plane's normal
/// (every ray shares that one exact direction under orthographic
/// projection - see [_worldUnitsPerPixelAtDepth]) can end up numerically
/// *exactly* parallel to a seam edge that also runs along that normal,
/// which is precisely what this function's own `denom` (`|d2|² · sin²θ`
/// between the segment and the ray) measures: near-zero only for a
/// (near-)zero-length segment or a (near-)parallel one. The old code
/// treated both cases identically - clamp to the segment's start point,
/// report whatever distance results - which is correct for a genuinely
/// short segment, but actively wrong for a parallel one: a segment lying
/// exactly along the ray reports a *real* zero-distance "hit" at any point
/// along its own length, an on-screen sliver invisible in this exact view,
/// that can - and, per the live repro, reliably does - out-tie a real,
/// intended curve sample sitting right beside it in world space (arriving
/// earlier in `MeshDto.edgeIds` decides the tie, since [hitTestEdges] only
/// replaces its running-best on a strict `<`). A user can never deliberately
/// aim at an edge-on sliver they cannot see, so a parallel segment is
/// excluded outright below instead of being treated as an ultra-close hit -
/// the zero-length case is unaffected, still resolving to its one real
/// point.
(double, double)? _closestRaySegmentDistance(
  vm.Vector3 rayOrigin,
  vm.Vector3 rayDirection,
  vm.Vector3 segStart,
  vm.Vector3 segEnd,
) {
  final d1 = rayDirection;
  final d2 = segEnd - segStart;
  final r = rayOrigin - segStart;

  final b = d1.dot(d2);
  final c = d2.dot(d2);
  final d = d1.dot(r);
  final e = d2.dot(r);

  // a = d1.dot(d1) == 1 since d1 is unit-length.
  final denom = c - b * b;
  double segT;
  if (c < 1e-9) {
    // Zero-length segment (segStart == segEnd): every segT resolves to the
    // same single point, so 0 is as good as any other value.
    segT = 0.0;
  } else if (denom.abs() < 1e-9) {
    // Segment (near-)parallel to the ray - see this function's own doc
    // comment for why this is excluded rather than treated as a hit.
    return null;
  } else {
    segT = (e - b * d) / denom;
  }
  segT = segT.clamp(0.0, 1.0);

  final segPoint = segStart + d2 * segT;
  final rayT = d1.dot(segPoint - rayOrigin);
  if (rayT <= 0) return null;

  final closestOnRay = rayOrigin + d1 * rayT;
  return (rayT, (segPoint - closestOnRay).length);
}

/// Nearest of [segments] (ids parallel in [ids], one id per segment - see
/// `MeshDto.edgeIds`) to [ray], in screen space, within [radiusPixels] - or
/// null if none are that close.
HoverHit? hitTestEdges(
  vm.Ray ray,
  Size viewportSize,
  List<(vm.Vector3, vm.Vector3)> segments,
  List<int> ids, {
  double radiusPixels = kSelectionHitRadiusPixels,
  double? orthographicHalfHeight,
}) {
  final direction = ray.direction.normalized();
  HoverHit? best;
  for (var i = 0; i < segments.length; i++) {
    final closest =
        _closestRaySegmentDistance(ray.origin, direction, segments[i].$1, segments[i].$2);
    if (closest == null) continue;
    final (t, worldDistance) = closest;
    final pixelDistance = worldDistance /
        _worldUnitsPerPixelAtDepth(t, viewportSize, orthographicHalfHeight: orthographicHalfHeight);
    if (pixelDistance > radiusPixels) continue;
    if (best == null || _isCloserHit(pixelDistance, t, best.pixelDistance!, best.rayT)) {
      best = HoverHit(
        entity: SelectionEntityRef(kind: SelectionEntityKind.edge, id: ids[i]),
        rayT: t,
        pixelDistance: pixelDistance,
      );
    }
  }
  return best;
}

/// Prompt C1: [hitTestVertices]' counterpart for a Sketch's own Points -
/// same nearest-in-range-wins logic, just producing
/// [SelectionEntityKind.sketchPoint] entities tagged with [sketchFeatureId]/
/// a String [SketchEntityRef]-style id (see [SelectionEntityRef]'s own doc
/// comment for why that's a separate field pair from [bodyId]/`id`) instead
/// of a Body-scoped int id.
HoverHit? hitTestSketchPoints(
  vm.Ray ray,
  Size viewportSize,
  String sketchFeatureId,
  List<vm.Vector3> points,
  List<String> ids, {
  double radiusPixels = kVertexSelectionHitRadiusPixels,
  double? orthographicHalfHeight,
}) {
  final direction = ray.direction.normalized();
  HoverHit? best;
  for (var i = 0; i < points.length; i++) {
    final toPoint = points[i] - ray.origin;
    final t = toPoint.dot(direction);
    if (t <= 0) continue;
    final closestOnRay = ray.origin + direction * t;
    final worldDistance = (points[i] - closestOnRay).length;
    final pixelDistance = worldDistance /
        _worldUnitsPerPixelAtDepth(t, viewportSize, orthographicHalfHeight: orthographicHalfHeight);
    if (pixelDistance > radiusPixels) continue;
    if (best == null || _isCloserHit(pixelDistance, t, best.pixelDistance!, best.rayT)) {
      best = HoverHit(
        entity: SelectionEntityRef(
          kind: SelectionEntityKind.sketchPoint,
          sketchFeatureId: sketchFeatureId,
          sketchEntityId: ids[i],
        ),
        rayT: t,
        pixelDistance: pixelDistance,
      );
    }
  }
  return best;
}

/// Prompt C1: [hitTestEdges]' counterpart for a Sketch's own Lines - see
/// [hitTestSketchPoints]'s doc comment for why this produces
/// [SelectionEntityRef.sketchFeatureId]/[SelectionEntityRef.sketchEntityId]
/// rather than [SelectionEntityRef.bodyId]/`id`.
HoverHit? hitTestSketchLines(
  vm.Ray ray,
  Size viewportSize,
  String sketchFeatureId,
  List<(vm.Vector3, vm.Vector3)> segments,
  List<String> ids, {
  double radiusPixels = kSelectionHitRadiusPixels,
  double? orthographicHalfHeight,
}) {
  final direction = ray.direction.normalized();
  HoverHit? best;
  for (var i = 0; i < segments.length; i++) {
    final closest =
        _closestRaySegmentDistance(ray.origin, direction, segments[i].$1, segments[i].$2);
    if (closest == null) continue;
    final (t, worldDistance) = closest;
    final pixelDistance = worldDistance /
        _worldUnitsPerPixelAtDepth(t, viewportSize, orthographicHalfHeight: orthographicHalfHeight);
    if (pixelDistance > radiusPixels) continue;
    if (best == null || _isCloserHit(pixelDistance, t, best.pixelDistance!, best.rayT)) {
      best = HoverHit(
        entity: SelectionEntityRef(
          kind: SelectionEntityKind.sketchLine,
          sketchFeatureId: sketchFeatureId,
          sketchEntityId: ids[i],
        ),
        rayT: t,
        pixelDistance: pixelDistance,
      );
    }
  }
  return best;
}

/// On-device feedback: [hitTestSketchLines]' counterpart for a Sketch's own
/// Circles - each circle is rendered as a closed polyline of
/// [circleSegments3D] straight segments (see `sketch_geometry_3d.dart`'s
/// `circlePolygons`), so this tests every consecutive segment pair of each
/// polygon the same way [hitTestSketchLines] tests one segment per Line, and
/// keeps whichever segment (across every polygon) comes closest - tagging
/// the hit with that whole polygon's own Circle id (parallel in [ids]), not
/// a per-segment one, since a Circle is selected as a single entity.
HoverHit? hitTestSketchCircles(
  vm.Ray ray,
  Size viewportSize,
  String sketchFeatureId,
  List<List<vm.Vector3>> polygons,
  List<String> ids, {
  double radiusPixels = kSelectionHitRadiusPixels,
  double? orthographicHalfHeight,
}) =>
    _hitTestSketchPolylines(
      ray,
      viewportSize,
      sketchFeatureId,
      polygons,
      ids,
      SelectionEntityKind.sketchCircle,
      radiusPixels: radiusPixels,
      orthographicHalfHeight: orthographicHalfHeight,
    );

/// On-device feedback: a Circle could be selected but an Arc/Ellipse/
/// Spline silently couldn't - there was never any hit-test for them at all,
/// not a filter/gating bug. Mirrors [hitTestSketchCircles] exactly (each
/// rendered as a polyline of straight segments - see `sketch_geometry_3d.dart`'s
/// `arcPolylines`), just tagging the hit as [SelectionEntityKind.sketchArc].
/// An Arc's own polyline is already open (no closing duplicate point, unlike
/// a Circle's), which needs no special-casing here - testing consecutive
/// pairs up to `length - 1` already stops short of wrapping around.
HoverHit? hitTestSketchArcs(
  vm.Ray ray,
  Size viewportSize,
  String sketchFeatureId,
  List<List<vm.Vector3>> polylines,
  List<String> ids, {
  double radiusPixels = kSelectionHitRadiusPixels,
  double? orthographicHalfHeight,
}) =>
    _hitTestSketchPolylines(
      ray,
      viewportSize,
      sketchFeatureId,
      polylines,
      ids,
      SelectionEntityKind.sketchArc,
      radiusPixels: radiusPixels,
      orthographicHalfHeight: orthographicHalfHeight,
    );

/// Mirrors [hitTestSketchCircles] for an Ellipse's own closed polygon (see
/// `sketch_geometry_3d.dart`'s `ellipsePolygons`) - see [hitTestSketchArcs]'s
/// own doc comment for why this was missing entirely, not just gated off.
HoverHit? hitTestSketchEllipses(
  vm.Ray ray,
  Size viewportSize,
  String sketchFeatureId,
  List<List<vm.Vector3>> polygons,
  List<String> ids, {
  double radiusPixels = kSelectionHitRadiusPixels,
  double? orthographicHalfHeight,
}) =>
    _hitTestSketchPolylines(
      ray,
      viewportSize,
      sketchFeatureId,
      polygons,
      ids,
      SelectionEntityKind.sketchEllipse,
      radiusPixels: radiusPixels,
      orthographicHalfHeight: orthographicHalfHeight,
    );

/// Mirrors [hitTestSketchArcs] for an EllipseArc's own open polyline (see
/// `sketch_geometry_3d.dart`'s `ellipseArcPolylines`) - Pattern/Mirror
/// roadmap follow-up: an EllipseArc had no 3D-viewport hit-test of its own
/// at all, mirroring [hitTestSketchArcs]'s own doc comment for why.
HoverHit? hitTestSketchEllipseArcs(
  vm.Ray ray,
  Size viewportSize,
  String sketchFeatureId,
  List<List<vm.Vector3>> polylines,
  List<String> ids, {
  double radiusPixels = kSelectionHitRadiusPixels,
  double? orthographicHalfHeight,
}) =>
    _hitTestSketchPolylines(
      ray,
      viewportSize,
      sketchFeatureId,
      polylines,
      ids,
      SelectionEntityKind.sketchEllipseArc,
      radiusPixels: radiusPixels,
      orthographicHalfHeight: orthographicHalfHeight,
    );

/// Mirrors [hitTestSketchArcs] for a Spline's own tessellated polyline (see
/// `sketch_geometry_3d.dart`'s `splinePolylines`) - see [hitTestSketchArcs]'s
/// own doc comment for why this was missing entirely, not just gated off.
HoverHit? hitTestSketchSplines(
  vm.Ray ray,
  Size viewportSize,
  String sketchFeatureId,
  List<List<vm.Vector3>> polylines,
  List<String> ids, {
  double radiusPixels = kSelectionHitRadiusPixels,
  double? orthographicHalfHeight,
}) =>
    _hitTestSketchPolylines(
      ray,
      viewportSize,
      sketchFeatureId,
      polylines,
      ids,
      SelectionEntityKind.sketchSpline,
      radiusPixels: radiusPixels,
      orthographicHalfHeight: orthographicHalfHeight,
    );

/// 3D-viewport Text tool round: [hitTestSketchCircles]' counterpart for a
/// Sketch's own Text entities - each glyph contour's outer loop *or* one
/// of its own holes is already its own closed polyline (see
/// `sketch_geometry_3d.dart`'s `textPolygons`, one owning Text id per
/// loop in the parallel `ids`), so this needs no Text-specific geometry
/// of its own - a straight [_hitTestSketchPolylines] call, exactly like
/// every sibling `hitTestSketchXxx` function here. A hole's own hit-test
/// resolving to the owning Text id (never a "this is just a hole" flag)
/// is correct - the whole point of tagging every loop with the same
/// owning id is that a tap anywhere on the outline, hole included,
/// selects the one Text entity, not a sub-piece of it.
HoverHit? hitTestSketchTexts(
  vm.Ray ray,
  Size viewportSize,
  String sketchFeatureId,
  List<List<vm.Vector3>> polygons,
  List<String> ids, {
  double radiusPixels = kSelectionHitRadiusPixels,
  double? orthographicHalfHeight,
}) =>
    _hitTestSketchPolylines(
      ray,
      viewportSize,
      sketchFeatureId,
      polygons,
      ids,
      SelectionEntityKind.sketchText,
      radiusPixels: radiusPixels,
      orthographicHalfHeight: orthographicHalfHeight,
    );

HoverHit? _hitTestSketchPolylines(
  vm.Ray ray,
  Size viewportSize,
  String sketchFeatureId,
  List<List<vm.Vector3>> polylines,
  List<String> ids,
  SelectionEntityKind kind, {
  double radiusPixels = kSelectionHitRadiusPixels,
  double? orthographicHalfHeight,
}) {
  final direction = ray.direction.normalized();
  HoverHit? best;
  for (var p = 0; p < polylines.length; p++) {
    final polyline = polylines[p];
    for (var i = 0; i < polyline.length - 1; i++) {
      final closest = _closestRaySegmentDistance(ray.origin, direction, polyline[i], polyline[i + 1]);
      if (closest == null) continue;
      final (t, worldDistance) = closest;
      final pixelDistance = worldDistance /
          _worldUnitsPerPixelAtDepth(t, viewportSize, orthographicHalfHeight: orthographicHalfHeight);
      if (pixelDistance > radiusPixels) continue;
      if (best == null || _isCloserHit(pixelDistance, t, best.pixelDistance!, best.rayT)) {
        best = HoverHit(
          entity: SelectionEntityRef(
            kind: kind,
            sketchFeatureId: sketchFeatureId,
            sketchEntityId: ids[p],
          ),
          rayT: t,
          pixelDistance: pixelDistance,
        );
      }
    }
  }
  return best;
}

/// On-device feedback ("the patterned circle under the cursor is not
/// highlighted and will not select" - the embedded-3D-view report, distinct
/// from `sketch_canvas.dart`'s own flat-2D-canvas fix for the identical
/// complaint there): [hitTestSketchLines]'s own counterpart for a committed
/// Pattern/Mirror instance's own derived (ghost) geometry. Unlike every
/// other `hitTestSketchXxx` function above, [segments] is already flattened
/// to individual straight hops by the caller (`sketch_screen.dart` - a
/// Circle/Arc ghost tessellates into several, a Line ghost into exactly
/// one, mirroring `sketch_geometry_3d.dart`'s own `circlePolygons`/
/// `arcPolylines` convention) rather than one polyline per entity, since
/// [ownerInstanceIds] tags each segment with its *owning instance's* own
/// id - several segments (even across several different derived copies)
/// legitimately share the same id, unlike every other kind here where ids
/// are 1:1 with a real entity.
HoverHit? hitTestSketchPatternMirrorInstances(
  vm.Ray ray,
  Size viewportSize,
  String sketchFeatureId,
  List<(vm.Vector3, vm.Vector3)> segments,
  List<String> ownerInstanceIds, {
  double radiusPixels = kSelectionHitRadiusPixels,
  double? orthographicHalfHeight,
}) {
  final direction = ray.direction.normalized();
  HoverHit? best;
  for (var i = 0; i < segments.length; i++) {
    final closest = _closestRaySegmentDistance(ray.origin, direction, segments[i].$1, segments[i].$2);
    if (closest == null) continue;
    final (t, worldDistance) = closest;
    final pixelDistance = worldDistance /
        _worldUnitsPerPixelAtDepth(t, viewportSize, orthographicHalfHeight: orthographicHalfHeight);
    if (pixelDistance > radiusPixels) continue;
    if (best == null || _isCloserHit(pixelDistance, t, best.pixelDistance!, best.rayT)) {
      best = HoverHit(
        entity: SelectionEntityRef(
          kind: SelectionEntityKind.sketchPatternMirrorInstance,
          sketchFeatureId: sketchFeatureId,
          sketchEntityId: ownerInstanceIds[i],
        ),
        rayT: t,
        pixelDistance: pixelDistance,
      );
    }
  }
  return best;
}

/// Möller-Trumbore ray-triangle intersection - returns the ray parameter
/// `t` of the intersection, or null if [ray] misses the triangle (or hits
/// only behind the camera/at the camera itself).
double? _rayTriangleIntersectionT(
  vm.Vector3 origin,
  vm.Vector3 direction,
  vm.Vector3 v0,
  vm.Vector3 v1,
  vm.Vector3 v2,
) {
  const epsilon = 1e-9;
  final edge1 = v1 - v0;
  final edge2 = v2 - v0;
  final h = direction.cross(edge2);
  final a = edge1.dot(h);
  if (a.abs() < epsilon) return null; // Ray parallel to the triangle's plane.
  final f = 1.0 / a;
  final s = origin - v0;
  final u = f * s.dot(h);
  if (u < 0.0 || u > 1.0) return null;
  final q = s.cross(edge1);
  final v = f * direction.dot(q);
  if (v < 0.0 || u + v > 1.0) return null;
  final t = f * edge2.dot(q);
  if (t <= epsilon) return null;
  return t;
}

/// Nearest of [triangles] (ids parallel in [ids], one id per triangle - see
/// `MeshDto.faceIds`) actually intersected by [ray] - or null if [ray]
/// misses every triangle. Unlike [hitTestVertices]/[hitTestEdges], there is
/// no pixel-radius check: a face is only ever the fallback once no
/// edge/vertex is close enough (see [hitTestMeshEntities]), at which point
/// "the cursor ray actually passes through this triangle" is itself the
/// hit-test - no separate proximity radius is meaningful for a filled face.
HoverHit? hitTestFaces(
  vm.Ray ray,
  List<(vm.Vector3, vm.Vector3, vm.Vector3)> triangles,
  List<int> ids,
) {
  final direction = ray.direction.normalized();
  double? bestT;
  int? bestId;
  for (var i = 0; i < triangles.length; i++) {
    final triangle = triangles[i];
    final t = _rayTriangleIntersectionT(
      ray.origin,
      direction,
      triangle.$1,
      triangle.$2,
      triangle.$3,
    );
    if (t == null) continue;
    if (bestT == null || t < bestT) {
      bestT = t;
      bestId = ids[i];
    }
  }
  if (bestT == null || bestId == null) return null;
  return HoverHit(entity: SelectionEntityRef(kind: SelectionEntityKind.face, id: bestId), rayT: bestT);
}

/// [mesh.topologyVertices] as [vm.Vector3]s, parallel to
/// [MeshDto.topologyVertexIds] - the pure parsing step [hitTestMeshEntities]
/// needs before calling [hitTestVertices].
List<vm.Vector3> topologyVerticesFromMesh(MeshDto mesh) =>
    [for (final v in mesh.topologyVertices) vm.Vector3(v[0], v[1], v[2])];

/// [mesh.vertices]/[mesh.triangleIndices] resolved into actual triangle
/// corner positions, parallel to [MeshDto.faceIds] - the pure parsing step
/// [hitTestMeshEntities] needs before calling [hitTestFaces].
List<(vm.Vector3, vm.Vector3, vm.Vector3)> trianglesFromMesh(MeshDto mesh) => [
      for (final triangle in mesh.triangleIndices)
        (
          _vector3At(mesh, triangle[0]),
          _vector3At(mesh, triangle[1]),
          _vector3At(mesh, triangle[2]),
        ),
    ];

vm.Vector3 _vector3At(MeshDto mesh, int index) {
  final p = mesh.vertices[index];
  return vm.Vector3(p[0], p[1], p[2]);
}

/// World position of the topology vertex with the given [id], or null if no
/// such id exists in [mesh] - the lookup [PartViewport]'s highlight
/// rendering needs to turn a hovered/selected [SelectionEntityRef] (vertex
/// kind) back into a world-space point for [buildVertexMarkersNode]-style
/// rendering. A vertex id is always unique per [MeshDto.topologyVertexIds],
/// so this returns at most one position (contrast [edgeSegmentsForId]/
/// [faceTrianglesForId] below, which can each return several).
vm.Vector3? vertexPositionForId(MeshDto mesh, int id) {
  final index = mesh.topologyVertexIds.indexOf(id);
  if (index == -1) return null;
  final v = mesh.topologyVertices[index];
  return vm.Vector3(v[0], v[1], v[2]);
}

/// World-space segments making up the edge with the given [id] - a straight
/// OCCT edge contributes exactly one segment to `mesh.edges`, but a curved
/// one is sampled into several consecutive segments that all share the same
/// id (see backend/app/document/mesh.py's `_extract_edges`:
/// `edge_ids.extend([next_edge_id] * segment_count)`), so this must return a
/// list rather than a single segment. Empty if [id] is not present.
List<(vm.Vector3, vm.Vector3)> edgeSegmentsForId(MeshDto mesh, int id) {
  final allSegments = edgeSegmentsFromMesh(mesh);
  return [
    for (var i = 0; i < mesh.edgeIds.length; i++)
      if (mesh.edgeIds[i] == id) allSegments[i],
  ];
}

/// World-space triangles making up the face with the given [id] - an OCCT
/// face tessellates into one or more triangles that all share the same face
/// id (see backend/app/document/mesh.py's tessellation loop), so this must
/// return a list rather than a single triangle. Empty if [id] is not
/// present.
List<(vm.Vector3, vm.Vector3, vm.Vector3)> faceTrianglesForId(MeshDto mesh, int id) {
  final allTriangles = trianglesFromMesh(mesh);
  return [
    for (var i = 0; i < mesh.faceIds.length; i++)
      if (mesh.faceIds[i] == id) allTriangles[i],
  ];
}

/// The combined Item 3 hit-test: any topology vertex within
/// [vertexRadiusPixels] wins outright over edges/faces - not just when it's
/// the *closer* of the two. A vertex sits at the shared endpoint of one or
/// more edges, so comparing raw distance (as this used to) meant an edge's
/// closest point - which slides along the segment toward wherever the
/// cursor actually is - would beat the fixed vertex point for almost any
/// cursor position off its exact projected pixel, defeating the whole point
/// of giving vertices a wider radius. [vertexRadiusPixels] is wider than
/// [radiusPixels] (the latter applies to edges) precisely so a corner is a
/// realistically reachable target - see [kVertexSelectionHitRadiusPixels]'s
/// doc comment - so being inside it is itself the priority signal; only
/// when no vertex is in range does the nearer of edge/face apply.
///
/// Prompt A2: [filter] gates which kinds are considered at all - a kind
/// whose [SelectionFilterState] flag is off is skipped entirely (as if it
/// weren't in the mesh), not merely deprioritized, so e.g. turning vertices
/// off lets a hover land on an edge/face that a nearby vertex would
/// otherwise have won outright. [SelectionFilterState.body] has no effect
/// here - this function has no Body concept at all (it only ever sees one
/// mesh at a time); see [hitTestBodies] for the real multi-body entry
/// point (Prompt A3) that does honor it.
HoverHit? hitTestMeshEntities({
  required vm.Ray ray,
  required Size viewportSize,
  required MeshDto mesh,
  double radiusPixels = kSelectionHitRadiusPixels,
  double vertexRadiusPixels = kVertexSelectionHitRadiusPixels,
  SelectionFilterState filter = SelectionFilterState.defaults,
  double? orthographicHalfHeight,
}) {
  final vertexHit = filter.vertex
      ? hitTestVertices(
          ray,
          viewportSize,
          topologyVerticesFromMesh(mesh),
          mesh.topologyVertexIds,
          radiusPixels: vertexRadiusPixels,
          orthographicHalfHeight: orthographicHalfHeight,
        )
      : null;
  final edgeHit = filter.edge
      ? hitTestEdges(
          ray,
          viewportSize,
          edgeSegmentsFromMesh(mesh),
          mesh.edgeIds,
          radiusPixels: radiusPixels,
          orthographicHalfHeight: orthographicHalfHeight,
        )
      : null;

  if (vertexHit != null) return vertexHit;
  if (edgeHit != null) return edgeHit;

  if (!filter.face) return null;
  return hitTestFaces(ray, trianglesFromMesh(mesh), mesh.faceIds);
}

/// Prompt A3: the real multi-body hit-test entry point [PartViewport]
/// uses - generalizes [hitTestMeshEntities] across every currently-visible
/// Body (Prompt A1's `/mesh` array), tagging the winning entity with which
/// Body it came from (see [SelectionEntityRef.bodyId]) since ids are only
/// body-local.
///
/// Vertex/edge priority is unchanged (nearest in-range vertex always wins;
/// then nearest in-range edge) - just extended from "nearest within one
/// mesh" to "nearest across every Body". Face-vs-Body resolution is new:
/// [SelectionFilterState.body] is not an independent fourth hit-test tier
/// alongside vertex/edge/face - toggling it on changes what a face
/// intersection *means*, rather than adding a competing kind of its own. A
/// face-ray-intersection test runs whenever either [SelectionFilterState.face]
/// or [SelectionFilterState.body] is on (so a future picking mode that
/// forces "bodies only, everything else off" - see Prompt A4 - still gets
/// a working ray-vs-geometry test even with `face` itself off), and if
/// [SelectionFilterState.body] is on, the winning triangle's owning Body is
/// resolved and returned as a [SelectionEntityKind.body] entity instead of
/// the tapped [SelectionEntityKind.face] - Body deliberately takes
/// precedence over a plain face pick whenever both are enabled, since
/// toggling Body on is specifically a request for the coarser granularity.
///
/// Prompt C1: [sketchGeometries] (same map [PartViewport.sketchGeometries]
/// carries, keyed by Feature id) is folded into the same two tiers rather
/// than tested as a separate third pass - a Sketch Point ties with a Body
/// Vertex at the top priority tier, a Sketch Line ties with a Body Edge at
/// the next one, per this prompt's own confirmed design (the recommended
/// "kind-based tie" over "all Sketch entities outrank all Body entities" -
/// see the prompt's own scope doc). Reuses [hitTestSketchPoints]/
/// [hitTestSketchLines] rather than a second hit-test path, per this
/// project's standing "extend the existing projection/hit-test logic"
/// principle.
/// On-device feedback ("I'm able to pick edges through faces. when the
/// body is shaded, this shouldn't happen"): tolerance (world units) for
/// [hitTestBodies]' own face-occlusion check - a vertex/edge whose own
/// ray parameter is farther than the nearest face's by more than this is
/// treated as hidden behind that face, not a legitimate pick. Reuses
/// `mesh_geometry.dart`'s `meshEdgeNudgeAmount`/[biasSegmentsTowardCamera]
/// constant (`0.02`) rather than inventing a second on-device-tuned
/// magnitude - same "small enough not to misjudge genuinely coplanar
/// geometry (e.g. a Sketch drawn directly on a Body face), big enough to
/// survive float noise" tradeoff that constant's own doc comment already
/// works through, and the same order of magnitude is exactly what's
/// needed here too.
const double kFaceOcclusionEpsilon = 0.02;

HoverHit? hitTestBodies({
  required vm.Ray ray,
  required Size viewportSize,
  required List<BodyMeshDto> bodies,
  Map<String, SketchGeometry3D> sketchGeometries = const {},
  // On-device feedback ("the patterned circle under the cursor is not
  // highlighted and will not select"): a committed Pattern/Mirror
  // instance's own derived (ghost) geometry, keyed by owning instance id
  // (never a real backend entity id, unlike every other map/list
  // parameter here) - see [hitTestSketchPatternMirrorInstances]'s own doc
  // comment for why this is pre-flattened to segments rather than
  // [sketchGeometries]' own per-entity polyline shape.
  Map<String, List<(vm.Vector3, vm.Vector3)>> patternMirrorGhostSegments = const {},
  String patternMirrorSketchFeatureId = '',
  double radiusPixels = kSelectionHitRadiusPixels,
  double vertexRadiusPixels = kVertexSelectionHitRadiusPixels,
  SelectionFilterState filter = SelectionFilterState.defaults,
  // On-device feedback ("I'm able to pick edges through faces. when the
  // body is shaded, this shouldn't happen"): vertex/edge hit-testing
  // below is purely 2D-screen-space (see hitTestVertices/hitTestEdges'
  // own doc comments) and previously always won outright over a face
  // hit, with no regard for which one the camera would actually see -
  // a vertex/edge on the *far* side of a shaded body can project to
  // nearly the same screen position as the near face in front of it.
  // When true, a face intersection is computed regardless of
  // filter.face/filter.body (those only gate whether a face/Body is
  // itself a *selectable outcome*, not whether rendered faces occlude
  // other picks) and used to drop any vertex/edge candidate that sits
  // behind it - see kFaceOcclusionEpsilon. The caller is expected to
  // pass this as `renderMode.showsFilledFaces && !bodiesHidden` (i.e.
  // only when faces are actually being drawn solid) - in wireframe
  // there is nothing rendered to be "behind", so reaching through stays
  // intentional there.
  bool facesOccludeOtherHits = false,
  // Bug fix (on-device feedback: "when editing a sketch, the entities in
  // that sketch should be visible, selectable... it shouldn't be obscured
  // or restricted by bodies"): [facesOccludeOtherHits] above is otherwise
  // unconditional - a nearer Body face drops *any* farther vertex/edge
  // candidate, sketch entities included, so a Sketch actively being edited
  // could be rendered on top of a Body (see [buildSketchGeometryNode]'s
  // own doc comment) yet still be unselectable underneath it, since
  // hit-testing never stopped respecting real depth the way rendering now
  // does. When non-empty, exempts only the sketch whose
  // [SelectionEntityRef.sketchFeatureId] equals this from the occlusion
  // check below - every other candidate (Body vertices/edges, and any
  // *other* Sketch's entities, e.g. `PartViewport.otherSketchGeometries`'
  // read-only reference geometry) still gets dropped exactly as before.
  // The caller is expected to pass the Feature id of whichever Sketch is
  // actually being edited (empty string - the default - preserves the
  // pre-fix behaviour everywhere else, e.g. Part-level face/edge
  // selection for Fillet/Extrude, which must keep genuinely respecting
  // occlusion).
  String activeSketchFeatureId = '',
  double? orthographicHalfHeight,
}) {
  HoverHit taggedWithBody(HoverHit hit, String bodyId) => HoverHit(
        entity: SelectionEntityRef(kind: hit.entity.kind, bodyId: bodyId, id: hit.entity.id),
        rayT: hit.rayT,
        pixelDistance: hit.pixelDistance,
      );

  HoverHit? bestVertex;
  HoverHit? bestEdge;
  HoverHit? bestFace;
  String? bestFaceBodyId;

  for (final body in bodies) {
    final mesh = body.mesh;
    if (filter.vertex) {
      final hit = hitTestVertices(
        ray,
        viewportSize,
        topologyVerticesFromMesh(mesh),
        mesh.topologyVertexIds,
        radiusPixels: vertexRadiusPixels,
        orthographicHalfHeight: orthographicHalfHeight,
      );
      if (hit != null && (bestVertex == null || _isCloserHit(hit.pixelDistance!, hit.rayT, bestVertex.pixelDistance!, bestVertex.rayT))) {
        bestVertex = taggedWithBody(hit, body.bodyId);
      }
    }
    if (filter.edge) {
      final hit = hitTestEdges(
        ray,
        viewportSize,
        edgeSegmentsFromMesh(mesh),
        mesh.edgeIds,
        radiusPixels: radiusPixels,
        orthographicHalfHeight: orthographicHalfHeight,
      );
      if (hit != null && (bestEdge == null || _isCloserHit(hit.pixelDistance!, hit.rayT, bestEdge.pixelDistance!, bestEdge.rayT))) {
        bestEdge = taggedWithBody(hit, body.bodyId);
      }
    }
    if (filter.face || filter.body || facesOccludeOtherHits) {
      final hit = hitTestFaces(ray, trianglesFromMesh(mesh), mesh.faceIds);
      if (hit != null && (bestFace == null || hit.rayT < bestFace.rayT)) {
        bestFace = hit;
        bestFaceBodyId = body.bodyId;
      }
    }
  }

  for (final entry in sketchGeometries.entries) {
    final geometry = entry.value;
    if (filter.sketchPoint) {
      final hit = hitTestSketchPoints(
        ray,
        viewportSize,
        entry.key,
        geometry.points,
        geometry.pointIds,
        radiusPixels: vertexRadiusPixels,
        orthographicHalfHeight: orthographicHalfHeight,
      );
      if (hit != null && (bestVertex == null || _isCloserHit(hit.pixelDistance!, hit.rayT, bestVertex.pixelDistance!, bestVertex.rayT))) {
        bestVertex = hit;
      }
    }
    if (filter.sketchLine) {
      final hit = hitTestSketchLines(
        ray,
        viewportSize,
        entry.key,
        geometry.lineSegments,
        geometry.lineIds,
        radiusPixels: radiusPixels,
        orthographicHalfHeight: orthographicHalfHeight,
      );
      if (hit != null && (bestEdge == null || _isCloserHit(hit.pixelDistance!, hit.rayT, bestEdge.pixelDistance!, bestEdge.rayT))) {
        bestEdge = hit;
      }
    }
    if (filter.sketchCircle) {
      final hit = hitTestSketchCircles(
        ray,
        viewportSize,
        entry.key,
        geometry.circlePolygons,
        geometry.circleIds,
        radiusPixels: radiusPixels,
        orthographicHalfHeight: orthographicHalfHeight,
      );
      if (hit != null && (bestEdge == null || _isCloserHit(hit.pixelDistance!, hit.rayT, bestEdge.pixelDistance!, bestEdge.rayT))) {
        bestEdge = hit;
      }
    }
    if (filter.sketchArc) {
      final hit = hitTestSketchArcs(
        ray,
        viewportSize,
        entry.key,
        geometry.arcPolylines,
        geometry.arcIds,
        radiusPixels: radiusPixels,
        orthographicHalfHeight: orthographicHalfHeight,
      );
      if (hit != null && (bestEdge == null || _isCloserHit(hit.pixelDistance!, hit.rayT, bestEdge.pixelDistance!, bestEdge.rayT))) {
        bestEdge = hit;
      }
    }
    if (filter.sketchEllipse) {
      final hit = hitTestSketchEllipses(
        ray,
        viewportSize,
        entry.key,
        geometry.ellipsePolygons,
        geometry.ellipseIds,
        radiusPixels: radiusPixels,
        orthographicHalfHeight: orthographicHalfHeight,
      );
      if (hit != null && (bestEdge == null || _isCloserHit(hit.pixelDistance!, hit.rayT, bestEdge.pixelDistance!, bestEdge.rayT))) {
        bestEdge = hit;
      }
    }
    if (filter.sketchEllipseArc) {
      final hit = hitTestSketchEllipseArcs(
        ray,
        viewportSize,
        entry.key,
        geometry.ellipseArcPolylines,
        geometry.ellipseArcIds,
        radiusPixels: radiusPixels,
        orthographicHalfHeight: orthographicHalfHeight,
      );
      if (hit != null && (bestEdge == null || _isCloserHit(hit.pixelDistance!, hit.rayT, bestEdge.pixelDistance!, bestEdge.rayT))) {
        bestEdge = hit;
      }
    }
    if (filter.sketchSpline) {
      final hit = hitTestSketchSplines(
        ray,
        viewportSize,
        entry.key,
        geometry.splinePolylines,
        geometry.splineIds,
        radiusPixels: radiusPixels,
        orthographicHalfHeight: orthographicHalfHeight,
      );
      if (hit != null && (bestEdge == null || _isCloserHit(hit.pixelDistance!, hit.rayT, bestEdge.pixelDistance!, bestEdge.rayT))) {
        bestEdge = hit;
      }
    }
    if (filter.sketchText) {
      final hit = hitTestSketchTexts(
        ray,
        viewportSize,
        entry.key,
        geometry.textPolygons,
        geometry.textIds,
        radiusPixels: radiusPixels,
        orthographicHalfHeight: orthographicHalfHeight,
      );
      if (hit != null && (bestEdge == null || _isCloserHit(hit.pixelDistance!, hit.rayT, bestEdge.pixelDistance!, bestEdge.rayT))) {
        bestEdge = hit;
      }
    }
  }

  // On-device feedback ("the patterned circle under the cursor is not
  // highlighted and will not select"): ties with real Sketch Lines/
  // Circles/Arcs at the same priority tier (bestEdge) - a Pattern/Mirror
  // instance's own derived copy is exactly as tappable as a real entity,
  // same as `SketchController._resolveSelectableAt`'s own real-geometry-
  // vs-synthetic-fallback resolution never distinguishing them once real
  // geometry has already had first refusal on the 2D-canvas side (here,
  // both compete on nearest-pixel-distance directly instead, since this
  // function has no separate "only once nothing else is near" fallback
  // tier the way [SketchController.hoveredEntity] does).
  if (filter.sketchPatternMirrorInstance && patternMirrorGhostSegments.isNotEmpty) {
    final segments = <(vm.Vector3, vm.Vector3)>[];
    final ownerIds = <String>[];
    for (final entry in patternMirrorGhostSegments.entries) {
      for (final segment in entry.value) {
        segments.add(segment);
        ownerIds.add(entry.key);
      }
    }
    final hit = hitTestSketchPatternMirrorInstances(
      ray,
      viewportSize,
      patternMirrorSketchFeatureId,
      segments,
      ownerIds,
      radiusPixels: radiusPixels,
      orthographicHalfHeight: orthographicHalfHeight,
    );
    if (hit != null && (bestEdge == null || _isCloserHit(hit.pixelDistance!, hit.rayT, bestEdge.pixelDistance!, bestEdge.rayT))) {
      bestEdge = hit;
    }
  }

  if (facesOccludeOtherHits && bestFace != null) {
    bool isActiveSketchEntity(HoverHit hit) =>
        activeSketchFeatureId.isNotEmpty && hit.entity.sketchFeatureId == activeSketchFeatureId;
    // Bug fix (bug report: "if a sweep path line exists entirely within a
    // body it cannot be selected"): [isActiveSketchEntity] above only
    // exempts the one Sketch actively being edited (`sketch_screen.dart`'s
    // embedded 2D-in-3D editor) - every picker in the main modeling screen
    // (`part_screen.dart`'s Sweep path/Loft guide curve picker, neither of
    // which ever set [activeSketchFeatureId]) still had *any* sketch curve
    // dropped the moment a Body's face sat nearer along the ray, even
    // though neither picker's own filter accepts a Body/face pick at all -
    // there is no Body/face outcome for the ray to "correctly" fall back to
    // there, so occluding the curve just loses the pick outright.
    //
    // Scoped to `!filter.face && !filter.body` (not just "the hit's own
    // kind passed its own filter check", which - confirmed against this
    // file's own existing occlusion tests, e.g. "with no
    // activeSketchFeatureId, a Sketch Point behind the nearest face is
    // occluded like a Body vertex would be - no regression" - is too broad:
    // ordinary default browsing, and pickers like Split/Revolve that accept
    // *either* a sketch curve or a Body/face in the same filter, still need
    // a nearer Body's face to keep winning that pixel over a farther sketch
    // entity, exactly as before this fix). Real Body topology
    // ([SelectionEntityKind.vertex]/[edge]) is untouched either way, so a
    // genuinely hidden mesh edge/vertex (e.g. Fillet's edge picker) stays
    // occluded exactly as before.
    bool isSketchOnlyFilterKind(HoverHit hit) {
      if (filter.face || filter.body) return false;
      switch (hit.entity.kind) {
        case SelectionEntityKind.sketchPoint:
          return filter.sketchPoint;
        case SelectionEntityKind.sketchLine:
          return filter.sketchLine;
        case SelectionEntityKind.sketchCircle:
          return filter.sketchCircle;
        case SelectionEntityKind.sketchArc:
          return filter.sketchArc;
        case SelectionEntityKind.sketchEllipse:
          return filter.sketchEllipse;
        case SelectionEntityKind.sketchEllipseArc:
          return filter.sketchEllipseArc;
        case SelectionEntityKind.sketchSpline:
          return filter.sketchSpline;
        case SelectionEntityKind.sketchText:
          return filter.sketchText;
        case SelectionEntityKind.sketchPatternMirrorInstance:
          return filter.sketchPatternMirrorInstance;
        default:
          return false;
      }
    }

    bool isExemptFromFaceOcclusion(HoverHit hit) => isActiveSketchEntity(hit) || isSketchOnlyFilterKind(hit);

    if (bestVertex != null &&
        !isExemptFromFaceOcclusion(bestVertex) &&
        bestVertex.rayT > bestFace.rayT + kFaceOcclusionEpsilon) {
      bestVertex = null;
    }
    if (bestEdge != null &&
        !isExemptFromFaceOcclusion(bestEdge) &&
        bestEdge.rayT > bestFace.rayT + kFaceOcclusionEpsilon) {
      bestEdge = null;
    }
  }

  if (bestVertex != null) return bestVertex;
  if (bestEdge != null) return bestEdge;
  if (bestFace == null) return null;

  if (filter.body) {
    return HoverHit(
      entity: SelectionEntityRef(kind: SelectionEntityKind.body, bodyId: bestFaceBodyId!),
      rayT: bestFace.rayT,
    );
  }
  if (!filter.face) return null;
  return taggedWithBody(bestFace, bestFaceBodyId!);
}

/// Every valid-per-[filter] hit-test candidate at [ray]'s screen position,
/// nearest to farthest - the "Select Other" counterpart to [hitTestBodies]
/// (bug report: "if one body is entirely inside another body, it cannot be
/// selected"). [hitTestBodies] only ever keeps the single nearest Body/face
/// along the ray (its own `bestFace`), so a fully-enclosed Body's own faces
/// can never win there, from any camera angle - a fundamentally different
/// gap from the face-occlusion fix above (that only ever drops an
/// otherwise-good, farther candidate; this one never even considers a
/// second, equally-valid Body). Mirrors [hitTestBodies]'s own per-body loop,
/// except it keeps every Body the ray crosses (not just the nearest one),
/// each represented by its own nearest-face intersection, so a "Select
/// Other" list can offer all of them - the same nested/enclosed-Body case
/// [hitTestBodies] structurally cannot reach.
///
/// Vertex/edge (mesh and sketch) candidates are still each resolved to a
/// single nearest winner exactly like [hitTestBodies] - multi-body
/// occlusion, not multi-vertex/edge occlusion, is the reported gap, and a
/// caller wanting the same face-occlusion treatment those get in
/// [hitTestBodies] should call that first and only fall back to this one
/// when disambiguation is actually needed (e.g. the user's own
/// double-click-and-hold gesture).
List<HoverHit> hitTestAllCandidates({
  required vm.Ray ray,
  required Size viewportSize,
  required List<BodyMeshDto> bodies,
  Map<String, SketchGeometry3D> sketchGeometries = const {},
  double radiusPixels = kSelectionHitRadiusPixels,
  double vertexRadiusPixels = kVertexSelectionHitRadiusPixels,
  SelectionFilterState filter = SelectionFilterState.defaults,
  double? orthographicHalfHeight,
}) {
  HoverHit taggedWithBody(HoverHit hit, String bodyId) => HoverHit(
        entity: SelectionEntityRef(kind: hit.entity.kind, bodyId: bodyId, id: hit.entity.id),
        rayT: hit.rayT,
        pixelDistance: hit.pixelDistance,
      );

  HoverHit? bestVertex;
  HoverHit? bestEdge;
  final bodyFaceHits = <String, HoverHit>{};

  for (final body in bodies) {
    final mesh = body.mesh;
    if (filter.vertex) {
      final hit = hitTestVertices(
        ray,
        viewportSize,
        topologyVerticesFromMesh(mesh),
        mesh.topologyVertexIds,
        radiusPixels: vertexRadiusPixels,
        orthographicHalfHeight: orthographicHalfHeight,
      );
      if (hit != null && (bestVertex == null || _isCloserHit(hit.pixelDistance!, hit.rayT, bestVertex.pixelDistance!, bestVertex.rayT))) {
        bestVertex = taggedWithBody(hit, body.bodyId);
      }
    }
    if (filter.edge) {
      final hit = hitTestEdges(
        ray,
        viewportSize,
        edgeSegmentsFromMesh(mesh),
        mesh.edgeIds,
        radiusPixels: radiusPixels,
        orthographicHalfHeight: orthographicHalfHeight,
      );
      if (hit != null && (bestEdge == null || _isCloserHit(hit.pixelDistance!, hit.rayT, bestEdge.pixelDistance!, bestEdge.rayT))) {
        bestEdge = taggedWithBody(hit, body.bodyId);
      }
    }
    if (filter.face || filter.body) {
      final hit = hitTestFaces(ray, trianglesFromMesh(mesh), mesh.faceIds);
      if (hit != null) {
        bodyFaceHits[body.bodyId] = hit;
      }
    }
  }

  for (final entry in sketchGeometries.entries) {
    final geometry = entry.value;
    if (filter.sketchPoint) {
      final hit = hitTestSketchPoints(
        ray,
        viewportSize,
        entry.key,
        geometry.points,
        geometry.pointIds,
        radiusPixels: vertexRadiusPixels,
        orthographicHalfHeight: orthographicHalfHeight,
      );
      if (hit != null && (bestVertex == null || _isCloserHit(hit.pixelDistance!, hit.rayT, bestVertex.pixelDistance!, bestVertex.rayT))) {
        bestVertex = hit;
      }
    }
    if (filter.sketchLine) {
      final hit = hitTestSketchLines(
        ray,
        viewportSize,
        entry.key,
        geometry.lineSegments,
        geometry.lineIds,
        radiusPixels: radiusPixels,
        orthographicHalfHeight: orthographicHalfHeight,
      );
      if (hit != null && (bestEdge == null || _isCloserHit(hit.pixelDistance!, hit.rayT, bestEdge.pixelDistance!, bestEdge.rayT))) {
        bestEdge = hit;
      }
    }
    if (filter.sketchCircle) {
      final hit = hitTestSketchCircles(
        ray,
        viewportSize,
        entry.key,
        geometry.circlePolygons,
        geometry.circleIds,
        radiusPixels: radiusPixels,
        orthographicHalfHeight: orthographicHalfHeight,
      );
      if (hit != null && (bestEdge == null || _isCloserHit(hit.pixelDistance!, hit.rayT, bestEdge.pixelDistance!, bestEdge.rayT))) {
        bestEdge = hit;
      }
    }
    if (filter.sketchArc) {
      final hit = hitTestSketchArcs(
        ray,
        viewportSize,
        entry.key,
        geometry.arcPolylines,
        geometry.arcIds,
        radiusPixels: radiusPixels,
        orthographicHalfHeight: orthographicHalfHeight,
      );
      if (hit != null && (bestEdge == null || _isCloserHit(hit.pixelDistance!, hit.rayT, bestEdge.pixelDistance!, bestEdge.rayT))) {
        bestEdge = hit;
      }
    }
    if (filter.sketchEllipse) {
      final hit = hitTestSketchEllipses(
        ray,
        viewportSize,
        entry.key,
        geometry.ellipsePolygons,
        geometry.ellipseIds,
        radiusPixels: radiusPixels,
        orthographicHalfHeight: orthographicHalfHeight,
      );
      if (hit != null && (bestEdge == null || _isCloserHit(hit.pixelDistance!, hit.rayT, bestEdge.pixelDistance!, bestEdge.rayT))) {
        bestEdge = hit;
      }
    }
    if (filter.sketchEllipseArc) {
      final hit = hitTestSketchEllipseArcs(
        ray,
        viewportSize,
        entry.key,
        geometry.ellipseArcPolylines,
        geometry.ellipseArcIds,
        radiusPixels: radiusPixels,
        orthographicHalfHeight: orthographicHalfHeight,
      );
      if (hit != null && (bestEdge == null || _isCloserHit(hit.pixelDistance!, hit.rayT, bestEdge.pixelDistance!, bestEdge.rayT))) {
        bestEdge = hit;
      }
    }
    if (filter.sketchSpline) {
      final hit = hitTestSketchSplines(
        ray,
        viewportSize,
        entry.key,
        geometry.splinePolylines,
        geometry.splineIds,
        radiusPixels: radiusPixels,
        orthographicHalfHeight: orthographicHalfHeight,
      );
      if (hit != null && (bestEdge == null || _isCloserHit(hit.pixelDistance!, hit.rayT, bestEdge.pixelDistance!, bestEdge.rayT))) {
        bestEdge = hit;
      }
    }
    if (filter.sketchText) {
      final hit = hitTestSketchTexts(
        ray,
        viewportSize,
        entry.key,
        geometry.textPolygons,
        geometry.textIds,
        radiusPixels: radiusPixels,
        orthographicHalfHeight: orthographicHalfHeight,
      );
      if (hit != null && (bestEdge == null || _isCloserHit(hit.pixelDistance!, hit.rayT, bestEdge.pixelDistance!, bestEdge.rayT))) {
        bestEdge = hit;
      }
    }
  }

  final candidates = <HoverHit>[];
  if (bestVertex != null) candidates.add(bestVertex);
  if (bestEdge != null) candidates.add(bestEdge);
  for (final entry in bodyFaceHits.entries) {
    final hit = entry.value;
    if (filter.body) {
      candidates.add(HoverHit(
        entity: SelectionEntityRef(kind: SelectionEntityKind.body, bodyId: entry.key),
        rayT: hit.rayT,
      ));
    } else if (filter.face) {
      candidates.add(taggedWithBody(hit, entry.key));
    }
  }

  candidates.sort((a, b) => a.rayT.compareTo(b.rayT));
  return candidates;
}
