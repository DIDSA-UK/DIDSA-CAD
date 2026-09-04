"""Measure tool: a stateless, read-only geometry query over 1-2 already-
picked sub-shapes - never a `Feature`, never mutates `Part`, no undo/redo
entry. Every other module in this package resolves a `SubShapeRef` in order
to *build* something (Fillet's edge_refs, Move Face's face group, ...); this
is the first to resolve one purely to *report* on it, so there is no
existing "compute-only" module to mirror wholesale - the resolution half
(`resolve_subshape_from_bodies`/`compute_part_bodies`) is reused verbatim
from `app.document.extrude`, and the geometry-property extraction half
repackages OCCT adaptor calls already proven elsewhere in this codebase
(`move_face.py`'s face-axis/outward-normal helpers, `pattern.py`'s circular-
edge-to-axis resolution) rather than inventing new OCCT usage patterns,
except for `BRepExtrema_DistShapeShape` (the two-entity minimum-distance
case) and the axis-to-axis skew/parallel-line distance formula, both new to
this codebase - see this module's own docstrings on `_measure_pair`/
`_axis_to_axis_distance` for why those two are safe additions.
"""

from dataclasses import dataclass

from fastapi import HTTPException
from OCC.Core.BRep import BRep_Tool
from OCC.Core.BRepAdaptor import BRepAdaptor_Curve, BRepAdaptor_Surface
from OCC.Core.BRepExtrema import BRepExtrema_DistShapeShape
from OCC.Core.BRepGProp import brepgprop
from OCC.Core.GeomAbs import GeomAbs_Circle, GeomAbs_Cylinder, GeomAbs_Plane
from OCC.Core.gp import gp_Ax1, gp_Pnt, gp_Vec
from OCC.Core.GProp import GProp_GProps
from OCC.Core.TopAbs import TopAbs_REVERSED
from OCC.Core.TopoDS import TopoDS_Face, TopoDS_Shape, topods

from app.document.extrude import compute_part_bodies, resolve_subshape_from_bodies
from app.document.models import Part, SubShapeRef, SubShapeType

# Same tolerances `move_face.py`'s `_axes_coincide` already uses to decide
# whether two independently-fit cylinder/cone axes are "the same infinite
# line" - reused here (not re-derived) for the parallel/non-parallel branch
# of `_axis_to_axis_distance`, which is answering a closely related
# question (are these two axes parallel at all, regardless of offset).
_AXIS_ANGULAR_TOLERANCE = 1e-4


@dataclass
class MeasurementResult:
    """Plain result type the router converts to `MeasurementResultSchema`.
    Every field is optional - which ones are populated depends on what was
    selected (see `_measure_single`/`_measure_pair`); this mirrors the
    schema's own "one flat, mostly-null response" shape, kept as a
    dataclass here rather than the pydantic model itself so this module has
    no wire-format/pydantic dependency of its own (consistent with every
    other domain-computation module in this package, which returns plain
    dataclasses/tuples and leaves schema conversion to `router.py`)."""

    point: tuple[float, float, float] | None = None
    length: float | None = None
    area: float | None = None
    radius: float | None = None
    diameter: float | None = None
    center: tuple[float, float, float] | None = None
    axis_origin: tuple[float, float, float] | None = None
    axis_direction: tuple[float, float, float] | None = None
    normal: tuple[float, float, float] | None = None
    point_on_face: tuple[float, float, float] | None = None
    distance: float | None = None
    point_a: tuple[float, float, float] | None = None
    point_b: tuple[float, float, float] | None = None
    delta: tuple[float, float, float] | None = None
    axis_distance: float | None = None
    axes_parallel: bool | None = None
    normal_distance: float | None = None
    faces_parallel: bool | None = None


def _measure_failed(refs: list[SubShapeRef]) -> HTTPException:
    """Mirrors `app.document.extrude._missing_reference`'s structured-422
    envelope exactly - the only other failure mode this endpoint can hit
    (`BRepExtrema_DistShapeShape` not converging is a genuinely rare,
    effectively-degenerate-input case; there is no recovery beyond telling
    the client the pair couldn't be measured)."""
    return HTTPException(
        status_code=422,
        detail={
            "type": "measure_failed",
            "refs": [{"body_id": r.body_id, "shape_type": r.shape_type.value, "index": r.index} for r in refs],
        },
    )


def _point(p: gp_Pnt) -> tuple[float, float, float]:
    return (p.X(), p.Y(), p.Z())


def _vec_tuple(v: gp_Vec) -> tuple[float, float, float]:
    return (v.X(), v.Y(), v.Z())


