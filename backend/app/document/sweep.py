"""OCCT geometry construction for SweepFeature (the Sweep module) - kept
separate from app.document.router the same way app.document.extrude/
revolve/fillet/chamfer already are.

Boss/Cut parity with Extrude/Revolve (this module's own resolved decision,
mirroring Prompt F's): a SweepFeature's raw solid
(`resolve_sweep_from_bodies` below) is combined with `target_body_ids` by
the exact same fuse/cut/register dispatch `app.document.extrude.
compute_part_bodies` already uses for ExtrudeFeature/RevolveFeature (see
`app.document.extrude._apply_boss_or_cut`, shared rather than duplicated) -
this module only builds the raw swept solid, mirroring `app.document.
revolve.resolve_revolve_from_bodies`'s own contract (return `None` if the
backing Sketch has no sweepable/extrudable profile).

Imported from app.document.extrude's own compute_part_bodies via a
function-local import, the same circular-import avoidance app.document.
fillet/chamfer/revolve already use: this module needs compute_part_bodies/
wire_for_profile/EXTRUDABLE_STATUSES/select_profiles from extrude.py at
module level, so extrude.py cannot import this module back at its own
module level.
"""

import logging
from dataclasses import dataclass

from fastapi import HTTPException
from OCC.Core.BRep import BRep_Builder, BRep_Tool
from OCC.Core.BRepAlgoAPI import BRepAlgoAPI_Cut
from OCC.Core.BRepCheck import BRepCheck_Analyzer
from OCC.Core.BRepBuilderAPI import (
    BRepBuilderAPI_MakeEdge,
    BRepBuilderAPI_MakeWire,
    BRepBuilderAPI_RightCorner,
)
from OCC.Core.BRepOffsetAPI import BRepOffsetAPI_MakePipeShell
from OCC.Core.Geom import Geom_BezierCurve
from OCC.Core.gp import gp_Ax2, gp_Circ, gp_Dir, gp_Elips, gp_Pnt
from OCC.Core.TColgp import TColgp_Array1OfPnt
from OCC.Core.TopAbs import TopAbs_VERTEX
from OCC.Core.TopExp import TopExp_Explorer
from OCC.Core.TopoDS import TopoDS_Compound, TopoDS_Edge, TopoDS_Shape, TopoDS_Wire, topods

from app.document.create_plane import resolve_sketch_basis
from app.document.extrude import (
    EXTRUDABLE_STATUSES,
    EdgeProvenanceEntry,
    _edge_provenance_from_builder,
    _ellipse_axis,
    _explode_solids,
    _profile_boundary_shapes,
    _record_feature_edge_provenance,
    arc_axis,
    basis_normal,
    basis_point_to_world,
    compute_part_bodies,
    resolve_subshape_from_bodies,
    select_profiles,
    wire_for_profile,
)
from app.document.graph import sketch_feature_id_for_sketch
from app.document.models import Part, SketchFeature, SketchOrEdgeRef, SubShapeRef, SweepFeature
from app.document.plane_geometry import is_mirrored_basis
from app.sketch.models import Arc, Circle, Ellipse, Line, SketchEntityRef, SketchEntityType, Spline
from app.sketch.profile import ProfileStatus, detect_profile
from app.sketch.store import get_sketch_or_404, resolve_sketch_entity

logger = logging.getLogger(__name__)

# World-space distance (same units the rest of this project's geometry
# uses) within which two path segment endpoints are considered the same
# point - needed because, unlike a single-Sketch Line-chain Profile (which
# can test connectivity by shared Point id), path_refs entries may each
# name a Line in a *different* Sketch, so there is no shared Point id to
# compare at all: connectivity can only be judged by where each endpoint
# actually lands in 3D world space once embedded through its own Sketch's
# basis. Deliberately coarser than a bare floating-point epsilon (e.g.
# 1e-9) since it stands in for "the user intended these two Sketch Points
# to land on each other", not for exact arithmetic equality.
_PATH_POINT_TOLERANCE = 1e-6


def _path_ref_error_detail(ref: SketchEntityRef | SketchOrEdgeRef) -> dict:
    """The `sketch_id`/`entity_type`/`entity_id` (a Sketch entity) or
    `body_id`/`shape_type`/`index` (a Body edge) fields `_invalid_path_ref`/
    `_disconnected_path` embed to identify which `path_refs`/`guide_curve_
    refs` entry failed. Accepts a bare `SketchEntityRef` directly (every
    call site inside `_resolve_path_segment`, which only ever handles the
    Sketch-entity branches and never itself sees the outer wrapper) as well
    as a `SketchOrEdgeRef` (every call site in `resolve_path_wire` itself,
    which sees whichever of the two callers actually resolved) - whichever
    of `ref.sketch_entity_ref`/`ref.edge_ref` is set on the latter (the
    router's own payload-shape validation guarantees exactly one is, by the
    time either error can fire)."""
    if isinstance(ref, SketchEntityRef):
        return {"sketch_id": ref.sketch_id, "entity_type": ref.entity_type.value, "entity_id": ref.entity_id}
    if ref.sketch_entity_ref is not None:
        return {
            "sketch_id": ref.sketch_entity_ref.sketch_id,
            "entity_type": ref.sketch_entity_ref.entity_type.value,
            "entity_id": ref.sketch_entity_ref.entity_id,
        }
    assert ref.edge_ref is not None
    return {
        "body_id": ref.edge_ref.body_id,
        "shape_type": ref.edge_ref.shape_type.value,
        "index": ref.edge_ref.index,
    }


