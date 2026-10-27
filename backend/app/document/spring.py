"""OCCT geometry for `SpringFeature`: a helical compression spring as one solid (owner's request:
closed ends, optionally ground flat, in a dedicated Spring feature).

Layout (`spring_layout`, plain math). Along the centreline the pitch (axis advance per turn) is a
function of turns `t`:
- a closed end starts with `DEAD_COILS` dead coil(s) at the wire's own pitch (the coils touch), then
  the pitch rises to the working (active) pitch over `TRANSITION_TURNS` (a smoothstep, so the
  centreline stays smooth); an open end runs at the working pitch right to its tip;
- the working pitch is solved so the spring is `free_length` tall: from the base plane to the top of
  the last coil, or to the ground faces.
A ground end is cut flat square to the axis `GRIND_DEPTH` x wire into the dead coil above its
centreline start, which leaves a flat about three quarters of a turn long (a usual ground spring),
the wire at the tip a quarter of its diameter thick.

Geometry (`resolve_spring_from_bodies`): the centreline (`app.document.helix_profile` samples, an
interpolated wire, one edge per turn) swept with the wire's circle, the ground ends cut off by one
`BRepAlgoAPI_Common` with a slab between the two grind planes, then moved onto `plane_ref` (base on
the plane), mirrored for a left-handed spring.
"""

import math
from collections.abc import Callable
from dataclasses import dataclass

from fastapi import HTTPException
from OCC.Core.BRepAdaptor import BRepAdaptor_CompCurve
from OCC.Core.BRepAlgoAPI import BRepAlgoAPI_Common
from OCC.Core.BRepBuilderAPI import BRepBuilderAPI_MakeEdge, BRepBuilderAPI_MakeWire, BRepBuilderAPI_Transform
from OCC.Core.BRepOffsetAPI import BRepOffsetAPI_MakePipeShell
from OCC.Core.BRepPrimAPI import BRepPrimAPI_MakeBox
from OCC.Core.gp import gp_Ax2, gp_Ax3, gp_Circ, gp_Dir, gp_Pnt, gp_Trsf, gp_Vec
from OCC.Core.TopAbs import TopAbs_SOLID
from OCC.Core.TopExp import TopExp_Explorer
from OCC.Core.TopoDS import TopoDS_Shape

from app.document.create_plane import resolve_plane_ref
from app.document.curve import sampled_helix_wire
from app.document.extrude import compute_part_bodies
from app.document.helix_profile import samples_to_turns
from app.document.models import Part, SpringEnd, SpringFeature

# Dead coils at a closed end, at the wire's own pitch.
DEAD_COILS = 1.0
# Turns over which a closed end's pitch rises to the working pitch.
TRANSITION_TURNS = 0.5
# How far into the dead coil a ground end is cut, as a fraction of the wire diameter, above the
# centreline's start: the tip is left `0.5 - GRIND_DEPTH` of the wire thick, the flat runs about
# (0.5 + GRIND_DEPTH) of a turn.
GRIND_DEPTH = 0.25


def _invalid_spring(detail: str) -> HTTPException:
    """A spring whose numbers cannot make a spring (422), with the reason in the user's terms."""
    return HTTPException(status_code=422, detail={"type": "invalid_spring_parameters", "detail": detail})


def _spring_failed(detail: str) -> HTTPException:
    return HTTPException(status_code=422, detail={"type": "spring_failed", "detail": detail})


@dataclass(frozen=True)
class SpringLayout:
    """A spring's centreline, worked out from its numbers (all lengths mm, before placing it)."""

    active_pitch: float
    total_coils: float
    # The centreline's height from its start to its end.
    centreline_height: float
    # The pitch along the centreline, by turns from the start.
    pitch_of_turn: Callable[[float], float]
    # How far below the centreline's start the spring's base is (negative: above, a ground end).
    base_below_start: float
    top_above_end: float
    # The shortest free length these coils allow (the active coils closed up to the wire).
    solid_length: float


def _smoothstep(s: float) -> float:
    return s * s * (3.0 - 2.0 * s)


