import base64
import binascii
import logging
import uuid

from fastapi import APIRouter, HTTPException, Query, Response
from OCC.Core.BRepPrimAPI import BRepPrimAPI_MakeBox

from app.document.chamfer import resolve_chamfer
from app.document.create_plane import resolve_create_plane
from app.document.extrude import compute_part_bodies, select_profiles
from app.document.fillet import resolve_fillet
from app.document.graph import base_feature_id, build_feature_graph, transitive_dependents
from app.document.import_geometry import resolve_import
from app.document.mesh import DEFAULT_MESH_QUALITY, MeshData, tessellate_shape
from app.document.mesh_data import Triangle
from app.document.mesh_export import encode_glb, encode_obj, encode_stl
from app.document.native_format import NativeFormatError, export_native, import_native
from app.document.step_export import export_step
from app.document.models import (
    ChamferFeature,
    CreatePlaneFeature,
    ExtrudeFeature,
    ExtrudeType,
    Feature,
    FilletFeature,
    ImportFeature,
    ImportSourceFormat,
    Part,
    PlaneRef,
    PlaneType,
    PointRef,
    RevolveFeature,
    RevolveMode,
    SketchFeature,
    SubShapeRef,
    SubShapeType,
    SweepFeature,
    SweepMode,
)
from app.document.revolve import resolve_revolve
from app.document.schemas import (
    BodyMeshResponse,
    CascadeDeleteResponse,
    ChamferFeatureCreate,
    ChamferFeatureResponse,
    ChamferFeatureUpdate,
    CreatePlaneFeatureCreate,
    CreatePlaneFeatureResponse,
    CreatePlaneFeatureUpdate,
    ExtrudeFeatureCreate,
    ExtrudeFeatureResponse,
    ExtrudeFeatureUpdate,
    FeatureResponse,
    FilletFeatureCreate,
    FilletFeatureResponse,
    FilletFeatureUpdate,
    ImportFeatureCreate,
    ImportFeatureResponse,
    MeshVertexData,
    NativeImportResponse,
    PartCreate,
    PartResponse,
    PlaneRefSchema,
    PointRefSchema,
    RevolveFeatureCreate,
    RevolveFeatureResponse,
    RevolveFeatureUpdate,
    SketchEntityRefSchema,
    SketchFeatureCreate,
    SketchFeatureResponse,
    SubShapeRefSchema,
    SweepFeatureCreate,
    SweepFeatureResponse,
    SweepFeatureUpdate,
)
from app.document.sweep import resolve_sweep
from app.document.store import get_document, get_part_or_404, replace_document
from app.sketch.models import Plane, SketchEntityRef, SketchEntityType
from app.sketch.profile import ProfileStatus, detect_profile
from app.sketch.store import all_sketches, create_sketch, delete_sketch, get_sketch_or_404, replace_all_sketches

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/document", tags=["document"])

# A1: body id used for the fixed placeholder box returned while a Part has
# no ExtrudeFeature yet (see `Part.produces_solid_geometry`) - never a real
# Feature id, so it can't collide with one.
_PLACEHOLDER_BODY_ID = "placeholder"


def _get_feature_or_404(part: Part, feature_id: str) -> Feature:
    feature = part.get_feature(feature_id)
    if feature is None:
        raise HTTPException(status_code=404, detail="Feature not found")
    return feature


def _part_response(part: Part) -> PartResponse:
    return PartResponse(id=part.id, name=part.name, feature_ids=[f.id for f in part.features])


def _subshape_ref_to_domain(schema: SubShapeRefSchema) -> SubShapeRef:
    return SubShapeRef(body_id=schema.body_id, shape_type=schema.shape_type, index=schema.index)


def _subshape_ref_to_schema(ref: SubShapeRef) -> SubShapeRefSchema:
    return SubShapeRefSchema(body_id=ref.body_id, shape_type=ref.shape_type, index=ref.index)


def _sketch_entity_ref_to_domain(schema: SketchEntityRefSchema) -> SketchEntityRef:
    return SketchEntityRef(
        sketch_id=schema.sketch_id, entity_type=schema.entity_type, entity_id=schema.entity_id
    )


def _sketch_entity_ref_to_schema(ref: SketchEntityRef) -> SketchEntityRefSchema:
    return SketchEntityRefSchema(
        sketch_id=ref.sketch_id, entity_type=ref.entity_type, entity_id=ref.entity_id
    )


def _point_ref_to_domain(schema: PointRefSchema) -> PointRef:
    return PointRef(
        vertex_ref=_subshape_ref_to_domain(schema.vertex_ref) if schema.vertex_ref else None,
        sketch_point_ref=_sketch_entity_ref_to_domain(schema.sketch_point_ref)
        if schema.sketch_point_ref
        else None,
    )


def _point_ref_to_schema(ref: PointRef) -> PointRefSchema:
    return PointRefSchema(
        vertex_ref=_subshape_ref_to_schema(ref.vertex_ref) if ref.vertex_ref else None,
        sketch_point_ref=_sketch_entity_ref_to_schema(ref.sketch_point_ref)
        if ref.sketch_point_ref
        else None,
    )


def _plane_ref_to_domain(schema: PlaneRefSchema) -> PlaneRef:
    return PlaneRef(
        face_ref=_subshape_ref_to_domain(schema.face_ref) if schema.face_ref else None,
        fixed_plane=schema.fixed_plane,
        plane_feature_id=schema.plane_feature_id,
    )


def _plane_ref_to_schema(ref: PlaneRef) -> PlaneRefSchema:
    return PlaneRefSchema(
        face_ref=_subshape_ref_to_schema(ref.face_ref) if ref.face_ref else None,
        fixed_plane=ref.fixed_plane,
        plane_feature_id=ref.plane_feature_id,
    )


def _create_plane_feature_response(part: Part, feature: CreatePlaneFeature) -> CreatePlaneFeatureResponse:
    """C2: unlike every other `_feature_response` branch, this resolves live
    geometry (`origin`/`normal`) on every read - soft-fails to `None` rather
    than raising, so one Feature with a since-broken reference (its
    referenced Body/Sketch deleted, or its face's topology having shrunk)
    never fails the whole `GET .../features` list. Real validation still
    happens at create/update time (`_validate_create_plane_payload` plus an
    explicit `resolve_create_plane` call - see `create_create_plane_feature`/
    `update_create_plane_feature`), so a freshly created/edited Feature's
    response is always non-null here; only a Feature that became stale
    *after* creation, or an existing test fixture with unresolvable OCCT
    (no kernel in this sandbox - never a concern over real HTTP), reaches
    the fallback."""
    try:
        resolved = resolve_create_plane(part, feature)
        origin, normal, x_axis, y_axis = (
            resolved.origin,
            resolved.normal,
            resolved.x_axis,
            resolved.y_axis,
        )
    except HTTPException:
        logger.warning("CreatePlaneFeature %s could not be resolved for its response", feature.id)
        origin, normal, x_axis, y_axis = None, None, None, None
    return CreatePlaneFeatureResponse(
        id=feature.id,
        plane_type=feature.plane_type,
        face_refs=[_plane_ref_to_schema(ref) for ref in feature.face_refs],
        offset=feature.offset,
        line_ref=_sketch_entity_ref_to_schema(feature.line_ref) if feature.line_ref else None,
        point_ref=_sketch_entity_ref_to_schema(feature.point_ref) if feature.point_ref else None,
        edge_ref=_subshape_ref_to_schema(feature.edge_ref) if feature.edge_ref else None,
        vertex_ref=_subshape_ref_to_schema(feature.vertex_ref) if feature.vertex_ref else None,
        point_refs=[_point_ref_to_schema(ref) for ref in feature.point_refs],
        origin=origin,
        normal=normal,
        x_axis=x_axis,
        y_axis=y_axis,
        locked=part.is_locked(feature.id),
        produces=feature.produces,
    )


