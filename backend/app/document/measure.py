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
from OCC.Core.BRepBuilderAPI import BRepBuilderAPI_MakeVertex
from OCC.Core.BRepExtrema import BRepExtrema_DistShapeShape
from OCC.Core.BRepGProp import brepgprop
from OCC.Core.GeomAbs import GeomAbs_Circle, GeomAbs_Cylinder, GeomAbs_Line, GeomAbs_Plane
from OCC.Core.gp import gp_Ax1, gp_Pnt, gp_Vec
from OCC.Core.GProp import GProp_GProps
from OCC.Core.TopAbs import TopAbs_REVERSED
from OCC.Core.TopoDS import TopoDS_Face, TopoDS_Shape, topods

from app.document.assembly import resolve_occurrence_target
from app.document.extrude import apply_rigid_transform_to_shape, compute_part_bodies, resolve_subshape_from_bodies
from app.document.models import Document, MeasureEntityRef, Part, SubShapeRef, SubShapeType

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
    selected (see `single_shape_geometry`/`_measure_pair`); this mirrors the
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
    # Phase 6: reused by `app.document.assembly_solver` as "a representative
    # point on the referenced planar face" for point-in-plane/point-plane-
    # distance mate constraints - identical meaning to its original Measure
    # tool use, no new field needed.
    point_on_face: tuple[float, float, float] | None = None
    distance: float | None = None
    point_a: tuple[float, float, float] | None = None
    point_b: tuple[float, float, float] | None = None
    delta: tuple[float, float, float] | None = None
    axis_distance: float | None = None
    axes_parallel: bool | None = None
    normal_distance: float | None = None
    faces_parallel: bool | None = None
    # Volume/mass of every *distinct* Body among the 1-2 refs, keyed by Body
    # id - populated regardless of whether a ref's own shape_type is BODY
    # (selecting a face still reports its owning Body's volume/mass), so a
    # 2-ref measurement spanning two different Bodies can carry up to two
    # entries. `body_masses` only ever carries an entry for a Body that has
    # a resolvable material (per-Body override, else the Part's own default -
    # see `app.document.models.Part.default_material`/
    # `body_material_assignments`); a Body with no material assigned is
    # simply absent from `body_masses`, not present with a null/zero value.
    body_volumes: dict[str, float] | None = None
    body_masses: dict[str, float] | None = None


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


def _missing_occurrence(occurrence_id: str) -> HTTPException:
    """Assembly-testing bug fix: mirrors `app.document.extrude.
    _missing_reference`'s `missing_reference` envelope - a
    `MeasureEntityRef.occurrence_id` that doesn't resolve to a real,
    top-level Occurrence of the open Part is exactly as much "the client's
    picked reference no longer exists" as a stale `body_id`/`index` is, so
    it gets the same `type` rather than a new one the client would need a
    separate case for."""
    return HTTPException(status_code=422, detail={"type": "missing_reference", "occurrence_id": occurrence_id})


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


def _circle_center_shape(ref: SubShapeRef, shape: TopoDS_Shape) -> TopoDS_Shape | None:
    """Bug fix (assembly testing: "when the user selects a diameter or arc
    and another entity ... it should measure to/from the centre point, e.g.
    when measuring distance between hole centres"): `None` unless `ref` is a
    circular EDGE (a circle or arc - the only case with a well-defined,
    bounded centre point; a cylindrical FACE's own "axis" is infinite, with
    no single centre point of its own, so is deliberately left out of scope
    here - it keeps its existing axis-based `axis_distance` treatment in
    `_measure_pair` instead), in which case returns a synthetic zero-size
    vertex `TopoDS_Shape` at that circle's own centre
    (`BRepAdaptor_Curve.Circle().Location()`, the same point
    `single_shape_geometry`'s own circular-edge case already reports as
    `center`). Building a real vertex Shape (rather than hand-rolling a
    point-to-shape distance) lets `_measure_pair` reuse the exact same
    `BRepExtrema_DistShapeShape` call it already makes for the generic case,
    substituting this centre vertex in place of the circular edge itself -
    correct for every pairing (vertex, straight edge, planar/cylindrical
    face, or another circle) with no separate formula needed."""
    if ref.shape_type != SubShapeType.EDGE:
        return None
    curve = BRepAdaptor_Curve(topods.Edge(shape))
    if curve.GetType() != GeomAbs_Circle:
        return None
    return BRepBuilderAPI_MakeVertex(curve.Circle().Location()).Shape()


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


