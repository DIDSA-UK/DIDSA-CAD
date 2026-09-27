"""OCCT geometry construction for `CurveFeature` (Helix/Intersection curve) -
kept separate from `app.document.router` the same way every other feature
module already is.

Split into a `_from_bodies` core (accepts an already-computed `bodies` dict,
never recomputes) plus a "fresh" wrapper (`resolve_curve`, computes `bodies`
once via `compute_part_bodies`), the same convention `app.document.create_
plane`/`app.document.sweep` already use - a Curve feature is never itself
persisted into `compute_part_bodies`'s own `bodies` accumulator (a curve
isn't a Body), so every consumer (Sweep/Swept-Surface path resolution, the
`NORMAL_TO_CURVE_FEATURE_AT_PARAMETER` plane resolver, Fill Surface boundary
resolution) resolves it fresh on demand, exactly the way `CreatePlaneFeature`
(`Produces.PLANE`) already is.
"""

import math
from dataclasses import dataclass

from fastapi import HTTPException
from OCC.Core.BRep import BRep_Tool
from OCC.Core.BRepAdaptor import BRepAdaptor_CompCurve
from OCC.Core.BRepAlgoAPI import BRepAlgoAPI_Section
from OCC.Core.BRepBuilderAPI import (
    BRepBuilderAPI_MakeEdge,
    BRepBuilderAPI_MakeWire,
    BRepBuilderAPI_Transform,
)
from OCC.Core.BRepGProp import brepgprop
from OCC.Core.BRepLib import breplib
from OCC.Core.BRepPrimAPI import BRepPrimAPI_MakePrism
from OCC.Core.Geom import Geom_CylindricalSurface
from OCC.Core.Geom2d import Geom2d_Line, Geom2d_TrimmedCurve
from OCC.Core.gp import gp_Ax3, gp_Dir, gp_Dir2d, gp_Pnt, gp_Pnt2d, gp_Trsf, gp_Vec
from OCC.Core.GProp import GProp_GProps
from OCC.Core.TopAbs import TopAbs_EDGE, TopAbs_VERTEX
from OCC.Core.TopExp import TopExp_Explorer
from OCC.Core.TopoDS import TopoDS_Edge, TopoDS_Shape, TopoDS_Wire, topods

from app.document.create_plane import resolve_plane_ref, resolve_sketch_basis
from app.document.extrude import (
    EXTRUDABLE_STATUSES,
    basis_normal,
    compute_part_bodies,
    select_profiles,
    wire_for_profile,
)
from app.document.loft import wire_for_open_chain
from app.document.models import CurveFeature, CurveType, Part, ResolvedPlane, SketchFeature
from app.sketch.profile import OpenChainStatus, ProfileStatus, detect_open_chain, detect_profile
from app.sketch.store import get_sketch_or_404

# Endpoint coincidence tolerance for chaining Intersection-curve edges into a
# single wire - matches `app.document.sweep._PATH_POINT_TOLERANCE` exactly
# (same "position-based connectivity, not shared Point ids" reasoning: the
# edges come out of `BRepAlgoAPI_Section` with no shared vertex identity at
# all, only coincident 3D positions).
_CHAIN_POINT_TOLERANCE = 1e-6

# How far each sketch's profile is extruded (in both directions along its
# own plane normal) before intersecting - generous relative to any
# realistic part size so the two extruded shells always actually overlap
# regardless of how far apart the two sketch planes sit, without the prism
# itself becoming numerically unwieldy.
_INTERSECTION_PRISM_HALF_LENGTH = 10_000.0


@dataclass(frozen=True)
class ResolvedCurve:
    """The world-space geometry a `CurveFeature` resolves to - a single
    `TopoDS_Wire` (possibly multi-edge, for `INTERSECTION`), its total arc
    length, and whether it's closed. Not persisted - recomputed on every
    read/use, mirroring `ResolvedPlane`'s own "re-derive, don't cache"
    convention. Lives here, not in `app.document.models`, because (unlike
    `ResolvedPlane`'s plain coordinate tuples) it holds a real OCCT shape -
    `models.py` stays OCCT-free by design (see that module's own docstring
    conventions for `ResolvedPlane`/`Feature`)."""

    wire: TopoDS_Wire
    length: float
    closed: bool


