"""OCCT geometry for CreatePlaneFeature's OFFSET_FACE case (C2) - the only
half of Create Plane that needs a real OCCT environment, since checking a
face is planar (BRepAdaptor_Surface(face).GetType() == GeomAbs_Plane) has no
pure-Python equivalent. See app.document.plane_geometry for the
NORMAL_TO_LINE_AT_POINT case, which needs no OCCT at all - kept in a
separate module for exactly that reason, mirroring the existing
app.document.extrude / app.sketch.store split by OCCT dependency.
"""

from fastapi import HTTPException
from OCC.Core.BRepAdaptor import BRepAdaptor_Surface
from OCC.Core.GeomAbs import GeomAbs_Plane
from OCC.Core.gp import gp_Vec
from OCC.Core.TopAbs import TopAbs_REVERSED
from OCC.Core.TopoDS import topods

from app.document.extrude import resolve_subshape
from app.document.models import CreatePlaneFeature, Part, PlaneType, ResolvedPlane, SubShapeRef
from app.document.plane_geometry import resolve_normal_to_line_at_point


def _non_planar_reference(ref: SubShapeRef) -> HTTPException:
    """C2: structured 422, same envelope B1/C1 already established for
    `missing_reference`, for an OFFSET_FACE `face_ref` that resolves to a
    real face but not a planar one - rejecting rather than silently taking
    a tangent plane at some arbitrary point on a curved surface."""
    return HTTPException(
        status_code=422,
        detail={"type": "non_planar_reference", "body_id": ref.body_id, "index": ref.index},
    )


def resolve_offset_face(
    part: Part,
    face_ref: SubShapeRef,
    offset: float,
    hidden_feature_ids: frozenset[str] = frozenset(),
) -> ResolvedPlane:
    """C2: resolves an OFFSET_FACE CreatePlaneFeature - a plane parallel to
    the referenced face, translated `offset` along the face's own outward
    normal (positive = along the normal direction, matching
    `ExtrudeFeature`'s own signed-distance convention). Resolves `face_ref`
    via B1's `resolve_subshape` (fails closed with `missing_reference` for
    an unknown body/index, same as every other consumer), then requires the
    resolved face to be planar - fails closed with `non_planar_reference`
    otherwise (see `_non_planar_reference`).

    Orientation correction (`TopAbs_REVERSED`) mirrors
    `app.document.extrude._wire_normal`'s own handling of the same OCCT
    quirk: a face's `Orientation()` can flip its effective normal without
    changing the underlying surface, so the raw `BRepAdaptor_Surface`
    normal must be corrected before use."""
    shape = resolve_subshape(part, face_ref, hidden_feature_ids)
    face = topods.Face(shape)
    surface = BRepAdaptor_Surface(face, True)
    if surface.GetType() != GeomAbs_Plane:
        raise _non_planar_reference(face_ref)

    plane = surface.Plane()
    location = plane.Location()
    normal = plane.Axis().Direction()
    if face.Orientation() == TopAbs_REVERSED:
        normal = normal.Reversed()

    offset_vector = gp_Vec(normal.X(), normal.Y(), normal.Z()).Multiplied(offset)
    origin = (
        location.X() + offset_vector.X(),
        location.Y() + offset_vector.Y(),
        location.Z() + offset_vector.Z(),
    )
    return ResolvedPlane(origin=origin, normal=(normal.X(), normal.Y(), normal.Z()))


def resolve_create_plane(
    part: Part, feature: CreatePlaneFeature, hidden_feature_ids: frozenset[str] = frozenset()
) -> ResolvedPlane:
    """C2: the single dispatch point `app.document.router` uses regardless
    of `feature.plane_type` - callers never need to branch on `plane_type`
    themselves. Delegates to `resolve_offset_face` above (OCCT) or
    `app.document.plane_geometry.resolve_normal_to_line_at_point` (pure
    Python) - both raise their own structured 422 on failure; this function
    adds no behavior of its own beyond the dispatch. The `assert`s document
    the invariant `app.document.router._validate_create_plane_payload`
    already enforces at construction time (the right ref/offset fields are
    always populated for `feature.plane_type`) rather than re-validating it
    here."""
    if feature.plane_type == PlaneType.OFFSET_FACE:
        assert feature.face_ref is not None and feature.offset is not None
        return resolve_offset_face(part, feature.face_ref, feature.offset, hidden_feature_ids)
    assert feature.line_ref is not None and feature.point_ref is not None
    return resolve_normal_to_line_at_point(feature.line_ref, feature.point_ref)