def _feature_response(part: Part, feature: Feature) -> FeatureResponse:
    if isinstance(feature, SketchFeature):
        return SketchFeatureResponse(
            id=feature.id,
            sketch_id=feature.sketch_id,
            plane_feature_id=feature.plane_feature_id,
            locked=part.is_locked(feature.id),
            produces=feature.produces,
        )
    if isinstance(feature, ExtrudeFeature):
        return ExtrudeFeatureResponse(
            id=feature.id,
            sketch_feature_id=feature.sketch_feature_id,
            extrude_type=feature.extrude_type,
            start_distance=feature.start_distance,
            end_distance=feature.end_distance,
            locked=part.is_locked(feature.id),
            target_body_ids=feature.target_body_ids,
            profile_refs=[_sketch_entity_ref_to_schema(ref) for ref in feature.profile_refs],
            produces=feature.produces,
        )
    if isinstance(feature, CreatePlaneFeature):
        return _create_plane_feature_response(part, feature)
    if isinstance(feature, FilletFeature):
        return FilletFeatureResponse(
            id=feature.id,
            edge_refs=[_subshape_ref_to_schema(ref) for ref in feature.edge_refs],
            radius=feature.radius,
            locked=part.is_locked(feature.id),
            produces=feature.produces,
        )
    if isinstance(feature, ChamferFeature):
        return ChamferFeatureResponse(
            id=feature.id,
            edge_refs=[_subshape_ref_to_schema(ref) for ref in feature.edge_refs],
            distance=feature.distance,
            locked=part.is_locked(feature.id),
            produces=feature.produces,
        )
    if isinstance(feature, RevolveFeature):
        return RevolveFeatureResponse(
            id=feature.id,
            sketch_feature_id=feature.sketch_feature_id,
            axis_ref=_sketch_entity_ref_to_schema(feature.axis_ref),
            angle=feature.angle,
            mode=feature.mode,
            locked=part.is_locked(feature.id),
            target_body_ids=feature.target_body_ids,
            profile_refs=[_sketch_entity_ref_to_schema(ref) for ref in feature.profile_refs],
            produces=feature.produces,
        )
    if isinstance(feature, SweepFeature):
        return SweepFeatureResponse(
            id=feature.id,
            sketch_feature_id=feature.sketch_feature_id,
            path_refs=[_sketch_entity_ref_to_schema(ref) for ref in feature.path_refs],
            mode=feature.mode,
            locked=part.is_locked(feature.id),
            target_body_ids=feature.target_body_ids,
            profile_refs=[_sketch_entity_ref_to_schema(ref) for ref in feature.profile_refs],
            produces=feature.produces,
        )
    if isinstance(feature, ImportFeature):
        return ImportFeatureResponse(
            id=feature.id,
            source_format=feature.source_format,
            source_byte_count=len(feature.source_data),
            locked=part.is_locked(feature.id),
            produces=feature.produces,
        )
    raise NotImplementedError(f"No response mapping for feature type: {feature.type}")


def _mesh_vertex_data(mesh_data: MeshData) -> MeshVertexData:
    return MeshVertexData(
        vertices=mesh_data.vertices,
        normals=mesh_data.normals,
        triangle_indices=[(t.a, t.b, t.c) for t in mesh_data.triangles],
        edges=mesh_data.edges,
        face_ids=mesh_data.face_ids,
        edge_ids=mesh_data.edge_ids,
        topology_vertices=mesh_data.topology_vertices,
        topology_vertex_ids=mesh_data.topology_vertex_ids,
        face_edge_ids=mesh_data.face_edge_ids,
    )


def _validate_extrude_distances(start_distance: float, end_distance: float) -> None:
    """The only validation Stage 10a requires for start_distance/end_distance:
    the extrude must span a positive distance (end_distance > start_distance),
    since both are now signed offsets along the plane normal and the solid
    spans literally from one to the other (see app.document.extrude)."""
    if end_distance <= start_distance:
        raise HTTPException(
            status_code=400,
            detail="end_distance must be greater than start_distance",
        )


def _validate_target_body_ids(part: Part, is_cut: bool, target_body_ids: list[str]) -> None:
    """A1: Cut must name at least one target Body - there is nothing to
    subtract from an empty list, so this is a structured-validation-error
    case (422, `{"detail": "..."}` - the same plain-HTTPException shape
    every other validation error in this API uses, e.g.
    `_validate_extrude_distances`'s 400). Every named id (Boss or Cut) must
    resolve to a Feature that produces a Body already in this Part - a
    Body's id is always derived from the id of the ExtrudeFeature or (Prompt
    F) RevolveFeature that created (or, after a merge, still identifies) it,
    possibly with a `#N` split-index suffix (see app.document.graph.
    base_feature_id) if that operation produced more than one disconnected
    solid - `base_feature_id` strips that suffix before the lookup, so a
    composite id round-tripped from a prior `/mesh` response validates the
    same way a plain one does.

    Takes `is_cut` (a plain bool) rather than a specific Feature type's own
    mode enum (`ExtrudeType`/`RevolveMode`/`SweepMode`) since Boss/Cut
    parity means this check is now shared by all three Feature types - each
    caller passes its own `... == ....CUT` comparison rather than this
    function needing to know about every mode enum that might ever call
    it."""
    if is_cut and not target_body_ids:
        raise HTTPException(
            status_code=422,
            detail="Cut requires at least one target_body_ids entry - there is nothing to cut "
            "from an empty list",
        )
    for target_id in target_body_ids:
        target_feature = part.get_feature(base_feature_id(target_id))
        if not isinstance(target_feature, (ExtrudeFeature, RevolveFeature, SweepFeature, ImportFeature)):
            raise HTTPException(
                status_code=400,
                detail=f"target_body_ids entry {target_id!r} does not refer to an ExtrudeFeature, "
                "RevolveFeature, SweepFeature, or ImportFeature in this Part",
            )


def _require_closed_sketch_feature(part: Part, sketch_feature_id: str) -> SketchFeature:
    """Validates that `sketch_feature_id` resolves to a SketchFeature in
    `part` whose Sketch has an extrudable Profile - a single 400 for every
    way this can fail, per the brief ("Validate ... return a clear 400
    error if not"). CLOSED_LOOP (a single nested profile, C1) and
    MULTIPLE_LOOPS (a MultiProfile of disjoint outer profiles, C2) are both
    extrudable - see app.document.extrude._solid_for_extrude_feature, which
    this must stay in sync with."""
    feature = part.get_feature(sketch_feature_id)
    if not isinstance(feature, SketchFeature):
        raise HTTPException(
            status_code=400,
            detail="sketch_feature_id does not refer to a SketchFeature in this Part",
        )
    sketch = get_sketch_or_404(feature.sketch_id)
    result = detect_profile(sketch)
    if result.status not in (ProfileStatus.CLOSED_LOOP, ProfileStatus.MULTIPLE_LOOPS):
        raise HTTPException(
            status_code=400,
            detail=f"Sketch does not contain a closed profile (status: {result.status.value})",
        )
    return feature


def _validate_profile_refs(sketch_feature: SketchFeature, profile_refs: list[SketchEntityRef]) -> None:
    """Prompt G: eagerly validates `profile_refs` against `sketch_feature`'s
    *current* Profile detection, discarding the result - fails closed with
    `invalid_profile_ref` (see `app.document.extrude.select_profiles`)
    before ever persisting an Extrude/RevolveFeature with an unusable
    profile selection. Cheap (pure-Python, no OCCT) unlike the rest of
    Extrude's own validation, which stays lazy-only (`_require_closed_
    sketch_feature` above never calls into OCCT either) - `profile_refs` is
    new and error-prone enough to warrant this eager check regardless,
    mirroring Revolve's own `axis_ref`/`resolve_revolve` precedent rather
    than Extrude's older, more permissive convention.

    Called after `_require_closed_sketch_feature` has already confirmed
    `sketch_feature` resolves to a real, currently-extrudable SketchFeature -
    this re-runs `detect_profile` once more (cheap) rather than threading
    that call's own result through, keeping this a standalone, reusable
    check for both Extrude's and Revolve's create/update endpoints."""
    sketch = get_sketch_or_404(sketch_feature.sketch_id)
    result = detect_profile(sketch)
    candidates = [result.profile] if result.status == ProfileStatus.CLOSED_LOOP else result.loops
    select_profiles(candidates, profile_refs)


def _validate_sweep_path_refs(path_refs: list[SketchEntityRef]) -> None:
    """A SweepFeature must name at least one `path_refs` entry (422,
    mirroring Cut's own "at least one target_body_ids entry" check in
    `_validate_target_body_ids`) and every named ref must be a Line (422,
    mirroring `_validate_fillet_edge_refs`'s own `shape_type == EDGE`
    check) - these are payload-shape checks. Whether the named Lines
    actually resolve and chain into one connected path (open or closed) is
    a referential/geometric check made by `app.document.sweep.resolve_
    sweep` instead (the same "payload shape in the router, resolution in
    the OCCT module" split every other structured Feature error in this
    codebase already uses)."""
    if not path_refs:
        raise HTTPException(
            status_code=422,
            detail="SweepFeature requires at least one path_refs entry",
        )
    for ref in path_refs:
        if ref.entity_type != SketchEntityType.LINE:
            raise HTTPException(status_code=422, detail="path_refs entries must have entity_type=line")


