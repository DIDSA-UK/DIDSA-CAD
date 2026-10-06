"""OCCT geometry for CreatePlaneFeature's OFFSET_FACE/MIDPLANE cases (C2/C3)
- the only plane-construction methods that need a real OCCT environment,
since checking a face is planar (BRepAdaptor_Surface(face).GetType() ==
GeomAbs_Plane) has no pure-Python equivalent. See app.document.plane_geometry
for the NORMAL_TO_LINE_AT_POINT case, which needs no OCCT of its own (though,
since C3, resolving *this* module's `resolve_sketch_basis` for a Sketch
anchored to a custom plane does) - kept in a separate module for exactly that
reason, mirroring the existing app.document.extrude / app.sketch.store split
by OCCT dependency.

C5: `OFFSET_FACE`/`MIDPLANE`/`PARALLEL_TO_FACE_THROUGH_VERTEX` no longer
require a Body face specifically - `resolve_plane_ref` dispatches a
`PlaneRef` to whichever of a Body face (still OCCT, via `_resolve_planar_
face`), a fixed reference plane, or an existing Plane it actually names, so
this module's own resolvers work against a single, uniform `ResolvedPlane`
regardless of which kind of reference they were given.

C3 also splits every resolver here into a `_from_bodies` core (accepts an
already-computed `bodies` dict, never recomputes) plus a "fresh" wrapper
(computes `bodies` once via `compute_part_bodies`) - needed because `app.
document.extrude._solid_for_extrude_feature` now calls into this module
(via `resolve_sketch_basis`, function-local import to break the circular
import this module's own module-level `from app.document.extrude import
resolve_subshape` would otherwise create) *from inside* `compute_part_
bodies`'s own topological-order loop, using its in-progress `bodies`
accumulator - calling back into a fresh top-level `compute_part_bodies`
there would recurse forever.

C3 also splits every resolver here into a `_from_bodies` core (accepts an
already-computed `bodies` dict, never recomputes) plus a "fresh" wrapper
(computes `bodies` once via `compute_part_bodies`) - needed because `app.
document.extrude._solid_for_extrude_feature` now calls into this module
(via `resolve_sketch_basis`, function-local import to break the circular
import this module's own module-level `from app.document.extrude import
resolve_subshape` would otherwise create) *from inside* `compute_part_
bodies`'s own topological-order loop, using its in-progress `bodies`
accumulator - calling back into a fresh top-level `compute_part_bodies`
there would recurse forever.
"""

import math
from dataclasses import replace
from typing import TYPE_CHECKING

from fastapi import HTTPException
from OCC.Core.BRep import BRep_Tool
from OCC.Core.BRepAdaptor import BRepAdaptor_Curve, BRepAdaptor_Surface
from OCC.Core.GeomAbs import GeomAbs_Line, GeomAbs_Plane
from OCC.Core.gp import gp_Pnt
from OCC.Core.TopAbs import TopAbs_REVERSED
from OCC.Core.TopoDS import TopoDS_Shape, topods

from app.document.extrude import compute_part_bodies, resolve_subshape_from_bodies
from app.document.graph import sketch_feature_id_for_sketch
from app.document.models import (
    CreatePlaneFeature,
    Part,
    PlaneRef,
    PlaneType,
    PointRef,
    ResolvedPlane,
    SketchFeature,
    SubShapeRef,
    SubShapeType,
)
from app.document.plane_geometry import (
    apply_orientation,
    arbitrary_perpendicular_basis,
    basis_point,
    oriented_basis_for_plane,
    resolve_normal_to_arc_at_point,
    resolve_normal_to_line_at_point,
    resolve_three_points,
    sketch_basis_for_plane,
    world_point_to_basis,
)
from app.document.reference_signature import BodyVertexMeasurer, measurer_for
from app.sketch.constraints import DistanceConstraint
from app.sketch.models import Arc, Circle, ExternalVertexReference, Point, Sketch
from app.sketch.reference_signature import (
    SEARCH_TOLERANCE_REL,
    LineageOrigin,
    ReferenceDecision,
    ReferenceStatus,
    NORMAL_TOLERANCE_DEGREES,
    ShapeSignature,
    decide_reference,
    fingerprint_matches,
    shape_distance,
)
from app.sketch.store import get_sketch_or_404, resolve_sketch_entity

if TYPE_CHECKING:
    from app.document.reference_history import ReferenceHistory


def _non_planar_reference(ref: SubShapeRef) -> HTTPException:
    """C2: structured 422, same envelope B1/C1 already established for
    `missing_reference`, for an OFFSET_FACE/MIDPLANE `face_refs` entry that
    resolves to a real face but not a planar one - rejecting rather than
    silently taking a tangent plane at some arbitrary point on a curved
    surface."""
    return HTTPException(
        status_code=422,
        detail={"type": "non_planar_reference", "body_id": ref.body_id, "index": ref.index},
    )


def _describe_plane_ref(ref: PlaneRef) -> dict:
    """C5: a small JSON-safe description of whichever of `ref`'s three
    kinds is set, for embedding in a structured error - a single
    (body_id, index) pair can no longer describe every `face_refs` entry,
    now that one can be a fixed reference plane or an existing Plane
    instead of a Body face."""
    if ref.face_ref is not None:
        return {"kind": "face", "body_id": ref.face_ref.body_id, "index": ref.face_ref.index}
    if ref.fixed_plane is not None:
        return {"kind": "fixed_plane", "plane": ref.fixed_plane.value}
    assert ref.plane_feature_id is not None
    return {"kind": "create_plane", "feature_id": ref.plane_feature_id}


