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
from collections.abc import Callable
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
from OCC.Core.BRepPrimAPI import BRepPrimAPI_MakePrism
from OCC.Core.gp import gp_Ax2, gp_Ax3, gp_Dir, gp_Pnt, gp_Trsf, gp_Vec
from OCC.Core.GeomAPI import GeomAPI_Interpolate
from OCC.Core.HelixBRep import HelixBRep_BuilderHelix
from OCC.Core.TColgp import TColgp_HArray1OfPnt
from OCC.Core.TColStd import TColStd_Array1OfReal, TColStd_HArray1OfReal
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
from app.document.helix_profile import HelixSample, pitch_at_height, samples_to_height
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


def _real_array(values: list[float]) -> TColStd_Array1OfReal:
    array = TColStd_Array1OfReal(1, len(values))
    for position, value in enumerate(values, start=1):
        array.SetValue(position, value)
    return array


def _mirrored(wire: TopoDS_Wire, origin: gp_Pnt, plane_normal: gp_Dir) -> TopoDS_Wire:
    transform = gp_Trsf()
    transform.SetMirror(gp_Ax2(origin, plane_normal))
    return topods.Wire(BRepBuilderAPI_Transform(wire, transform, True).Shape())


def sampled_helix_wire(
    frame: gp_Ax3, samples: list[HelixSample], radius_at_height: Callable[[float], float]
) -> TopoDS_Wire:
    """A counterclockwise (viewed down `frame`'s axis) helix through `samples` (see
    `app.document.helix_profile`), its radius `radius_at_height(z)`, starting on `frame`'s x axis:
    one C2 cubic BSpline edge interpolated through the points at their turn counts. Used where the
    pitch varies smoothly, which `HelixBRep_BuilderHelix` (constant-pitch segments only) cannot make:
    a variable-pitch Helix and a Spring's centreline (`app.document.spring`)."""
    origin = frame.Location()
    axis = gp_Vec(frame.Direction())
    x_dir = gp_Vec(frame.XDirection())
    y_dir = axis.Crossed(x_dir)
    points = TColgp_HArray1OfPnt(1, len(samples))
    params = TColStd_HArray1OfReal(1, len(samples))
    for index, sample in enumerate(samples, start=1):
        angle = 2.0 * math.pi * sample.t
        radius = radius_at_height(sample.z)
        offset = (
            x_dir.Multiplied(radius * math.cos(angle))
            + y_dir.Multiplied(radius * math.sin(angle))
            + axis.Multiplied(sample.z)
        )
        points.SetValue(index, origin.Translated(offset))
        params.SetValue(index, sample.t)
    interpolate = GeomAPI_Interpolate(points, params, False, 1e-9)
    interpolate.Perform()
    if not interpolate.IsDone():
        raise _curve_construction_failed("", "could not interpolate the helix")
    edge = BRepBuilderAPI_MakeEdge(interpolate.Curve()).Edge()
    return BRepBuilderAPI_MakeWire(edge).Wire()


def helix_height(feature: CurveFeature) -> float:
    """A helix's height along its axis, signed like its pitch: pitch x turns summed over its segments,
    or its last pitch point's distance."""
    if feature.pitch_points:
        return math.copysign(feature.pitch_points[-1].at, feature.pitch_points[0].pitch)
    return sum(seg.pitch * seg.turns for seg in feature.segments)


def _variable_pitch_samples(feature: CurveFeature) -> list[HelixSample]:
    """The centreline samples of a pitch-points helix (pitches made positive: the direction is
    applied afterwards, like a negative segment pitch)."""
    at = [point.at for point in feature.pitch_points]
    pitches = [abs(point.pitch) for point in feature.pitch_points]
    return samples_to_height(pitch_at_height(at, pitches), at[-1])


def helix_turns(feature: CurveFeature) -> float:
    """How many turns a helix makes: its segments' turns, or worked out from its pitch points."""
    if feature.pitch_points:
        return _variable_pitch_samples(feature)[-1].t
    return sum(seg.turns for seg in feature.segments)