def _validate_fillet_radius(radius: float) -> None:
    """Prompt D: mirrors `_validate_extrude_distances`'s own plain-400
    convention for a bare numeric-field check with no structured error
    type - a Fillet's radius must be a positive real number, otherwise
    there is no rounding to construct."""
    if radius <= 0:
        raise HTTPException(status_code=400, detail="radius must be greater than 0")


def _validate_fillet_edge_refs(edge_refs: list[SubShapeRef]) -> None:
    """Prompt D: a FilletFeature must name at least one edge (422, mirroring
    Cut's own "at least one target_body_ids entry" check in
    `_validate_target_body_ids`) and every named ref must actually be an
    edge (422, mirroring `_validate_plane_ref`'s own `shape_type == FACE`
    check) - these are payload-shape checks. Whether the edges actually
    resolve, and whether they all belong to the same Body, is a
    referential/geometric check made by `app.document.fillet.resolve_
    fillet` instead (the same "payload shape in the router, resolution in
    the OCCT module" split every other structured Feature error in this
    codebase already uses)."""
    if not edge_refs:
        raise HTTPException(
            status_code=422,
            detail="FilletFeature requires at least one edge_refs entry",
        )
    for ref in edge_refs:
        if ref.shape_type != SubShapeType.EDGE:
            raise HTTPException(status_code=422, detail="edge_refs entries must have shape_type=EDGE")


def _validate_chamfer_distance(distance: float) -> None:
    """Prompt E: mirrors `_validate_fillet_radius` exactly, substituting
    `distance` for `radius`."""
    if distance <= 0:
        raise HTTPException(status_code=400, detail="distance must be greater than 0")


def _validate_chamfer_edge_refs(edge_refs: list[SubShapeRef]) -> None:
    """Prompt E: mirrors `_validate_fillet_edge_refs` exactly - see that
    function's own doc comment for the full reasoning."""
    if not edge_refs:
        raise HTTPException(
            status_code=422,
            detail="ChamferFeature requires at least one edge_refs entry",
        )
    for ref in edge_refs:
        if ref.shape_type != SubShapeType.EDGE:
            raise HTTPException(status_code=422, detail="edge_refs entries must have shape_type=EDGE")


def _validate_revolve_angle(angle: float) -> None:
    """Prompt F: mirrors `_validate_fillet_radius`/`_validate_chamfer_
    distance`'s own plain-400 convention for a bare numeric-field check -
    `angle` must be in `(0, 360]` (see `app.document.models.RevolveFeature`'s
    own docstring: 360 itself is valid, a full revolve; an arbitrary partial
    angle is just as valid, not just 360-only)."""
    if angle <= 0 or angle > 360:
        raise HTTPException(status_code=400, detail="angle must be greater than 0 and at most 360")


def _all_other_create_plane_fields_empty(
    exclude: set[str],
    *,
    face_refs: list[PlaneRef],
    offset: float | None,
    line_ref: SketchEntityRef | None,
    point_ref: SketchEntityRef | None,
    edge_ref: SubShapeRef | None,
    vertex_ref: SubShapeRef | None,
    point_refs: list[PointRef],
) -> bool:
    """C4: every `CreatePlaneFeature` field not named in `exclude` is empty
    (`None` for a single optional ref/`offset`, `[]` for a list) - the
    "and nothing else" half of `_validate_create_plane_payload`'s per-
    `plane_type` check, split out since C4 grew the field count from four to
    seven and repeating a seven-field emptiness check inline for each of six
    `plane_type` branches would be far more error-prone than one shared
    helper. `offset` is checked via `is None` (not falsiness) so a
    legitimate `offset=0.0` is correctly treated as "set", not "empty"."""
    empty = {
        "face_refs": not face_refs,
        "offset": offset is None,
        "line_ref": line_ref is None,
        "point_ref": point_ref is None,
        "edge_ref": edge_ref is None,
        "vertex_ref": vertex_ref is None,
        "point_refs": not point_refs,
    }
    return all(is_empty for name, is_empty in empty.items() if name not in exclude)


def _validate_plane_ref(part: Part, ref: PlaneRef) -> None:
    """C5: enforces exactly one of `face_ref`/`fixed_plane`/`plane_feature_id`
    is supplied on a single `face_refs` entry, matching `PlaneRef`'s own
    "one of three" convention (see its docstring), and that whichever one is
    supplied is itself well-formed: a `face_ref` must have `shape_type=FACE`
    (the same typed-slot check `_validate_create_plane_payload` already made
    for a bare `SubShapeRef` before C5), and a `plane_feature_id` must name
    a real `CreatePlaneFeature` in this Part (same existence check
    `_validate_sketch_feature_payload` already makes for its own
    `plane_feature_id`) - this runs *before* `resolve_create_plane`, so a
    malformed or dangling reference here is reported as this function's own
    422/400 rather than surfacing as an `AttributeError`/`AssertionError`
    out of `app.document.create_plane._resolve_plane_ref`. A `fixed_plane`
    needs no further check - `Plane` is already a closed enum, so pydantic
    itself rejects anything else."""
    set_count = sum(x is not None for x in (ref.face_ref, ref.fixed_plane, ref.plane_feature_id))
    if set_count != 1:
        raise HTTPException(
            status_code=422,
            detail="Each face_refs entry must have exactly one of face_ref, fixed_plane, or "
            "plane_feature_id",
        )
    if ref.face_ref is not None and ref.face_ref.shape_type != SubShapeType.FACE:
        raise HTTPException(status_code=422, detail="face_refs face_ref entries must have shape_type=FACE")
    if ref.plane_feature_id is not None:
        plane_feature = part.get_feature(ref.plane_feature_id)
        if not isinstance(plane_feature, CreatePlaneFeature):
            raise HTTPException(
                status_code=400,
                detail="face_refs plane_feature_id does not refer to a CreatePlaneFeature in this Part",
            )