def _invalid_path_ref(ref: SketchEntityRef | SketchOrEdgeRef) -> HTTPException:
    """The structured `invalid_path_ref` error for a `path_refs` entry that
    cannot be used as a Sweep path segment - covers every way this can
    fail: the entity doesn't exist, exists but isn't a Line/Arc/Circle/
    Ellipse/Spline, is a degenerate (zero-length/zero-span) entity, or is a
    Circle/Ellipse (always closed, see `_PathSegment.closed`'s own doc
    comment) appearing anywhere other than alone as the entire path. Mirrors
    `app.document.revolve._invalid_axis_ref`'s envelope shape exactly (422,
    a structured `detail` dict).

    On-device feedback ("unable to select an arc as the sweep path... can
    select the arc but it doesn't allow confirming"; "ellipses and splines
    should also be valid targets for sweep paths"): Line was the only
    path-capable entity type until this fix - see `_resolve_path_segment`'s
    own doc comment for how the others are now resolved.

    Bug fix (root-caused against a real OCCT kernel: a hollow Profile swept
    along a closed path built from 2+ Arcs fragmented into multiple
    disconnected Bodies): Circle is now also a valid, standalone closed
    path entity - a single genuinely seamless edge, unlike a full circle
    built from 2+ Arc segments glued at a real (if tangent-continuous)
    vertex, which is what triggered that fragmentation - see the Circle
    branch of `_resolve_path_segment`'s own doc comment for the full
    root-cause writeup."""
    return HTTPException(
        status_code=422,
        detail={"type": "invalid_path_ref", **_path_ref_error_detail(ref)},
    )


def _disconnected_path(ref: SketchOrEdgeRef, index: int) -> HTTPException:
    """The structured `disconnected_path` error for a `path_refs` entry
    (at `index`, the entry's own position in the list) whose Line does not
    share a coincident endpoint (within `_PATH_POINT_TOLERANCE`) with the
    chain traced so far - the only way a cross-Sketch, position-based
    connectivity check can fail once every individual entry has already
    resolved to a real, non-degenerate Line (see `_invalid_path_ref` for
    that earlier failure mode)."""
    return HTTPException(
        status_code=422,
        detail={"type": "disconnected_path", **_path_ref_error_detail(ref), "index": index},
    )


def _sweep_failed() -> HTTPException:
    """`BRepOffsetAPI_MakePipeShell.IsDone()`/`.MakeSolid()` returned false -
    a geometric failure (the path's curvature/corners make the profile
    self-intersect as it sweeps, etc.), not a malformed reference. 422,
    matching `app.document.revolve._revolve_failed`'s identical "structured
    error, not an uncaught OCCT exception surfacing as a 500" convention."""
    return HTTPException(status_code=422, detail={"type": "sweep_failed"})