def _faces_not_parallel(ref_a: PlaneRef, ref_b: PlaneRef) -> HTTPException:
    """C3/C5: structured 422 for a MIDPLANE whose two `face_refs` do not
    resolve to parallel planes - a midplane is only meaningful between two
    references that face each other (or away from each other) along a
    shared normal direction; anything else has no single well-defined
    equidistant plane. C5: `ref_a`/`ref_b` describe whichever of a face, a
    fixed plane, or an existing Plane each entry actually was (see
    `_describe_plane_ref`) - the error detail shape changed from C3's
    Body-face-only `body_id_a`/`index_a`/`body_id_b`/`index_b` fields to
    accommodate that; nothing in this project's client inspects those
    fields individually (only `type`), so this is not a breaking change in
    practice."""
    return HTTPException(
        status_code=422,
        detail={
            "type": "faces_not_parallel",
            "ref_a": _describe_plane_ref(ref_a),
            "ref_b": _describe_plane_ref(ref_b),
        },
    )


def _non_linear_edge(ref: SubShapeRef) -> HTTPException:
    """C4: structured 422, same envelope as `_non_planar_reference`, for a
    `NORMAL_TO_EDGE_THROUGH_VERTEX` `edge_ref` that resolves to a real edge
    but not a straight one - a curved edge has no single well-defined
    direction to be normal to."""
    return HTTPException(
        status_code=422,
        detail={"type": "non_linear_edge", "body_id": ref.body_id, "index": ref.index},
    )


def _resolve_vertex_position(bodies: dict[str, TopoDS_Shape], ref: SubShapeRef) -> gp_Pnt:
    """C4: `ref`'s world-space position - shared by every plane-construction
    method that references a Body vertex (`NORMAL_TO_EDGE_THROUGH_VERTEX`,
    `PARALLEL_TO_FACE_THROUGH_VERTEX`, `THREE_POINTS`'s own `PointRef.
    vertex_ref`). Fails closed with `missing_reference` via `resolve_
    subshape_from_bodies`, same as every other `SubShapeRef` resolution."""
    shape = resolve_subshape_from_bodies(bodies, ref)
    vertex = topods.Vertex(shape)
    return BRep_Tool.Pnt(vertex)


def _resolve_planar_face(bodies: dict[str, TopoDS_Shape], ref: SubShapeRef) -> ResolvedPlane:
    """The full natural frame (origin, normal, x_axis, y_axis) OCCT's own
    `gp_Ax3` already derives for a planar face's underlying surface -
    corrected for `TopAbs_REVERSED` (a face's `Orientation()` can flip its
    effective normal without changing the underlying surface, same quirk
    `app.document.extrude._wire_normal` already handles). When `normal` is
    flipped, `y_axis` is flipped too (not `x_axis`) to keep `normal ==
    x_axis cross y_axis` - a genuinely arbitrary, brand-new plane derived
    fresh from real OCCT geometry has no pre-existing in-plane convention to
    preserve (unlike the fixed XY/XZ/YZ planes - see `app.document.plane_
    geometry`'s own docstring for why *those* use an explicit lookup table
    instead of trusting a formula), so trusting `gp_Ax3`'s own XDirection/
    YDirection here, with this one sign correction, is both correct and the
    simplest option.

    C5: returns a `ResolvedPlane` (plain float tuples) rather than the four
    raw OCCT `gp_Pnt`/`gp_Dir` values it used to - every caller now also
    needs to combine this with `resolve_plane_ref`'s other two, OCCT-free
    branches (a fixed reference plane, an existing Plane), so converting at
    this one boundary lets every caller work against the same plain-tuple
    `ResolvedPlane` shape regardless of which kind of reference it got."""
    shape = resolve_subshape_from_bodies(bodies, ref)
    face = topods.Face(shape)
    surface = BRepAdaptor_Surface(face, True)
    if surface.GetType() != GeomAbs_Plane:
        raise _non_planar_reference(ref)

    plane = surface.Plane()
    position = plane.Position()
    location = position.Location()
    normal = position.Direction()
    x_axis = position.XDirection()
    y_axis = position.YDirection()
    if face.Orientation() == TopAbs_REVERSED:
        normal = normal.Reversed()
        y_axis = y_axis.Reversed()
    return ResolvedPlane(
        origin=(location.X(), location.Y(), location.Z()),
        normal=(normal.X(), normal.Y(), normal.Z()),
        x_axis=(x_axis.X(), x_axis.Y(), x_axis.Z()),
        y_axis=(y_axis.X(), y_axis.Y(), y_axis.Z()),
    )


def resolve_plane_ref(
    part: Part,
    bodies: dict[str, TopoDS_Shape],
    ref: PlaneRef,
    excluded_feature_ids: frozenset[str],
) -> ResolvedPlane:
    """C5: `ref`'s own resolved plane, regardless of which of its three
    kinds is set - a Body face (OCCT, `_resolve_planar_face`), a fixed
    reference plane (pure Python, `sketch_basis_for_plane`), or an existing
    Plane (recursive `resolve_create_plane_from_bodies`, against the same
    `bodies` accumulator - never a fresh `compute_part_bodies` call, same
    "would recurse forever from inside `compute_part_bodies`'s own loop"
    reasoning this module's own docstring already gives for
    `basis_for_sketch`). A cycle (a Plane transitively referencing itself)
    is structurally impossible: a `plane_feature_id` can only ever name a
    Feature created *before* this one, and Feature creation is strictly
    append-only, so the reference graph is a DAG by construction. The
    router guarantees exactly one of the three fields is set before this is
    ever called.

    Public (no leading underscore) since Pattern/Mirror scoping's Phase 1
    (`app.document.mirror.resolve_mirror_from_bodies`) is a second real
    consumer outside this module - same "promote to public once a second
    module needs it" convention `sketch_feature_id_for_sketch` (app.
    document.graph) already follows."""
    if ref.face_ref is not None:
        return _resolve_planar_face(bodies, ref.face_ref)
    if ref.fixed_plane is not None:
        return sketch_basis_for_plane(ref.fixed_plane)
    assert ref.plane_feature_id is not None
    plane_feature = part.get_feature(ref.plane_feature_id)
    assert isinstance(plane_feature, CreatePlaneFeature)
    return resolve_create_plane_from_bodies(part, plane_feature, bodies, excluded_feature_ids)