def _validate_create_plane_payload(
    part: Part,
    plane_type: PlaneType,
    face_refs: list[PlaneRef],
    offset: float | None,
    line_ref: SketchEntityRef | None,
    point_ref: SketchEntityRef | None,
    edge_ref: SubShapeRef | None = None,
    vertex_ref: SubShapeRef | None = None,
    point_refs: list[PointRef] | None = None,
) -> None:
    """C2/C3/C4/C5: enforces exactly one combination of fields is supplied,
    matching `plane_type` (see `app.document.schemas.CreatePlaneFeatureCreate`
    for the full per-type field list) - a plain-string 422, same convention
    as `_validate_target_body_ids`'s Cut-empty-list case, since (unlike
    `missing_reference`/`non_planar_reference`/`point_not_on_line`/
    `faces_not_parallel`/`non_linear_edge`/`collinear_points`) this doesn't
    name a structured error type for a malformed combination of fields, only
    for a resolvable-but-wrong reference. Also checks each ref's own
    `shape_type`/`entity_type` tag matches its named role - these are typed
    slots, not a generic reference, so a client sending e.g. a POINT ref as
    `line_ref` is already malformed input, not merely an unresolvable-later
    reference. Each `face_refs` entry is additionally checked by
    `_validate_plane_ref` (C5), which is why this now needs `part`.

    Takes the domain (`SubShapeRef`/`SketchEntityRef`/`PointRef`/`PlaneRef`)
    types rather than their pydantic (`...Schema`) counterparts, even though
    the create route below has schema instances on hand - both share the
    same `shape_type`/`entity_type` attribute names, this function only ever
    reads those, and accepting the domain type lets the update route reuse
    this same function against a merged existing-plus-payload value without
    a pointless schema round-trip."""
    point_refs = point_refs or []

    def other_fields_empty(exclude: set[str]) -> bool:
        return _all_other_create_plane_fields_empty(
            exclude,
            face_refs=face_refs,
            offset=offset,
            line_ref=line_ref,
            point_ref=point_ref,
            edge_ref=edge_ref,
            vertex_ref=vertex_ref,
            point_refs=point_refs,
        )

    if plane_type == PlaneType.OFFSET_FACE:
        if len(face_refs) != 1 or offset is None or not other_fields_empty({"face_refs", "offset"}):
            raise HTTPException(
                status_code=422,
                detail="OFFSET_FACE requires exactly one face_refs entry and an offset, and nothing else",
            )
        _validate_plane_ref(part, face_refs[0])
    elif plane_type == PlaneType.MIDPLANE:
        if len(face_refs) != 2 or not other_fields_empty({"face_refs"}):
            raise HTTPException(
                status_code=422,
                detail="MIDPLANE requires exactly two face_refs entries, and nothing else",
            )
        for ref in face_refs:
            _validate_plane_ref(part, ref)
    elif plane_type == PlaneType.NORMAL_TO_LINE_AT_POINT:
        if line_ref is None or point_ref is None or not other_fields_empty({"line_ref", "point_ref"}):
            raise HTTPException(
                status_code=422,
                detail="NORMAL_TO_LINE_AT_POINT requires both line_ref and point_ref, and nothing else",
            )
        if line_ref.entity_type != SketchEntityType.LINE:
            raise HTTPException(status_code=422, detail="line_ref must have entity_type=LINE")
        if point_ref.entity_type != SketchEntityType.POINT:
            raise HTTPException(status_code=422, detail="point_ref must have entity_type=POINT")
    elif plane_type == PlaneType.NORMAL_TO_EDGE_THROUGH_VERTEX:
        if edge_ref is None or vertex_ref is None or not other_fields_empty({"edge_ref", "vertex_ref"}):
            raise HTTPException(
                status_code=422,
                detail="NORMAL_TO_EDGE_THROUGH_VERTEX requires both edge_ref and vertex_ref, and "
                "nothing else",
            )
        if edge_ref.shape_type != SubShapeType.EDGE:
            raise HTTPException(status_code=422, detail="edge_ref must have shape_type=EDGE")
        if vertex_ref.shape_type != SubShapeType.VERTEX:
            raise HTTPException(status_code=422, detail="vertex_ref must have shape_type=VERTEX")
    elif plane_type == PlaneType.PARALLEL_TO_FACE_THROUGH_VERTEX:
        if (
            len(face_refs) != 1
            or vertex_ref is None
            or not other_fields_empty({"face_refs", "vertex_ref"})
        ):
            raise HTTPException(
                status_code=422,
                detail="PARALLEL_TO_FACE_THROUGH_VERTEX requires exactly one face_refs entry and a "
                "vertex_ref, and nothing else",
            )
        _validate_plane_ref(part, face_refs[0])
        if vertex_ref.shape_type != SubShapeType.VERTEX:
            raise HTTPException(status_code=422, detail="vertex_ref must have shape_type=VERTEX")
    else:
        assert plane_type == PlaneType.THREE_POINTS
        if len(point_refs) != 3 or not other_fields_empty({"point_refs"}):
            raise HTTPException(
                status_code=422,
                detail="THREE_POINTS requires exactly three point_refs entries, and nothing else",
            )
        for entry in point_refs:
            if (entry.vertex_ref is None) == (entry.sketch_point_ref is None):
                raise HTTPException(
                    status_code=422,
                    detail="Each point_refs entry must have exactly one of vertex_ref or "
                    "sketch_point_ref",
                )
            if entry.vertex_ref is not None and entry.vertex_ref.shape_type != SubShapeType.VERTEX:
                raise HTTPException(
                    status_code=422, detail="point_refs vertex_ref entries must have shape_type=VERTEX"
                )
            if (
                entry.sketch_point_ref is not None
                and entry.sketch_point_ref.entity_type != SketchEntityType.POINT
            ):
                raise HTTPException(
                    status_code=422,
                    detail="point_refs sketch_point_ref entries must have entity_type=POINT",
                )


def _validate_sketch_feature_payload(
    part: Part, plane: Plane | None, plane_feature_id: str | None
) -> None:
    """C3: enforces exactly one of `plane` (one of the three fixed reference
    planes) or `plane_feature_id` (an existing `CreatePlaneFeature` in this
    Part) is supplied. When `plane_feature_id` is given, it must resolve to
    a real `CreatePlaneFeature` in this Part, and that Plane must currently
    be resolvable (`resolve_create_plane`, discarding its result here - see
    `create_create_plane_feature`'s own docstring for why re-resolving for
    the response afterwards is simpler than threading a resolved value
    through) - a Sketch can never anchor to a since-broken or otherwise
    unresolvable Plane."""
    if (plane is None) == (plane_feature_id is None):
        raise HTTPException(
            status_code=422, detail="Provide exactly one of plane or plane_feature_id"
        )
    if plane_feature_id is not None:
        plane_feature = part.get_feature(plane_feature_id)
        if not isinstance(plane_feature, CreatePlaneFeature):
            raise HTTPException(
                status_code=400,
                detail="plane_feature_id does not refer to a CreatePlaneFeature in this Part",
            )
        resolve_create_plane(part, plane_feature)  # raises on an unresolvable reference


@router.post("/parts", response_model=PartResponse, status_code=201)
def create_part(payload: PartCreate) -> PartResponse:
    part = get_document().add_part(payload.name)
    return _part_response(part)


@router.get("/parts/{part_id}", response_model=PartResponse)
def get_part(part_id: str) -> PartResponse:
    return _part_response(get_part_or_404(part_id))


@router.get("/parts/{part_id}/features", response_model=list[FeatureResponse])
def list_features(part_id: str) -> list[FeatureResponse]:
    part = get_part_or_404(part_id)
    return [_feature_response(part, feature) for feature in part.features]


@router.get("/parts/{part_id}/features/{feature_id}", response_model=FeatureResponse)
def get_feature(part_id: str, feature_id: str) -> FeatureResponse:
    part = get_part_or_404(part_id)
    return _feature_response(part, _get_feature_or_404(part, feature_id))


@router.post(
    "/parts/{part_id}/features/sketch", response_model=SketchFeatureResponse, status_code=201
)
def create_sketch_feature(part_id: str, payload: SketchFeatureCreate) -> SketchFeatureResponse:
    part = get_part_or_404(part_id)
    _validate_sketch_feature_payload(part, payload.plane, payload.plane_feature_id)
    sketch = create_sketch(payload.plane)
    feature = SketchFeature(
        id=str(uuid.uuid4()), sketch_id=sketch.id, plane_feature_id=payload.plane_feature_id
    )
    part.add_feature(feature)
    return _feature_response(part, feature)


@router.post(
    "/parts/{part_id}/extrude-features", response_model=ExtrudeFeatureResponse, status_code=201
)
def create_extrude_feature(part_id: str, payload: ExtrudeFeatureCreate) -> ExtrudeFeatureResponse:
    part = get_part_or_404(part_id)
    sketch_feature = _require_closed_sketch_feature(part, payload.sketch_feature_id)
    _validate_extrude_distances(payload.start_distance, payload.end_distance)
    _validate_target_body_ids(part, payload.extrude_type == ExtrudeType.CUT, payload.target_body_ids)
    profile_refs = [_sketch_entity_ref_to_domain(ref) for ref in payload.profile_refs]
    _validate_profile_refs(sketch_feature, profile_refs)
    feature = ExtrudeFeature(
        id=str(uuid.uuid4()),
        sketch_feature_id=payload.sketch_feature_id,
        extrude_type=payload.extrude_type,
        start_distance=payload.start_distance,
        end_distance=payload.end_distance,
        target_body_ids=list(payload.target_body_ids),
        profile_refs=profile_refs,
    )
    part.add_feature(feature)
    return _feature_response(part, feature)


def _get_extrude_feature_or_404(part: Part, feature_id: str) -> ExtrudeFeature:
    feature = part.get_feature(feature_id)
    if not isinstance(feature, ExtrudeFeature):
        raise HTTPException(status_code=404, detail="Extrude feature not found")
    return feature