def _curve_construction_failed(feature_id: str, reason: str) -> HTTPException:
    """The structured `curve_construction_failed` error for any geometric
    (not payload-shape) failure building a Curve feature's OCCT geometry -
    mirrors `app.document.sweep._sweep_failed`'s identical "structured 422,
    not an uncaught OCCT exception surfacing as a 500" convention."""
    return HTTPException(
        status_code=422,
        detail={"type": "curve_construction_failed", "feature_id": feature_id, "reason": reason},
    )


def _missing_curve_input(feature_id: str, missing: str) -> HTTPException:
    """The structured `missing_reference` error for a Curve feature whose
    own required input (an axis `PlaneRef`, a Sketch it names by id) no
    longer resolves - same envelope shape `app.document.extrude.resolve_
    subshape_from_bodies` already uses for a stale `SubShapeRef`."""
    return HTTPException(
        status_code=422,
        detail={"type": "missing_reference", "feature_id": feature_id, "missing": missing},
    )


def _wire_length(wire: TopoDS_Wire) -> float:
    """The total arc length of `wire` (single- or multi-edge) via OCCT's own
    analytic integration - the same `GProp_GProps`/`brepgprop.
    LinearProperties` pattern `app.document.measure`/`app.document.loft`
    already use for an edge's length, applied to a whole wire here."""
    props = GProp_GProps()
    brepgprop.LinearProperties(wire, props)
    return props.Mass()


def point_and_tangent_at_fraction(wire: TopoDS_Wire, length: float, fraction: float) -> tuple[gp_Pnt, gp_Vec]:
    """The point and (unnormalized) tangent on `wire` at `fraction` (0-1) of
    its own total arc length `length` - shared by `app.document.create_
    plane.resolve_normal_to_curve_feature_at_parameter_from_bodies` (the
    `NORMAL_TO_CURVE_FEATURE_AT_PARAMETER` plane resolver) and this module's
    own tests. `BRepAdaptor_CompCurve` treats `wire` (single- or multi-edge)
    as one continuous curve; `GCPnts_AbscissaPoint` finds the parameter `u`
    a given arc-length distance from the wire's own start, which is the only
    reliable way to convert "a fraction of arc length" into a curve
    parameter regardless of how that curve happens to be parametrized
    internally (a helix's own 2D-line-on-a-cylinder parametrization is not
    itself arc-length, for instance)."""
    from OCC.Core.GCPnts import GCPnts_AbscissaPoint

    adaptor = BRepAdaptor_CompCurve(wire)
    target_length = max(0.0, min(1.0, fraction)) * length
    abscissa = GCPnts_AbscissaPoint(1e-6, adaptor, target_length, adaptor.FirstParameter())
    if not abscissa.IsDone():
        raise _curve_construction_failed("", "could not locate point at requested curve parameter")
    u = abscissa.Parameter()
    point = gp_Pnt()
    tangent = gp_Vec()
    adaptor.D1(u, point, tangent)
    return point, tangent