def _sweep_wire(
    path_wire: TopoDS_Wire,
    wire: TopoDS_Wire,
    fixed_binormal: gp_Dir | None = None,
) -> tuple[TopoDS_Shape, BRepOffsetAPI_MakePipeShell]:
    """Sweeps one closed `wire` (a Profile's outer boundary, or one of its
    holes - see `resolve_sweep_from_bodies`, which sweeps each of those
    independently and boolean-cuts the results together rather than
    handing `BRepOffsetAPI_MakePipeShell` a compound outer+hole section in
    one call) along `path_wire`, producing a solid. Also returns the live
    `pipe_maker` builder itself (Workstream 12, docs/ai-modelling/12-
    provenance-edge-selectors.md) - its own `.Generated()`/`.Modified()`
    only works when queried while it's still the exact object that just
    ran the sweep, so a caller needing edge-index provenance can't get it
    back later from `wire`/`shape` alone.

    `BRepOffsetAPI_MakePipeShell.Add` only ever accepts a single Wire (or
    Edge/Vertex) as one swept "section", not a Face - see this function's
    caller for why a hole is instead handled as a second, independent
    sweep of its own, boolean-cut out of the outer one afterward, rather
    than attempting a not-yet-verified multi-wire single-section call
    here.

    `SetTransitionMode(BRepBuilderAPI_RightCorner)` was chosen (see
    `resolve_sweep_from_bodies`'s own doc comment) back when every path
    segment was a straight Line - now that `path_wire` can also contain
    Arc/Ellipse/Spline segments (`resolve_path_wire`), a genuinely sharp
    Line-to-curve corner still gets the same flat-cut treatment, which is
    likely still correct (there's still a real corner to cut), but this
    hasn't been re-verified on-device against a curved path specifically -
    flagged as a follow-up if a curved-path Sweep looks wrong at a Line/
    curve junction, not changed speculatively here.

    On-device feedback ("body created by rectangle swept around an
    ellipse... an internal/duplicate face only visible with transparency
    on"): `MakePipeShell`'s own default trihedron mode (Frenet, or this
    OCCT version's "corrected Frenet" - never explicitly set before this)
    continuously reorients `wire` to stay normal to `path_wire`'s local
    tangent. That tracks a Circle's constant curvature back to its own
    starting orientation after one full loop with nothing left over, but
    an Ellipse's curvature varies around the loop - for a non-radially-
    symmetric profile (a rectangle, not a circle) the frame does not
    generally return to its exact starting orientation at the seam,
    leaving a twist `MakePipeShell` can silently resolve into a spurious
    internal, reversed-winding face rather than failing `IsDone()`
    outright. Since every Ellipse (and Circle) path here is planar by
    construction (`_resolve_path_segment`'s own Circle/Ellipse branches),
    the profile's own orientation never actually needs to *vary* around
    the loop at all - `fixed_binormal` (the path plane's own normal,
    `_PathSegment.plane_normal`, threaded through by `resolve_path_wire`/
    `resolve_sweep_from_bodies` for exactly this single-closed-segment
    case) switches to OCCT's "fixed binormal direction" trihedron mode
    instead: the profile keeps one constant orientation the entire way
    around, so there is no curvature-dependent twist to fail to close in
    the first place. Applied to the Circle case too (not just Ellipse) so
    both share one code path rather than silently diverging - confirmed
    by `BRepCheck_Analyzer` below not to regress the already-working
    Circle sweep."""
    pipe_maker = BRepOffsetAPI_MakePipeShell(path_wire)
    pipe_maker.SetTransitionMode(BRepBuilderAPI_RightCorner)
    if fixed_binormal is not None:
        pipe_maker.SetMode(fixed_binormal)
    pipe_maker.Add(wire)
    pipe_maker.Build()
    if not pipe_maker.IsDone() or not pipe_maker.MakeSolid():
        raise _sweep_failed()
    shape = pipe_maker.Shape()
    # Defense-in-depth (same convention as app.document.extrude/move_face/
    # solid_from_surfaces), scoped to the new `fixed_binormal` path only -
    # `IsDone()`/`MakeSolid()` alone do not rule out a self-intersecting/
    # duplicate-face result (see this function's own doc comment above),
    # so this additionally requires `BRepCheck_Analyzer` to pass before
    # handing the shape back, turning a bad sweep into the same
    # `_sweep_failed()` 422 rather than a silently wrong solid. Not
    # applied to the general Line/Arc-chain path below (`fixed_binormal is
    # None`): `app.document.bevel`'s own doc comment on
    # `BRepCheck_Analyzer` warns it has real false positives
    # (`BRepCheck_UnorientableShape`) on otherwise-legitimate shapes -
    # a risk not worth taking on the already-working, unrelated path this
    # change isn't trying to fix.
    if fixed_binormal is not None and not BRepCheck_Analyzer(shape).IsValid():
        raise _sweep_failed()
    return shape, pipe_maker


@dataclass
class _PathSegment:
    """One `path_refs` entry's resolved, world-space edge-building
    ingredients - `_resolve_path_segment`'s return type.

    `start`/`end` are the segment's own connection endpoints (for chain-
    order/connectivity purposes only, mirroring the pre-generalization
    `(start, end)` pair this replaces) - `None` for a `closed` segment,
    which has no endpoints to connect at. `edges` are the already-built
    OCCT edge(s) in this segment's own natural order; multiple only for a
    Spline (one Bezier edge per internal through-point-to-through-point
    hop).

    `plane_normal` is set only for a `closed` segment (Circle/Ellipse) -
    the sketch plane's own normal that segment's edge was built against
    (`basis_normal(basis)`/`_ellipse_axis(...).Direction()` respectively).
    `resolve_path_wire` threads this through to `_sweep_wire`'s own
    `fixed_binormal` - see that function's own doc comment for why a
    varying-curvature closed path (an Ellipse, unlike a Circle) needs it."""

    start: gp_Pnt | None
    end: gp_Pnt | None
    edges: list[TopoDS_Edge]
    closed: bool = False
    plane_normal: gp_Dir | None = None


def _reversed_edge(edge: TopoDS_Edge) -> TopoDS_Edge:
    """The same physical edge, walked in the opposite direction - used by
    `resolve_path_wire` for a segment traversed back-to-front.

    On-device feedback ("sweep around an arc guide curve went the wrong
    direction"): `TopoDS_Shape.Reversed()` (a bare `TopAbs_Orientation`
    flag flip, no change to the underlying `Geom_Curve` at all) is NOT
    enough here - confirmed by direct on-device inspection this session:
    `BRepBuilderAPI_MakeWire.Add` already re-derives each edge's own
    Orientation flag from real vertex-position connectivity regardless of
    whatever Orientation the caller handed it, so a bare `.Reversed()`
    before `.Add()` is silently discarded, never reaching `_sweep_wire`'s
    `BRepOffsetAPI_MakePipeShell` as any real difference at all. This
    instead rebuilds the edge from its own underlying curve's `.Reversed()`
    (a genuinely different `Geom_Curve` object, re-parametrized start-to-
    end the other way around - the same physical arc/line/Bezier span,
    same shape, just walked backward) via `BRep_Tool.Curve`, so the
    resulting edge's own natural parametrization - what `MakePipeShell`
    actually reorients the profile against - is truly reversed, not just
    relabeled. `ReversedParameter` maps the original curve's own First/
    Last parameters onto the reversed curve's matching ones (needed since
    a reversed curve's own parametrization is `t' = -t` for most curve
    types, so the trimmed range's bounds swap and negate together)."""
    curve, first, last = BRep_Tool.Curve(edge)
    reversed_curve = curve.Reversed()
    new_first = curve.ReversedParameter(last)
    new_last = curve.ReversedParameter(first)
    return BRepBuilderAPI_MakeEdge(reversed_curve, new_first, new_last).Edge()