@router.patch("/parts/{part_id}/extrude-features/{feature_id}", response_model=ExtrudeFeatureResponse)
def update_extrude_feature(
    part_id: str, feature_id: str, payload: ExtrudeFeatureUpdate
) -> ExtrudeFeatureResponse:
    """B4: any ExtrudeFeature can be edited now, not just the last one in its
    Part - the pre-B4 "only the last Feature is editable" lock only ever
    gated this endpoint and `app.sketch.router`'s Sketch-mutation endpoints
    (see `_ensure_sketch_editable`, removed there for the same reason); it
    never applied to reading a Feature, and `Part.is_locked`/the `locked`
    response field are otherwise untouched (single-`DELETE` still requires
    cascade-delete for anything but the last Feature - B4 is about editing,
    not deleting). Editing a Feature with downstream dependents still
    triggers a normal full recompute of all of them the next time `/mesh` is
    fetched, via A1's existing graph-based recompute path, unchanged by
    this prompt - there is no separate "rollback" concept on this side at
    all, since suppressing downstream Features during an edit is purely a
    client-side concern (`rollback_excluded_feature_ids`, already existed
    before B4 under the `hidden_feature_ids` name it shared with plain
    Hide/Show until the bug fix that split them - see `get_part_mesh`)."""
    part = get_part_or_404(part_id)
    feature = _get_extrude_feature_or_404(part, feature_id)
    new_start = payload.start_distance if payload.start_distance is not None else feature.start_distance
    new_end = payload.end_distance if payload.end_distance is not None else feature.end_distance
    _validate_extrude_distances(new_start, new_end)
    new_extrude_type = payload.extrude_type if payload.extrude_type is not None else feature.extrude_type
    new_target_body_ids = (
        payload.target_body_ids if payload.target_body_ids is not None else feature.target_body_ids
    )
    _validate_target_body_ids(part, new_extrude_type == ExtrudeType.CUT, new_target_body_ids)
    new_profile_refs = (
        [_sketch_entity_ref_to_domain(ref) for ref in payload.profile_refs]
        if payload.profile_refs is not None
        else feature.profile_refs
    )
    sketch_feature = _require_closed_sketch_feature(part, feature.sketch_feature_id)
    _validate_profile_refs(sketch_feature, new_profile_refs)

    feature.extrude_type = new_extrude_type
    feature.start_distance = new_start
    feature.end_distance = new_end
    feature.target_body_ids = list(new_target_body_ids)
    feature.profile_refs = new_profile_refs
    return _feature_response(part, feature)


@router.post(
    "/parts/{part_id}/create-plane-features",
    response_model=CreatePlaneFeatureResponse,
    status_code=201,
)
def create_create_plane_feature(
    part_id: str, payload: CreatePlaneFeatureCreate
) -> CreatePlaneFeatureResponse:
    """C2: never locked-editable-only-if-last from the start (per this
    prompt's own explicit instruction) - unlike `ExtrudeFeatureUpdate`'s
    B4 removal, there is no lock to remove here since this endpoint is new
    after B4 already established "any Feature can be edited" generically.

    Validates the payload shape (`_validate_create_plane_payload`) and then
    resolvability (`resolve_create_plane`, discarding its result here - the
    real geometry is (re)computed again for the response by
    `_feature_response`/`_create_plane_feature_response`, since resolving
    twice is simpler than threading a resolved value through construction,
    and cheap next to the OCCT work `compute_part_bodies` already does)
    *before* constructing the Feature - fails closed with `missing_
    reference`/`non_planar_reference`/`point_not_on_line` rather than ever
    persisting an unresolvable Plane."""
    part = get_part_or_404(part_id)
    face_refs = [_plane_ref_to_domain(ref) for ref in payload.face_refs]
    line_ref = _sketch_entity_ref_to_domain(payload.line_ref) if payload.line_ref else None
    point_ref = _sketch_entity_ref_to_domain(payload.point_ref) if payload.point_ref else None
    edge_ref = _subshape_ref_to_domain(payload.edge_ref) if payload.edge_ref else None
    vertex_ref = _subshape_ref_to_domain(payload.vertex_ref) if payload.vertex_ref else None
    point_refs = [_point_ref_to_domain(ref) for ref in payload.point_refs]
    _validate_create_plane_payload(
        part,
        payload.plane_type,
        face_refs,
        payload.offset,
        line_ref,
        point_ref,
        edge_ref,
        vertex_ref,
        point_refs,
    )
    feature = CreatePlaneFeature(
        id=str(uuid.uuid4()),
        plane_type=payload.plane_type,
        face_refs=face_refs,
        offset=payload.offset,
        line_ref=line_ref,
        point_ref=point_ref,
        edge_ref=edge_ref,
        vertex_ref=vertex_ref,
        point_refs=point_refs,
    )
    resolve_create_plane(part, feature)  # raises on an unresolvable reference; result unused here
    part.add_feature(feature)
    return _feature_response(part, feature)


def _get_create_plane_feature_or_404(part: Part, feature_id: str) -> CreatePlaneFeature:
    feature = part.get_feature(feature_id)
    if not isinstance(feature, CreatePlaneFeature):
        raise HTTPException(status_code=404, detail="Create Plane feature not found")
    return feature


@router.patch(
    "/parts/{part_id}/create-plane-features/{feature_id}",
    response_model=CreatePlaneFeatureResponse,
)
def update_create_plane_feature(
    part_id: str, feature_id: str, payload: CreatePlaneFeatureUpdate
) -> CreatePlaneFeatureResponse:
    """C2: `plane_type` itself is never revised (see `CreatePlaneFeatureUpdate`'s
    own doc comment) - only the refs/offset for whichever type this Feature
    already is. Same validate-before-mutate discipline as
    `create_create_plane_feature`: the merged (existing-plus-payload)
    values are checked (`_validate_create_plane_payload`,
    `resolve_create_plane`) against a scratch Feature before anything on
    the real, stored Feature is touched, so a failed PATCH never leaves it
    half-updated."""
    part = get_part_or_404(part_id)
    feature = _get_create_plane_feature_or_404(part, feature_id)

    new_face_refs = (
        [_plane_ref_to_domain(ref) for ref in payload.face_refs]
        if payload.face_refs is not None
        else feature.face_refs
    )
    new_offset = payload.offset if payload.offset is not None else feature.offset
    new_line_ref = (
        _sketch_entity_ref_to_domain(payload.line_ref)
        if payload.line_ref is not None
        else feature.line_ref
    )
    new_point_ref = (
        _sketch_entity_ref_to_domain(payload.point_ref)
        if payload.point_ref is not None
        else feature.point_ref
    )
    new_edge_ref = (
        _subshape_ref_to_domain(payload.edge_ref) if payload.edge_ref is not None else feature.edge_ref
    )
    new_vertex_ref = (
        _subshape_ref_to_domain(payload.vertex_ref)
        if payload.vertex_ref is not None
        else feature.vertex_ref
    )
    new_point_refs = (
        [_point_ref_to_domain(ref) for ref in payload.point_refs]
        if payload.point_refs is not None
        else feature.point_refs
    )

    _validate_create_plane_payload(
        part,
        feature.plane_type,
        new_face_refs,
        new_offset,
        new_line_ref,
        new_point_ref,
        new_edge_ref,
        new_vertex_ref,
        new_point_refs,
    )
    candidate = CreatePlaneFeature(
        id=feature.id,
        plane_type=feature.plane_type,
        face_refs=new_face_refs,
        offset=new_offset,
        line_ref=new_line_ref,
        point_ref=new_point_ref,
        edge_ref=new_edge_ref,
        vertex_ref=new_vertex_ref,
        point_refs=new_point_refs,
    )
    resolve_create_plane(part, candidate)  # raises on an unresolvable reference

    feature.face_refs = candidate.face_refs
    feature.offset = candidate.offset
    feature.line_ref = candidate.line_ref
    feature.point_ref = candidate.point_ref
    feature.edge_ref = candidate.edge_ref
    feature.vertex_ref = candidate.vertex_ref
    feature.point_refs = candidate.point_refs
    return _feature_response(part, feature)


@router.post(
    "/parts/{part_id}/fillet-features", response_model=FilletFeatureResponse, status_code=201
)
def create_fillet_feature(part_id: str, payload: FilletFeatureCreate) -> FilletFeatureResponse:
    """Prompt D: never locked-editable-only-if-last from the start, same
    instruction as C2/C5 - B4 already established "any Feature can be
    edited" generically before this endpoint existed.

    Validates the payload shape (`_validate_fillet_edge_refs`/
    `_validate_fillet_radius`) and then resolvability
    (`app.document.fillet.resolve_fillet`, discarding its result here - the
    real geometry is recomputed again the next time `/mesh` is fetched, via
    `compute_part_bodies`'s own Fillet handling) *before* constructing the
    Feature - fails closed with `mixed_body_selection`/`fillet_failed`/
    `missing_reference` rather than ever persisting an unresolvable
    Fillet."""
    part = get_part_or_404(part_id)
    edge_refs = [_subshape_ref_to_domain(ref) for ref in payload.edge_refs]
    _validate_fillet_edge_refs(edge_refs)
    _validate_fillet_radius(payload.radius)
    feature = FilletFeature(id=str(uuid.uuid4()), edge_refs=edge_refs, radius=payload.radius)
    resolve_fillet(part, feature)  # raises on an unresolvable reference; result unused here
    part.add_feature(feature)
    return _feature_response(part, feature)


def _get_fillet_feature_or_404(part: Part, feature_id: str) -> FilletFeature:
    feature = part.get_feature(feature_id)
    if not isinstance(feature, FilletFeature):
        raise HTTPException(status_code=404, detail="Fillet feature not found")
    return feature


