"""OCCT geometry construction for `RackFeature`
(`docs/gear-design/03-rack.md`) - the OCCT-dependent half of
`app.document.gear_math`'s pure math. Unlike `app.document.gear`, every
edge of a rack's profile is a straight line (no involute/BSpline curve
fitting needed at all - see `docs/gear-design/01-gear-math-core.md`'s own
"genuinely different math... not a variant" framing), so this is a much
simpler `BRepBuilderAPI_MakePolygon` construction - the same primitive
`app.document.extrude.wire_for_profile` already uses for a plain
Line-chain Sketch profile.

**Verification status**: see `app.document.gear`'s own module docstring
for this project's general OCCT-verification caveat in this sandbox -
applies here too, modulo whatever real-OCCT testing has actually run by
the time this is read (check `docs/status.md`'s own dated entries).
"""

from fastapi import HTTPException
from OCC.Core.BRepBuilderAPI import BRepBuilderAPI_MakeFace, BRepBuilderAPI_MakePolygon
from OCC.Core.BRepPrimAPI import BRepPrimAPI_MakePrism
from OCC.Core.gp import gp_Vec
from OCC.Core.TopoDS import TopoDS_Shape

from app.document.create_plane import resolve_plane_ref
from app.document.extrude import basis_normal, basis_point_to_world, compute_part_bodies
from app.document.gear_math import (
    GearGeometryError,
    default_rack_backing_height,
    full_rack_profile_points,
    rack_tooth_geometry,
)
from app.document.models import Part, RackFeature, ResolvedPlane


def _invalid_rack_parameters(detail: str) -> HTTPException:
    """A rack parameter combination `gear_math` itself rejects, or a
    resolved `backing_height` that isn't positive - mirrors
    `app.document.gear._invalid_gear_parameters`'s own convention."""
    return HTTPException(status_code=422, detail={"type": "invalid_rack_parameters", "detail": detail})


def _rack_failed(detail: str) -> HTTPException:
    """A structurally-valid rack that OCCT nonetheless couldn't build -
    mirrors `app.document.gear._gear_failed`'s own convention."""
    return HTTPException(status_code=422, detail={"type": "rack_failed", "detail": detail})


def rack_outline_points(
    *, module: float, tooth_count: int, pressure_angle_degrees: float, backlash: float, backing_height: float | None
) -> list[tuple[float, float]]:
    """The rack's full closed 2D outline in the plane's own local (x, y):
    the toothed top edge (`full_rack_profile_points`) plus two more points
    closing a solid backing rectangle beneath it (bottom-right, bottom-
    left - `BRepBuilderAPI_MakePolygon.Close()` draws the final closing
    edge back to the first point, so only these two extra corners are
    needed, not all four).

    Takes plain params rather than a whole `RackFeature` (`resolve_rack_
    from_bodies`'s original shape) so `docs/gear-design/05-gear-chain-and-
    planetary.md`'s `GearChainFeature` can reuse this for one rack chain
    member at a time, which has no `RackFeature` of its own to pass -
    mirrors `app.document.gear._gear_face`'s identical "promote to an
    explicit-params helper once a second caller needs it" refactor."""
    try:
        rack_geometry = rack_tooth_geometry(
            module=module,
            pressure_angle_degrees=pressure_angle_degrees,
            backlash=backlash,
        )
        tooth_points = full_rack_profile_points(rack_geometry, tooth_count)
    except GearGeometryError as exc:
        raise _invalid_rack_parameters(str(exc)) from exc

    resolved_backing_height = backing_height if backing_height is not None else default_rack_backing_height(module)
    if resolved_backing_height <= 0:
        raise _invalid_rack_parameters(f"backing_height must be positive, got {resolved_backing_height!r}")

    min_x = min(x for x, _ in tooth_points)
    max_x = max(x for x, _ in tooth_points)
    bottom_y = -rack_geometry.dedendum_height - resolved_backing_height
    return [*tooth_points, (max_x, bottom_y), (min_x, bottom_y)]


def prism_solid_from_outline(basis: ResolvedPlane, outline_points: list[tuple[float, float]], depth: float) -> TopoDS_Shape:
    """Builds a closed straight-edged polygon from `outline_points` (local
    (x, y) in `basis`'s own frame) and extrudes it `depth` along `basis`'s
    normal - the wire/face/prism construction shared by `resolve_rack_from_
    bodies` below and `app.document.gear_chain`'s own rack chain members."""
    polygon_maker = BRepBuilderAPI_MakePolygon()
    for x, y in outline_points:
        polygon_maker.Add(basis_point_to_world(basis, x, y))
    polygon_maker.Close()
    wire = polygon_maker.Wire()

    face_maker = BRepBuilderAPI_MakeFace(wire)
    if not face_maker.IsDone():
        raise _rack_failed("could not build a face from the rack's own outline")
    face = face_maker.Face()

    normal = basis_normal(basis)
    prism_vector = gp_Vec(normal.X(), normal.Y(), normal.Z()).Multiplied(depth)
    return BRepPrimAPI_MakePrism(face, prism_vector).Shape()


def resolve_rack_from_bodies(
    feature: RackFeature,
    part: Part,
    bodies: dict[str, TopoDS_Shape],
    excluded_feature_ids: frozenset[str],
) -> TopoDS_Shape:
    """The real OCCT solid for one `RackFeature` - mirrors
    `app.document.gear.resolve_gear_from_bodies`'s overall shape (raises a
    structured `HTTPException` rather than returning `None`: no backing
    Sketch means no "temporarily has nothing to build" state to
    tolerate, same reasoning as `GearFeature`)."""
    if feature.face_width <= 0:
        raise _invalid_rack_parameters(f"face_width must be positive, got {feature.face_width!r}")

    outline_points = rack_outline_points(
        module=feature.module,
        tooth_count=feature.tooth_count,
        pressure_angle_degrees=feature.pressure_angle_degrees,
        backlash=feature.backlash,
        backing_height=feature.backing_height,
    )
    basis: ResolvedPlane = resolve_plane_ref(part, bodies, feature.plane_ref, excluded_feature_ids)
    return prism_solid_from_outline(basis, outline_points, feature.face_width)


def resolve_rack(
    part: Part, feature: RackFeature, excluded_feature_ids: frozenset[str] = frozenset()
) -> TopoDS_Shape:
    """Fresh entry point for the router's create/update validation -
    mirrors `app.document.gear.resolve_gear`'s exact shape (self-excluding,
    computes `bodies` as if `feature` weren't in `part.features` yet)."""
    bodies = compute_part_bodies(part, excluded_feature_ids | {feature.id})
    return resolve_rack_from_bodies(feature, part, bodies, excluded_feature_ids | {feature.id})