def _resolve_path_segment(
    part: Part,
    ref: SketchEntityRef,
    bodies_so_far: dict[str, TopoDS_Shape],
    excluded_feature_ids: frozenset[str],
) -> _PathSegment:
    """Resolves one `path_refs` entry into a [_PathSegment] - mirrors
    `app.document.revolve._resolve_axis`'s own resolution shape (each
    entry resolved entirely independently: its own owning SketchFeature,
    its own basis) generalized from the original Line-only version to
    Line/Arc/Ellipse/Spline, reusing exactly the same OCCT edge-
    construction math `app.document.extrude.wire_for_profile` already
    proved correct for these same four entity types within an ordinary
    (single-Sketch) Profile - `arc_axis`'s mirror-aware P1/P2 swap and
    `Spline.segments()`'s own pole ordering in particular, both previously
    fixed against real on-device bugs (see their own doc comments) and
    deliberately not re-derived here.

    A path segment's orientation relative to its neighbours is not yet
    known here (an Arc/Spline's own stored start/end may need to be
    traversed backwards once the full chain order is resolved) - each edge
    here is still built once, in its own natural stored orientation;
    `resolve_path_wire` is the one that reverses it (`_reversed_edge`) once
    the chain order is known, exactly mirroring `wire_for_profile`'s own
    Spline branch (see that function's own doc comment for why a Line-
    chain's shared-vertex fuse alone is NOT enough here - unlike
    `wire_for_profile`, which only needs `BRepBuilderAPI_MakeWire` for
    visual connectivity before a Face/Prism, this wire feeds
    `BRepOffsetAPI_MakePipeShell`, which sweeps along each edge's own
    parametric direction, not just its topological connectivity - see
    `_reversed_edge`'s own doc comment for why a bare `.Reversed()` isn't
    enough for that).

    Fails closed with `invalid_path_ref` (never a generic `missing_
    reference` or an uncaught OCCT exception) for every way `ref` can be
    unusable as a path segment: wrong `entity_type`, an unresolvable
    entity lookup, no SketchFeature owning `ref.sketch_id` in this Part,
    or degenerate (zero-length/zero-span) geometry."""
    if ref.entity_type not in (
        SketchEntityType.LINE,
        SketchEntityType.ARC,
        SketchEntityType.CIRCLE,
        SketchEntityType.ELLIPSE,
        SketchEntityType.SPLINE,
    ):
        raise _invalid_path_ref(ref)
    try:
        entity = resolve_sketch_entity(ref)
    except HTTPException:
        raise _invalid_path_ref(ref) from None

    path_sketch_feature_id = sketch_feature_id_for_sketch(part, ref.sketch_id)
    path_sketch_feature = part.get_feature(path_sketch_feature_id) if path_sketch_feature_id else None
    if not isinstance(path_sketch_feature, SketchFeature):
        raise _invalid_path_ref(ref)

    sketch = get_sketch_or_404(ref.sketch_id)
    basis = resolve_sketch_basis(part, path_sketch_feature, bodies_so_far, excluded_feature_ids)

    if ref.entity_type == SketchEntityType.LINE and isinstance(entity, Line):
        start = sketch.points[entity.start_point_id]
        end = sketch.points[entity.end_point_id]
        start_world = basis_point_to_world(basis, start.x, start.y)
        end_world = basis_point_to_world(basis, end.x, end.y)
        if start_world.Distance(end_world) < _PATH_POINT_TOLERANCE:
            raise _invalid_path_ref(ref)
        edge = BRepBuilderAPI_MakeEdge(start_world, end_world).Edge()
        return _PathSegment(start=start_world, end=end_world, edges=[edge])

    if ref.entity_type == SketchEntityType.ARC and isinstance(entity, Arc):
        center = sketch.points[entity.center_point_id]
        radius = entity.radius(sketch.points)
        axis = arc_axis(basis, center.x, center.y)
        start = sketch.points[entity.start_point_id]
        end = sketch.points[entity.end_point_id]
        start_world = basis_point_to_world(basis, start.x, start.y)
        end_world = basis_point_to_world(basis, end.x, end.y)
        if start_world.Distance(end_world) < _PATH_POINT_TOLERANCE:
            raise _invalid_path_ref(ref)
        # Mirror-aware P1/P2 swap, identical to wire_for_profile's own Arc
        # branch - picks the correct one of the two possible arcs between
        # start/end on a mirrored Sketch. Connectivity (below) still keys
        # off the plain, unswapped start_world/end_world - the swap only
        # affects which physical arc gets built, not which Points it
        # connects.
        p1, p2 = (end_world, start_world) if is_mirrored_basis(basis) else (start_world, end_world)
        edge = BRepBuilderAPI_MakeEdge(gp_Circ(axis, radius), p1, p2).Edge()
        return _PathSegment(start=start_world, end=end_world, edges=[edge])

    if ref.entity_type == SketchEntityType.SPLINE and isinstance(entity, Spline):
        edges = []
        for p0_id, p1_id, p2_id, p3_id in entity.segments():
            poles = TColgp_Array1OfPnt(1, 4)
            for index, point_id in enumerate((p0_id, p1_id, p2_id, p3_id), start=1):
                point = sketch.points[point_id]
                poles.SetValue(index, basis_point_to_world(basis, point.x, point.y))
            edges.append(BRepBuilderAPI_MakeEdge(Geom_BezierCurve(poles)).Edge())
        start = sketch.points[entity.through_point_ids[0]]
        end = sketch.points[entity.through_point_ids[-1]]
        start_world = basis_point_to_world(basis, start.x, start.y)
        end_world = basis_point_to_world(basis, end.x, end.y)
        if start_world.Distance(end_world) < _PATH_POINT_TOLERANCE:
            raise _invalid_path_ref(ref)
        return _PathSegment(start=start_world, end=end_world, edges=edges)

    if ref.entity_type == SketchEntityType.CIRCLE and isinstance(entity, Circle):
        # Bug fix (root-caused directly against a real OCCT kernel: sweeping
        # a hollow/annular Profile along a closed path built from 2+ Arc
        # segments produced 3 disconnected Bodies from one Sweep instead of
        # one clean torus - the *outer* and *inner* wires, per this
        # function's own hollow-Profile handling below, are each swept via
        # an independent `BRepOffsetAPI_MakePipeShell`, and a path wire
        # with a real vertex at the arc-to-arc seam - even one that's
        # perfectly tangent-continuous there, so not a genuine corner at
        # all - was found to make `.MakeSolid()` cap the "opened" pipe with
        # two flat planar end faces instead of a seamless seam-free closure;
        # cutting two independently, differently-capped tubes together
        # (`BRepAlgoAPI_Cut` below) then fragments instead of cleanly
        # hollowing out. Confirmed empirically: the *identical* profile/path
        # radii built as one genuinely seamless single-edge `gp_Circ` wire -
        # exactly what this branch now builds - produces a real 1-face
        # torus and a clean single-solid Cut with the exact analytically-
        # expected volume, every time.) Always closed/standalone, same
        # shape as the Ellipse branch below - a full circle has no
        # endpoints to connect to another segment, so this only ever
        # appears alone as the entire path (enforced generically by
        # `resolve_path_wire`'s own `_PathSegment.closed` handling, not
        # re-checked per entity type here).
        center = sketch.points[entity.center_point_id]
        radius = entity.radius(sketch.points)
        normal = basis_normal(basis)
        axis = gp_Ax2(basis_point_to_world(basis, center.x, center.y), normal)
        edge = BRepBuilderAPI_MakeEdge(gp_Circ(axis, radius)).Edge()
        return _PathSegment(start=None, end=None, edges=[edge], closed=True, plane_normal=normal)

    if ref.entity_type == SketchEntityType.ELLIPSE and isinstance(entity, Ellipse):
        # Always closed/standalone (see the Ellipse class's own doc
        # comment) - no connection endpoints, handled by
        # resolve_path_wire as a lone-segment special case.
        center = sketch.points[entity.center_point_id]
        major_radius = entity.major_radius(sketch.points)
        minor_radius = entity.minor_radius(sketch.points)
        rotation = entity.rotation(sketch.points)
        axis = _ellipse_axis(basis, center.x, center.y, rotation)
        edge = BRepBuilderAPI_MakeEdge(gp_Elips(axis, major_radius, minor_radius)).Edge()
        return _PathSegment(start=None, end=None, edges=[edge], closed=True, plane_normal=axis.Direction())

    raise _invalid_path_ref(ref)