def resolve_offset_face_from_bodies(
    part: Part,
    bodies: dict[str, TopoDS_Shape],
    plane_ref: PlaneRef,
    offset: float,
    excluded_feature_ids: frozenset[str],
) -> ResolvedPlane:
    """C2/C3/C5: the `_from_bodies` core of `resolve_offset_face` - a plane
    parallel to the referenced plane-like reference, translated `offset`
    along its own normal (positive = along the normal direction, matching
    `ExtrudeFeature`'s own signed-distance convention). C5: `plane_ref` can
    be a Body face, a fixed reference plane, or an existing Plane (see
    `resolve_plane_ref`) - `part`/`excluded_feature_ids` are only actually
    used by the existing-Plane case, a Body face or fixed plane ignores
    both, but every caller threads them through uniformly rather than
    branching on `plane_ref`'s own kind itself."""
    resolved = resolve_plane_ref(part, bodies, plane_ref, excluded_feature_ids)
    nx, ny, nz = resolved.normal
    ox, oy, oz = resolved.origin
    origin = (ox + nx * offset, oy + ny * offset, oz + nz * offset)
    return ResolvedPlane(origin=origin, normal=resolved.normal, x_axis=resolved.x_axis, y_axis=resolved.y_axis)


def resolve_offset_face(
    part: Part,
    plane_ref: PlaneRef,
    offset: float,
    excluded_feature_ids: frozenset[str] = frozenset(),
) -> ResolvedPlane:
    """C2/C5: resolves an OFFSET_FACE CreatePlaneFeature - fresh wrapper
    around `resolve_offset_face_from_bodies` that computes `bodies` itself
    via `compute_part_bodies`, for callers (the router) that don't already
    have one on hand. Fails closed with `missing_reference` (via `resolve_
    subshape_from_bodies`) or `non_planar_reference` (see `_resolve_planar_
    face`) for the Body-face case."""
    bodies = compute_part_bodies(part, excluded_feature_ids)
    return resolve_offset_face_from_bodies(part, bodies, plane_ref, offset, excluded_feature_ids)


def resolve_midplane_from_bodies(
    part: Part,
    bodies: dict[str, TopoDS_Shape],
    plane_ref_a: PlaneRef,
    plane_ref_b: PlaneRef,
    excluded_feature_ids: frozenset[str],
) -> ResolvedPlane:
    """C3/C5: the `_from_bodies` core of `resolve_midplane` - a plane
    equidistant between two parallel plane-like references (any mix of
    Body faces, fixed reference planes, and existing Planes - see
    `resolve_plane_ref`), oriented along the first reference's own
    (corrected) normal. Fails closed with `faces_not_parallel` (see
    `_faces_not_parallel`) unless the two references' normals are parallel
    or anti-parallel (`abs(dot) ~= 1`) - anything else has no single
    well-defined midplane.

    The origin is the plain component-wise average of the two references'
    own origins. This is always a point exactly on the true midplane
    regardless of where within its own plane each reference's origin
    happens to sit: if `dot(origin_a, n)` and `dot(origin_b, n)` are planes
    A/B's own signed offsets along the shared normal `n`, their average
    trivially satisfies the midpoint offset by linearity, with no
    assumption needed about the two origins lining up on the other two
    axes. That assumption-free property matters in practice - a real bug
    shipped here originally by instead projecting from `resolved_a.origin`
    along the normal by half the separation, which silently produces a
    *different*, still-technically-on-plane point whenever the two
    origins aren't already aligned off-axis. OCCT's own raw `Geom_Plane`
    location has no guarantee of that alignment: confirmed via CI that a
    box's four side faces each report their location at a *corner*, while
    its top/bottom faces report a true face-center, so a pair of side
    faces broke the old formula while a pair of top/bottom faces
    coincidentally didn't. C5: plain-tuple math now that `_resolve_plane_
    ref` always returns a `ResolvedPlane`, not raw OCCT `gp_Pnt`/`gp_Dir`
    values - no OCCT construction needed in this function at all anymore
    (resolving the references themselves may still need it, for the
    Body-face case)."""
    resolved_a = resolve_plane_ref(part, bodies, plane_ref_a, excluded_feature_ids)
    resolved_b = resolve_plane_ref(part, bodies, plane_ref_b, excluded_feature_ids)

    dot = sum(a * b for a, b in zip(resolved_a.normal, resolved_b.normal))
    if abs(abs(dot) - 1.0) > 1e-6:
        raise _faces_not_parallel(plane_ref_a, plane_ref_b)

    origin = tuple((a + b) / 2.0 for a, b in zip(resolved_a.origin, resolved_b.origin))
    return ResolvedPlane(
        origin=origin, normal=resolved_a.normal, x_axis=resolved_a.x_axis, y_axis=resolved_a.y_axis
    )


def resolve_midplane(
    part: Part,
    plane_ref_a: PlaneRef,
    plane_ref_b: PlaneRef,
    excluded_feature_ids: frozenset[str] = frozenset(),
) -> ResolvedPlane:
    """C3/C5: resolves a MIDPLANE CreatePlaneFeature - fresh wrapper around
    `resolve_midplane_from_bodies`, mirroring `resolve_offset_face`'s own
    fresh-vs-`_from_bodies` split."""
    bodies = compute_part_bodies(part, excluded_feature_ids)
    return resolve_midplane_from_bodies(part, bodies, plane_ref_a, plane_ref_b, excluded_feature_ids)