def _resolve_helix_from_bodies(
    part: Part,
    feature: CurveFeature,
    bodies_so_far: dict[str, TopoDS_Shape],
    excluded_feature_ids: frozenset[str],
) -> ResolvedCurve:
    """A constant-pitch helix around `feature.axis_ref` (its origin = the
    helix's start point, its normal = the axis direction), built via the
    standard OCCT "2D line in a cylinder's own (angle, height) parameter
    space, mapped to 3D through that surface" recipe: a `Geom2d_Line` with
    direction `(+-2*pi, pitch)` (one revolution's worth of (angle, height))
    trimmed to `turns` revolutions, handed to `BRepBuilderAPI_MakeEdge`
    together with the `Geom_CylindricalSurface` it lies on - the overload
    that builds a 3D edge by evaluating a UV curve through a surface, not by
    interpolating points. `right_handed=False` negates the angular
    component only (not the pitch), which reverses winding direction
    (clockwise vs counterclockwise viewed along the axis) while keeping
    the same axis-progression direction for a given `pitch` sign."""
    assert feature.axis_ref is not None and feature.radius is not None
    assert feature.pitch is not None and feature.turns is not None
    if feature.radius <= 0.0:
        raise _curve_construction_failed(feature.id, "helix radius must be positive")
    if feature.pitch == 0.0:
        raise _curve_construction_failed(feature.id, "helix pitch must be non-zero")
    if feature.turns <= 0.0:
        raise _curve_construction_failed(feature.id, "helix turns must be positive")

    axis_plane = resolve_plane_ref(part, bodies_so_far, feature.axis_ref, excluded_feature_ids)
    origin = gp_Pnt(*axis_plane.origin)
    axis_dir = gp_Dir(*axis_plane.normal)
    x_dir = gp_Dir(*axis_plane.x_axis)
    cylinder = Geom_CylindricalSurface(gp_Ax3(origin, axis_dir, x_dir), feature.radius)

    angular_sign = 1.0 if feature.right_handed else -1.0
    revolution_step = math.sqrt((2.0 * math.pi) ** 2 + feature.pitch**2)
    line_2d = Geom2d_Line(gp_Pnt2d(0.0, 0.0), gp_Dir2d(angular_sign * 2.0 * math.pi, feature.pitch))
    segment_2d = Geom2d_TrimmedCurve(line_2d, 0.0, feature.turns * revolution_step)

    edge = BRepBuilderAPI_MakeEdge(segment_2d, cylinder).Edge()
    # `BRepBuilderAPI_MakeEdge(Geom2d_Curve, Geom_Surface)` only gives the
    # edge a pcurve-on-surface representation, no actual 3D `Geom_Curve` -
    # confirmed on-device: `BRep_Tool.Curve` returns `None` for it, and
    # `BRepOffsetAPI_MakePipeShell.Build()` (a Sweep along this Helix)
    # fails outright with a bare `Standard_NullObject` because of it.
    # `BRepLib.BuildCurves3d` computes and attaches the missing 3D curve
    # from the pcurve+surface pair - the standard OCCT fix for a
    # surface-parametrized edge that a 3D-curve-only consumer needs.
    breplib.BuildCurves3d(edge)
    wire = BRepBuilderAPI_MakeWire(edge).Wire()
    return ResolvedCurve(wire=wire, length=_wire_length(wire), closed=False)


def _profile_or_open_chain_wire(
    part: Part,
    sketch_feature: SketchFeature,
    profile_refs,
    bodies_so_far: dict[str, TopoDS_Shape],
    excluded_feature_ids: frozenset[str],
    feature_id: str,
) -> tuple[TopoDS_Wire, ResolvedPlane]:
    """One Sketch's own profile wire plus the basis it was built against -
    tries a closed profile first (same `detect_profile`/`select_profiles`/
    `wire_for_profile` machinery `app.document.surface.resolve_surface_
    from_bodies` already uses), falling back to a single open chain. v1
    scope, matching `app.document.loft`'s own conservative precedent:
    exactly one profile/chain is required - a MultiProfile Sketch (more than
    one candidate loop) is rejected outright rather than guessing which
    loop the Intersection curve should use."""
    sketch = get_sketch_or_404(sketch_feature.sketch_id)
    basis = resolve_sketch_basis(part, sketch_feature, bodies_so_far, excluded_feature_ids)

    result = detect_profile(sketch)
    if result.status in EXTRUDABLE_STATUSES:
        expanded_sketch = sketch.expand_pattern_and_mirror_instances()
        candidates = [result.profile] if result.status == ProfileStatus.CLOSED_LOOP else result.loops
        profiles = select_profiles(candidates, profile_refs)
        if len(profiles) != 1:
            raise _curve_construction_failed(
                feature_id, "sketch must resolve to exactly one profile for an intersection curve"
            )
        return wire_for_profile(expanded_sketch, profiles[0], basis), basis

    open_result = detect_open_chain(sketch)
    if open_result.status == OpenChainStatus.SINGLE_CHAIN:
        expanded_sketch = sketch.expand_pattern_and_mirror_instances()
        return wire_for_open_chain(expanded_sketch, open_result.chain, basis), basis

    raise _curve_construction_failed(feature_id, "sketch has no closed profile or open chain to intersect")


def _prism_shell(wire: TopoDS_Wire, direction: gp_Dir) -> TopoDS_Shape:
    """`wire` extruded symmetrically `_INTERSECTION_PRISM_HALF_LENGTH` in
    both directions along `direction` - unlike `app.document.surface.
    _prism_shell_for_wire` (a fixed, user-chosen start/end distance), an
    Intersection curve's own extrusion span has no user-facing meaning at
    all (it exists purely so the two shells are guaranteed to overlap
    wherever the two sketch planes actually sit relative to each other), so
    it is always centered on the wire's own plane rather than offset."""
    vector = gp_Vec(direction.X(), direction.Y(), direction.Z())
    start_transform = gp_Trsf()
    start_transform.SetTranslation(vector.Multiplied(-_INTERSECTION_PRISM_HALF_LENGTH))
    moved_wire = BRepBuilderAPI_Transform(wire, start_transform, True).Shape()
    prism_vector = vector.Multiplied(2.0 * _INTERSECTION_PRISM_HALF_LENGTH)
    return BRepPrimAPI_MakePrism(moved_wire, prism_vector).Shape()