def _resolve_edge_path_segment(bodies_so_far: dict[str, TopoDS_Shape], edge_ref: SubShapeRef) -> _PathSegment:
    """On-device feedback ("surface tools should support edges, curves...
    e.g. sweep along an edge"): the Body-edge counterpart to
    `_resolve_path_segment`'s Sketch-entity branches, for a `path_refs`/
    `guide_curve_refs` entry whose `SketchOrEdgeRef.edge_ref` is set
    instead of `sketch_entity_ref`. Reuses `app.document.extrude.resolve_
    subshape_from_bodies` verbatim - the same resolver `FilletFeature.
    edge_refs`/`PointRef.vertex_ref` already use - so an unresolvable/stale
    reference fails the same way theirs does (`missing_reference`), not a
    separate error type.

    A closed/periodic edge with no two genuinely distinct vertices (e.g. a
    full-circle silhouette edge on a cylindrical face) resolves as its own
    standalone closed segment, mirroring `_resolve_path_segment`'s Circle/
    Ellipse branches - but with `plane_normal=None` (unlike those, an
    arbitrary Body edge's own plane isn't already known here the way a
    Sketch entity's own basis is) - `_sweep_wire`'s fixed-binormal fix
    (see its own doc comment) is simply not applied for this case, falling
    back to the same default trihedron every other non-fixed-binormal path
    already uses; not yet extended to cover it."""
    edge = topods.Edge(resolve_subshape_from_bodies(bodies_so_far, edge_ref))
    explorer = TopExp_Explorer(edge, TopAbs_VERTEX)
    vertices = []
    while explorer.More():
        vertices.append(topods.Vertex(explorer.Current()))
        explorer.Next()
    if len(vertices) >= 2:
        start = BRep_Tool.Pnt(vertices[0])
        end = BRep_Tool.Pnt(vertices[-1])
        if start.Distance(end) >= _PATH_POINT_TOLERANCE:
            return _PathSegment(start=start, end=end, edges=[edge], closed=False)
    return _PathSegment(start=None, end=None, edges=[edge], closed=True)