def resolve_normal_to_edge_through_vertex_from_bodies(
    bodies: dict[str, TopoDS_Shape], edge_ref: SubShapeRef, vertex_ref: SubShapeRef
) -> ResolvedPlane:
    """C4: the `_from_bodies` core of `resolve_normal_to_edge_through_vertex`
    - a plane normal to `edge_ref`'s direction, through `vertex_ref`'s
    position. Fails closed with `non_linear_edge` (see `_non_linear_edge`)
    unless the edge's own underlying curve is a straight line
    (`BRepAdaptor_Curve.GetType() == GeomAbs_Line`) - a curved edge has no
    single direction to be normal to. Has no natural in-plane reference of
    its own (unlike `OFFSET_FACE`/`MIDPLANE`, which inherit one from their
    referenced face's own OCCT frame), so its basis comes from
    `arbitrary_perpendicular_basis`, same as `NORMAL_TO_LINE_AT_POINT`."""
    shape = resolve_subshape_from_bodies(bodies, edge_ref)
    edge = topods.Edge(shape)
    curve = BRepAdaptor_Curve(edge)
    if curve.GetType() != GeomAbs_Line:
        raise _non_linear_edge(edge_ref)

    direction = curve.Line().Direction()
    normal = (direction.X(), direction.Y(), direction.Z())
    vertex_point = _resolve_vertex_position(bodies, vertex_ref)
    origin = (vertex_point.X(), vertex_point.Y(), vertex_point.Z())
    x_axis, y_axis = arbitrary_perpendicular_basis(normal)
    return ResolvedPlane(origin=origin, normal=normal, x_axis=x_axis, y_axis=y_axis)


def resolve_normal_to_edge_through_vertex(
    part: Part,
    edge_ref: SubShapeRef,
    vertex_ref: SubShapeRef,
    excluded_feature_ids: frozenset[str] = frozenset(),
) -> ResolvedPlane:
    """C4: resolves a NORMAL_TO_EDGE_THROUGH_VERTEX CreatePlaneFeature -
    fresh wrapper around `resolve_normal_to_edge_through_vertex_from_bodies`,
    mirroring `resolve_offset_face`'s own fresh-vs-`_from_bodies` split."""
    bodies = compute_part_bodies(part, excluded_feature_ids)
    return resolve_normal_to_edge_through_vertex_from_bodies(bodies, edge_ref, vertex_ref)


def resolve_parallel_face_through_vertex_from_bodies(
    part: Part,
    bodies: dict[str, TopoDS_Shape],
    plane_ref: PlaneRef,
    vertex_ref: SubShapeRef,
    excluded_feature_ids: frozenset[str],
) -> ResolvedPlane:
    """C4/C5: the `_from_bodies` core of `resolve_parallel_face_through_vertex`
    - a plane parallel to `plane_ref`'s own plane (a Body face, a fixed
    reference plane, or an existing Plane - see `resolve_plane_ref`),
    passing through `vertex_ref`'s position instead of `OFFSET_FACE`'s
    numeric offset. `vertex_ref`'s own position becomes `origin` directly
    (rather than, say, the reference's own origin projected along its
    normal) - the vertex necessarily lies on the resulting plane by
    construction, so using its own position as the plane's origin is both
    correct and the simplest option, and renders the plane's quad naturally
    centered on the point the user actually picked."""
    resolved = resolve_plane_ref(part, bodies, plane_ref, excluded_feature_ids)
    vertex_point = _resolve_vertex_position(bodies, vertex_ref)
    origin = (vertex_point.X(), vertex_point.Y(), vertex_point.Z())
    return ResolvedPlane(origin=origin, normal=resolved.normal, x_axis=resolved.x_axis, y_axis=resolved.y_axis)


def resolve_parallel_face_through_vertex(
    part: Part,
    plane_ref: PlaneRef,
    vertex_ref: SubShapeRef,
    excluded_feature_ids: frozenset[str] = frozenset(),
) -> ResolvedPlane:
    """C4/C5: resolves a PARALLEL_TO_FACE_THROUGH_VERTEX CreatePlaneFeature -
    fresh wrapper around `resolve_parallel_face_through_vertex_from_bodies`,
    mirroring `resolve_offset_face`'s own fresh-vs-`_from_bodies` split."""
    bodies = compute_part_bodies(part, excluded_feature_ids)
    return resolve_parallel_face_through_vertex_from_bodies(
        part, bodies, plane_ref, vertex_ref, excluded_feature_ids
    )