def _resolve_helix_from_bodies(
    part: Part,
    feature: CurveFeature,
    bodies_so_far: dict[str, TopoDS_Shape],
    excluded_feature_ids: frozenset[str],
) -> ResolvedCurve:
    """A helix around `feature.axis_ref` (its origin = the helix's start axis point, its normal =
    the axis direction, its x axis = where the start lies, at `radius`), built by OCCT 8's
    `HelixBRep_BuilderHelix`: a composite helix of `feature.segments` (each `turns` revolutions at
    its own `pitch`), whose diameter runs linearly with height from `radius` to `end_radius` (a
    constant `radius` when that is None).

    The builder only makes a counterclockwise (viewed down the axis) helix that advances along the
    axis (it rejects a negative pitch, error status 12), so the other cases are mirrors of it:
    `right_handed=False` mirrors across the plane through the axis and the x axis (it winds the
    other way, the start point stays), a negative pitch across the plane normal to the axis at the
    origin (it advances the other way, the winding stays). `right_handed` is therefore the winding
    direction and the pitch's sign the axis direction, as in the 7.9 construction this replaced
    (a 2D line on a cylinder, approximated into 3D)."""
    assert feature.axis_ref is not None and feature.radius is not None
    assert feature.segments or feature.pitch_points
    if feature.radius <= 0.0 or (feature.end_radius is not None and feature.end_radius <= 0.0):
        raise _curve_construction_failed(feature.id, "helix radii must be positive")
    if feature.pitch_points:
        return _resolve_variable_pitch_helix(part, feature, bodies_so_far, excluded_feature_ids)
    if any(seg.pitch == 0.0 or seg.turns <= 0.0 for seg in feature.segments):
        raise _curve_construction_failed(feature.id, "helix pitch must be non-zero and turns positive")
    advances_up = feature.segments[0].pitch > 0.0
    if any((seg.pitch > 0.0) != advances_up for seg in feature.segments):
        raise _curve_construction_failed(feature.id, "every helix segment must advance the same way along the axis")

    axis_plane = resolve_plane_ref(part, bodies_so_far, feature.axis_ref, excluded_feature_ids)
    origin = gp_Pnt(*axis_plane.origin)
    axis_dir = gp_Dir(*axis_plane.normal)
    x_dir = gp_Dir(*axis_plane.x_axis)

    pitches = [abs(seg.pitch) for seg in feature.segments]
    turns = [seg.turns for seg in feature.segments]
    heights = [pitch * turn for pitch, turn in zip(pitches, turns)]
    total = sum(heights)
    end_radius = feature.radius if feature.end_radius is None else feature.end_radius
    diameters = [2.0 * feature.radius]
    travelled = 0.0
    for height in heights:
        travelled += height
        diameters.append(2.0 * (feature.radius + (end_radius - feature.radius) * travelled / total))

    builder = HelixBRep_BuilderHelix()
    builder.SetParameters(gp_Ax3(origin, axis_dir, x_dir), _real_array(diameters), _real_array(pitches), _real_array(turns))
    builder.Perform()
    shape = builder.Shape()
    if builder.ErrorStatus() != 0 or shape is None or shape.IsNull():
        raise _curve_construction_failed(feature.id, f"helix builder failed (status {builder.ErrorStatus()})")
    wire = topods.Wire(shape)

    if not feature.right_handed:
        wire = _mirrored(wire, origin, gp_Dir(axis_dir.Crossed(x_dir)))
    if not advances_up:
        wire = _mirrored(wire, origin, axis_dir)
    return ResolvedCurve(wire=wire, length=_wire_length(wire), closed=False)


def _resolve_variable_pitch_helix(
    part: Part,
    feature: CurveFeature,
    bodies_so_far: dict[str, TopoDS_Shape],
    excluded_feature_ids: frozenset[str],
) -> ResolvedCurve:
    """A helix whose pitch varies smoothly with height (`feature.pitch_points`), sampled
    (`app.document.helix_profile`) and interpolated (`sampled_helix_wire`); radius, taper, hand and
    direction as `_resolve_helix_from_bodies`."""
    points = feature.pitch_points
    if len(points) < 2 or points[0].at != 0.0 or any(b.at <= a.at for a, b in zip(points, points[1:])):
        raise _curve_construction_failed(feature.id, "pitch points must start at 0 and increase along the axis")
    if any(point.pitch == 0.0 for point in points) or len({point.pitch > 0.0 for point in points}) != 1:
        raise _curve_construction_failed(feature.id, "pitches must be non-zero and all advance the same way")
    axis_plane = resolve_plane_ref(part, bodies_so_far, feature.axis_ref, excluded_feature_ids)
    origin = gp_Pnt(*axis_plane.origin)
    axis_dir = gp_Dir(*axis_plane.normal)
    x_dir = gp_Dir(*axis_plane.x_axis)
    height = points[-1].at
    start, end = feature.radius, feature.radius if feature.end_radius is None else feature.end_radius
    wire = sampled_helix_wire(
        gp_Ax3(origin, axis_dir, x_dir),
        _variable_pitch_samples(feature),
        lambda z: start + (end - start) * z / height,
    )
    if not feature.right_handed:
        wire = _mirrored(wire, origin, gp_Dir(axis_dir.Crossed(x_dir)))
    if points[0].pitch < 0.0:
        wire = _mirrored(wire, origin, axis_dir)
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