def _chain_section_edges_into_wire(edges: list[TopoDS_Edge], feature_id: str) -> ResolvedCurve:
    """Chains `edges` (raw, unordered, un-oriented - `BRepAlgoAPI_Section`'s
    own output) into a single `TopoDS_Wire` by endpoint coincidence, the
    same "position-based connectivity" approach `app.document.sweep.
    resolve_path_wire` already uses for cross-Sketch `path_refs` chaining,
    generalized to work directly on raw edges instead of pre-grouped
    `_PathSegment`s (Section's result has no such grouping to begin with).

    Direction doesn't matter here (unlike Sweep's own path, whose direction
    drives `BRepOffsetAPI_MakePipeShell`'s trihedron) - `BRepBuilderAPI_
    MakeWire.Add` already re-derives each edge's own topological Orientation
    from real vertex-position connectivity regardless of which order/
    direction it's handed in (see `app.document.sweep._reversed_edge`'s own
    doc comment for the on-device-confirmed detail), so edges are added in
    whatever order they're found to connect, with no reversal step needed.

    If not every edge chains into the same connected run, the two sketches
    intersect in more than one disjoint curve - out of scope (v1): raises
    `curve_construction_failed` rather than silently picking one piece."""
    if not edges:
        raise _curve_construction_failed(feature_id, "the two sketches do not intersect")

    remaining = list(edges)
    chain = [remaining.pop(0)]
    endpoints = [_edge_vertex_points(chain[0])]

    progressed = True
    while remaining and progressed:
        progressed = False
        front_point = endpoints[0][0]
        back_point = endpoints[-1][1]
        for index, edge in enumerate(remaining):
            edge_start, edge_end = _edge_vertex_points(edge)
            if back_point.Distance(edge_start) < _CHAIN_POINT_TOLERANCE:
                chain.append(edge)
                endpoints.append((edge_start, edge_end))
            elif back_point.Distance(edge_end) < _CHAIN_POINT_TOLERANCE:
                chain.append(edge)
                endpoints.append((edge_end, edge_start))
            elif front_point.Distance(edge_end) < _CHAIN_POINT_TOLERANCE:
                chain.insert(0, edge)
                endpoints.insert(0, (edge_start, edge_end))
            elif front_point.Distance(edge_start) < _CHAIN_POINT_TOLERANCE:
                chain.insert(0, edge)
                endpoints.insert(0, (edge_end, edge_start))
            else:
                continue
            remaining.pop(index)
            progressed = True
            break

    if remaining:
        raise _curve_construction_failed(
            feature_id, "sketches must intersect in a single connected curve (found disjoint pieces)"
        )

    wire_maker = BRepBuilderAPI_MakeWire()
    for edge in chain:
        wire_maker.Add(edge)
    wire = wire_maker.Wire()
    closed = endpoints[0][0].Distance(endpoints[-1][1]) < _CHAIN_POINT_TOLERANCE
    return ResolvedCurve(wire=wire, length=_wire_length(wire), closed=closed)


def _edge_vertex_points(edge: TopoDS_Edge) -> tuple[gp_Pnt, gp_Pnt]:
    """`edge`'s own first/last vertex positions, in the edge's own natural
    (possibly single-vertex, for a closed/periodic edge) order - same
    vertex-explosion approach as `_wire_endpoints`, at single-edge
    granularity."""
    explorer = TopExp_Explorer(edge, TopAbs_VERTEX)
    vertices = []
    while explorer.More():
        vertices.append(topods.Vertex(explorer.Current()))
        explorer.Next()
    start = BRep_Tool.Pnt(vertices[0])
    end = BRep_Tool.Pnt(vertices[-1]) if len(vertices) > 1 else start
    return start, end


