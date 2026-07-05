import logging
import uuid

from fastapi import APIRouter, HTTPException, Query
from OCC.Core.BRepPrimAPI import BRepPrimAPI_MakeBox

from app.document.create_plane import resolve_create_plane
from app.document.extrude import compute_part_bodies
from app.document.graph import base_feature_id, build_feature_graph, transitive_dependents
from app.document.mesh import DEFAULT_MESH_QUALITY, MeshData, tessellate_shape
from app.document.models import (
    CreatePlaneFeature,
    ExtrudeFeature,
    ExtrudeType,
    Feature,
    Part,
    PlaneRef,
    PlaneType,
    PointRef,
    SketchFeature,
    SubShapeRef,
    SubShapeType,
)
from app.document.schemas import (
    BodyMeshResponse,
    CascadeDeleteResponse,
    CreatePlaneFeatureCreate,
    CreatePlaneFeatureResponse,
    CreatePlaneFeatureUpdate,
    ExtrudeFeatureCreate,
    ExtrudeFeatureResponse,
    ExtrudeFeatureUpdate,
    FeatureResponse,
    MeshVertexData,
    PartCreate,
    PartResponse,
    PlaneRefSchema,
    PointRefSchema,
    SketchEntityRefSchema,
    SketchFeatureCreate,
    SketchFeatureResponse,
    SubShapeRefSchema,
)
from app.document.store import get_document, get_part_or_404
from app.sketch.models import Plane, SketchEntityRef, SketchEntityType
from app.sketch.profile import ProfileStatus, detect_profile
from app.sketch.store import create_sketch, delete_sketch, get_sketch_or_404

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
            produces=feature.produces,
        )
    if isinstance(feature, CreatePlaneFeature):
        return _create_plane_feature_response(part, feature)
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


def _validate_target_body_ids(
    part: Part, extrude_type: ExtrudeType, target_body_ids: list[str]
) -> None:
    """A1: Cut must name at least one target Body - there is nothing to
    subtract from an empty list, so this is a structured-validation-error
    case (422, `{"detail": "..."}` - the same plain-HTTPException shape
    every other validation error in this API uses, e.g.
    `_validate_extrude_distances`'s 400). Every named id (Boss or Cut) must
    resolve to an ExtrudeFeature already in this Part - a Body's id is
    always derived from the id of the ExtrudeFeature that created (or,
    after a merge, still identifies) it, possibly with a `#N` split-index
    suffix (see app.document.graph.base_feature_id) if that operation
    produced more than one disconnected solid - `base_feature_id` strips
    that suffix before the lookup, so a composite id round-tripped from a
    prior `/mesh` response validates the same way a plain one does."""
    if extrude_type == ExtrudeType.CUT and not target_body_ids:
        raise HTTPException(
            status_code=422,
            detail="Cut requires at least one target_body_ids entry - there is nothing to cut "
            "from an empty list",
        )
    for target_id in target_body_ids:
        target_feature = part.get_feature(base_feature_id(target_id))
        if not isinstance(target_feature, ExtrudeFeature):
            raise HTTPException(
                status_code=400,
                detail=f"target_body_ids entry {target_id!r} does not refer to an ExtrudeFeature "
                "in this Part",
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
    _require_closed_sketch_feature(part, payload.sketch_feature_id)
    _validate_extrude_distances(payload.start_distance, payload.end_distance)
    _validate_target_body_ids(part, payload.extrude_type, payload.target_body_ids)
    feature = ExtrudeFeature(
        id=str(uuid.uuid4()),
        sketch_feature_id=payload.sketch_feature_id,
        extrude_type=payload.extrude_type,
        start_distance=payload.start_distance,
        end_distance=payload.end_distance,
        target_body_ids=list(payload.target_body_ids),
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
    _validate_target_body_ids(part, new_extrude_type, new_target_body_ids)

    feature.extrude_type = new_extrude_type
    feature.start_distance = new_start
    feature.end_distance = new_end
    feature.target_body_ids = list(new_target_body_ids)
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