@router.patch("/parts/{part_id}/fillet-features/{feature_id}", response_model=FilletFeatureResponse)
def update_fillet_feature(
    part_id: str, feature_id: str, payload: FilletFeatureUpdate
) -> FilletFeatureResponse:
    """Same validate-before-mutate discipline as `create_fillet_feature`:
    the merged (existing-plus-payload) values are checked against a scratch
    Feature (same `id` as the real one - `resolve_fillet` excludes that id
    from its own "current bodies" computation for exactly this reason, see
    its own doc comment) before anything on the real, stored Feature is
    touched, so a failed PATCH never leaves it half-updated."""
    part = get_part_or_404(part_id)
    feature = _get_fillet_feature_or_404(part, feature_id)

    new_edge_refs = (
        [_subshape_ref_to_domain(ref) for ref in payload.edge_refs]
        if payload.edge_refs is not None
        else feature.edge_refs
    )
    new_radius = payload.radius if payload.radius is not None else feature.radius
    _validate_fillet_edge_refs(new_edge_refs)
    _validate_fillet_radius(new_radius)

    candidate = FilletFeature(id=feature.id, edge_refs=new_edge_refs, radius=new_radius)
    resolve_fillet(part, candidate)  # raises on an unresolvable reference

    feature.edge_refs = candidate.edge_refs
    feature.radius = candidate.radius
    return _feature_response(part, feature)


@router.post(
    "/parts/{part_id}/chamfer-features", response_model=ChamferFeatureResponse, status_code=201
)
def create_chamfer_feature(part_id: str, payload: ChamferFeatureCreate) -> ChamferFeatureResponse:
    """Prompt E: mirrors `create_fillet_feature` exactly - see that
    function's own doc comment for the full reasoning (unlocked from the
    start, fails closed before ever persisting an unresolvable Chamfer)."""
    part = get_part_or_404(part_id)
    edge_refs = [_subshape_ref_to_domain(ref) for ref in payload.edge_refs]
    _validate_chamfer_edge_refs(edge_refs)
    _validate_chamfer_distance(payload.distance)
    feature = ChamferFeature(id=str(uuid.uuid4()), edge_refs=edge_refs, distance=payload.distance)
    resolve_chamfer(part, feature)  # raises on an unresolvable reference; result unused here
    part.add_feature(feature)
    return _feature_response(part, feature)


def _get_chamfer_feature_or_404(part: Part, feature_id: str) -> ChamferFeature:
    feature = part.get_feature(feature_id)
    if not isinstance(feature, ChamferFeature):
        raise HTTPException(status_code=404, detail="Chamfer feature not found")
    return feature


@router.patch("/parts/{part_id}/chamfer-features/{feature_id}", response_model=ChamferFeatureResponse)
def update_chamfer_feature(
    part_id: str, feature_id: str, payload: ChamferFeatureUpdate
) -> ChamferFeatureResponse:
    """Mirrors `update_fillet_feature` exactly - same validate-before-
    mutate discipline against a scratch Feature sharing the real one's id."""
    part = get_part_or_404(part_id)
    feature = _get_chamfer_feature_or_404(part, feature_id)

    new_edge_refs = (
        [_subshape_ref_to_domain(ref) for ref in payload.edge_refs]
        if payload.edge_refs is not None
        else feature.edge_refs
    )
    new_distance = payload.distance if payload.distance is not None else feature.distance
    _validate_chamfer_edge_refs(new_edge_refs)
    _validate_chamfer_distance(new_distance)

    candidate = ChamferFeature(id=feature.id, edge_refs=new_edge_refs, distance=new_distance)
    resolve_chamfer(part, candidate)  # raises on an unresolvable reference

    feature.edge_refs = candidate.edge_refs
    feature.distance = candidate.distance
    return _feature_response(part, feature)


@router.post(
    "/parts/{part_id}/revolve-features", response_model=RevolveFeatureResponse, status_code=201
)
def create_revolve_feature(part_id: str, payload: RevolveFeatureCreate) -> RevolveFeatureResponse:
    """Prompt F: never locked-editable-only-if-last from the start, same
    instruction as C2/C5/D/E - B4 already established "any Feature can be
    edited" generically before this endpoint existed.

    Validates the payload shape (`_require_closed_sketch_feature`, same
    closed-profile check `ExtrudeFeatureCreate` uses; `_validate_revolve_
    angle`; `_validate_target_body_ids`, generalized to accept a Body from
    either an ExtrudeFeature or a RevolveFeature) and then resolvability
    (`app.document.revolve.resolve_revolve`, discarding its result here - the
    real geometry is recomputed again the next time `/mesh` is fetched, via
    `compute_part_bodies`'s own RevolveFeature handling) *before*
    constructing the Feature - fails closed with `invalid_axis_ref`/
    `revolve_failed`/`missing_reference` rather than ever persisting an
    unresolvable Revolve."""
    part = get_part_or_404(part_id)
    _require_closed_sketch_feature(part, payload.sketch_feature_id)
    _validate_revolve_angle(payload.angle)
    _validate_target_body_ids(part, payload.mode == RevolveMode.CUT, payload.target_body_ids)
    feature = RevolveFeature(
        id=str(uuid.uuid4()),
        sketch_feature_id=payload.sketch_feature_id,
        axis_ref=_sketch_entity_ref_to_domain(payload.axis_ref),
        angle=payload.angle,
        mode=payload.mode,
        target_body_ids=list(payload.target_body_ids),
        profile_refs=[_sketch_entity_ref_to_domain(ref) for ref in payload.profile_refs],
    )
    # Prompt G: profile_refs' own validity (invalid_profile_ref) is checked
    # as part of this same resolve - resolve_revolve_from_bodies calls
    # select_profiles internally, so no separate eager check is needed here
    # the way Extrude's own _validate_profile_refs is (Extrude has no
    # equivalent full-resolve step at create time).
    resolve_revolve(part, feature)  # raises on an unresolvable reference; result unused here
    part.add_feature(feature)
    return _feature_response(part, feature)


def _get_revolve_feature_or_404(part: Part, feature_id: str) -> RevolveFeature:
    feature = part.get_feature(feature_id)
    if not isinstance(feature, RevolveFeature):
        raise HTTPException(status_code=404, detail="Revolve feature not found")
    return feature


@router.patch("/parts/{part_id}/revolve-features/{feature_id}", response_model=RevolveFeatureResponse)
def update_revolve_feature(
    part_id: str, feature_id: str, payload: RevolveFeatureUpdate
) -> RevolveFeatureResponse:
    """Same validate-before-mutate discipline as `create_revolve_feature`:
    the merged (existing-plus-payload) values are checked against a scratch
    Feature sharing the real one's id (`resolve_revolve` excludes that id
    from its own "current bodies" computation for exactly this reason, see
    its own doc comment) before anything on the real, stored Feature is
    touched, so a failed PATCH never leaves it half-updated. `sketch_
    feature_id` is never revised, same as `update_extrude_feature`."""
    part = get_part_or_404(part_id)
    feature = _get_revolve_feature_or_404(part, feature_id)

    new_axis_ref = (
        _sketch_entity_ref_to_domain(payload.axis_ref) if payload.axis_ref is not None else feature.axis_ref
    )
    new_angle = payload.angle if payload.angle is not None else feature.angle
    new_mode = payload.mode if payload.mode is not None else feature.mode
    new_target_body_ids = (
        payload.target_body_ids if payload.target_body_ids is not None else feature.target_body_ids
    )
    new_profile_refs = (
        [_sketch_entity_ref_to_domain(ref) for ref in payload.profile_refs]
        if payload.profile_refs is not None
        else feature.profile_refs
    )
    _validate_revolve_angle(new_angle)
    _validate_target_body_ids(part, new_mode == RevolveMode.CUT, new_target_body_ids)

    candidate = RevolveFeature(
        id=feature.id,
        sketch_feature_id=feature.sketch_feature_id,
        axis_ref=new_axis_ref,
        angle=new_angle,
        mode=new_mode,
        target_body_ids=list(new_target_body_ids),
        profile_refs=new_profile_refs,
    )
    resolve_revolve(part, candidate)  # raises on an unresolvable reference

    feature.axis_ref = candidate.axis_ref
    feature.angle = candidate.angle
    feature.mode = candidate.mode
    feature.target_body_ids = candidate.target_body_ids
    feature.profile_refs = candidate.profile_refs
    return _feature_response(part, feature)