def _end_extent(end: SpringEnd, wire: float, mean_diameter: float, pitch_at_end: float) -> float:
    """How far the spring reaches past its centreline's end along the axis: half the wire (seen
    through the slope of the end coil) for an open or closed end, minus the ground-off depth
    (a negative extent) for a ground one."""
    if end == SpringEnd.CLOSED_GROUND:
        return -GRIND_DEPTH * wire
    return 0.5 * wire * math.cos(math.atan(pitch_at_end / (math.pi * mean_diameter)))


def spring_layout(feature: SpringFeature) -> SpringLayout:
    """Checks the numbers and works out the centreline (see the module docstring)."""
    d, mean, length, active = feature.wire_diameter, feature.mean_diameter, feature.free_length, feature.active_coils
    if d <= 0.0:
        raise _invalid_spring("the wire diameter must be more than 0")
    if mean <= d:
        raise _invalid_spring(
            f"the mean diameter ({mean:g} mm) must be bigger than the wire diameter ({d:g} mm), "
            "or the coils run into each other across the middle"
        )
    if active < 1.0:
        raise _invalid_spring("a spring needs at least 1 active coil")
    if length <= 0.0:
        raise _invalid_spring("the free length must be more than 0")

    closed_start = feature.start_end != SpringEnd.OPEN
    closed_finish = feature.finish_end != SpringEnd.OPEN
    dead_start = DEAD_COILS if closed_start else 0.0
    dead_finish = DEAD_COILS if closed_finish else 0.0
    ramp_start = TRANSITION_TURNS if closed_start else 0.0
    ramp_finish = TRANSITION_TURNS if closed_finish else 0.0
    closed_pitch = d

    def centreline_height(active_pitch: float) -> float:
        # Dead coils at the closed pitch, the active coils at the working pitch, the transitions at
        # the mean of the two (a smoothstep's average).
        ramps = ramp_start + ramp_finish
        return (dead_start + dead_finish) * closed_pitch + active_pitch * (active - ramps / 2) + closed_pitch * ramps / 2

    def extents(active_pitch: float) -> tuple[float, float]:
        start = _end_extent(feature.start_end, d, mean, closed_pitch if closed_start else active_pitch)
        finish = _end_extent(feature.finish_end, d, mean, closed_pitch if closed_finish else active_pitch)
        return start, finish

    # free length = centreline height (linear in the working pitch) + the two end extents (an open
    # end's depends slightly on the working pitch): a few fixed-point steps settle it.
    ramps = ramp_start + ramp_finish
    fixed = (dead_start + dead_finish) * closed_pitch + closed_pitch * ramps / 2
    active_pitch = d
    for _ in range(8):
        start_extent, finish_extent = extents(active_pitch)
        active_pitch = (length - start_extent - finish_extent - fixed) / (active - ramps / 2)
    start_extent, finish_extent = extents(active_pitch)
    solid_start, solid_finish = extents(closed_pitch)
    solid_length = centreline_height(closed_pitch) + solid_start + solid_finish
    if active_pitch <= closed_pitch * 1.001:
        raise _invalid_spring(
            f"the free length is too short: {active:g} active coils of {d:g} mm wire close up solid at "
            f"{solid_length:.3f} mm, so the free length has to be longer than that"
        )

    total = dead_start + active + dead_finish
    ramp_up_end = dead_start + ramp_start
    ramp_down_start = total - dead_finish - ramp_finish

    def pitch_of_turn(t: float) -> float:
        if t < dead_start or t > total - dead_finish:
            return closed_pitch
        if t < ramp_up_end:
            return closed_pitch + (active_pitch - closed_pitch) * _smoothstep((t - dead_start) / ramp_start)
        if t > ramp_down_start:
            return closed_pitch + (active_pitch - closed_pitch) * _smoothstep((total - dead_finish - t) / ramp_finish)
        return active_pitch

    return SpringLayout(
        active_pitch=active_pitch,
        total_coils=total,
        centreline_height=centreline_height(active_pitch),
        pitch_of_turn=pitch_of_turn,
        base_below_start=start_extent,
        top_above_end=finish_extent,
        solid_length=solid_length,
    )