def resolve_path_wire(
    part: Part,
    path_refs: list[SketchOrEdgeRef],
    bodies_so_far: dict[str, TopoDS_Shape],
    excluded_feature_ids: frozenset[str],
) -> tuple[TopoDS_Wire, gp_Dir | None]:
    """Resolves `path_refs` (an ordered, possibly cross-Sketch, possibly
    mixed-type list of Line/Arc/Circle/Ellipse/Spline references - see
    `SweepFeature`'s own docstring) into a single OCCT wire, via
    `_resolve_path_segment` per entry.

    A lone Circle or Ellipse (the only closed/standalone path-capable
    entities - see `_PathSegment.closed`'s own doc comment) is handled
    first, as its own complete closed wire; either mixed with anything
    else, or more than one, is rejected via `invalid_path_ref` (a closed
    curve has nothing to connect to). Prefer a Circle over 2+ chained Arcs
    for a full-circle path where possible - see the Circle branch of
    `_resolve_path_segment`'s own doc comment for why a multi-Arc circle's
    real (if tangent-continuous) seam vertex is a genuine correctness risk
    for a hollow Profile, not just a style preference.

    Otherwise, chain order/connectivity is validated exactly as before
    this was generalized beyond Line: `path_refs[0]` seeds the chain with
    both its own endpoints, each subsequent entry must have exactly one
    endpoint coincident with *either* end of the chain built so far - the
    running chain's front (`points[0]`) or its back (`points[-1]`), not
    just the back, since the user may extend the pick in either direction
    from the very first segment - raising `disconnected_path` (never
    silently guessing a connection) if neither end matches.

    The wire itself is then built from every segment's own already-resolved
    `edges`, added to `BRepBuilderAPI_MakeWire` in `path_refs` order - since
    that order has just been positionally verified as a genuine connected
    chain. `MakeWire.Add` fuses shared vertices regardless of an individual
    edge's own parametric direction, so no explicit `.Close()` call or
    point-list reversal is needed the way the old, Line-only
    `BRepBuilderAPI_MakePolygon`-based version needed - a chain whose first
    and last points coincide fuses into a genuinely closed wire on its own,
    structurally, the same way `wire_for_profile`'s own mixed-chain branch
    already relies on `MakeWire` to do.

    On-device feedback ("sweep around an arc guide curve went the wrong
    direction ... not always the case"): that connectivity fuse is NOT
    enough on its own here, unlike `wire_for_profile` - this wire feeds
    `BRepOffsetAPI_MakePipeShell` (`_sweep_wire`), which sweeps along each
    edge's own parametric direction (used to reorient the profile as it
    goes), not just the wire's topological connectivity. An Arc/Spline
    segment's edge(s) are always built in `_resolve_path_segment`'s own
    fixed sense (`entity.start_point_id` -> `entity.end_point_id`) -
    whichever the user happened to click first/last while drawing it,
    unrelated to which way this chain is actually being walked - so each
    segment's actual walk direction is tracked alongside `points` above
    (`reversed_flags`: True whenever a segment's own `end` is what connects
    to the chain's existing endpoint, i.e. it's being walked back-to-front)
    and its edge(s) are rebuilt reversed (`_reversed_edge` - a real
    `Geom_Curve.Reversed()`, not a bare `TopoDS_Shape.Reversed()` flag flip;
    see that function's own doc comment for why the flag alone is silently
    discarded here) before being added, exactly mirroring `wire_for_profile`'s
    own Spline branch (`segments = reversed(...)` when `profile.point_ids[i]`
    is the entity's last through-point) generalized to every segment type
    via `_PathSegment.edges` rather than re-derived per entity type.

    Returns `(wire, fixed_binormal)`: `fixed_binormal` is the lone closed
    segment's own `plane_normal` (see `_PathSegment`'s own doc comment) for
    the single-Circle/single-Ellipse case, `None` otherwise - `_sweep_wire`'s
    own parameter of the same name, threaded through by
    `resolve_sweep_from_bodies`.

    Each entry resolves via `_resolve_path_segment` (a Sketch entity,
    `ref.sketch_entity_ref`) or `_resolve_edge_path_segment` (a Body edge,
    `ref.edge_ref`) - see `SketchOrEdgeRef`'s own doc comment; the router's
    payload-shape validation already guarantees exactly one is set per
    entry, so this dispatches on whichever is, rather than re-checking."""
    segments = [
        _resolve_path_segment(part, ref.sketch_entity_ref, bodies_so_far, excluded_feature_ids)
        if ref.sketch_entity_ref is not None
        else _resolve_edge_path_segment(bodies_so_far, ref.edge_ref)
        for ref in path_refs
    ]

    if len(segments) == 1 and segments[0].closed:
        wire_maker = BRepBuilderAPI_MakeWire()
        for edge in segments[0].edges:
            wire_maker.Add(edge)
        return wire_maker.Wire(), segments[0].plane_normal

    for ref, segment in zip(path_refs, segments):
        if segment.closed:
            raise _invalid_path_ref(ref)

    points: list[gp_Pnt] = []
    reversed_flags: list[bool] = []
    for index, (ref, segment) in enumerate(zip(path_refs, segments)):
        start_world, end_world = segment.start, segment.end
        if not points:
            points.append(start_world)
            points.append(end_world)
            reversed_flags.append(False)
            continue
        front, back = points[0], points[-1]
        if back.Distance(start_world) < _PATH_POINT_TOLERANCE:
            points.append(end_world)
            reversed_flags.append(False)
        elif back.Distance(end_world) < _PATH_POINT_TOLERANCE:
            points.append(start_world)
            reversed_flags.append(True)
        elif front.Distance(start_world) < _PATH_POINT_TOLERANCE:
            points.insert(0, end_world)
            reversed_flags.append(True)
        elif front.Distance(end_world) < _PATH_POINT_TOLERANCE:
            points.insert(0, start_world)
            reversed_flags.append(False)
        else:
            raise _disconnected_path(ref, index)

    wire_maker = BRepBuilderAPI_MakeWire()
    for segment, is_reversed in zip(segments, reversed_flags):
        edges = [_reversed_edge(edge) for edge in reversed(segment.edges)] if is_reversed else segment.edges
        for edge in edges:
            wire_maker.Add(edge)
    return wire_maker.Wire(), None