@router.post("/parts/{part_id}/sweep-features", response_model=SweepFeatureResponse, status_code=201)
def create_sweep_feature(part_id: str, payload: SweepFeatureCreate) -> SweepFeatureResponse:
    """Mirrors `create_revolve_feature` exactly, substituting `path_refs`
    for `axis_ref`/`angle`: validates the payload shape (`_require_closed_
    sketch_feature`; `_validate_sweep_path_refs`; `_validate_target_body_
    ids`, generalized to accept a Body from any of Extrude/Revolve/Sweep)
    and then resolvability (`app.document.sweep.resolve_sweep`, discarding
    its result here - the real geometry is recomputed again the next time
    `/mesh` is fetched, via `compute_part_bodies`'s own SweepFeature
    handling) *before* constructing the Feature - fails closed with
    `invalid_path_ref`/`disconnected_path`/`sweep_failed`/`missing_
    reference` rather than ever persisting an unresolvable Sweep."""
    part = get_part_or_404(part_id)
    _require_closed_sketch_feature(part, payload.sketch_feature_id)
    path_refs = [_sketch_entity_ref_to_domain(ref) for ref in payload.path_refs]
    _validate_sweep_path_refs(path_refs)
    _validate_target_body_ids(part, payload.mode == SweepMode.CUT, payload.target_body_ids)
    feature = SweepFeature(
        id=str(uuid.uuid4()),
        sketch_feature_id=payload.sketch_feature_id,
        path_refs=path_refs,
        mode=payload.mode,
        target_body_ids=list(payload.target_body_ids),
        profile_refs=[_sketch_entity_ref_to_domain(ref) for ref in payload.profile_refs],
    )
    # profile_refs' own validity (invalid_profile_ref) is checked as part of
    # this same resolve - resolve_sweep_from_bodies calls select_profiles
    # internally, same as resolve_revolve_from_bodies already does.
    resolve_sweep(part, feature)  # raises on an unresolvable reference; result unused here
    part.add_feature(feature)
    return _feature_response(part, feature)


def _get_sweep_feature_or_404(part: Part, feature_id: str) -> SweepFeature:
    feature = part.get_feature(feature_id)
    if not isinstance(feature, SweepFeature):
        raise HTTPException(status_code=404, detail="Sweep feature not found")
    return feature


@router.patch("/parts/{part_id}/sweep-features/{feature_id}", response_model=SweepFeatureResponse)
def update_sweep_feature(part_id: str, feature_id: str, payload: SweepFeatureUpdate) -> SweepFeatureResponse:
    """Same validate-before-mutate discipline as `create_sweep_feature`/
    `update_revolve_feature`: the merged (existing-plus-payload) values are
    checked against a scratch Feature sharing the real one's id
    (`resolve_sweep` excludes that id from its own "current bodies"
    computation for exactly this reason) before anything on the real,
    stored Feature is touched, so a failed PATCH never leaves it
    half-updated. `sketch_feature_id` is never revised, same as
    `update_revolve_feature`."""
    part = get_part_or_404(part_id)
    feature = _get_sweep_feature_or_404(part, feature_id)

    new_path_refs = (
        [_sketch_entity_ref_to_domain(ref) for ref in payload.path_refs]
        if payload.path_refs is not None
        else feature.path_refs
    )
    new_mode = payload.mode if payload.mode is not None else feature.mode
    new_target_body_ids = (
        payload.target_body_ids if payload.target_body_ids is not None else feature.target_body_ids
    )
    new_profile_refs = (
        [_sketch_entity_ref_to_domain(ref) for ref in payload.profile_refs]
        if payload.profile_refs is not None
        else feature.profile_refs
    )
    _validate_sweep_path_refs(new_path_refs)
    _validate_target_body_ids(part, new_mode == SweepMode.CUT, new_target_body_ids)

    candidate = SweepFeature(
        id=feature.id,
        sketch_feature_id=feature.sketch_feature_id,
        path_refs=new_path_refs,
        mode=new_mode,
        target_body_ids=list(new_target_body_ids),
        profile_refs=new_profile_refs,
    )
    resolve_sweep(part, candidate)  # raises on an unresolvable reference

    feature.path_refs = candidate.path_refs
    feature.mode = candidate.mode
    feature.target_body_ids = candidate.target_body_ids
    feature.profile_refs = candidate.profile_refs
    return _feature_response(part, feature)


@router.post("/parts/{part_id}/import-features", response_model=ImportFeatureResponse, status_code=201)
def create_import_feature(part_id: str, payload: ImportFeatureCreate) -> ImportFeatureResponse:
    """Brings an external file's geometry in as a fixed, non-parametric
    Body (locked-in scope - see `app.document.models.ImportFeature`'s own
    docstring). Never locked-editable-only-if-last from the start, same
    instruction as every other post-B4 Feature endpoint; there is also no
    corresponding PATCH - a dumb, no-parameters Feature has nothing to
    revise, only delete-and-recreate.

    Decodes `data_base64` and validates resolvability (`resolve_import`,
    discarding its result here - the real geometry is recomputed again the
    next time `/mesh` is fetched, via `compute_part_bodies`'s own
    ImportFeature handling) *before* constructing the Feature - fails
    closed with `invalid_import_data`/`import_failed` rather than ever
    persisting an unimportable file."""
    part = get_part_or_404(part_id)
    try:
        source_data = base64.b64decode(payload.data_base64, validate=True)
    except (binascii.Error, ValueError):
        raise HTTPException(status_code=422, detail="data_base64 is not valid base64")
    feature = ImportFeature(id=str(uuid.uuid4()), source_format=payload.source_format, source_data=source_data)
    resolve_import(feature)  # raises on an unimportable file; result unused here
    part.add_feature(feature)
    return _feature_response(part, feature)


@router.delete("/parts/{part_id}/features/{feature_id}", status_code=204)
def delete_feature(part_id: str, feature_id: str) -> None:
    part = get_part_or_404(part_id)
    _get_feature_or_404(part, feature_id)
    if part.is_locked(feature_id):
        raise HTTPException(
            status_code=400,
            detail="Only the last Feature in a Part can be deleted - it is locked because a "
            "later Feature exists. Delete the later Feature(s) first.",
        )
    part.delete_feature(feature_id)


@router.delete(
    "/parts/{part_id}/features/{feature_id}/cascade", response_model=CascadeDeleteResponse
)
def delete_feature_cascade(part_id: str, feature_id: str) -> CascadeDeleteResponse:
    """B2: deletes `feature_id` and every Feature that *actually transitively
    depends on it* per the real dependency graph (A1) - not "every Feature
    after it in the list", which is what this endpoint did before B2 and
    which only happened to match for every scenario where list order and
    dependency order coincide (every pre-A1 single-body Part). Regardless of
    locking - this is the only way to remove a locked Feature, since
    removing it always also removes everything that depends on it being in
    the history. Distinct from `delete_feature` above (which only ever
    removes a single, unlocked, last Feature) precisely so a client can't
    trigger a multi-Feature deletion by accident through the single-delete
    endpoint.

    A Feature with no dependents deletes alone. A Sketch feeding two
    independent Extrudes, deleting only one of them, never touches the
    Sketch or the untouched sibling Extrude - neither is a dependent of the
    deleted one. Deleting the Sketch itself takes both Extrudes (and
    anything downstream of either) with it, since each names the Sketch in
    its own dependency edge (see `app.document.graph.build_feature_graph`/
    `transitive_dependents`).

    Each deleted SketchFeature's underlying Sketch is deleted too, since
    a Sketch created via this Document/Part/Feature flow is owned solely
    by the SketchFeature that wraps it - nothing else references it, so
    nothing else needs it once that SketchFeature is gone. (Sketches
    created directly via the standalone /sketch API, bypassing a Part
    entirely, are never touched here - the only Sketches this loop ever
    sees are the ones already attached to a Feature this Part is deleting.)
    """
    part = get_part_or_404(part_id)
    _get_feature_or_404(part, feature_id)
    to_delete = transitive_dependents(build_feature_graph(part), feature_id)
    deleted_features = part.delete_features(to_delete)

    deleted_sketch_ids = []
    for feature in deleted_features:
        if isinstance(feature, SketchFeature):
            delete_sketch(feature.sketch_id)
            deleted_sketch_ids.append(feature.sketch_id)

    return CascadeDeleteResponse(
        deleted_feature_ids=[f.id for f in deleted_features],
        deleted_sketch_ids=deleted_sketch_ids,
    )