def _outward_normal(face: TopoDS_Face) -> gp_Vec:
    """`face`'s own plane normal, corrected for `Orientation()` - a
    `REVERSED` face's raw `BRepAdaptor_Surface` normal points *into* the
    solid, not out of it. Duplicated from `move_face.py`'s identical
    private helper of the same name rather than imported cross-module -
    that function is `_`-prefixed (module-private) and there is no existing
    precedent in this codebase for one module reaching into another's
    private helpers; six lines of duplication is cheaper than promoting it
    to a shared module for a single caller."""
    plane = BRepAdaptor_Surface(face, True).Plane()
    direction = plane.Axis().Direction()
    normal = gp_Vec(direction.X(), direction.Y(), direction.Z())
    if face.Orientation() == TopAbs_REVERSED:
        normal = normal.Reversed()
    return normal


def _face_surface_type(ref: SubShapeRef, shape: TopoDS_Shape):
    """The `GeomAbs_*` surface type of `shape`, or `None` if `ref` isn't a
    FACE at all - lets `_measure_pair` branch on "are both of these
    cylindrical faces?"/"are both of these planar faces?" without a
    face-ness check duplicated at every call site."""
    if ref.shape_type != SubShapeType.FACE:
        return None
    return BRepAdaptor_Surface(topods.Face(shape), True).GetType()


def _axis_to_axis_distance(a: gp_Ax1, b: gp_Ax1) -> tuple[float, bool]:
    """The minimum distance between two infinite 3D lines given as
    `gp_Ax1` (origin + direction), plus whether they're parallel - standard
    analytic-geometry formulas, not an OCCT-specific trick:

    Parallel (|d1 x d2| ~= 0, using the same angular tolerance `move_face.
    _axes_coincide` uses to answer the closely related "are these the same
    axis" question): the distance is the magnitude of the component of
    (p2 - p1) perpendicular to the shared direction.

    Skew or intersecting: distance = |(p2 - p1) . (d1 x d2)| / |d1 x d2|
    (the standard skew-line formula) - this also correctly evaluates to
    ~0 for two axes that are non-parallel but actually intersect (e.g. two
    holes whose axes cross), since then (p2-p1) is coplanar with d1/d2 and
    the scalar triple product vanishes.

    New, hand-derived code (unlike the rest of this module, which
    repackages already-proven OCCT calls) - covered by dedicated unit tests
    with hand-computed expected values (parallel-offset, perpendicular-skew,
    and intersecting cases) rather than relied on from first principles
    alone.
    """
    da, db = a.Direction(), b.Direction()
    va = gp_Vec(da.X(), da.Y(), da.Z())
    vb = gp_Vec(db.X(), db.Y(), db.Z())
    cross = va.Crossed(vb)

    la, lb = a.Location(), b.Location()
    w = gp_Vec(lb.X() - la.X(), lb.Y() - la.Y(), lb.Z() - la.Z())

    if cross.Magnitude() <= _AXIS_ANGULAR_TOLERANCE:
        va_unit = va.Normalized()
        perpendicular = w - va_unit.Multiplied(w.Dot(va_unit))
        return perpendicular.Magnitude(), True

    distance = abs(w.Dot(cross)) / cross.Magnitude()
    return distance, False


def _measure_single(ref: SubShapeRef, shape: TopoDS_Shape) -> MeasurementResult:
    if ref.shape_type == SubShapeType.VERTEX:
        pnt = BRep_Tool.Pnt(topods.Vertex(shape))
        return MeasurementResult(point=_point(pnt))

    if ref.shape_type == SubShapeType.EDGE:
        edge = topods.Edge(shape)
        curve = BRepAdaptor_Curve(edge)
        props = GProp_GProps()
        brepgprop.LinearProperties(edge, props)
        length = props.Mass()
        if curve.GetType() == GeomAbs_Circle:
            circle = curve.Circle()
            axis = circle.Axis()
            return MeasurementResult(
                length=length,
                radius=circle.Radius(),
                diameter=circle.Radius() * 2,
                center=_point(circle.Location()),
                axis_origin=_point(axis.Location()),
                axis_direction=_vec_tuple(gp_Vec(axis.Direction().X(), axis.Direction().Y(), axis.Direction().Z())),
            )
        return MeasurementResult(length=length)

    # ref.shape_type == SubShapeType.FACE (the only remaining case - the
    # SubShapeType enum has exactly these three members).
    face = topods.Face(shape)
    surf = BRepAdaptor_Surface(face, True)
    props = GProp_GProps()
    brepgprop.SurfaceProperties(face, props)
    area = props.Mass()

    if surf.GetType() == GeomAbs_Cylinder:
        cylinder = surf.Cylinder()
        axis = cylinder.Axis()
        return MeasurementResult(
            area=area,
            radius=cylinder.Radius(),
            diameter=cylinder.Radius() * 2,
            axis_origin=_point(axis.Location()),
            axis_direction=_vec_tuple(gp_Vec(axis.Direction().X(), axis.Direction().Y(), axis.Direction().Z())),
        )

    if surf.GetType() == GeomAbs_Plane:
        plane = surf.Plane()
        normal = _outward_normal(face)
        return MeasurementResult(area=area, normal=_vec_tuple(normal), point_on_face=_point(plane.Location()))

    return MeasurementResult(area=area)