def single_shape_geometry(ref: SubShapeRef, shape: TopoDS_Shape) -> MeasurementResult:
    """Renamed from `_measure_single` (Phase 6, `docs/assembly-scope.md`
    §3) - promoted to public since `app.document.assembly_solver` needs
    the exact same point/normal/axis extraction a mate's `SubShapeRef`
    resolves to (a vertex's point, a circular edge's or cylindrical face's
    own fitted axis, a planar face's normal + a point on it) that this
    function already provides, mirroring how `app.document.create_plane.
    resolve_plane_ref` was itself promoted public for the same
    cross-module-reuse reason. Behavior is unchanged - only the name and
    its `measure()` call site below moved."""
    if ref.shape_type == SubShapeType.BODY:
        # No single-entity field of its own - the whole-Body volume/mass
        # rides on `body_volumes`/`body_masses` instead (populated by
        # `measure()` for every distinct body among the refs, whether or not
        # any ref's own shape_type is BODY), so a direct Body selection
        # reports identically to selecting one of its faces/edges/vertices.
        return MeasurementResult()

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
        if curve.GetType() == GeomAbs_Line:
            # Phase 13 (`docs/assembly-scope.md` §6 `[15]`): a straight
            # edge's own infinite-line direction + a point on it (the same
            # `gp_Lin`-shaped `Location()`/`Direction()` pair a circular
            # edge's `gp_Ax1` axis already reports above) - `app.document.
            # create_plane._resolve_normal_to_edge_through_vertex`/`app.
            # document.pattern`'s identical `curve.Line()` idiom, promoted
            # here so `assembly_solver.py`'s CONCENTRIC/PARALLEL/ANGLE mate
            # dispatch (already direction-agnostic to circle-vs-line - see
            # that module's own docstring) can resolve a straight-edge mate
            # reference the exact same way it already resolves a circular
            # one, through this one shared function.
            line = curve.Line()
            direction = line.Direction()
            return MeasurementResult(
                length=length,
                axis_origin=_point(line.Location()),
                axis_direction=_vec_tuple(gp_Vec(direction.X(), direction.Y(), direction.Z())),
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
    two entities; every pair gets at least the generic fields.

    Bug fix: when either (or both) operand is a circular edge (circle/arc),
    the generic `BRepExtrema_DistShapeShape` result above - the *nearest rim
    point* on that circle, wherever the other entity happens to sit - is
    replaced with a distance/points computed from that circle's own centre
    instead (see `_circle_center_shape`'s own doc comment). Two circular
    edges paired together measure true centre-to-centre (e.g. "distance
    between hole centres"); a circle paired with anything else (a vertex, a
    straight edge, a face) measures from its centre to that other entity's
    own nearest point. A cylindrical face is unaffected - it keeps its
    existing axis-based `axis_distance` treatment below, not this centre
    substitution."""
    extrema = BRepExtrema_DistShapeShape(shape_a, shape_b)
    if not extrema.IsDone() or extrema.NbSolution() < 1:
        raise _measure_failed([ref_a, ref_b])

    distance = extrema.Value()
    p1, p2 = extrema.PointOnShape1(1), extrema.PointOnShape2(1)
    delta = (p2.X() - p1.X(), p2.Y() - p1.Y(), p2.Z() - p1.Z())

    center_shape_a = _circle_center_shape(ref_a, shape_a)
    center_shape_b = _circle_center_shape(ref_b, shape_b)
    if center_shape_a is not None or center_shape_b is not None:
        center_extrema = BRepExtrema_DistShapeShape(
            center_shape_a if center_shape_a is not None else shape_a,
            center_shape_b if center_shape_b is not None else shape_b,
        )
        if center_extrema.IsDone() and center_extrema.NbSolution() >= 1:
            distance = center_extrema.Value()
            p1, p2 = center_extrema.PointOnShape1(1), center_extrema.PointOnShape2(1)
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


def _mass_grams(volume_mm3: float, density_g_cm3: float) -> float:
    """`volume_mm3 * density_g_cm3 * 0.001` - 1 cm^3 == 1000 mm^3, so
    density in g/cm^3 is 0.001 g/mm^3. The one mass formula used everywhere
    this app computes mass (Measure, the mass-properties endpoint, STEP
    export's validation properties) - see `docs/dxf-io/00-conventions.md`'s
    "implicitly all-mm" note for why volume always arrives in mm^3."""
    return volume_mm3 * density_g_cm3 * 0.001


def _body_volumes_and_masses(
    part: Part, bodies: dict[str, TopoDS_Shape], body_ids: set[str]
) -> tuple[dict[str, float], dict[str, float]]:
    """Volume (mm^3) for every id in `body_ids` that still resolves in
    `bodies`, plus mass (g) for whichever of those also have a resolvable
    material (`Part.resolve_material`) - a Body with no material assigned
    is simply absent from the mass dict, not present with a null/zero
    value."""
    volumes: dict[str, float] = {}
    masses: dict[str, float] = {}
    for body_id in body_ids:
        body = bodies.get(body_id)
        if body is None:
            continue
        props = GProp_GProps()
        brepgprop.VolumeProperties(body, props)
        volume = abs(props.Mass())
        volumes[body_id] = volume

        material = part.resolve_material(body_id)
        if material is not None:
            masses[body_id] = _mass_grams(volume, material.density_g_cm3)
    return volumes, masses


def mass_properties(part: Part) -> tuple[dict[str, float], dict[str, float]]:
    """`(body_volumes, body_masses)` for *every* current Body in `part` -
    the `GET /parts/{part_id}/mass-properties` endpoint's own entry point,
    powering the Part Properties screen's Mass field. Deliberately its own
    explicit, on-demand call (not folded into the cheap `GET /parts/
    {part_id}`) since it requires a full `compute_part_bodies` geometry
    recompute, same reasoning `measure()` itself already has for why this
    isn't free."""
    bodies = compute_part_bodies(part)
    return _body_volumes_and_masses(part, bodies, set(bodies.keys()))


def measure(
    document: Document,
    part: Part,
    refs: list[MeasureEntityRef],
    excluded_feature_ids: frozenset[str] = frozenset(),
) -> MeasurementResult:
    """Entry point for `router.measure_entities` - `refs` must already be
    validated as length 1 or 2 (the router's job, mirroring every other
    endpoint's "payload shape in the router, resolution in here" split).

    Assembly-testing bug fix: each ref now carries its own `occurrence_id`
    (mirroring `app.document.assembly_solver`'s identical need), resolved
    via the shared `app.document.assembly.resolve_occurrence_target` -
    `""` means `part`'s own root content (the pre-existing, single-Part
    behavior, unchanged), non-empty means a placed Occurrence's target Part,
    whose local geometry is then placed into world space
    (`app.document.extrude.apply_rigid_transform_to_shape`) before measuring, so two refs picked on two
    *different* Occurrences still measure a real, physically-meaningful
    relationship (e.g. the true distance between them) rather than mixing
    two unrelated local frames. `excluded_feature_ids` only ever applies to
    `part`'s own root content (a live feature-editing preview's own
    in-progress Part) - it would not be meaningful against an unrelated
    Occurrence's target Part. Raises `missing_reference` (422) if any ref's
    `occurrence_id` doesn't resolve (`_missing_occurrence`) or its
    `body_id`/`index` doesn't (the existing `resolve_subshape_from_bodies`
    behavior, unchanged).

    Bodies are still resolved through one shared `compute_part_bodies`
    snapshot per distinct target Part (not once per ref) - two refs into
    the same Occurrence's target Part (or both into `part`'s own root
    content) still see a mutually consistent state, exactly like the
    pre-existing single-Part behavior."""
    bodies_by_part_id: dict[str, tuple[Part, dict[str, TopoDS_Shape]]] = {}
    resolved: list[tuple[SubShapeRef, TopoDS_Shape]] = []
    ref_target_part_ids: list[str] = []
    for ref in refs:
        try:
            target_part, transform = resolve_occurrence_target(document, part, ref.occurrence_id)
        except KeyError:
            raise _missing_occurrence(ref.occurrence_id) from None
        cached = bodies_by_part_id.get(target_part.id)
        if cached is None:
            part_excluded_feature_ids = excluded_feature_ids if target_part is part else frozenset()
            target_bodies = compute_part_bodies(target_part, part_excluded_feature_ids)
            bodies_by_part_id[target_part.id] = (target_part, target_bodies)
        else:
            _, target_bodies = cached
        local_shape = resolve_subshape_from_bodies(target_bodies, ref.subshape_ref)
        shape = local_shape if transform is None else apply_rigid_transform_to_shape(local_shape, transform)
        resolved.append((ref.subshape_ref, shape))
        ref_target_part_ids.append(target_part.id)

    if len(resolved) == 1:
        result = single_shape_geometry(resolved[0][0], resolved[0][1])
    else:
        result = _measure_pair(resolved[0][0], resolved[0][1], resolved[1][0], resolved[1][1])

    # Also always computes `body_volumes`/`body_masses` for every *distinct*
    # Body among `refs` (regardless of whether any ref's own shape_type is
    # BODY - selecting a face still reports its owning Body's volume/mass),
    # grouped by whichever target Part each ref actually resolved against -
    # unchanged from the pre-existing single-Part behavior when every ref
    # shares one target Part (the overwhelmingly common case).
    body_volumes: dict[str, float] = {}
    body_masses: dict[str, float] = {}
    body_ids_by_part_id: dict[str, set[str]] = {}
    for ref, target_part_id in zip(refs, ref_target_part_ids):
        body_ids_by_part_id.setdefault(target_part_id, set()).add(ref.subshape_ref.body_id)
    for target_part_id, body_ids in body_ids_by_part_id.items():
        target_part, target_bodies = bodies_by_part_id[target_part_id]
        volumes, masses = _body_volumes_and_masses(target_part, target_bodies, body_ids)
        body_volumes.update(volumes)
        body_masses.update(masses)
    result.body_volumes, result.body_masses = body_volumes, body_masses
    return result