def basis_for_sketch(
    part: Part,
    sketch: Sketch,
    bodies: dict[str, TopoDS_Shape],
    excluded_feature_ids: frozenset[str],
) -> ResolvedPlane:
    """C3: `sketch`'s own resolved anchor plane - a fixed plane's `sketch_
    basis_for_plane(sketch.plane)`, or (new in C3) the `ResolvedPlane` of
    the `CreatePlaneFeature` its owning `SketchFeature.plane_feature_id`
    names, resolved recursively against the *same* `bodies` accumulator
    (never a fresh `compute_part_bodies` call - see this module's own
    docstring for why that would recurse forever from inside `app.document.
    extrude._solid_for_extrude_feature`).

    Falls back to `sketch.plane` when no owning `SketchFeature` exists at
    all (a bare `Sketch` created directly via the standalone `/sketch` API,
    bypassing the Document/Part/Feature layer entirely, or a hand-built
    `Part` in a unit test) - such a Sketch is never anchored to a custom
    plane (there is no `SketchFeature.plane_feature_id` to read), so it must
    already carry a fixed `plane`.

    Bug fix: the custom-plane branch used to return the anchor plane's
    resolved basis unmodified, silently ignoring `sketch.flip`/`sketch.
    rotation_quarter_turns` - a custom-plane Sketch's orientation controls
    had no effect on the real Extrude solid, only on its own rendering
    (which already applied orientation correctly client-side). Both
    branches now go through `apply_orientation` the same way."""
    sketch_feature_id = sketch_feature_id_for_sketch(part, sketch.id)
    sketch_feature = part.get_feature(sketch_feature_id) if sketch_feature_id else None
    if isinstance(sketch_feature, SketchFeature) and sketch_feature.plane_feature_id is not None:
        plane_feature = part.get_feature(sketch_feature.plane_feature_id)
        assert isinstance(plane_feature, CreatePlaneFeature)
        anchor_basis = resolve_create_plane_from_bodies(part, plane_feature, bodies, excluded_feature_ids)
        return apply_orientation(
            anchor_basis, flip=sketch.flip, rotation_quarter_turns=sketch.rotation_quarter_turns
        )
    assert sketch.plane is not None, f"Sketch {sketch.id} has neither a fixed plane nor an anchor plane"
    return oriented_basis_for_plane(sketch.plane, flip=sketch.flip, rotation_quarter_turns=sketch.rotation_quarter_turns)


def resolve_sketch_basis(
    part: Part,
    sketch_feature: SketchFeature,
    bodies: dict[str, TopoDS_Shape],
    excluded_feature_ids: frozenset[str] = frozenset(),
) -> ResolvedPlane:
    """C3: `sketch_feature`'s own resolved anchor plane - the public entry
    point `app.document.extrude._solid_for_extrude_feature` calls (function-
    local import, see this module's docstring) to embed its Sketch's local
    2D geometry into world space regardless of whether that Sketch sits on
    a fixed plane or a custom one."""
    sketch = get_sketch_or_404(sketch_feature.sketch_id)
    return basis_for_sketch(part, sketch, bodies, excluded_feature_ids)


def resolve_external_vertex_position(
    part: Part,
    sketch: Sketch,
    ref: ExternalVertexReference,
    bodies: dict[str, TopoDS_Shape],
    excluded_feature_ids: frozenset[str] = frozenset(),
) -> tuple[float, float]:
    """Sketcher-roadmap Phase 4.3 v1: `ref`'s current position projected
    into `sketch`'s own local (x, y) - the one piece of OCCT/Part-aware
    work `Sketch.add_external_vertex_reference`/`solve_sketch` can't do
    themselves (see those doc comments). Converts the sketch layer's own
    `ExternalVertexReference` into the document layer's `SubShapeRef`
    (`shape_type=VERTEX`) at this exact boundary, then reuses
    `_resolve_vertex_position` (fails closed with `missing_reference`,
    same as every other `SubShapeRef` resolution) and `basis_for_sketch`
    (the same basis every other embedding of this Sketch's geometry into
    world space already goes through) verbatim - no new resolution or
    projection logic, just composing two already-existing pieces."""
    vertex_ref = SubShapeRef(body_id=ref.body_id, shape_type=SubShapeType.VERTEX, index=ref.vertex_index)
    world_point = _resolve_vertex_position(bodies, vertex_ref)
    basis = basis_for_sketch(part, sketch, bodies, excluded_feature_ids)
    return world_point_to_basis(basis, (world_point.X(), world_point.Y(), world_point.Z()))


def make_external_vertex_reference(
    bodies: dict[str, TopoDS_Shape], body_id: str, vertex_index: int, lineage: LineageOrigin | None = None
) -> ExternalVertexReference:
    """A new `ExternalVertexReference` carrying the geometric signature of the vertex it names, measured on `bodies` now (reference-identity overhaul,
    docs/reference-identity-design.md (a)). Fails closed with the usual `missing_reference` 422 if the vertex does not exist."""
    resolve_subshape_from_bodies(bodies, SubShapeRef(body_id=body_id, shape_type=SubShapeType.VERTEX, index=vertex_index))
    signature = BodyVertexMeasurer(bodies[body_id]).signature(vertex_index)
    return ExternalVertexReference(body_id=body_id, vertex_index=vertex_index, signature=signature, lineage=lineage)


def make_circle_centre_reference(
    bodies: dict[str, TopoDS_Shape], body_id: str, edge_index: int, lineage: LineageOrigin | None = None
) -> ExternalVertexReference:
    """A new `kind="circle_centre"` reference: the centre of the CIRCULAR Body edge `edge_index` (a hole's or boss's rim), signed with the edge's own signature
    (circle, axis, adjacent faces, plus the centre and radius it is re-derived from). Fails closed with `missing_reference` if the edge does not exist and with
    `not_a_circular_edge` (422) if it is not a circle - an arc's or full circle's centre is only defined for a circular edge."""
    resolve_subshape_from_bodies(bodies, SubShapeRef(body_id=body_id, shape_type=SubShapeType.EDGE, index=edge_index))
    signature = measurer_for(bodies[body_id], "edge").signature(edge_index)
    if signature.curve_kind != "circle":
        raise HTTPException(status_code=422, detail={"type": "not_a_circular_edge", "body_id": body_id, "index": edge_index})
    return ExternalVertexReference(body_id=body_id, vertex_index=edge_index, signature=signature, lineage=lineage, kind="circle_centre")


