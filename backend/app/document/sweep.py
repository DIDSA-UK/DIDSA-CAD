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

from fastapi import HTTPException
from OCC.Core.BRep import BRep_Builder
from OCC.Core.BRepAlgoAPI import BRepAlgoAPI_Cut
from OCC.Core.BRepBuilderAPI import BRepBuilderAPI_MakePolygon, BRepBuilderAPI_RightCorner
from OCC.Core.BRepOffsetAPI import BRepOffsetAPI_MakePipeShell
from OCC.Core.gp import gp_Pnt
from OCC.Core.TopoDS import TopoDS_Compound, TopoDS_Shape, TopoDS_Wire

from app.document.create_plane import resolve_sketch_basis
from app.document.extrude import (
    EXTRUDABLE_STATUSES,
    basis_point_to_world,
    compute_part_bodies,
    select_profiles,
    wire_for_profile,
)
from app.document.graph import sketch_feature_id_for_sketch
from app.document.models import Part, SketchFeature, SweepFeature
from app.sketch.models import Line, SketchEntityRef, SketchEntityType
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


def _invalid_path_ref(ref: SketchEntityRef) -> HTTPException:
    """The structured `invalid_path_ref` error for a `path_refs` entry that
    cannot be used as a Sweep path segment - covers every way this can
    fail: the entity doesn't exist, exists but isn't a Line (only Lines
    exist as path-capable Sketch entities today), or is a degenerate
    (zero-length) Line. Mirrors `app.document.revolve._invalid_axis_ref`'s
    envelope shape exactly (422, a structured `detail` dict)."""
    return HTTPException(
        status_code=422,
        detail={
            "type": "invalid_path_ref",
            "sketch_id": ref.sketch_id,
            "entity_type": ref.entity_type.value,
            "entity_id": ref.entity_id,
        },
    )


def _disconnected_path(ref: SketchEntityRef, index: int) -> HTTPException:
    """The structured `disconnected_path` error for a `path_refs` entry
    (at `index`, the entry's own position in the list) whose Line does not
    share a coincident endpoint (within `_PATH_POINT_TOLERANCE`) with the
    chain traced so far - the only way a cross-Sketch, position-based
    connectivity check can fail once every individual entry has already
    resolved to a real, non-degenerate Line (see `_invalid_path_ref` for
    that earlier failure mode)."""
    return HTTPException(
        status_code=422,
        detail={
            "type": "disconnected_path",
            "sketch_id": ref.sketch_id,
            "entity_type": ref.entity_type.value,
            "entity_id": ref.entity_id,
            "index": index,
        },
    )


def _sweep_failed() -> HTTPException:
    """`BRepOffsetAPI_MakePipeShell.IsDone()`/`.MakeSolid()` returned false -
    a geometric failure (the path's curvature/corners make the profile
    self-intersect as it sweeps, etc.), not a malformed reference. 422,
    matching `app.document.revolve._revolve_failed`'s identical "structured
    error, not an uncaught OCCT exception surfacing as a 500" convention."""
    return HTTPException(status_code=422, detail={"type": "sweep_failed"})


def _sweep_wire(path_wire: TopoDS_Wire, wire: TopoDS_Wire) -> TopoDS_Shape:
    """Sweeps one closed `wire` (a Profile's outer boundary, or one of its
    holes - see `resolve_sweep_from_bodies`, which sweeps each of those
    independently and boolean-cuts the results together rather than
    handing `BRepOffsetAPI_MakePipeShell` a compound outer+hole section in
    one call) along `path_wire`, producing a solid.

    `BRepOffsetAPI_MakePipeShell.Add` only ever accepts a single Wire (or
    Edge/Vertex) as one swept "section", not a Face - see this function's
    caller for why a hole is instead handled as a second, independent
    sweep of its own, boolean-cut out of the outer one afterward, rather
    than attempting a not-yet-verified multi-wire single-section call
    here."""
    pipe_maker = BRepOffsetAPI_MakePipeShell(path_wire)
    pipe_maker.SetTransitionMode(BRepBuilderAPI_RightCorner)
    pipe_maker.Add(wire)
    pipe_maker.Build()
    if not pipe_maker.IsDone() or not pipe_maker.MakeSolid():
        raise _sweep_failed()
    return pipe_maker.Shape()


def _resolve_path_segment_endpoints(
    part: Part,
    ref: SketchEntityRef,
    bodies_so_far: dict[str, TopoDS_Shape],
    excluded_feature_ids: frozenset[str],
) -> tuple[gp_Pnt, gp_Pnt]:
    """The world-space `(start, end)` endpoints `ref` resolves to - mirrors
    `app.document.revolve._resolve_axis`'s own resolution exactly (each
    `path_refs` entry is resolved entirely independently: its own owning
    SketchFeature, its own basis, its own Line's two endpoints mapped
    through that basis), just returning the raw endpoint pair instead of a
    `gp_Ax1`, since a path segment's own orientation relative to its
    neighbours is not yet known here - see `_resolve_path_wire`, which
    works that out afterward from the full ordered list.

    Fails closed with `invalid_path_ref` (never a generic `missing_
    reference` or an uncaught OCCT exception) for every way `ref` can be
    unusable as a path segment: wrong `entity_type`, an unresolvable
    Point/Line/Circle lookup, no SketchFeature owning `ref.sketch_id` in
    this Part, or a degenerate (zero-length) Line."""
    if ref.entity_type != SketchEntityType.LINE:
        raise _invalid_path_ref(ref)
    try:
        entity = resolve_sketch_entity(ref)
    except HTTPException:
        raise _invalid_path_ref(ref) from None
    if not isinstance(entity, Line):
        raise _invalid_path_ref(ref)

    path_sketch_feature_id = sketch_feature_id_for_sketch(part, ref.sketch_id)
    path_sketch_feature = part.get_feature(path_sketch_feature_id) if path_sketch_feature_id else None
    if not isinstance(path_sketch_feature, SketchFeature):
        raise _invalid_path_ref(ref)

    sketch = get_sketch_or_404(ref.sketch_id)
    basis = resolve_sketch_basis(part, path_sketch_feature, bodies_so_far, excluded_feature_ids)
    start = sketch.points[entity.start_point_id]
    end = sketch.points[entity.end_point_id]
    start_world = basis_point_to_world(basis, start.x, start.y)
    end_world = basis_point_to_world(basis, end.x, end.y)
    if start_world.Distance(end_world) < _PATH_POINT_TOLERANCE:
        raise _invalid_path_ref(ref)
    return start_world, end_world