def _resolve_intersection_from_bodies(
    part: Part,
    feature: CurveFeature,
    bodies_so_far: dict[str, TopoDS_Shape],
    excluded_feature_ids: frozenset[str],
) -> ResolvedCurve:
    """The 3D curve where Sketch A's and Sketch B's own profiles, each
    extruded into an infinite (`_INTERSECTION_PRISM_HALF_LENGTH`-bounded)
    shell along its own sketch plane's normal, intersect - via OCCT
    `BRepAlgoAPI_Section`. This is the standard "curve from two sketches"
    tool: projecting each sketch normal to its own plane before
    intersecting (rather than, say, requiring both sketches to already
    share one plane) is exactly what makes this useful for a curve that
    lies on neither sketch's own plane."""
    assert feature.sketch_feature_id_a is not None and feature.sketch_feature_id_b is not None
    feature_a = part.get_feature(feature.sketch_feature_id_a)
    feature_b = part.get_feature(feature.sketch_feature_id_b)
    if not isinstance(feature_a, SketchFeature):
        raise _missing_curve_input(feature.id, "sketch_feature_id_a")
    if not isinstance(feature_b, SketchFeature):
        raise _missing_curve_input(feature.id, "sketch_feature_id_b")

    wire_a, basis_a = _profile_or_open_chain_wire(
        part, feature_a, feature.profile_refs_a, bodies_so_far, excluded_feature_ids, feature.id
    )
    wire_b, basis_b = _profile_or_open_chain_wire(
        part, feature_b, feature.profile_refs_b, bodies_so_far, excluded_feature_ids, feature.id
    )
    shell_a = _prism_shell(wire_a, basis_normal(basis_a))
    shell_b = _prism_shell(wire_b, basis_normal(basis_b))

    section = BRepAlgoAPI_Section(shell_a, shell_b)
    section.ComputePCurveOn1(True)
    section.Approximation(True)
    section.Build()
    if not section.IsDone():
        raise _curve_construction_failed(feature.id, "the two sketches do not intersect")

    explorer = TopExp_Explorer(section.Shape(), TopAbs_EDGE)
    edges: list[TopoDS_Edge] = []
    while explorer.More():
        edges.append(topods.Edge(explorer.Current()))
        explorer.Next()
    return _chain_section_edges_into_wire(edges, feature.id)


def resolve_curve_from_bodies(
    part: Part,
    feature: CurveFeature,
    bodies_so_far: dict[str, TopoDS_Shape],
    excluded_feature_ids: frozenset[str],
) -> ResolvedCurve:
    """`feature`'s own resolved curve geometry, regardless of `curve_type` -
    the `_from_bodies` core every consumer (Sweep/Swept-Surface path
    resolution, Fill Surface boundary resolution, the plane-at-parameter
    resolver) calls against their own in-progress `bodies` accumulator,
    mirroring `app.document.create_plane.resolve_plane_ref`'s identical
    role for `PlaneRef`."""
    if feature.curve_type == CurveType.HELIX:
        return _resolve_helix_from_bodies(part, feature, bodies_so_far, excluded_feature_ids)
    assert feature.curve_type == CurveType.INTERSECTION
    return _resolve_intersection_from_bodies(part, feature, bodies_so_far, excluded_feature_ids)


def resolve_curve(
    part: Part,
    feature: CurveFeature,
    excluded_feature_ids: frozenset[str] = frozenset(),
) -> ResolvedCurve:
    """Resolves a `CurveFeature` - fresh wrapper around `resolve_curve_from_
    bodies` that computes `bodies` itself via `compute_part_bodies`, for
    callers (the router) that don't already have one on hand. Mirrors
    `app.document.create_plane.resolve_offset_face`'s own fresh-vs-`_from_
    bodies` split."""
    bodies = compute_part_bodies(part, excluded_feature_ids)
    return resolve_curve_from_bodies(part, feature, bodies, excluded_feature_ids)


def resolve_curve_feature_by_id(
    part: Part,
    curve_feature_id: str,
    bodies_so_far: dict[str, TopoDS_Shape],
    excluded_feature_ids: frozenset[str],
) -> ResolvedCurve:
    """Looks up `curve_feature_id` in `part` and resolves it - the shape
    every `SketchOrEdgeRef.curve_feature_id` consumer needs (Sweep/Swept-
    Surface path segments, Fill Surface boundaries), so the "look up by id,
    fail closed if missing/wrong-type" step isn't duplicated at each call
    site."""
    curve_feature = part.get_feature(curve_feature_id)
    if not isinstance(curve_feature, CurveFeature):
        raise _missing_curve_input(curve_feature_id, "curve_feature_id")
    return resolve_curve_from_bodies(part, curve_feature, bodies_so_far, excluded_feature_ids)