def capture_external_reference(
    bodies: dict[str, TopoDS_Shape], ref: ExternalVertexReference, lineage: LineageOrigin | None = None
) -> ExternalVertexReference:
    """`ref` re-captured against `bodies` as it names its sub-shape now (confirm / re-attach): a fresh signature, whatever the kind."""
    if ref.kind == "circle_centre":
        return make_circle_centre_reference(bodies, ref.body_id, ref.vertex_index, lineage)
    return make_external_vertex_reference(bodies, ref.body_id, ref.vertex_index, lineage)


def _measurer_kind(ref: ExternalVertexReference) -> str:
    return "edge" if ref.kind == "circle_centre" else "vertex"


def _decide_external_reference(
    ref: ExternalVertexReference,
    bodies: dict[str, TopoDS_Shape],
    history: "ReferenceHistory | None",
) -> ReferenceDecision:
    body = bodies.get(ref.body_id)
    if body is None:
        return ReferenceDecision(ReferenceStatus.LOST, None, reason="body_missing")
    measurer = measurer_for(body, _measurer_kind(ref))
    in_range = 0 <= ref.vertex_index < measurer.count

    if ref.signature is None:
        # A reference made before signatures existed (an old file): trust the index once and adopt its signature.
        if in_range:
            return ReferenceDecision(ReferenceStatus.OK, ref.vertex_index, reason="signature_adopted", method="index")
        return ReferenceDecision(ReferenceStatus.LOST, None, reason="no_match")

    # Fast path, measuring only the one sub-shape the index names: same fingerprint and still where it was (to within the search tolerance).
    if in_range:
        here = measurer.signature(ref.vertex_index)
        tolerance = SEARCH_TOLERANCE_REL * (ref.signature.body_diagonal or measurer.diagonal)
        if fingerprint_matches(ref.signature, here) and shape_distance(ref.signature, here) <= tolerance:
            return ReferenceDecision(ReferenceStatus.OK, ref.vertex_index, method="index")

    signature_decision = decide_reference(ref.signature, ref.vertex_index, measurer.all())
    if history is not None and ref.lineage is not None:
        return history.refine_lineage(
            ref.lineage,
            ref.body_id,
            ref.vertex_index,
            ref.signature,
            signature_decision,
            measurer,
            final_body_id=ref.body_id,
            kind=_measurer_kind(ref),
        )
    return signature_decision


def _reference_world_position(ref: ExternalVertexReference, signature: ShapeSignature) -> tuple[float, float, float]:
    return signature.centre if ref.kind == "circle_centre" else signature.position


def _follow_circle_centre(
    sketch: Sketch, centre_point_id: str, old_xy: tuple[float, float], new_xy: tuple[float, float], new_radius: float
) -> bool:
    """The Circle built on a re-found circle centre follows it: every Point that defines it (radius Point, the four cardinal Points) is moved with the centre
    and scaled about it to the circle's new radius, so a hole that moved or changed diameter upstream moves and resizes here too. An Arc only has its centre
    to move (its start / end Points are vertex references of their own). Returns whether anything moved or resized (the centre Point itself is the caller's)."""
    changed = math.dist(old_xy, new_xy) > 1e-12
    for entity in sketch.entities.values():
        if isinstance(entity, Circle) and entity.center_point_id == centre_point_id:
            radius_point = sketch.points[entity.radius_point_id]
            old_radius = math.dist(old_xy, (radius_point.x, radius_point.y))
            scale = new_radius / old_radius if old_radius > 1e-12 else 1.0
            if abs(scale - 1.0) > 1e-12:
                changed = True
            for point_id in {entity.radius_point_id, *entity.cardinal_point_ids}:
                point = sketch.points[point_id]
                point.x = new_xy[0] + (point.x - old_xy[0]) * scale
                point.y = new_xy[1] + (point.y - old_xy[1]) * scale
    return changed


def _sync_provisional_radius_dimensions(sketch: Sketch, centre_point_ids: set[str]) -> None:
    """The provisional radius DistanceConstraint a converted Circle / Arc carries stores a length; after its centre moved it must say the geometry's own."""
    for entity in sketch.entities.values():
        if isinstance(entity, Circle) and entity.center_point_id in centre_point_ids:
            far_point_id = entity.radius_point_id
        elif isinstance(entity, Arc) and entity.center_point_id in centre_point_ids:
            far_point_id = entity.start_point_id
        else:
            continue
        constraint = sketch.constraints.get(entity.radius_constraint_id)
        if isinstance(constraint, DistanceConstraint) and getattr(constraint, "provisional", False):
            centre, far = sketch.points[entity.center_point_id], sketch.points[far_point_id]
            constraint.distance = math.dist((centre.x, centre.y), (far.x, far.y))