def _point_to_plane_distance(face_a: TopoDS_Face, face_b: TopoDS_Face, normal_a: gp_Vec) -> float:
    """The distance between two *parallel* planar faces' own planes -
    projects the vector between each plane's own representative point
    (`Plane().Location()`) onto the shared normal. Deliberately NOT the
    same as the generic `BRepExtrema_DistShapeShape` minimum distance
    whenever the two faces' footprints don't overlap (that would include
    the lateral offset too, via Pythagoras) - this is the "how far apart
    are these two faces" a CAD user actually means by wall thickness/gap,
    independent of how much of each face's own bounded area is directly
    across from the other."""
    origin_a = BRepAdaptor_Surface(face_a, True).Plane().Location()
    origin_b = BRepAdaptor_Surface(face_b, True).Plane().Location()
    between = gp_Vec(origin_b.X() - origin_a.X(), origin_b.Y() - origin_a.Y(), origin_b.Z() - origin_a.Z())
    return abs(between.Dot(normal_a.Normalized()))


def _directions_parallel(a: gp_Vec, b: gp_Vec) -> bool:
    return a.Crossed(b).Magnitude() <= _AXIS_ANGULAR_TOLERANCE


def _measure_pair(
    ref_a: SubShapeRef, shape_a: TopoDS_Shape, ref_b: SubShapeRef, shape_b: TopoDS_Shape
) -> MeasurementResult:
    """Always computes the generic minimum-distance/closest-points/delta
    answer first (works for every combination of vertex/edge/face), then
    layers a named result (axis distance, normal distance) on top only
    when a specific geometric relationship is actually detected - per the
    product requirement, there is no "unsupported combination" error for
    two entities; every pair gets at least the generic fields."""
    extrema = BRepExtrema_DistShapeShape(shape_a, shape_b)
    if not extrema.IsDone() or extrema.NbSolution() < 1:
        raise _measure_failed([ref_a, ref_b])

    distance = extrema.Value()
    p1, p2 = extrema.PointOnShape1(1), extrema.PointOnShape2(1)
    delta = (p2.X() - p1.X(), p2.Y() - p1.Y(), p2.Z() - p1.Z())

    result = MeasurementResult(
        distance=distance,
        point_a=_point(p1),
        point_b=_point(p2),
        delta=delta,
    )

    surf_a, surf_b = _face_surface_type(ref_a, shape_a), _face_surface_type(ref_b, shape_b)

    if surf_a == GeomAbs_Cylinder and surf_b == GeomAbs_Cylinder:
        axis_a = BRepAdaptor_Surface(topods.Face(shape_a), True).Cylinder().Axis()
        axis_b = BRepAdaptor_Surface(topods.Face(shape_b), True).Cylinder().Axis()
        result.axis_distance, result.axes_parallel = _axis_to_axis_distance(axis_a, axis_b)

    elif surf_a == GeomAbs_Plane and surf_b == GeomAbs_Plane:
        face_a, face_b = topods.Face(shape_a), topods.Face(shape_b)
        normal_a = _outward_normal(face_a)
        normal_b = _outward_normal(face_b)
        if _directions_parallel(normal_a, normal_b):
            result.normal_distance = _point_to_plane_distance(face_a, face_b, normal_a)
            result.faces_parallel = True

    return result


def measure(
    part: Part, refs: list[SubShapeRef], excluded_feature_ids: frozenset[str] = frozenset()
) -> MeasurementResult:
    """Entry point for `router.measure_entities` - `refs` must already be
    validated as length 1 or 2 (the router's job, mirroring every other
    endpoint's "payload shape in the router, resolution in here" split).
    Resolves every ref against one shared `compute_part_bodies` snapshot so
    two refs into two different Bodies still see a mutually consistent
    Part state, then dispatches on how many entities were selected. Raises
    the existing `missing_reference` 422 (via `resolve_subshape_from_bodies`)
    if any ref no longer resolves."""
    bodies = compute_part_bodies(part, excluded_feature_ids)
    shapes = [resolve_subshape_from_bodies(bodies, ref) for ref in refs]
    if len(shapes) == 1:
        return _measure_single(refs[0], shapes[0])
    return _measure_pair(refs[0], shapes[0], refs[1], shapes[1])