def _single_solid(shape: TopoDS_Shape) -> bool:
    explorer = TopExp_Explorer(shape, TopAbs_SOLID)
    count = 0
    while explorer.More():
        count += 1
        explorer.Next()
    return count == 1


def spring_solid_local(feature: SpringFeature) -> TopoDS_Shape:
    """The spring standing on the XY plane at the origin, rising along +Z, its wire starting on +X,
    right- or left-handed: the sweep of the wire along the centreline, ground ends cut off."""
    layout = spring_layout(feature)
    d = feature.wire_diameter
    samples = samples_to_turns(layout.pitch_of_turn, layout.total_coils)
    height = samples[-1].z
    path = sampled_helix_wire(gp_Ax3(), samples, lambda _z: feature.mean_diameter / 2)

    adaptor = BRepAdaptor_CompCurve(path)
    start, tangent = gp_Pnt(), gp_Vec()
    adaptor.D1(adaptor.FirstParameter(), start, tangent)
    circle = BRepBuilderAPI_MakeEdge(gp_Circ(gp_Ax2(start, gp_Dir(tangent)), d / 2)).Edge()
    pipe = BRepOffsetAPI_MakePipeShell(path)
    pipe.Add(BRepBuilderAPI_MakeWire(circle).Wire())
    pipe.Build()
    try:
        made = pipe.IsDone() and pipe.MakeSolid()
    except RuntimeError:
        made = False
    if not made:
        raise _spring_failed("could not sweep the wire along the spring")
    solid = pipe.Shape()

    grind_low = GRIND_DEPTH * d if feature.start_end == SpringEnd.CLOSED_GROUND else None
    grind_high = height - GRIND_DEPTH * d if feature.finish_end == SpringEnd.CLOSED_GROUND else None
    if grind_low is not None or grind_high is not None:
        reach = feature.mean_diameter + 10 * d + height
        low = grind_low if grind_low is not None else -reach
        high = grind_high if grind_high is not None else height + reach
        slab = BRepPrimAPI_MakeBox(gp_Pnt(-reach, -reach, low), gp_Pnt(reach, reach, high)).Shape()
        common = BRepAlgoAPI_Common(solid, slab)
        if not common.IsDone() or common.HasErrors():
            raise _spring_failed("could not grind the ends flat")
        solid = common.Shape()
    if not _single_solid(solid):
        raise _spring_failed("the spring did not come out as one solid")

    # Base on z = 0 (the lowest point is the base extent below the centreline's start).
    move = gp_Trsf()
    move.SetTranslation(gp_Vec(0.0, 0.0, layout.base_below_start))
    if not feature.right_handed:
        mirror = gp_Trsf()
        mirror.SetMirror(gp_Ax2(gp_Pnt(0, 0, 0), gp_Dir(0, 1, 0)))
        move = move.Multiplied(mirror)
    return BRepBuilderAPI_Transform(solid, move, True).Shape()


def resolve_spring_from_bodies(
    feature: SpringFeature,
    part: Part,
    bodies: dict[str, TopoDS_Shape],
    excluded_feature_ids: frozenset[str],
) -> TopoDS_Shape:
    """The spring's solid, placed on `feature.plane_ref` (normal = axis, origin = base centre,
    x axis = where the wire starts). Raises a structured 422 for numbers that make no spring."""
    local = spring_solid_local(feature)
    basis = resolve_plane_ref(part, bodies, feature.plane_ref, excluded_feature_ids)
    placement = gp_Trsf()
    placement.SetDisplacement(
        gp_Ax3(),
        gp_Ax3(gp_Pnt(*basis.origin), gp_Dir(*basis.normal), gp_Dir(*basis.x_axis)),
    )
    return BRepBuilderAPI_Transform(local, placement, True).Shape()


def resolve_spring(
    part: Part, feature: SpringFeature, excluded_feature_ids: frozenset[str] = frozenset()
) -> TopoDS_Shape:
    """Fresh entry point for the router's create/update validation (self-excluding), as
    `app.document.rack.resolve_rack`."""
    bodies = compute_part_bodies(part, excluded_feature_ids | {feature.id})
    return resolve_spring_from_bodies(feature, part, bodies, excluded_feature_ids | {feature.id})