def refresh_external_references(
    part: Part,
    sketch: Sketch,
    bodies: dict[str, TopoDS_Shape],
    excluded_feature_ids: frozenset[str] = frozenset(),
    history: "ReferenceHistory | None" = None,
) -> list[str]:
    """Sketcher-roadmap Phase 4.3 v1, rebuilt by the reference-identity overhaul (docs/reference-identity-design.md): re-validates every one of
    `sketch`'s `external_references` against `bodies`' *current* topology and returns the ids of the Points whose reference is lost.

    A reference is no longer just "the index still resolves". Each one carries the signature of the sub-shape it was made against, and the stored index is
    only trusted while the sub-shape it now names still has that fingerprint (`app.sketch.reference_signature.decide_reference`). When it does not, it
    is re-found by signature (and, for a vertex, by OCCT history, `history`), unique match only; the new index is persisted, so downstream resolution by
    index keeps working. A reference that cannot be found unambiguously is *never rebound*: it is left at its last-known position (so the rest of the Sketch
    does not visually collapse), its Point id is returned, and the reason is on `sketch.external_reference_decisions` for the response layer.
    Each healthy outcome also refreshes the stored signature (the sub-shape legitimately moves with parametric edits); a `potentially_moved` binding keeps
    its old signature until the user confirms it.

    Two kinds of reference: `"vertex"` (the Point sits on a Body vertex) and `"circle_centre"` (the Point sits at the centre of a circular Body edge; the Circle /
    Arc built on it follows its position and radius, and the reference is lost - `not_coplanar` - if the edge no longer lies in the Sketch's plane).

    Every decision of this refresh (ok / followed / potentially_moved / lost, and why) is left on `sketch.external_reference_decisions`."""
    lost_point_ids: list[str] = []
    decisions: dict[str, ReferenceDecision] = {}
    moved_centres: set[str] = set()
    try:
        basis = basis_for_sketch(part, sketch, bodies, excluded_feature_ids) if sketch.external_references else None
    except HTTPException:
        basis = None
    for point_id, ref in list(sketch.external_references.items()):
        if basis is None:
            decision = ReferenceDecision(ReferenceStatus.LOST, None, reason="sketch_plane_unresolved")
        else:
            decision = _decide_external_reference(ref, bodies, history)
        if decision.index is not None and decision.status != ReferenceStatus.LOST and ref.kind == "circle_centre":
            here = measurer_for(bodies[ref.body_id], "edge").signature(decision.index)
            axis_alignment = abs(sum(a * b for a, b in zip(here.direction, basis.normal)))
            if axis_alignment < math.cos(math.radians(NORMAL_TOLERANCE_DEGREES)):
                decision = ReferenceDecision(ReferenceStatus.LOST, None, reason="not_coplanar")
        decisions[point_id] = decision
        if decision.status == ReferenceStatus.LOST or decision.index is None:
            lost_point_ids.append(point_id)
            continue
        here = measurer_for(bodies[ref.body_id], _measurer_kind(ref)).signature(decision.index)
        refreshed = replace(ref, vertex_index=decision.index)
        if decision.status != ReferenceStatus.POTENTIALLY_MOVED:
            refreshed = replace(refreshed, signature=here)
        if decision.lineage is not None:
            refreshed = replace(refreshed, lineage=decision.lineage)
        sketch.external_references[point_id] = refreshed
        x, y = world_point_to_basis(basis, _reference_world_position(ref, here))
        point = sketch.points[point_id]
        if ref.kind == "circle_centre" and _follow_circle_centre(sketch, point_id, (point.x, point.y), (x, y), here.radius):
            moved_centres.add(point_id)
        point.x = x
        point.y = y
    if moved_centres:
        _sync_provisional_radius_dimensions(sketch, moved_centres)
    sketch.external_reference_decisions = decisions
    return lost_point_ids


def resolve_point_ref_position(
    part: Part,
    bodies: dict[str, TopoDS_Shape],
    point_ref: PointRef,
    excluded_feature_ids: frozenset[str],
) -> tuple[float, float, float]:
    """C4: `point_ref`'s own world-space position - a Body vertex's directly
    (see `_resolve_vertex_position`), or a Sketch Point's local (x, y)
    mapped through its own Sketch's resolved basis (fixed or custom, via
    `basis_for_sketch` - the same recursive resolution `resolve_create_
    plane_from_bodies`'s own `NORMAL_TO_LINE_AT_POINT` branch already uses).

    Renamed from `_resolve_point_ref_position` (Phase 6, `docs/assembly-
    scope.md` §3) and promoted to public - `app.document.assembly_solver`
    needs the exact same "resolve a `PointRef` to a world position" logic
    for a mate's own point-like references, mirroring `resolve_plane_ref`'s
    own identical public-promotion precedent in this same file. Behavior is
    unchanged - only the name and its one call site below moved."""
    if point_ref.vertex_ref is not None:
        point = _resolve_vertex_position(bodies, point_ref.vertex_ref)
        return (point.X(), point.Y(), point.Z())
    assert point_ref.sketch_point_ref is not None
    ref = point_ref.sketch_point_ref
    sketch_point = resolve_sketch_entity(ref)
    assert isinstance(sketch_point, Point)  # entity_type already validated POINT by resolve_sketch_entity
    sketch = get_sketch_or_404(ref.sketch_id)
    basis = basis_for_sketch(part, sketch, bodies, excluded_feature_ids)
    return basis_point(basis, sketch_point.x, sketch_point.y)


def resolve_three_points_from_bodies(
    part: Part,
    bodies: dict[str, TopoDS_Shape],
    point_refs: list[PointRef],
    excluded_feature_ids: frozenset[str],
) -> ResolvedPlane:
    """C4: the `_from_bodies` core of `resolve_three_points_feature` -
    resolves each of `point_refs`' three entries to a world position (see
    `resolve_point_ref_position`) and delegates the actual plane math to
    `app.document.plane_geometry.resolve_three_points`, which needs no OCCT
    of its own once given three plain positions."""
    p0, p1, p2 = (
        resolve_point_ref_position(part, bodies, point_ref, excluded_feature_ids)
        for point_ref in point_refs
    )
    return resolve_three_points(p0, p1, p2)


def resolve_three_points_feature(
    part: Part,
    point_refs: list[PointRef],
    excluded_feature_ids: frozenset[str] = frozenset(),
) -> ResolvedPlane:
    """C4: resolves a THREE_POINTS CreatePlaneFeature - fresh wrapper around
    `resolve_three_points_from_bodies`, mirroring `resolve_offset_face`'s own
    fresh-vs-`_from_bodies` split. Named with a `_feature` suffix (unlike
    every other `resolve_<type>` fresh wrapper here) only to avoid shadowing
    `app.document.plane_geometry.resolve_three_points`, which this calls
    (via `resolve_three_points_from_bodies`) rather than duplicates."""
    bodies = compute_part_bodies(part, excluded_feature_ids)
    return resolve_three_points_from_bodies(part, bodies, point_refs, excluded_feature_ids)