def _resolve_path_wire(
    part: Part,
    path_refs: list[SketchEntityRef],
    bodies_so_far: dict[str, TopoDS_Shape],
    excluded_feature_ids: frozenset[str],
) -> TopoDS_Wire:
    """Resolves `path_refs` (an ordered, possibly cross-Sketch list of Line
    references - see `SweepFeature`'s own docstring) into a single OCCT
    wire, tracing the chain via `_resolve_path_segment_endpoints` and
    connecting consecutive entries by coincident endpoint position (within
    `_PATH_POINT_TOLERANCE`) rather than a shared Point id, which
    cross-Sketch entries never have.

    `path_refs[0]` seeds the chain with both of its own endpoints, in
    whatever order `_resolve_path_segment_endpoints` returned them (an
    open chain has no "correct" starting direction - either is equally
    valid). Each subsequent entry must have exactly one endpoint
    coincident with *either* end of the chain built so far - the running
    chain's front (`points[0]`) or its back (`points[-1]`), not just the
    back - since the user may extend the pick in either direction from the
    very first segment (nothing fixes which of its two ends is the
    "start" until a second segment actually picks one). Whichever endpoint
    coincides is dropped (it's the same point already in the list), the
    other extends the chain at that end (appended at the back, or inserted
    at the front) - raising `disconnected_path` (never silently picking a
    nearest-guess connection) if neither end matches.

    Builds the resulting ordered point list into a wire via
    `BRepBuilderAPI_MakePolygon` (the same idiom `app.document.extrude.
    _wire_for_profile` already uses for a Line-chain Profile) rather than
    assembling independent edges and relying on `BRepBuilderAPI_MakeWire`'s
    own vertex-fusing to (re)join them - the connectivity has already been
    fully verified above, so this only ever needs to trace a plain ordered
    polyline. A path whose first and last points coincide (within
    `_PATH_POINT_TOLERANCE`) is closed via `.Close()`, producing a
    continuous looping spine (confirmed explicitly as in-scope) instead of
    an open one - detected structurally, not by a separate flag."""
    points: list[gp_Pnt] = []
    for index, ref in enumerate(path_refs):
        start_world, end_world = _resolve_path_segment_endpoints(
            part, ref, bodies_so_far, excluded_feature_ids
        )
        if not points:
            points.append(start_world)
            points.append(end_world)
            continue
        front, back = points[0], points[-1]
        if back.Distance(start_world) < _PATH_POINT_TOLERANCE:
            points.append(end_world)
        elif back.Distance(end_world) < _PATH_POINT_TOLERANCE:
            points.append(start_world)
        elif front.Distance(start_world) < _PATH_POINT_TOLERANCE:
            points.insert(0, end_world)
        elif front.Distance(end_world) < _PATH_POINT_TOLERANCE:
            points.insert(0, start_world)
        else:
            raise _disconnected_path(ref, index)

    is_closed = len(points) > 2 and points[0].Distance(points[-1]) < _PATH_POINT_TOLERANCE
    polygon = BRepBuilderAPI_MakePolygon()
    last_index = len(points) - 1 if is_closed else len(points)
    for point in points[:last_index]:
        polygon.Add(point)
    if is_closed:
        polygon.Close()
    return polygon.Wire()


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
    if result.status not in EXTRUDABLE_STATUSES:
        logger.warning(
            "Skipping SweepFeature %s: sketch %s has no closed profile (status=%s)",
            feature.id,
            sketch.id,
            result.status.value,
        )
        return None

    basis = resolve_sketch_basis(part, sketch_feature, bodies_so_far, excluded_feature_ids)
    path_wire = _resolve_path_wire(part, feature.path_refs, bodies_so_far, excluded_feature_ids)

    if result.status == ProfileStatus.CLOSED_LOOP:
        assert result.profile is not None
        candidates = [result.profile]
    else:
        candidates = result.loops
    profiles = select_profiles(candidates, feature.profile_refs)

    solids = []
    for profile in profiles:
        outer_wire = wire_for_profile(sketch, profile, basis)
        solid = _sweep_wire(path_wire, outer_wire)
        for inner_loop in profile.inner_loops:
            inner_wire = wire_for_profile(sketch, inner_loop, basis)
            inner_solid = _sweep_wire(path_wire, inner_wire)
            solid = BRepAlgoAPI_Cut(solid, inner_solid).Shape()
        solids.append(solid)

    if len(solids) == 1:
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