def resolve_sweep_from_bodies(
    feature: SweepFeature,
    sketch_feature: SketchFeature,
    part: Part,
    bodies_so_far: dict[str, TopoDS_Shape],
    excluded_feature_ids: frozenset[str],
) -> TopoDS_Shape | None:
    """The raw swept solid for `feature`, or `None` if its backing Sketch
    no longer has a sweepable profile - mirrors `app.document.revolve.
    resolve_revolve_from_bodies`'s own contract exactly (callers skip
    rather than error, per the same "a stale/edited-away profile shouldn't
    fail the whole mesh request" reasoning).

    Boss/Cut dispatch (fusing/cutting the returned solid into
    `bodies_so_far`) is the caller's job - see `app.document.extrude.
    _apply_boss_or_cut`, shared with ExtrudeFeature/RevolveFeature - not
    this function's, since that logic is identical regardless of which
    Feature type produced the new solid.

    A MultiProfile Sketch (disjoint outer loops) produces one swept solid
    per sub-profile, combined into a `TopoDS_Compound` - transparent to
    every caller, exactly like `_solid_for_extrude_feature`'s/
    `resolve_revolve_from_bodies`'s own MultiProfile handling.
    `feature.profile_refs`, if non-empty, narrows this down to just the
    named outer profile(s) - see `app.document.extrude.select_profiles`,
    reused directly rather than re-derived.

    On-device feedback: uses `BRepOffsetAPI_MakePipeShell`, not the
    simpler `BRepOffsetAPI_MakePipe` this originally shipped with -
    `MakePipe`'s own sweep does not keep the profile's cross-section
    reoriented normal to the spine's local tangent as the spine's direction
    changes (it stays visibly closer to its own original fixed orientation
    instead, most obvious with a non-radially-symmetric profile, e.g. a
    flat rectangle pinching to a wedge at a sharp path corner) -
    `MakePipeShell` is OCCT's more general "generalized sweep" API, built
    specifically to reorient the profile as it goes (its default trihedron
    mode already does this - no explicit `SetMode` override needed) and to
    handle a polyline spine's sharp (non-tangent-continuous) corners
    explicitly via `SetTransitionMode`, rather than leaving that undefined
    the way `MakePipe` does. `BRepBuilderAPI_RightCorner` is used here (cuts
    a sharp corner with a flat planar face rather than trying to round or
    stretch it) since every path segment is a straight Line - the standard
    choice for a polyline spine, avoiding the self-intersecting/pinched
    corner artifact `MakePipe` itself was producing.

    On-device feedback (second round): `MakePipeShell.Add` rejects a
    `TopoDS_Face` outright (`BRepFill_Section: bad shape type of section`,
    an uncaught `RuntimeError` from OCCT, not a graceful `HTTPException` -
    a real crash the first round of this fix shipped with) - it only
    accepts a Wire (or Edge/Vertex) as one swept "section", so `_sweep_wire`
    passes `wire_for_profile`'s bare wire instead of `face_for_profile`'s
    face.

    On-device feedback (third round): a Profile with holes (e.g. a pipe's
    annular wall - a hole-carrying Profile is a completely ordinary,
    common Sweep use case, not an edge case) is genuinely supported, just
    not by handing `MakePipeShell` a single compound outer+hole section (a
    real OCCT capability, but not one this could be verified against
    without a real kernel, so not risked here) - instead, the outer wire
    and each hole's own wire are swept *independently* via `_sweep_wire`
    (both are plain single-wire sweeps, the case already proven working
    above) and the hole solid(s) are boolean-cut out of the outer one
    (`BRepAlgoAPI_Cut`, the exact same operation `app.document.extrude.
    _apply_boss_or_cut` already relies on for every Cut-mode Boss/Cut in
    this codebase) - a hollow pipe is exactly "outer tube minus inner
    tube," so this reuses two already-independently-correct building
    blocks instead of a single untested one."""
    sketch = get_sketch_or_404(sketch_feature.sketch_id)
    result = detect_profile(sketch)
    # Sketcher-roadmap Phase 7 (2D Pattern/Mirror): see extrude.py's
    # identical call site for why this re-expansion is needed here too (a
    # no-instance Sketch is a no-op, returning the same object).
    sketch = sketch.expand_pattern_and_mirror_instances()
    if result.status not in EXTRUDABLE_STATUSES:
        logger.warning(
            "Skipping SweepFeature %s: sketch %s has no closed profile (status=%s)",
            feature.id,
            sketch.id,
            result.status.value,
        )
        return None

    basis = resolve_sketch_basis(part, sketch_feature, bodies_so_far, excluded_feature_ids)
    path_wire, fixed_binormal = resolve_path_wire(part, feature.path_refs, bodies_so_far, excluded_feature_ids)

    if result.status == ProfileStatus.CLOSED_LOOP:
        assert result.profile is not None
        candidates = [result.profile]
    else:
        candidates = result.loops
    profiles = select_profiles(candidates, feature.profile_refs)

    solids = []
    provenance_by_profile: list[dict[str, dict[str, EdgeProvenanceEntry]] | None] = []
    for profile in profiles:
        outer_wire = wire_for_profile(sketch, profile, basis)
        solid, pipe_maker = _sweep_wire(path_wire, outer_wire, fixed_binormal)
        point_to_vertex, line_to_edge = _profile_boundary_shapes(sketch, profile, basis, outer_wire)
        provenance = _edge_provenance_from_builder(pipe_maker, point_to_vertex, line_to_edge, solid)
        for inner_loop in profile.inner_loops:
            inner_wire = wire_for_profile(sketch, inner_loop, basis)
            inner_solid, _inner_pipe_maker = _sweep_wire(path_wire, inner_wire, fixed_binormal)
            # Bug fix (root-caused against a real OCCT kernel while
            # investigating a body silently losing material after Merge):
            # neither `IsDone()` nor a raw OCCT `RuntimeError` is
            # sufficient on its own here - confirmed empirically that this
            # Cut can report `IsDone() == True` while still producing a
            # shape with zero `TopAbs_SOLID`s (the outer solid's own hole
            # ends up fully consuming it), which is never a legitimate
            # outcome for "outer minus a strictly-smaller hole" the way a
            # general-purpose Cut's own "the tool can legitimately consume
            # the whole target" case is (see `_register_solids`'s own doc
            # comment) - so this checks all three.
            try:
                cut_op = BRepAlgoAPI_Cut(solid, inner_solid)
            except RuntimeError as exc:
                raise _sweep_failed() from exc
            if not cut_op.IsDone():
                raise _sweep_failed()
            solid = cut_op.Shape()
            if not _explode_solids(solid):
                raise _sweep_failed()
            # Workstream 12: the boolean Cut above rebuilds topology from
            # scratch - the provenance indices computed against the
            # pre-Cut outer solid no longer correspond to real edges in
            # this rebuilt one, so they must not be recorded.
            provenance = None
        solids.append(solid)
        provenance_by_profile.append(provenance)

    if len(solids) == 1:
        # Workstream 12 (docs/ai-modelling/12-provenance-edge-selectors.md):
        # same "only the common single-profile, no-target case" reasoning
        # as `app.document.extrude._solid_for_extrude_feature`'s identical
        # guard - see that function's own comment.
        provenance = provenance_by_profile[0]
        if not feature.target_body_ids and provenance is not None:
            _record_feature_edge_provenance(part, feature.id, provenance, excluded_feature_ids)
        return solids[0]

    builder = BRep_Builder()
    compound = TopoDS_Compound()
    builder.MakeCompound(compound)
    for solid in solids:
        builder.Add(compound, solid)
    return compound


def resolve_sweep(
    part: Part, feature: SweepFeature, excluded_feature_ids: frozenset[str] = frozenset()
) -> TopoDS_Shape | None:
    """Fresh entry point for the router's create/update validation -
    computes `bodies` *as if `feature` weren't in `part.features` yet*
    (excludes its own id in addition to whatever the caller already
    excludes), mirroring `app.document.revolve.resolve_revolve`'s own
    self-exclusion convention exactly (see that function's own doc comment
    for the full reasoning)."""
    sketch_feature = part.get_feature(feature.sketch_feature_id)
    if not isinstance(sketch_feature, SketchFeature):
        raise HTTPException(
            status_code=400,
            detail="sketch_feature_id does not refer to a SketchFeature in this Part",
        )
    all_excluded = excluded_feature_ids | {feature.id}
    bodies = compute_part_bodies(part, all_excluded)
    return resolve_sweep_from_bodies(feature, sketch_feature, part, bodies, all_excluded)