@router.get("/parts/{part_id}/mesh", response_model=list[BodyMeshResponse])
def get_part_mesh(
    part_id: str,
    hidden_feature_ids: list[str] = Query(default=[]),
    rollback_excluded_feature_ids: list[str] = Query(default=[]),
) -> list[BodyMeshResponse]:
    """A1: returns an array of Bodies rather than one combined mesh - each
    entry is one independently-tessellated Body, carrying its own stable
    `body_id` (see app.document.models.ExtrudeFeature's docstring) and its
    own `face_ids`/`edge_ids`/`topology_vertex_ids`, scoped to that Body's
    own tessellation only (not globally unique across the array).

    Placeholder mesh (a fixed box, `body_id="placeholder"`) while the Part
    has no ExtrudeFeature yet, per `Part.produces_solid_geometry` - always
    exactly one entry in that case. Once it does, this instead recomputes
    every ExtrudeFeature's real OCCT geometry (Boss/Cut, in dependency-graph
    order - see app.document.extrude.compute_part_bodies) and tessellates
    each resulting Body independently, before the two exclusion params
    below are applied. A Part whose ExtrudeFeature(s) all genuinely skipped
    (e.g. a Cut with no target left after a real deletion) returns an empty
    array - there is no "real" geometry to show at all, unlike the old
    single-mesh response which still returned an empty mesh tagged
    `source="computed"` for this case. A merely-*hidden* Body is never
    omitted this way (see `hidden_feature_ids` below) - the Build Tree's
    own Bodies section needs every Body's entry to keep listing it.

    Two distinct client-side exclusion sets, deliberately kept separate
    (bug fix, post-C4 - see `compute_part_bodies`'s own docstring for the
    full incident writeup of why conflating them broke Create Plane):

    - `hidden_feature_ids` is the client's plain Hide/Show state
      (`PartScreen._hiddenFeatureIds`) - purely cosmetic. Every Body is
      still fully computed against the Part's real, unmodified history (so
      a Plane anchored to a hidden Body's face, and anything built on that
      Plane, keeps resolving normally) *and* still included in this
      response - only `BodyMeshResponse.hidden` is set, by mapping the
      Body's `body_id` back to the ExtrudeFeature that produced it
      (`base_feature_id` - handles the `#N` multi-solid-split suffix) and
      checking that id against this set. The client is responsible for not
      rendering/hit-testing a `hidden` Body in the 3D viewport (and
      excluding it from camera-fit bounds) - this endpoint's own job is
      just to report the full, current state honestly.

    - `rollback_excluded_feature_ids` is B4 true-rollback's "pretend these
      Features (and hence anything depending on them) don't exist yet"
      state - fed straight into `compute_part_bodies`, which skips a named
      ExtrudeFeature's own computation entirely, exactly as before this fix
      (correct for rollback: a downstream Feature genuinely should fail to
      resolve if what it depends on is being edited out from under it, and
      there is truly no Body to report at all - not even a hidden one).

    Both are purely client-side and never persisted here; the client
    re-sends whichever apply on every mesh fetch."""
    part = get_part_or_404(part_id)

    if not part.produces_solid_geometry:
        box = BRepPrimAPI_MakeBox(10.0, 10.0, 10.0).Shape()
        mesh_data = tessellate_shape(box, DEFAULT_MESH_QUALITY)
        return [
            BodyMeshResponse(
                body_id=_PLACEHOLDER_BODY_ID, source="placeholder", mesh=_mesh_vertex_data(mesh_data)
            )
        ]

    bodies = compute_part_bodies(part, frozenset(rollback_excluded_feature_ids))
    hidden = frozenset(hidden_feature_ids)
    return [
        BodyMeshResponse(
            body_id=body_id,
            source="computed",
            mesh=_mesh_vertex_data(tessellate_shape(shape, DEFAULT_MESH_QUALITY)),
            hidden=base_feature_id(body_id) in hidden,
        )
        for body_id, shape in bodies.items()
    ]


@router.get("/export/native")
def export_native_document() -> dict:
    """Native Save: hands back the whole in-memory Document (every Part's
    ordered Feature list) plus every Sketch referenced by any SketchFeature
    in it, as a plain JSON dict - no cached mesh/geometry (see
    `app.document.native_format.export_native`'s own docstring for the full
    "pure parametric tree" rationale). Client-owned files (locked-in scope):
    the backend has no project storage of its own, this is the client's one
    chance to read the full state out before it writes the actual file to
    disk."""
    return export_native(get_document(), all_sketches())


@router.post("/import/native", response_model=NativeImportResponse)
def import_native_document(payload: dict) -> NativeImportResponse:
    """Native Load: the inverse of `export_native_document` - a full
    replace, not a merge (client-owned files, locked-in scope): whatever
    Document/Sketches were open before this call are discarded entirely in
    favor of exactly what `payload` describes. Fails closed with a 422 for
    anything malformed (`NativeFormatError` - an unsupported schema_version,
    an unknown Feature/entity/constraint type, a missing required field)
    *before* either store is touched, so a bad import can never leave the
    process in a half-replaced state."""
    try:
        document, sketches = import_native(payload)
    except NativeFormatError as exc:
        raise HTTPException(status_code=422, detail=f"Invalid native file: {exc}")
    replace_document(document)
    replace_all_sketches(sketches)
    return NativeImportResponse(document_id=document.id, part_ids=list(document.parts.keys()))


def _export_bodies_or_400(part: Part) -> dict[str, object]:
    """The current Body map every export format below shares (per
    `compute_part_bodies`, the same source of truth `/mesh` tessellates
    from) - 400s up front for a Part with nothing to export, rather than
    each format silently emitting an empty/invalid file."""
    if not part.produces_solid_geometry:
        raise HTTPException(status_code=400, detail="Part has no solid geometry to export")
    bodies = compute_part_bodies(part)
    if not bodies:
        raise HTTPException(status_code=400, detail="Part has no solid geometry to export")
    return bodies


def _merged_body_mesh_data(bodies: dict[str, object]) -> MeshData:
    """Tessellates every Body in `bodies` and concatenates them into one
    flat `MeshData`, offsetting each Body's own triangle indices past
    whatever's already been appended - a single combined mesh per Part,
    matching a single exported STL/OBJ/glb file (unlike `/mesh`, which
    deliberately keeps Bodies separate for the viewport's own per-Body
    hit-testing - export has no such need)."""
    merged = MeshData()
    for shape in bodies.values():
        body_mesh = tessellate_shape(shape, DEFAULT_MESH_QUALITY)
        offset = len(merged.vertices)
        merged.vertices.extend(body_mesh.vertices)
        merged.normals.extend(body_mesh.normals)
        merged.triangles.extend(
            Triangle(a=t.a + offset, b=t.b + offset, c=t.c + offset) for t in body_mesh.triangles
        )
    return merged


@router.get("/parts/{part_id}/export/step")
def export_part_step(part_id: str) -> Response:
    """AP242 STEP export (locked-in scope) of every current Body in this
    Part - see `app.document.step_export.export_step`'s own docstring for
    why AP242 is written now even with no PMI/MBD populated yet."""
    part = get_part_or_404(part_id)
    bodies = _export_bodies_or_400(part)
    data = export_step(bodies)
    return Response(
        content=data,
        media_type="application/step",
        headers={"Content-Disposition": f'attachment; filename="{part.name}.step"'},
    )


@router.get("/parts/{part_id}/export/stl")
def export_part_stl(part_id: str) -> Response:
    part = get_part_or_404(part_id)
    bodies = _export_bodies_or_400(part)
    data = encode_stl(_merged_body_mesh_data(bodies))
    return Response(
        content=data,
        media_type="model/stl",
        headers={"Content-Disposition": f'attachment; filename="{part.name}.stl"'},
    )


@router.get("/parts/{part_id}/export/obj")
def export_part_obj(part_id: str) -> Response:
    part = get_part_or_404(part_id)
    bodies = _export_bodies_or_400(part)
    data = encode_obj(_merged_body_mesh_data(bodies)).encode("utf-8")
    return Response(
        content=data,
        media_type="text/plain",
        headers={"Content-Disposition": f'attachment; filename="{part.name}.obj"'},
    )


@router.get("/parts/{part_id}/export/glb")
def export_part_glb(part_id: str) -> Response:
    part = get_part_or_404(part_id)
    bodies = _export_bodies_or_400(part)
    data = encode_glb(_merged_body_mesh_data(bodies))
    return Response(
        content=data,
        media_type="model/gltf-binary",
        headers={"Content-Disposition": f'attachment; filename="{part.name}.glb"'},
    )