def resolve_normal_to_curve_feature_at_parameter_from_bodies(
    part: Part,
    bodies: dict[str, TopoDS_Shape],
    curve_feature_id: str,
    parameter: float,
    excluded_feature_ids: frozenset[str],
) -> ResolvedPlane:
    """`NORMAL_TO_CURVE_FEATURE_AT_PARAMETER`'s own resolver - a plane normal
    to a Curve feature's (Helix/Intersection curve) own tangent at `parameter`
    (a 0-1 arc-length fraction along it), through the point there. Unlike
    `resolve_normal_to_arc_at_point` (pure-Python 2D circle math on a Sketch
    Arc), this always resolves a real OCCT `TopoDS_Edge`/`Geom_Curve` (via
    `app.document.curve.resolve_curve_feature_by_id`), so it lives here with
    this module's other OCCT-based resolvers - same "no in-plane reference of
    its own, use `arbitrary_perpendicular_basis`" treatment `resolve_normal_
    to_edge_through_vertex_from_bodies` already gives a straight Body edge.

    Function-local import of `app.document.curve` (not a module-level one):
    that module itself imports `resolve_plane_ref`/`resolve_sketch_basis`
    from here (for a Helix's own `axis_ref`/an Intersection curve's own
    Sketch basis) - a module-level import here would be circular."""
    from app.document.curve import point_and_tangent_at_fraction, resolve_curve_feature_by_id

    resolved_curve = resolve_curve_feature_by_id(part, curve_feature_id, bodies, excluded_feature_ids)
    point, tangent = point_and_tangent_at_fraction(resolved_curve.wire, resolved_curve.length, parameter)
    normal = (tangent.X(), tangent.Y(), tangent.Z())
    magnitude = math.sqrt(sum(component**2 for component in normal))
    normal = tuple(component / magnitude for component in normal)
    origin = (point.X(), point.Y(), point.Z())
    x_axis, y_axis = arbitrary_perpendicular_basis(normal)
    return ResolvedPlane(origin=origin, normal=normal, x_axis=x_axis, y_axis=y_axis)


def resolve_create_plane_from_bodies(
    part: Part,
    feature: CreatePlaneFeature,
    bodies: dict[str, TopoDS_Shape],
    excluded_feature_ids: frozenset[str] = frozenset(),
) -> ResolvedPlane:
    """C2/C3/C4: the `_from_bodies` core of `resolve_create_plane` - the
    single dispatch point for all six `PlaneType`s that never triggers its
    own top-level `compute_part_bodies` call (see module docstring)."""
    if feature.plane_type == PlaneType.OFFSET_FACE:
        assert len(feature.face_refs) == 1 and feature.offset is not None
        return resolve_offset_face_from_bodies(
            part, bodies, feature.face_refs[0], feature.offset, excluded_feature_ids
        )
    if feature.plane_type == PlaneType.MIDPLANE:
        assert len(feature.face_refs) == 2
        return resolve_midplane_from_bodies(
            part, bodies, feature.face_refs[0], feature.face_refs[1], excluded_feature_ids
        )
    if feature.plane_type == PlaneType.NORMAL_TO_EDGE_THROUGH_VERTEX:
        assert feature.edge_ref is not None and feature.vertex_ref is not None
        return resolve_normal_to_edge_through_vertex_from_bodies(
            bodies, feature.edge_ref, feature.vertex_ref
        )
    if feature.plane_type == PlaneType.PARALLEL_TO_FACE_THROUGH_VERTEX:
        assert len(feature.face_refs) == 1 and feature.vertex_ref is not None
        return resolve_parallel_face_through_vertex_from_bodies(
            part, bodies, feature.face_refs[0], feature.vertex_ref, excluded_feature_ids
        )
    if feature.plane_type == PlaneType.THREE_POINTS:
        assert len(feature.point_refs) == 3
        return resolve_three_points_from_bodies(part, bodies, feature.point_refs, excluded_feature_ids)
    if feature.plane_type == PlaneType.NORMAL_TO_CURVE_FEATURE_AT_PARAMETER:
        assert feature.curve_feature_id is not None and feature.curve_parameter is not None
        return resolve_normal_to_curve_feature_at_parameter_from_bodies(
            part, bodies, feature.curve_feature_id, feature.curve_parameter, excluded_feature_ids
        )
    assert feature.line_ref is not None and feature.point_ref is not None
    sketch = get_sketch_or_404(feature.line_ref.sketch_id)
    basis = basis_for_sketch(part, sketch, bodies, excluded_feature_ids)
    if feature.plane_type == PlaneType.NORMAL_TO_CURVE_AT_POINT:
        return resolve_normal_to_arc_at_point(feature.line_ref, feature.point_ref, basis)
    return resolve_normal_to_line_at_point(feature.line_ref, feature.point_ref, basis)


def resolve_create_plane(
    part: Part, feature: CreatePlaneFeature, excluded_feature_ids: frozenset[str] = frozenset()
) -> ResolvedPlane:
    """C2: the single dispatch point `app.document.router` uses regardless
    of `feature.plane_type` - callers never need to branch on `plane_type`
    themselves. Fresh wrapper around `resolve_create_plane_from_bodies`,
    mirroring `resolve_offset_face`/`resolve_midplane`'s own fresh-vs-
    `_from_bodies` split. Every branch raises its own structured 422 on
    failure; this function adds no behavior of its own beyond the dispatch
    and the one-time `bodies` computation."""
    bodies = compute_part_bodies(part, excluded_feature_ids)
    return resolve_create_plane_from_bodies(part, feature, bodies, excluded_feature_ids)
