import base64
import binascii
import logging
import math
import uuid
from typing import Literal

from fastapi import APIRouter, Depends, HTTPException, Query, Response
from OCC.Core.BRepPrimAPI import BRepPrimAPI_MakeBox
from OCC.Core.TopoDS import TopoDS_Shape

from app.document.ai_plan import validate_ai_plan as validate_ai_plan_steps
from app.document.ai_plan_schemas import PlanValidateRequest, PlanValidateResponse
from app.document.bevel import _spiral_hand_from_feature, resolve_bevel_gear, resolve_bevel_gear_coarse
from app.document.bevel_pair import resolve_bevel_pair, resolve_bevel_pair_coarse, resolve_member_profile_shifts
from app.document.chamfer import resolve_chamfer
from app.document.jobs import JobStatus, cancel_job, get_job, submit_bevel_pair_job, submit_planetary_job
from app.document.create_plane import (
    basis_for_sketch,
    refresh_external_references,
    resolve_create_plane,
    resolve_external_vertex_position,
)
from app.document.extrude import (
    _register_solids,
    cached_feature_warnings,
    coarse_eligible_feature_ids,
    compute_part_bodies,
    compute_part_bodies_coarse,
    edge_endpoint_vertex_refs,
    resolve_circular_edge_arc,
    resolve_full_circular_edge,
    select_profiles,
)
from app.document.fillet import resolve_fillet
from app.document.measure import MeasurementResult, measure as compute_measurement
from app.document.gear import resolve_gear, resolve_gear_coarse, resolve_gear_profile_shift
from app.document.gear_math import (
    GearGeometryError,
    default_rack_backing_height,
    full_gear_profile_points,
    full_rack_profile_points,
    planetary_planet_tooth_count,
    rack_length as gear_math_rack_length,
    rack_tooth_geometry,
    spur_gear_geometry,
    undercut_warning,
    validate_planetary_assembly,
)
from app.document.gear_chain_math import (
    ChainMemberKind,
    ChainMemberSpec,
    ChainStageSpec,
    LinkRatio,
    chain_overall_ratio,
    compound_transition_ratio,
    mesh_link_ratio,
    meshing_phase_base,
    pitch_radius,
    propagate_meshing_phase,
    rack_meshing_phase_base,
    resolve_chain as resolve_chain_positions_and_interference,
)
from app.document.bevel_math import (
    BevelGearGeometry,
    bevel_gear_geometry,
    bevel_pair_mesh_preview,
    max_recommended_face_width,
    pitch_cone_half_angles,
    spiral_hand_mismatch_warning,
)
from app.document.rack import resolve_rack
from app.document.loft import resolve_loft, resolve_loft_coarse
from app.document.gear_chain import resolve_gear_chain, resolve_gear_chain_coarse
from app.document.planetary_gear import resolve_planetary, resolve_planetary_coarse
from app.document.graph import (
    base_feature_id,
    build_feature_graph,
    excluded_feature_ids_after,
    tool_feature_qualifies,
    transitive_dependents,
)
from app.document.import_geometry import resolve_import
from app.document.mesh import DEFAULT_MESH_QUALITY, MeshData, mesh_quality_from_slider, tessellate_shape
from app.document.mesh_data import Triangle
from app.document.mesh_export import encode_glb, encode_obj, encode_stl
from app.document.mirror import resolve_mirror
from app.document.native_format import NativeFormatError, export_native, import_native
from app.document.pattern import resolve_pattern, resolve_pattern_coarse
from app.document.step_export import export_step
from app.document.models import (
    BevelGearFeature,
    BevelGearType,
    BevelPairFeature,
    BevelPairMemberSpec,
    BooleanFeature,
    ChamferFeature,
    CreatePlaneFeature,
    DeleteBodyFeature,
    DeleteFaceFeature,
    Document,
    ExtrudeFeature,
    ExtrudeType,
    Feature,
    FilletFeature,
    FixedAxis,
    GearChainFeature,
    GearChainMemberSpec,
    GearChainMemberType,
    GearChainStage,
    GearFeature,
    GearGroup,
    GearType,
    ImportFeature,
    ImportSourceFormat,
    LoftFeature,
    LoftMode,
    LoftSection,
    MergeFeature,
    MergeMode,
    MirrorFeature,
    MoveBodyFeature,
    MoveFaceFeature,
    Part,
    PatternAxisRef,
    PatternDirectionRef,
    PatternFeature,
    PatternType,
    PlanetaryGearFeature,
    PlaneRef,
    PlaneType,
    PointRef,
    Produces,
    RackFeature,
    RackType,
    RevolveFeature,
    RevolveMode,
    ScaleBodyFeature,
    SketchFeature,
    SplitFeature,
    SplitToolRef,
    SubShapeRef,
    SubShapeType,
    SurfaceFeature,
    SweepFeature,
    SweepMode,
)
from app.document.revolve import resolve_revolve
from app.document.delete_face import resolve_delete_face
from app.document.move_body import resolve_move_body
from app.document.move_face import resolve_move_face
from app.document.scale_body import resolve_scale_body
from app.document.schemas import (
    BevelGearFeatureCreate,
    BevelGearFeatureResponse,
    BevelGearFeatureUpdate,
    BevelPairFeatureCreate,
    BevelPairFeatureResponse,
    BevelPairFeatureUpdate,
    JobCancelResponse,
    JobCreateResponse,
    JobStatusResponse,
    BevelPairMemberSpecSchema,
    BevelPairMeshPreviewResult,
    BodyMeshResponse,
    BooleanFeatureCreate,
    BooleanFeatureResponse,
    BooleanFeatureUpdate,
    CascadeDeletePreviewResponse,
    CascadeDeleteResponse,
    ChamferFeatureCreate,
    ChamferFeatureResponse,
    ChamferFeatureUpdate,
    ConvertEdgeCreate,
    ConvertEdgeResponse,
    ConvertVertexCreate,
    CreatePlaneFeatureCreate,
    CreatePlaneFeatureResponse,
    CreatePlaneFeatureUpdate,
    DeleteBodyFeatureCreate,
    DeleteBodyFeatureResponse,
    DeleteBodyFeatureUpdate,
    DeleteFaceFeatureCreate,
    DeleteFaceFeatureResponse,
    DeleteFaceFeatureUpdate,
    ExternalEdgeReferenceCreate,
    MoveBodyFeatureCreate,
    MoveBodyFeatureResponse,
    MoveBodyFeatureUpdate,
    MoveFaceFeatureCreate,
    MoveFaceFeatureResponse,
    MoveFaceFeatureUpdate,
    AxisSchema,
    MeasureRequest,
    MeasurementResultSchema,
    ScaleBodyFeatureCreate,
    ScaleBodyFeatureResponse,
    ScaleBodyFeatureUpdate,
    ExternalEdgeReferenceResponse,
    ExternalVertexReferenceCreate,
    ExtrudeFeatureCreate,
    ExtrudeFeatureResponse,
    ExtrudeFeatureUpdate,
    FeatureResponse,
    FilletFeatureCreate,
    FilletFeatureResponse,
    FilletFeatureUpdate,
    GearChainFeatureCreate,
    GearChainFeatureResponse,
    GearChainFeatureUpdate,
    GearChainMemberSpecSchema,
    GearChainStageSchema,
    GearFeatureCreate,
    GearFeatureResponse,
    GearFeatureUpdate,
    GearGroupSchema,
    GearPreviewBevelGearRequest,
    GearPreviewBevelMember,
    GearPreviewBevelPairMemberRequest,
    GearPreviewBevelPairRequest,
    GearPreviewBevelPairResult,
    GearPreviewChainRequest,
    GearPreviewChainResult,
    GearPreviewInterferenceFinding,
    GearPreviewLink,
    GearPreviewMember,
    GearPreviewPlanetaryRequest,
    GearPreviewPlanetaryResult,
    GearPreviewRequest,
    GearPreviewResponse,
    ImportFeatureCreate,
    ImportFeatureResponse,
    LoftFeatureCreate,
    LoftFeatureResponse,
    LoftFeatureUpdate,
    LoftSectionSchema,
    MergeFeatureCreate,
    MergeFeatureResponse,
    MergeFeatureUpdate,
    MeshVertexData,
    MirrorFeatureCreate,
    MirrorFeatureResponse,
    MirrorFeatureUpdate,
    NativeImportResponse,
    PartCreate,
    PartResponse,
    PatternAxisRefSchema,
    PatternDirectionRefSchema,
    PatternFeatureCreate,
    PatternFeatureResponse,
    PatternFeatureUpdate,
    PlanetaryGearFeatureCreate,
    PlanetaryGearFeatureResponse,
    PlanetaryGearFeatureUpdate,
    PlaneRefSchema,
    PointRefSchema,
    RackFeatureCreate,
    RackFeatureResponse,
    RackFeatureUpdate,
    RevolveFeatureCreate,
    RevolveFeatureResponse,
    RevolveFeatureUpdate,
    SketchEntityRefSchema,
    SketchFeatureCreate,
    SketchFeatureResponse,
    SplitFeatureCreate,
    SplitFeatureResponse,
    SplitFeatureUpdate,
    SplitToolRefSchema,
    SubShapeRefSchema,
    SurfaceFeatureCreate,
    SurfaceFeatureResponse,
    SurfaceFeatureUpdate,
    SweepFeatureCreate,
    SweepFeatureResponse,
    SweepFeatureUpdate,
)
from app.document.split import CONNECTABLE_CURVE_ENTITY_TYPES, resolve_split
from app.document.sweep import resolve_sweep
from app.document.store import get_document, get_part_or_404, replace_document
from app.session_context import bind_session_id
from app.sketch.models import ExternalVertexReference, Plane, SketchEntityRef, SketchEntityType
from app.sketch.profile import ProfileStatus, detect_profile
from app.sketch.schemas import ArcResponse, CircleResponse, LineResponse, PointResponse
from app.sketch.store import all_sketches, create_sketch, delete_sketch, get_sketch_or_404, replace_all_sketches

logger = logging.getLogger(__name__)

# `bind_session_id` (not "default" for every caller) is what keeps this
# router's Document/Sketch state from being shared across every connection
# to the backend - see app.session_context's docstring.
router = APIRouter(prefix="/document", tags=["document"], dependencies=[Depends(bind_session_id)])

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


def _loft_section_to_domain(schema: LoftSectionSchema) -> LoftSection:
    return LoftSection(
        sketch_feature_id=schema.sketch_feature_id,
        profile_refs=[_sketch_entity_ref_to_domain(ref) for ref in schema.profile_refs],
        reference_point=_sketch_entity_ref_to_domain(schema.reference_point)
        if schema.reference_point
        else None,
        alignment_point=_sketch_entity_ref_to_domain(schema.alignment_point)
        if schema.alignment_point
        else None,
    )


def _loft_section_to_schema(section: LoftSection) -> LoftSectionSchema:
    return LoftSectionSchema(
        sketch_feature_id=section.sketch_feature_id,
        profile_refs=[_sketch_entity_ref_to_schema(ref) for ref in section.profile_refs],
        reference_point=_sketch_entity_ref_to_schema(section.reference_point)
        if section.reference_point
        else None,
        alignment_point=_sketch_entity_ref_to_schema(section.alignment_point)
        if section.alignment_point
        else None,
    )


def _gear_group_to_domain(schema: GearGroupSchema) -> GearGroup:
    return GearGroup(
        id=schema.id,
        module=schema.module,
        pressure_angle_degrees=schema.pressure_angle_degrees,
        display_color=schema.display_color,
    )


def _gear_group_to_schema(group: GearGroup) -> GearGroupSchema:
    return GearGroupSchema(
        id=group.id,
        module=group.module,
        pressure_angle_degrees=group.pressure_angle_degrees,
        display_color=group.display_color,
    )


def _gear_chain_member_to_domain(schema: GearChainMemberSpecSchema) -> GearChainMemberSpec:
    return GearChainMemberSpec(
        member_type=schema.member_type,
        group_id=schema.group_id,
        tooth_count=schema.tooth_count,
        face_width=schema.face_width,
        outer_diameter=schema.outer_diameter,
    )


def _gear_chain_member_to_schema(member: GearChainMemberSpec) -> GearChainMemberSpecSchema:
    return GearChainMemberSpecSchema(
        member_type=member.member_type,
        group_id=member.group_id,
        tooth_count=member.tooth_count,
        face_width=member.face_width,
        outer_diameter=member.outer_diameter,
    )


def _gear_chain_stage_to_domain(schema: GearChainStageSchema) -> GearChainStage:
    return GearChainStage(
        turn_angle_degrees=schema.turn_angle_degrees,
        member=_gear_chain_member_to_domain(schema.member) if schema.member is not None else None,
        compound_member_a=_gear_chain_member_to_domain(schema.compound_member_a)
        if schema.compound_member_a is not None
        else None,
        compound_member_b=_gear_chain_member_to_domain(schema.compound_member_b)
        if schema.compound_member_b is not None
        else None,
        compound_axial_offset=schema.compound_axial_offset,
        compound_merge=schema.compound_merge,
    )


def _gear_chain_stage_to_schema(stage: GearChainStage) -> GearChainStageSchema:
    return GearChainStageSchema(
        turn_angle_degrees=stage.turn_angle_degrees,
        member=_gear_chain_member_to_schema(stage.member) if stage.member is not None else None,
        compound_member_a=_gear_chain_member_to_schema(stage.compound_member_a)
        if stage.compound_member_a is not None
        else None,
        compound_member_b=_gear_chain_member_to_schema(stage.compound_member_b)
        if stage.compound_member_b is not None
        else None,
        compound_axial_offset=stage.compound_axial_offset,
        compound_merge=stage.compound_merge,
    )


def _bevel_pair_member_to_domain(schema: BevelPairMemberSpecSchema) -> BevelPairMemberSpec:
    return BevelPairMemberSpec(
        tooth_count=schema.tooth_count, profile_shift=schema.profile_shift, spiral_hand=schema.spiral_hand
    )


def _bevel_pair_member_to_schema(member: BevelPairMemberSpec) -> BevelPairMemberSpecSchema:
    return BevelPairMemberSpecSchema(
        tooth_count=member.tooth_count, profile_shift=member.profile_shift, spiral_hand=member.spiral_hand
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


def _split_tool_ref_to_domain(schema: SplitToolRefSchema) -> SplitToolRef:
    return SplitToolRef(
        plane_ref=_plane_ref_to_domain(schema.plane_ref) if schema.plane_ref else None,
        surface_feature_id=schema.surface_feature_id,
        sketch_line_ref=_sketch_entity_ref_to_domain(schema.sketch_line_ref) if schema.sketch_line_ref else None,
    )


def _split_tool_ref_to_schema(ref: SplitToolRef) -> SplitToolRefSchema:
    return SplitToolRefSchema(
        plane_ref=_plane_ref_to_schema(ref.plane_ref) if ref.plane_ref else None,
        surface_feature_id=ref.surface_feature_id,
        sketch_line_ref=_sketch_entity_ref_to_schema(ref.sketch_line_ref) if ref.sketch_line_ref else None,
    )


def _pattern_direction_ref_to_domain(schema: PatternDirectionRefSchema) -> PatternDirectionRef:
    return PatternDirectionRef(
        edge_ref=_subshape_ref_to_domain(schema.edge_ref) if schema.edge_ref else None,
        sketch_line_ref=_sketch_entity_ref_to_domain(schema.sketch_line_ref)
        if schema.sketch_line_ref
        else None,
        fixed_axis=schema.fixed_axis,
    )


def _pattern_direction_ref_to_schema(ref: PatternDirectionRef) -> PatternDirectionRefSchema:
    return PatternDirectionRefSchema(
        edge_ref=_subshape_ref_to_schema(ref.edge_ref) if ref.edge_ref else None,
        sketch_line_ref=_sketch_entity_ref_to_schema(ref.sketch_line_ref) if ref.sketch_line_ref else None,
        fixed_axis=ref.fixed_axis,
    )


def _pattern_axis_ref_to_domain(schema: PatternAxisRefSchema) -> PatternAxisRef:
    return PatternAxisRef(
        edge_ref=_subshape_ref_to_domain(schema.edge_ref) if schema.edge_ref else None,
        face_ref=_subshape_ref_to_domain(schema.face_ref) if schema.face_ref else None,
        sketch_line_ref=_sketch_entity_ref_to_domain(schema.sketch_line_ref)
        if schema.sketch_line_ref
        else None,
    )


def _pattern_axis_ref_to_schema(ref: PatternAxisRef) -> PatternAxisRefSchema:
    return PatternAxisRefSchema(
        edge_ref=_subshape_ref_to_schema(ref.edge_ref) if ref.edge_ref else None,
        face_ref=_subshape_ref_to_schema(ref.face_ref) if ref.face_ref else None,
        sketch_line_ref=_sketch_entity_ref_to_schema(ref.sketch_line_ref) if ref.sketch_line_ref else None,
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
    the fallback.

    Bug fix: resolves against `excluded_feature_ids_after`'s own
    causally-consistent snapshot (excludes every Feature that comes after
    this one) rather than the Part's fully-built one - see that helper's
    own docstring for the full "why" (this Plane's own face reference
    silently resolving to a different face once a later Feature, e.g. a
    Cut, modifies the same Body it's anchored to)."""
    try:
        resolved = resolve_create_plane(part, feature, excluded_feature_ids_after(part, feature.id))
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


def _sketch_has_lost_reference(part: Part, feature: SketchFeature) -> bool:
    """Sketcher-roadmap Phase 4.3 v1: whether `feature`'s own Sketch has at
    least one `external_references` entry that no longer resolves against
    the Part's *current* Bodies - same soft-fail-without-raising story as
    `_create_plane_feature_response`'s own `origin`/`normal` resolution:
    any failure (an unresolvable reference, or the Part's Bodies failing to
    compute at all for an unrelated reason) is treated as "lost" rather
    than propagating and failing the whole `GET .../features` list.
    Short-circuits to `False` without touching OCCT at all for the common
    case (a Sketch with no external references), so this costs nothing for
    every Sketch that doesn't use the feature.

    Bug fix: resolves (and, via `refresh_external_references`, persists)
    each external reference against `excluded_feature_ids_after`'s own
    causally-consistent snapshot rather than the Part's fully-built one -
    see that helper's own docstring for the full "why" (a stored vertex/
    edge index silently relocating to the wrong Body feature once a later
    Feature modifies the very Body this Sketch references)."""
    sketch = all_sketches().get(feature.sketch_id)
    if sketch is None or not sketch.external_references:
        return False
    try:
        excluded = excluded_feature_ids_after(part, feature.id)
        bodies = compute_part_bodies(part, excluded)
        lost_point_ids = refresh_external_references(part, sketch, bodies, excluded)
    except HTTPException:
        logger.warning("SketchFeature %s could not refresh its external references", feature.id)
        return True
    return bool(lost_point_ids)


def _feature_response(part: Part, feature: Feature) -> FeatureResponse:
    if isinstance(feature, SketchFeature):
        return SketchFeatureResponse(
            id=feature.id,
            sketch_id=feature.sketch_id,
            plane_feature_id=feature.plane_feature_id,
            has_lost_reference=_sketch_has_lost_reference(part, feature),
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
    if isinstance(feature, SurfaceFeature):
        return SurfaceFeatureResponse(
            id=feature.id,
            sketch_feature_id=feature.sketch_feature_id,
            start_distance=feature.start_distance,
            end_distance=feature.end_distance,
            direction_ref=_pattern_direction_ref_to_schema(feature.direction_ref)
            if feature.direction_ref
            else None,
            profile_refs=[_sketch_entity_ref_to_schema(ref) for ref in feature.profile_refs],
            locked=part.is_locked(feature.id),
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
    if isinstance(feature, MirrorFeature):
        return MirrorFeatureResponse(
            id=feature.id,
            source_body_ids=feature.source_body_ids,
            source_feature_ids=feature.source_feature_ids,
            mirror_plane=_plane_ref_to_schema(feature.mirror_plane),
            merge=feature.merge,
            tool_feature_id=feature.tool_feature_id,
            locked=part.is_locked(feature.id),
            produces=feature.produces,
        )
    if isinstance(feature, MergeFeature):
        return MergeFeatureResponse(
            id=feature.id,
            body_ids=feature.body_ids,
            locked=part.is_locked(feature.id),
            produces=feature.produces,
        )
    if isinstance(feature, BooleanFeature):
        return BooleanFeatureResponse(
            id=feature.id,
            operation=feature.operation,
            target_body_ids=feature.target_body_ids,
            tool_body_ids=feature.tool_body_ids,
            consume_tool_bodies=feature.consume_tool_bodies,
            locked=part.is_locked(feature.id),
            produces=feature.produces,
        )
    if isinstance(feature, DeleteBodyFeature):
        return DeleteBodyFeatureResponse(
            id=feature.id,
            body_ids=feature.body_ids,
            locked=part.is_locked(feature.id),
            produces=feature.produces,
        )
    if isinstance(feature, ScaleBodyFeature):
        return ScaleBodyFeatureResponse(
            id=feature.id,
            body_id=feature.body_id,
            factor=feature.factor,
            locked=part.is_locked(feature.id),
            produces=feature.produces,
        )
    if isinstance(feature, MoveBodyFeature):
        return MoveBodyFeatureResponse(
            id=feature.id,
            body_id=feature.body_id,
            delta=feature.delta,
            rotation_axis=_pattern_axis_ref_to_schema(feature.rotation_axis)
            if feature.rotation_axis
            else None,
            rotation_angle_degrees=feature.rotation_angle_degrees,
            make_copy=feature.make_copy,
            locked=part.is_locked(feature.id),
            produces=feature.produces,
        )
    if isinstance(feature, DeleteFaceFeature):
        return DeleteFaceFeatureResponse(
            id=feature.id,
            face_refs=[_subshape_ref_to_schema(r) for r in feature.face_refs],
            locked=part.is_locked(feature.id),
            produces=feature.produces,
        )
    if isinstance(feature, MoveFaceFeature):
        return MoveFaceFeatureResponse(
            id=feature.id,
            face_refs=[_subshape_ref_to_schema(r) for r in feature.face_refs],
            offset_distance=feature.offset_distance,
            delta=feature.delta,
            direction_ref=_pattern_direction_ref_to_schema(feature.direction_ref)
            if feature.direction_ref
            else None,
            direction_distance=feature.direction_distance,
            locked=part.is_locked(feature.id),
            produces=feature.produces,
        )
    if isinstance(feature, SplitFeature):
        return SplitFeatureResponse(
            id=feature.id,
            target_body_id=feature.target_body_id,
            tool=_split_tool_ref_to_schema(feature.tool),
            locked=part.is_locked(feature.id),
            produces=feature.produces,
        )
    if isinstance(feature, PatternFeature):
        return PatternFeatureResponse(
            id=feature.id,
            source_body_ids=feature.source_body_ids,
            source_feature_ids=feature.source_feature_ids,
            pattern_type=feature.pattern_type,
            direction_1=_pattern_direction_ref_to_schema(feature.direction_1)
            if feature.direction_1
            else None,
            count_1=feature.count_1,
            spacing_1=feature.spacing_1,
            reverse_1=feature.reverse_1,
            direction_2=_pattern_direction_ref_to_schema(feature.direction_2)
            if feature.direction_2
            else None,
            count_2=feature.count_2,
            spacing_2=feature.spacing_2,
            reverse_2=feature.reverse_2,
            axis=_pattern_axis_ref_to_schema(feature.axis) if feature.axis else None,
            count_angular=feature.count_angular,
            angle_total=feature.angle_total,
            reverse_angular=feature.reverse_angular,
            skip_indices=list(feature.skip_indices),
            merge=feature.merge,
            tool_feature_id=feature.tool_feature_id,
            locked=part.is_locked(feature.id),
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
    if isinstance(feature, GearFeature):
        return _gear_feature_response(part, feature)
    if isinstance(feature, RackFeature):
        return RackFeatureResponse(
            id=feature.id,
            plane_ref=_plane_ref_to_schema(feature.plane_ref),
            rack_type=feature.rack_type,
            module=feature.module,
            tooth_count=feature.tooth_count,
            face_width=feature.face_width,
            pressure_angle_degrees=feature.pressure_angle_degrees,
            backlash=feature.backlash,
            backing_height=feature.backing_height,
            target_body_ids=feature.target_body_ids,
            locked=part.is_locked(feature.id),
            produces=feature.produces,
        )
    if isinstance(feature, BevelGearFeature):
        return _bevel_gear_feature_response(part, feature)
    if isinstance(feature, BevelPairFeature):
        return _bevel_pair_feature_response(part, feature)
    if isinstance(feature, LoftFeature):
        return _loft_feature_response(part, feature)
    if isinstance(feature, GearChainFeature):
        return _gear_chain_feature_response(part, feature)
    if isinstance(feature, PlanetaryGearFeature):
        return PlanetaryGearFeatureResponse(
            id=feature.id,
            plane_ref=_plane_ref_to_schema(feature.plane_ref),
            module=feature.module,
            sun_tooth_count=feature.sun_tooth_count,
            ring_tooth_count=feature.ring_tooth_count,
            planet_count=feature.planet_count,
            face_width=feature.face_width,
            ring_outer_diameter=feature.ring_outer_diameter,
            pressure_angle_degrees=feature.pressure_angle_degrees,
            locked=part.is_locked(feature.id),
            produces=feature.produces,
        )
    raise NotImplementedError(f"No response mapping for feature type: {feature.type}")


def _gear_feature_response(
    part: Part, feature: GearFeature, warnings: list[str] | None = None
) -> GearFeatureResponse:
    """Mirrors `_loft_feature_response`'s exact shape: `warnings` (a
    requested root_fillet_radius that was silently honoured-in-name-only -
    see `app.document.gear.resolve_gear_from_bodies`) is only known at
    create/update time from that call's own return value - a plain `GET
    .../features` re-read (this function's other caller, via
    `_feature_response`) instead reads the last value `compute_part_bodies`
    computed for this Feature out of `app.document.extrude.
    cached_feature_warnings` (see the `warnings is None` branch below),
    `[]` if never computed, same as Loft's identical "since-broken Feature
    still shown, not one whose failure takes down the whole feature list"
    reasoning - including when the failure belongs to some other, unrelated
    Feature in the same Part (see the `try`/`except` below)."""
    if warnings is None:
        # Bug fix (LOD investigation, §6): a plain GET re-read of an
        # already-persisted, unchanged Feature has no reason to exclude its
        # own id the way create/update validation (`resolve_gear`) does -
        # that self-exclusion is what forced `compute_part_bodies` onto its
        # always-uncached `excluded_feature_ids`-non-empty branch, discarding
        # `body_cache` entirely. `compute_part_bodies(part)` (the ordinary
        # cached call, same one `/mesh` already makes) both brings `bodies`
        # up to date AND - as a side effect of `_apply_feature_to_bodies`'s
        # own GearFeature branch, whenever it actually runs - refreshes
        # `cached_feature_warnings`'s own entry for this Feature; reading it
        # back here needs no `resolve_gear_from_bodies` call of its own, so a
        # repeat fetch of an unchanged Part costs nothing beyond the cache
        # lookup, not even this one Feature's own rebuild.
        #
        # `compute_part_bodies(part)` walks every Feature in the Part, not
        # just this one - same as the old `resolve_gear(part, feature)` it
        # replaced (that also computed the whole Part, just excluding this
        # Feature's own id). So a since-broken *unrelated* Feature elsewhere
        # (e.g. a Mirror/Pattern/Split whose reference was deleted) can still
        # raise `missing_reference` here - caught the same way the old code
        # caught it, so this Feature's row still renders rather than taking
        # the whole `GET /parts/{id}/features` response down with it.
        try:
            compute_part_bodies(part)
            warnings = cached_feature_warnings(part, feature.id)
        except HTTPException:
            logger.warning("GearFeature %s could not be resolved for its response", feature.id)
            warnings = []
    # Cheap (pure gear_math, no OCCT) to recompute alongside the response -
    # never raises (falls back to 0.0 internally), so unlike `resolve_gear`
    # above this needs no try/except of its own. Mirrors `_bevel_pair_
    # feature_response`'s own `effective_profile_shift_1`/`_2` - lets the
    # Gear Design screen show "Auto (0.65)" instead of just "Auto".
    effective_profile_shift = resolve_gear_profile_shift(
        module=feature.module,
        tooth_count=feature.tooth_count,
        pressure_angle_degrees=feature.pressure_angle_degrees,
        backlash=feature.backlash,
        profile_shift=feature.profile_shift,
        is_internal=feature.is_internal,
    )
    return GearFeatureResponse(
        id=feature.id,
        plane_ref=_plane_ref_to_schema(feature.plane_ref),
        gear_type=feature.gear_type,
        is_internal=feature.is_internal,
        module=feature.module,
        tooth_count=feature.tooth_count,
        face_width=feature.face_width,
        pressure_angle_degrees=feature.pressure_angle_degrees,
        profile_shift=feature.profile_shift,
        effective_profile_shift=effective_profile_shift,
        backlash=feature.backlash,
        root_fillet_radius=feature.root_fillet_radius,
        outer_diameter=feature.outer_diameter,
        target_body_ids=feature.target_body_ids,
        helix_angle_degrees=feature.helix_angle_degrees,
        herringbone=feature.herringbone,
        points_per_flank=feature.points_per_flank,
        locked=part.is_locked(feature.id),
        produces=feature.produces,
        warnings=warnings,
    )


def _bevel_gear_feature_response(
    part: Part, feature: BevelGearFeature, warnings: list[str] | None = None
) -> BevelGearFeatureResponse:
    """Mirrors `_gear_feature_response`'s exact shape: `warnings` (face-
    width-vs-cone-distance, per-flank fold-risk, and assembled-solid
    sanity findings - see `app.document.bevel.resolve_bevel_gear_from_
    bodies`) is only known at create/update time from that call's own
    return value - a plain `GET .../features` re-read (this function's
    other caller, via `_feature_response`) instead reads the last value
    `compute_part_bodies` computed for this Feature out of `app.document.
    extrude.cached_feature_warnings` (see the `warnings is None` branch
    below), `[]` if never computed, same "since-broken Feature still shown,
    not one whose failure takes down the whole feature list" reasoning as
    every other warnings-bearing Feature type here - including when the
    failure belongs to some other, unrelated Feature in the same Part."""
    if warnings is None:
        # Bug fix (LOD investigation, §6) - see `_gear_feature_response`'s
        # identical fix above for the full reasoning: a plain-GET re-read
        # reads `cached_feature_warnings` (refreshed as a side effect of
        # `compute_part_bodies`'s own cached build, whenever this Feature's
        # own step actually runs) instead of calling `resolve_bevel_gear`'s
        # always-uncached self-exclusion. Same try/except scope as before -
        # `compute_part_bodies(part)` walks the whole Part, so a since-broken
        # unrelated Feature elsewhere must not take this row down with it.
        try:
            compute_part_bodies(part)
            warnings = cached_feature_warnings(part, feature.id)
        except HTTPException:
            logger.warning("BevelGearFeature %s could not be resolved for its response", feature.id)
            warnings = []
    return BevelGearFeatureResponse(
        id=feature.id,
        plane_ref=_plane_ref_to_schema(feature.plane_ref),
        bevel_type=feature.bevel_type,
        module=feature.module,
        tooth_count=feature.tooth_count,
        face_width=feature.face_width,
        pitch_cone_angle_degrees=feature.pitch_cone_angle_degrees,
        pressure_angle_degrees=feature.pressure_angle_degrees,
        backlash=feature.backlash,
        profile_shift=feature.profile_shift,
        target_body_ids=feature.target_body_ids,
        points_per_flank=feature.points_per_flank,
        spiral_angle_degrees=feature.spiral_angle_degrees,
        spiral_hand=feature.spiral_hand,
        locked=part.is_locked(feature.id),
        produces=feature.produces,
        warnings=warnings,
    )


def _bevel_pair_feature_response(
    part: Part, feature: BevelPairFeature, warnings: list[str] | None = None
) -> BevelPairFeatureResponse:
    """Mirrors `_bevel_gear_feature_response`'s exact shape: `warnings`
    (per-member face-width-vs-cone-distance, fold-risk, and assembled-solid
    sanity findings, label-prefixed - see `app.document.bevel_pair.
    resolve_bevel_pair_from_bodies`'s own return value) is only known at
    create/update time - a plain `GET .../features` re-read (this
    function's other caller, via `_feature_response`) instead reads the
    last value `compute_part_bodies` computed for this Feature out of `app.
    document.extrude.cached_feature_warnings` (see the `warnings is None`
    branch below), `[]` if never computed, same "since-broken Feature still
    shown" reasoning as every other warnings-bearing Feature type here -
    including when the failure belongs to some other, unrelated Feature in
    the same Part."""
    if warnings is None:
        # Bug fix (LOD investigation, §6) - see `_gear_feature_response`'s
        # identical fix above for the full reasoning: a plain-GET re-read
        # reads `cached_feature_warnings` (refreshed as a side effect of
        # `compute_part_bodies`'s own cached build, whenever this Feature's
        # own step actually runs - a real cache hit runs it for NEITHER of
        # the two member builds NOR the meshing-phase search) instead of
        # `resolve_bevel_pair`'s always-uncached self-exclusion - this is
        # the specific case that used to re-run the entire spiral-bevel-pair
        # build (both members, plus the meshing-phase search) on every
        # single `GET /parts/{id}/features` fetch, unconditionally. Same
        # try/except scope as before - `compute_part_bodies(part)` walks the
        # whole Part, so a since-broken unrelated Feature elsewhere must not
        # take this row down with it.
        try:
            compute_part_bodies(part)
            warnings = cached_feature_warnings(part, feature.id)
        except HTTPException:
            logger.warning("BevelPairFeature %s could not be resolved for its response", feature.id)
            warnings = []
    # Cheap (pure math, no OCCT) - computed fresh here regardless of
    # whether `warnings` was already known, rather than threading it
    # through every caller: `resolve_bevel_pair_from_bodies` doesn't return
    # the resolved profile shifts today, and duplicating this tiny
    # computation is far simpler than widening that return value.
    try:
        gamma_1, gamma_2 = pitch_cone_half_angles(
            feature.member_1.tooth_count, feature.member_2.tooth_count, feature.shaft_angle_degrees
        )
        effective_profile_shift_1, effective_profile_shift_2 = resolve_member_profile_shifts(
            module=feature.module,
            tooth_count_1=feature.member_1.tooth_count,
            tooth_count_2=feature.member_2.tooth_count,
            face_width=feature.face_width,
            pressure_angle_degrees=feature.pressure_angle_degrees,
            shaft_angle_degrees=feature.shaft_angle_degrees,
            backlash=feature.backlash,
            profile_shift_1=feature.member_1.profile_shift,
            profile_shift_2=feature.member_2.profile_shift,
            gamma_1=gamma_1,
            gamma_2=gamma_2,
        )
    except GearGeometryError:
        effective_profile_shift_1 = feature.member_1.profile_shift or 0.0
        effective_profile_shift_2 = feature.member_2.profile_shift or 0.0
    return BevelPairFeatureResponse(
        id=feature.id,
        plane_ref=_plane_ref_to_schema(feature.plane_ref),
        module=feature.module,
        member_1=_bevel_pair_member_to_schema(feature.member_1),
        member_2=_bevel_pair_member_to_schema(feature.member_2),
        face_width=feature.face_width,
        pressure_angle_degrees=feature.pressure_angle_degrees,
        shaft_angle_degrees=feature.shaft_angle_degrees,
        backlash=feature.backlash,
        points_per_flank=feature.points_per_flank,
        spiral_angle_degrees=feature.spiral_angle_degrees,
        effective_profile_shift_1=effective_profile_shift_1,
        effective_profile_shift_2=effective_profile_shift_2,
        locked=part.is_locked(feature.id),
        produces=feature.produces,
        warnings=warnings,
    )


def _loft_feature_response(part: Part, feature: LoftFeature, warnings: list[str] | None = None) -> LoftFeatureResponse:
    """`docs/gear-design/04-helical-herringbone-loft.md`: unlike every other
    `_feature_response` branch, a Loft's own non-blocking self-intersection
    `warnings` are only known at create/update time (from `app.document.
    loft.resolve_loft`'s own return value - see `create_loft_feature`/
    `update_loft_feature`) - a plain `GET .../features` re-read (this
    function's other caller, via `_feature_response`) instead reads the
    last value `compute_part_bodies` computed for this Feature out of `app.
    document.extrude.cached_feature_warnings` (see the `warnings is None`
    branch below) rather than persisting them on the Feature itself
    (mirrors `_create_plane_feature_response`'s own "resolve live geometry
    on every read" convention), `[]` if never computed - a since-broken
    Loft is still shown (as a locked/lit Feature row), not one whose
    failure - its own, or an unrelated Feature's elsewhere in the Part -
    takes down the whole feature list."""
    if warnings is None:
        # Bug fix (LOD investigation, §6) - see `_gear_feature_response`'s
        # identical fix above for the full reasoning: a plain-GET re-read
        # reads `cached_feature_warnings` (refreshed as a side effect of
        # `compute_part_bodies`'s own cached build, whenever this Feature's
        # own step actually runs) instead of calling `resolve_loft`'s
        # always-uncached self-exclusion. Same try/except scope as before -
        # `compute_part_bodies(part)` walks the whole Part, so a since-broken
        # unrelated Feature elsewhere must not take this row down with it.
        try:
            compute_part_bodies(part)
            warnings = cached_feature_warnings(part, feature.id)
        except HTTPException:
            logger.warning("LoftFeature %s could not be resolved for its response", feature.id)
            warnings = []
    return LoftFeatureResponse(
        id=feature.id,
        sections=[_loft_section_to_schema(section) for section in feature.sections],
        mode=feature.mode,
        ruled=feature.ruled,
        target_body_ids=feature.target_body_ids,
        thickness=feature.thickness,
        guide_curve_refs=[_sketch_entity_ref_to_schema(ref) for ref in feature.guide_curve_refs],
        locked=part.is_locked(feature.id),
        produces=feature.produces,
        warnings=warnings,
    )


def _gear_chain_feature_response(
    part: Part, feature: GearChainFeature, warnings: list[str] | None = None
) -> GearChainFeatureResponse:
    """`docs/gear-design/05-gear-chain-and-planetary.md`: mirrors
    `_loft_feature_response`'s own "known only at create/update time,
    read back from `app.document.extrude.cached_feature_warnings` for a
    GET" treatment exactly (see the `warnings is None` branch below) -
    `warnings` here covers both interference findings and compound-join
    volume-loss/thin-member findings (`app.document.gear_chain.
    resolve_gear_chain`'s own second return value). Same "a since-broken
    Feature elsewhere in the Part must not take this row down with it"
    resilience as every other warnings-bearing Feature type here."""
    if warnings is None:
        # Bug fix (LOD investigation, §6) - see `_gear_feature_response`'s
        # identical fix above for the full reasoning: a plain-GET re-read
        # reads `cached_feature_warnings` (refreshed as a side effect of
        # `compute_part_bodies`'s own cached build, whenever this Feature's
        # own step actually runs) instead of calling `resolve_gear_chain`'s
        # always-uncached self-exclusion. Same try/except scope as before -
        # `compute_part_bodies(part)` walks the whole Part, so a since-broken
        # unrelated Feature elsewhere must not take this row down with it.
        try:
            compute_part_bodies(part)
            warnings = cached_feature_warnings(part, feature.id)
        except HTTPException:
            logger.warning("GearChainFeature %s could not be resolved for its response", feature.id)
            warnings = []
    return GearChainFeatureResponse(
        id=feature.id,
        plane_ref=_plane_ref_to_schema(feature.plane_ref),
        groups=[_gear_group_to_schema(g) for g in feature.groups],
        stages=[_gear_chain_stage_to_schema(s) for s in feature.stages],
        start_direction_degrees=feature.start_direction_degrees,
        print_clearance_margin=feature.print_clearance_margin,
        locked=part.is_locked(feature.id),
        produces=feature.produces,
        warnings=warnings,
    )


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
        face_is_planar=mesh_data.face_is_planar,
    )


_COARSE_PREVIEW_BASE_ID = "coarse-preview"
"""`docs/lod-strategy/01-design.md` SS4's coarse-preview endpoints (the 3D
analogue of `/gear/preview`, but for a not-yet-created gear-family Feature)
have no real Feature id to key a Body off of - nothing is persisted, so
there is no `feature.id` `_register_solids` could otherwise use. A fixed,
synthetic base id plays that role instead; `_coarse_preview_response`'s own
docstring covers the resulting `body_id` shape."""


def _coarse_preview_response(shape: TopoDS_Shape, mesh_quality: float) -> list[BodyMeshResponse]:
    """Tessellates a not-yet-persisted coarse stand-in `shape` (one member's
    cone, a bevel pair's two cones, a chain/planetary's several members,
    ...) into the same per-Body `BodyMeshResponse` shape `GET /mesh` itself
    returns - `_register_solids` splits `shape` into its maximally-connected
    solids first (`_COARSE_PREVIEW_BASE_ID` alone for a single solid,
    `f"{_COARSE_PREVIEW_BASE_ID}#{i}"` for N>1, exactly its own documented
    convention), so a multi-Body coarse-eligible Feature type (BevelPair,
    GearChain, PlanetaryGear) comes back as one entry per member here too,
    not one merged mesh. Every entry is tagged `source="coarse"` - nothing
    this builds from is ever persisted or registered against any real
    Feature graph."""
    bodies: dict[str, TopoDS_Shape] = {}
    _register_solids(bodies, _COARSE_PREVIEW_BASE_ID, shape)
    return [
        BodyMeshResponse(
            body_id=body_id, source="coarse", mesh=_mesh_vertex_data(tessellate_shape(body_shape, mesh_quality))
        )
        for body_id, body_shape in bodies.items()
    ]


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
        if not isinstance(
            target_feature,
            (
                ExtrudeFeature,
                RevolveFeature,
                SweepFeature,
                ImportFeature,
                GearFeature,
                RackFeature,
                LoftFeature,
                GearChainFeature,
                PlanetaryGearFeature,
                BevelGearFeature,
                BevelPairFeature,
            ),
        ):
            raise HTTPException(
                status_code=400,
                detail=f"target_body_ids entry {target_id!r} does not refer to an ExtrudeFeature, "
                "RevolveFeature, SweepFeature, ImportFeature, GearFeature, RackFeature, LoftFeature, "
                "GearChainFeature, PlanetaryGearFeature, BevelGearFeature, or BevelPairFeature in this Part",
            )


def _validate_merge_body_ids(part: Part, body_ids: list[str]) -> None:
    """`MergeFeature` requires at least 2 `body_ids` entries - there is
    nothing to combine with only zero or one (422, same structured-
    validation-error shape `_validate_target_body_ids`'s Cut-empty-list
    case uses). Each entry must resolve (via `base_feature_id`, so a
    `#N`-suffixed id round-tripped from a prior `/mesh` response validates
    the same way a plain one does) to a Feature that currently produces a
    Body in this Part - checked via `produces == Produces.BODY` rather than
    an explicit isinstance tuple (unlike `_validate_target_body_ids`'s
    Boss/Cut-specific producer-type set) since Merge has no Boss/Cut
    concept of its own to narrow the accepted set for - any Body-producing
    Feature is a valid merge input."""
    if len(body_ids) < 2:
        raise HTTPException(
            status_code=422,
            detail="MergeFeature requires at least 2 body_ids entries - there is nothing to merge "
            "with fewer than two",
        )
    for body_id in body_ids:
        source_feature = part.get_feature(base_feature_id(body_id))
        if source_feature is None or source_feature.produces != Produces.BODY:
            raise HTTPException(
                status_code=400,
                detail=f"body_ids entry {body_id!r} does not refer to a Body-producing Feature in this Part",
            )


def _validate_delete_body_ids(part: Part, body_ids: list[str]) -> None:
    """Direct Editing family (first entry): `DeleteBodyFeature` requires at
    least 1 `body_ids` entry - there is nothing to delete with an empty
    list (422, same structured-validation-error shape `_validate_merge_
    body_ids`'s fewer-than-2 case uses, just a lower floor since deleting
    a single Body is a perfectly normal case, unlike merging one). Each
    entry must resolve (via `base_feature_id`, same round-trip tolerance as
    `_validate_merge_body_ids`) to a Feature that currently produces a Body
    in this Part - identical `produces == Produces.BODY` check, no
    Boss/Cut-specific producer-type set to narrow against (same reasoning
    as `_validate_merge_body_ids`'s own docstring)."""
    if not body_ids:
        raise HTTPException(
            status_code=422,
            detail="DeleteBodyFeature requires at least 1 body_ids entry - there is nothing to "
            "delete with an empty list",
        )
    for body_id in body_ids:
        source_feature = part.get_feature(base_feature_id(body_id))
        if source_feature is None or source_feature.produces != Produces.BODY:
            raise HTTPException(
                status_code=400,
                detail=f"body_ids entry {body_id!r} does not refer to a Body-producing Feature in this Part",
            )


def _validate_scale_body_factor(part: Part, body_id: str, factor: float) -> None:
    """Direct Editing family (second entry): `ScaleBodyFeature.factor` must
    be strictly positive - zero collapses the Body to a point, a negative
    factor isn't a scale at all (422, same structured-validation-error
    shape `_validate_merge_body_ids`'s fewer-than-2 case uses). `body_id`
    must resolve (via `base_feature_id`, same round-trip tolerance as
    `_validate_delete_body_ids`) to a Feature that currently produces a
    Body in this Part."""
    if factor <= 0:
        raise HTTPException(
            status_code=422,
            detail="ScaleBodyFeature requires factor > 0 - zero or negative is not a scale",
        )
    source_feature = part.get_feature(base_feature_id(body_id))
    if source_feature is None or source_feature.produces != Produces.BODY:
        raise HTTPException(
            status_code=400,
            detail=f"body_id {body_id!r} does not refer to a Body-producing Feature in this Part",
        )


def _validate_move_body_payload(
    part: Part, body_id: str, rotation_axis: PatternAxisRef | None
) -> None:
    """Direct Editing family (third entry, "Move/Copy Body"): `body_id`
    must resolve (via `base_feature_id`, same round-trip tolerance as
    `_validate_scale_body_factor`) to a Feature that currently produces a
    Body in this Part; `rotation_axis`, if supplied, must have exactly one
    of `edge_ref`/`face_ref`/`sketch_line_ref` set - reuses `_validate_
    pattern_axis_ref` verbatim (already shared with Circular Pattern's own
    `axis` field)."""
    source_feature = part.get_feature(base_feature_id(body_id))
    if source_feature is None or source_feature.produces != Produces.BODY:
        raise HTTPException(
            status_code=400,
            detail=f"body_id {body_id!r} does not refer to a Body-producing Feature in this Part",
        )
    if rotation_axis is not None:
        _validate_pattern_axis_ref(rotation_axis, field_name="rotation_axis")


def _validate_face_ref(ref: SubShapeRef, field_name: str = "face_ref") -> None:
    """Direct Editing family (fourth/fifth entries): `ref` must actually be
    a face (422, mirroring `_validate_fillet_edge_refs`'s own `shape_type
    == EDGE` check) - a payload-shape check; whether it resolves, and
    whether it's planar, is a referential/geometric check made by `app.
    document.delete_face.resolve_delete_face`/`app.document.move_face.
    resolve_move_face` instead (the same "payload shape in the router,
    resolution in the OCCT module" split every other structured Feature
    error in this codebase already uses)."""
    if ref.shape_type != SubShapeType.FACE:
        raise HTTPException(status_code=422, detail=f"{field_name} must have shape_type=FACE")


def _validate_face_refs(face_refs: list[SubShapeRef], field_name: str = "face_refs") -> None:
    """Direct Editing family (fifth/last entry), V2: `face_refs` must name
    at least one face (422, mirroring `_validate_fillet_edge_refs`'s own
    "at least one" check) and every named ref must actually be a face
    (422, mirroring `_validate_face_ref`'s own singular check) - payload-
    shape checks only. Whether they all resolve, all belong to the same
    Body, and (for `delta`/`direction_ref` modes) number exactly one, is a
    referential/geometric or mode-specific check made by `_validate_move_
    face_payload`/`app.document.move_face.resolve_move_face` instead."""
    if not face_refs:
        raise HTTPException(
            status_code=422,
            detail=f"MoveFaceFeature requires at least one {field_name} entry",
        )
    for ref in face_refs:
        _validate_face_ref(ref, field_name)


def _validate_move_face_payload(
    face_refs: list[SubShapeRef],
    offset_distance: float | None,
    delta: tuple[float, float, float] | None,
    direction_ref: PatternDirectionRef | None,
    direction_distance: float | None,
) -> None:
    """Direct Editing family (fifth/last entry): `face_refs` must all be
    faces (see `_validate_face_refs`); exactly one of the three mutually-
    exclusive modes must be set - `offset_distance`, `delta`, or
    (`direction_ref` + `direction_distance` together, not either alone) -
    matching `MoveFaceFeature`'s own docstring. Each mode's own distance/
    delta must be non-zero - a zero-magnitude move is not a meaningful
    Move Face, the same "no trivial no-op value" philosophy `_validate_
    fillet_radius`'s `> 0` check already establishes for Fillet.

    V3 (on-device feedback: imported/non-sketch geometry needs to move a
    connected multi-face group - e.g. a flat cap plus its own blend
    fillets - not just a single face): all three modes now accept 1+
    entries in `face_refs`, applied as one rigid group (`delta`/
    `direction_ref`+`direction_distance`) or identically to every face
    (`offset_distance`, unchanged V2 behaviour) - see `MoveFaceFeature`'s
    own docstring and `app.document.move_face`'s module docstring for the
    resolver's own geometric requirements on that group (confirmed via
    spike: at least one planar face to anchor the Fuse-vs-Cut sign
    decision, every face plane/cylinder/cone)."""
    _validate_face_refs(face_refs)
    modes_set = sum(
        (
            offset_distance is not None,
            delta is not None,
            direction_ref is not None or direction_distance is not None,
        )
    )
    if modes_set != 1:
        raise HTTPException(
            status_code=422,
            detail="MoveFaceFeature requires exactly one of offset_distance, delta, or "
            "direction_ref+direction_distance",
        )
    if offset_distance is not None and offset_distance == 0.0:
        raise HTTPException(status_code=422, detail="offset_distance must be non-zero")
    if delta is not None:
        if delta == (0.0, 0.0, 0.0):
            raise HTTPException(status_code=422, detail="delta must be non-zero")
    if direction_ref is not None or direction_distance is not None:
        if direction_ref is None or direction_distance is None:
            raise HTTPException(
                status_code=422,
                detail="direction_ref and direction_distance must be supplied together",
            )
        if direction_distance == 0.0:
            raise HTTPException(status_code=422, detail="direction_distance must be non-zero")
        _validate_pattern_direction_ref(direction_ref, "direction_ref")


def _validate_boolean_body_ids(
    part: Part, target_body_ids: list[str], tool_body_ids: list[str]
) -> None:
    """`BooleanFeature` (Subtract/Common) requires at least one entry in
    each of `target_body_ids`/`tool_body_ids` - there is nothing to
    subtract/intersect against with either side empty (422, same
    structured-validation-error shape `_validate_merge_body_ids`'s
    fewer-than-2 case uses). The two lists must also be disjoint - a Body
    can't be both a target and a tool of the same operation, which would
    otherwise leave `app.document.boolean`'s per-target fold operating on
    a Body it (or `consume_tool_bodies`) might simultaneously delete out
    from under itself. Every entry (either list) must resolve (via
    `base_feature_id`, same round-trip tolerance as `_validate_merge_
    body_ids`) to a Feature that currently produces a Body in this Part -
    checked via `produces == Produces.BODY`, identical to `_validate_
    merge_body_ids` (no Boss/Cut-specific producer-type set to narrow
    against, same reasoning as that function's own docstring)."""
    if not target_body_ids or not tool_body_ids:
        raise HTTPException(
            status_code=422,
            detail="BooleanFeature requires at least one target_body_ids entry and at least one "
            "tool_body_ids entry",
        )
    overlap = set(target_body_ids) & set(tool_body_ids)
    if overlap:
        raise HTTPException(
            status_code=422,
            detail=f"target_body_ids and tool_body_ids must be disjoint - {sorted(overlap)!r} "
            "appear in both",
        )
    for body_id in (*target_body_ids, *tool_body_ids):
        source_feature = part.get_feature(base_feature_id(body_id))
        if source_feature is None or source_feature.produces != Produces.BODY:
            raise HTTPException(
                status_code=400,
                detail=f"body_ids entry {body_id!r} does not refer to a Body-producing Feature in this Part",
            )


def _validate_split_target_body_id(part: Part, target_body_id: str) -> None:
    """Boolean family, fourth/last entry: `target_body_id` must resolve
    (via `base_feature_id`, same round-trip tolerance as `_validate_merge_
    body_ids`/`_validate_boolean_body_ids`) to a Feature that currently
    produces a Body in this Part - checked via `produces == Produces.BODY`,
    identical to those two (not `_validate_target_body_ids`'s own narrower
    Boss/Cut-specific isinstance tuple, which excludes Merge/Boolean/
    Mirror/Pattern-produced Bodies entirely - a Split's own target has no
    such restriction, any existing Body is a valid pick)."""
    target_feature = part.get_feature(base_feature_id(target_body_id))
    if target_feature is None or target_feature.produces != Produces.BODY:
        raise HTTPException(
            status_code=400,
            detail=f"target_body_id {target_body_id!r} does not refer to a Body-producing Feature "
            "in this Part",
        )


def _validate_split_tool_ref(part: Part, tool: SplitToolRef) -> None:
    """Boolean family, fourth/last entry: enforces exactly one of `plane_
    ref`/`surface_feature_id`/`sketch_line_ref` is supplied, matching
    `SplitToolRef`'s own "one of three" convention (see its docstring), and
    that whichever one is supplied is itself well-formed: a `plane_ref` is
    validated by the existing `_validate_plane_ref` (already shared by
    `CreatePlaneFeature`/`MirrorFeature`), a `surface_feature_id` must name
    a real `SurfaceFeature` in this Part (checked via `isinstance`, not just
    `part.get_feature(...) is not None` - any other Feature type id would
    otherwise silently pass this check), and a `sketch_line_ref` must have
    an `entity_type` that is actually a connectable curve (`app.document.
    split.CONNECTABLE_CURVE_ENTITY_TYPES`) - the same typed-slot check
    `edge_ref`/`face_ref` already get elsewhere in this module. Whether the
    referenced Sketch/entity actually still exists is left to `resolve_
    split`'s own eager-resolve-to-validate call (same "structural shape here,
    referential/geometric validity there" split every other tool kind
    already gets)."""
    set_count = sum(x is not None for x in (tool.plane_ref, tool.surface_feature_id, tool.sketch_line_ref))
    if set_count != 1:
        raise HTTPException(
            status_code=422,
            detail="SplitFeature tool must have exactly one of plane_ref, surface_feature_id, or "
            "sketch_line_ref",
        )
    if tool.plane_ref is not None:
        _validate_plane_ref(part, tool.plane_ref)
    elif tool.surface_feature_id is not None:
        surface_feature = part.get_feature(tool.surface_feature_id)
        if not isinstance(surface_feature, SurfaceFeature):
            raise HTTPException(
                status_code=400,
                detail="SplitFeature tool surface_feature_id does not refer to a SurfaceFeature "
                "in this Part",
            )
    else:
        assert tool.sketch_line_ref is not None
        if tool.sketch_line_ref.entity_type not in CONNECTABLE_CURVE_ENTITY_TYPES:
            raise HTTPException(
                status_code=422,
                detail="SplitFeature tool sketch_line_ref must reference a connectable curve entity "
                "(line, arc, ellipse_arc, or spline)",
            )


_PATTERN_MIRROR_SOURCE_FEATURE_TYPES = (
    ExtrudeFeature,
    RevolveFeature,
    SweepFeature,
    ImportFeature,
    MirrorFeature,
    PatternFeature,
    GearFeature,
    RackFeature,
    LoftFeature,
    GearChainFeature,
    PlanetaryGearFeature,
    BevelGearFeature,
    BevelPairFeature,
)
_PATTERN_MIRROR_SOURCE_FEATURE_TYPES_DESCRIPTION = (
    "ExtrudeFeature, RevolveFeature, SweepFeature, ImportFeature, MirrorFeature, PatternFeature, "
    "GearFeature, RackFeature, LoftFeature, GearChainFeature, PlanetaryGearFeature, BevelGearFeature, "
    "or BevelPairFeature"
)


def _validate_source_feature_ids(
    part: Part, source_feature_ids: list[str], feature_type_name: str
) -> None:
    """Pattern/Mirror scoping's Phase 6 (`docs/pattern-mirror-scope.md`
    §2.8/§4), shared by both `_validate_mirror_source_body_ids`/`_validate_
    pattern_source_body_ids`: each `source_feature_ids` entry must name a
    real Feature in this Part, of the identical accepted-producer-type set
    the two callers below already establish for a bare `source_body_ids`
    Body id - a Feature-tree pick is just a different way of naming the
    same kind of source, not a new kind of source. Deliberately does not
    check the named Feature currently resolves to 1+ Bodies (that needs a
    live `bodies` accumulator, not available at this payload-shape-
    validation stage) - `app.document.mirror.effective_mirror_source_
    body_ids`/`app.document.pattern.effective_pattern_source_body_ids`
    raise their own structured `missing_reference` for that, reached via
    `resolve_mirror`/`resolve_pattern`'s own eager-resolve-to-validate
    call a few lines after this one."""
    for feature_id in source_feature_ids:
        source_feature = part.get_feature(feature_id)
        if not isinstance(source_feature, _PATTERN_MIRROR_SOURCE_FEATURE_TYPES):
            raise HTTPException(
                status_code=400,
                detail=f"source_feature_ids entry {feature_id!r} does not refer to an "
                f"{_PATTERN_MIRROR_SOURCE_FEATURE_TYPES_DESCRIPTION} in this Part ({feature_type_name})",
            )


def _validate_mirror_source_body_ids(
    part: Part,
    source_body_ids: list[str],
    source_feature_ids: list[str],
    tool_feature_id: str | None = None,
) -> None:
    """Pattern/Mirror scoping's Phase 1/6 (`docs/pattern-mirror-scope.md`
    §2.1/§2.8/§4): `source_body_ids` combined with `source_feature_ids`
    (Phase 6 - a Feature-tree pick is an alternate way of naming a source,
    not a separate requirement) must have at least one entry between them
    - on-device feedback on the guided "New > Mirror" flow pulled multi-
    body seeding forward from its original Phase 6 scoping into Phase 1
    directly (see `MirrorFeature`'s own updated docstring), so any
    positive count is valid here now, not just exactly one. Each `source_
    body_ids` entry must resolve to a Feature that produces a Body already
    in this Part - Phase 6 widens the accepted-producer-type set to also
    include `MirrorFeature`/`PatternFeature` themselves (completing the
    nested-pattern/chained-mirror scope Phase 1's own docstring explicitly
    deferred to "Phase 6 scope" - see `docs/pattern-mirror-scope.md` §3's
    "Pattern seed = pattern" survey entry, "structurally unblocked
    already"), on top of the original `ExtrudeFeature`/`RevolveFeature`/
    `SweepFeature`/`ImportFeature` set `_validate_target_body_ids` still
    uses for Boss/Cut's own unrelated `target_body_ids` concept. Each
    `source_feature_ids` entry is validated by `_validate_source_feature_
    ids`, sharing the identical accepted-type set.

    Phase 8 (§2.11): the "at least one entry" requirement is skipped
    entirely when `tool_feature_id` is set - that's the third, mutually-
    exclusive seed-picking mode (`_validate_tool_feature_id`'s own job to
    validate), so `source_body_ids`/`source_feature_ids` being empty here
    is expected, not an error."""
    if tool_feature_id is None and not source_body_ids and not source_feature_ids:
        raise HTTPException(
            status_code=422,
            detail="MirrorFeature requires at least one source_body_ids or source_feature_ids entry",
        )
    for source_id in source_body_ids:
        source_feature = part.get_feature(base_feature_id(source_id))
        if not isinstance(source_feature, _PATTERN_MIRROR_SOURCE_FEATURE_TYPES):
            raise HTTPException(
                status_code=400,
                detail=f"source_body_ids entry {source_id!r} does not refer to an "
                f"{_PATTERN_MIRROR_SOURCE_FEATURE_TYPES_DESCRIPTION} in this Part",
            )
    _validate_source_feature_ids(part, source_feature_ids, "MirrorFeature")


def _validate_pattern_source_body_ids(
    part: Part,
    source_body_ids: list[str],
    source_feature_ids: list[str],
    tool_feature_id: str | None = None,
) -> None:
    """Pattern/Mirror scoping's Phase 2/6 (`docs/pattern-mirror-scope.md`
    §2.2/§4): `source_body_ids` combined with `source_feature_ids` (Phase 6)
    must have at least one entry between them - widened from Phase 2/4's
    original exactly-one-`source_body_ids`-entry requirement, mirroring
    `_validate_mirror_source_body_ids`'s own Phase 1 shape exactly (see
    `PatternFeature`'s own docstring for the full reasoning), including its
    identical Phase 6 widening of the accepted-producer-type set to
    `MirrorFeature`/`PatternFeature` too. Each `source_feature_ids` entry
    is validated by `_validate_source_feature_ids`.

    Phase 8 (§2.11): mirrors `_validate_mirror_source_body_ids`'s own
    identical `tool_feature_id` carve-out - the "at least one entry"
    requirement is skipped when `tool_feature_id` is set."""
    if tool_feature_id is None and not source_body_ids and not source_feature_ids:
        raise HTTPException(
            status_code=422,
            detail="PatternFeature requires at least one source_body_ids or source_feature_ids entry",
        )
    for source_id in source_body_ids:
        source_feature = part.get_feature(base_feature_id(source_id))
        if not isinstance(source_feature, _PATTERN_MIRROR_SOURCE_FEATURE_TYPES):
            raise HTTPException(
                status_code=400,
                detail=f"source_body_ids entry {source_id!r} does not refer to an "
                f"{_PATTERN_MIRROR_SOURCE_FEATURE_TYPES_DESCRIPTION} in this Part",
            )
    _validate_source_feature_ids(part, source_feature_ids, "PatternFeature")


def _invalid_tool_feature_ref(tool_feature_id: str) -> HTTPException:
    """Pattern/Mirror scoping's Phase 8 (`docs/pattern-mirror-scope.md`
    §2.11/§4): the structured `invalid_tool_feature_ref` error - shared
    shape with `app.document.mirror`/`app.document.pattern`'s own identical
    private helpers (this codebase's established per-module duplication
    convention for small, identically-shaped error constructors, same as
    `missing_reference`'s several independent copies)."""
    return HTTPException(
        status_code=422, detail={"type": "invalid_tool_feature_ref", "feature_id": tool_feature_id}
    )


def _validate_tool_feature_id(
    part: Part,
    tool_feature_id: str | None,
    source_body_ids: list[str],
    source_feature_ids: list[str],
    merge: MergeMode,
    feature_type_name: str,
) -> None:
    """Pattern/Mirror scoping's Phase 8 (`docs/pattern-mirror-scope.md`
    §2.11/§4): `tool_feature_id` is a third, mutually-exclusive seed-
    picking mode on both `MirrorFeature`/`PatternFeature` - a no-op when
    `None` (every pre-Phase-8 payload). When set:
    - `source_body_ids`/`source_feature_ids` must both be empty - the same
      "exactly one of N fields" convention `PlaneRef`/`PatternDirectionRef`
      already use, generalized here to "this field vs. the other two as a
      group" rather than "exactly one of three siblings".
    - `merge` must not be `KEEP_SEPARATE` (the type's own default) - there
      is exactly one target by construction once `tool_feature_id` is set,
      so "keep separate" has no referent (see `MirrorFeature`/
      `PatternFeature`'s own docstrings) - rejected outright rather than
      silently ignored, so a client can't fall into the "looks configured
      but isn't" trap.
    - `tool_feature_id` must resolve to a real Feature in this Part that
      `app.document.graph.tool_feature_qualifies` (an Extrude/Revolve/Sweep
      Feature in Cut mode, or Boss mode with a non-empty `target_body_ids`)
      - the structural half of `invalid_tool_feature_ref`; the referential/
      geometric half (does it currently resolve to a real tool shape/target
      Body) is checked later by `resolve_mirror`/`resolve_pattern`'s own
      eager-resolve-to-validate call, which raises the identical error for
      drift after the fact (`app.document.mirror.resolve_mirror_tool_
      feature_from_bodies`/`app.document.pattern.resolve_pattern_tool_
      feature_from_bodies`)."""
    if tool_feature_id is None:
        return
    if source_body_ids or source_feature_ids:
        raise HTTPException(
            status_code=422,
            detail=f"{feature_type_name} tool_feature_id is mutually exclusive with "
            "source_body_ids/source_feature_ids",
        )
    if merge == MergeMode.KEEP_SEPARATE:
        raise HTTPException(
            status_code=422,
            detail=f"{feature_type_name} merge must not be KEEP_SEPARATE when tool_feature_id is set - "
            "there is exactly one target by construction, so KEEP_SEPARATE has no referent",
        )
    tool_feature = part.get_feature(tool_feature_id)
    if not tool_feature_qualifies(tool_feature):
        raise _invalid_tool_feature_ref(tool_feature_id)


def _validate_pattern_direction_ref(ref: PatternDirectionRef, field_name: str) -> None:
    """Pattern/Mirror scoping's Phase 2: enforces exactly one of `edge_ref`/
    `sketch_line_ref`/`fixed_axis` is supplied on `ref` (`field_name` is
    `"direction_1"` or `"direction_2"`, for the error message), matching
    `PatternDirectionRef`'s own "one of three" convention (see its
    docstring) - mirrors `_validate_plane_ref`'s identical shape. Always
    called with a non-`None` `ref` - `_validate_pattern_rectangular_
    payload` only calls this for `direction_1`/`direction_2` when a value
    was actually required and supplied, raising its own error directly
    otherwise. Whichever field is supplied is itself well-formed: an
    `edge_ref` must have `shape_type=EDGE` (the same typed-slot check
    `_validate_plane_ref` makes for its own `face_ref`). `fixed_axis` needs
    no further check - `FixedAxis` is already a closed enum, so pydantic
    itself rejects anything else."""
    set_count = sum(x is not None for x in (ref.edge_ref, ref.sketch_line_ref, ref.fixed_axis))
    if set_count != 1:
        raise HTTPException(
            status_code=422,
            detail=f"{field_name} must have exactly one of edge_ref, sketch_line_ref, or fixed_axis",
        )
    if ref.edge_ref is not None and ref.edge_ref.shape_type != SubShapeType.EDGE:
        raise HTTPException(status_code=422, detail=f"{field_name} edge_ref must have shape_type=EDGE")


_PATTERN_MAX_TOTAL_INSTANCES = 500
"""`docs/lod-strategy/00-status.md` Finding 2 / `01-design.md` §6: prior to
this, `count_1`/`count_2`/`count_angular` had lower bounds only (`_validate_
pattern_rectangular_payload`/`_validate_pattern_circular_payload` below),
so a payload like `count_1=1000, count_2=1000, merge=true` was accepted
with no server-side rejection - a real, if previously theoretical,
unbounded-cost request (each additional instance is another `BRepAlgoAPI_
Fuse` call in the `MergeMode.FUSE_INTO_ONE`/`tool_feature_id` chain,
`app.document.extrude._fuse_realized_instances`/`app.document.pattern.
resolve_pattern_tool_feature_from_bodies`).

500 is a judgment call, not a precisely-derived constant (no per-instance
timing data was available for this specific chain at the time this cap was
added) - picked to comfortably cover every realistic real-world Pattern use
this project's own docs/examples describe (bolt-hole circles, perforation/
vent grids, tooth-like arrays - typically single digits to a few dozen
instances, rarely more than ~100) while still closing off an unbounded
integer field a client can otherwise set to any value. Applies to the
*total* instance count - Rectangular's own `count_1 * count_2` product,
Circular's own `count_angular` alone (it has no second dimension to
multiply against) - not either input dimension individually, so `count_1=
50, count_2=50` (2500 total) is still rejected even though neither factor
alone looks large."""


def _validate_pattern_rectangular_payload(
    direction_1: PatternDirectionRef | None,
    count_1: int,
    count_2: int,
    direction_2: PatternDirectionRef | None,
) -> None:
    """Pattern/Mirror scoping's Phase 2: validates a Rectangular
    `PatternFeature`'s own fields (`pattern_type == RECTANGULAR`) -
    `direction_1` is required and must be well-formed; `count_1`/`count_2`
    must each be at least 1 (a "pattern" of fewer than one instance in
    either direction is meaningless), their product must be at least 2
    (otherwise this Feature would produce zero new Bodies beyond the
    untouched seed - see `PatternFeature`'s own docstring on why index 0
    never gets a new Body - a pure no-op Feature, rejected the same
    "nothing valid to create" way `_validate_target_body_ids` rejects an
    empty Cut); `direction_2` is required exactly when `count_2 > 1` (see
    `PatternFeatureUpdate`'s own docstring on why `count_2 == 1` makes
    `direction_2` inert rather than requiring it be explicitly cleared)."""
    if direction_1 is None:
        raise HTTPException(
            status_code=422,
            detail="PatternFeature requires a direction_1 when pattern_type is rectangular",
        )
    _validate_pattern_direction_ref(direction_1, "direction_1")
    if count_1 < 1 or count_2 < 1:
        raise HTTPException(status_code=422, detail="PatternFeature count_1 and count_2 must each be >= 1")
    if count_1 * count_2 < 2:
        raise HTTPException(
            status_code=422,
            detail="PatternFeature count_1 * count_2 must be >= 2 - otherwise no new Body is produced "
            "beyond the existing seed",
        )
    if count_1 * count_2 > _PATTERN_MAX_TOTAL_INSTANCES:
        raise HTTPException(
            status_code=422,
            detail=f"PatternFeature count_1 * count_2 must not exceed {_PATTERN_MAX_TOTAL_INSTANCES} "
            f"total instances (got {count_1 * count_2})",
        )
    if direction_2 is not None:
        _validate_pattern_direction_ref(direction_2, "direction_2")
    elif count_2 > 1:
        raise HTTPException(status_code=422, detail="PatternFeature requires a direction_2 when count_2 > 1")


def _validate_pattern_axis_ref(ref: PatternAxisRef, field_name: str = "axis") -> None:
    """Pattern/Mirror scoping's Phase 4: enforces exactly one of `edge_ref`/
    `face_ref`/`sketch_line_ref` is supplied on `ref`, matching
    `PatternAxisRef`'s own "one of three" convention - mirrors
    `_validate_pattern_direction_ref`'s identical shape, generalized to
    `face_ref` as well as `edge_ref`: an `edge_ref` must have
    `shape_type=EDGE`, a `face_ref` must have `shape_type=FACE` (the same
    typed-slot checks `_validate_plane_ref`/`_validate_pattern_direction_
    ref` already make for their own equivalents)."""
    set_count = sum(x is not None for x in (ref.edge_ref, ref.face_ref, ref.sketch_line_ref))
    if set_count != 1:
        raise HTTPException(
            status_code=422,
            detail=f"{field_name} must have exactly one of edge_ref, face_ref, or sketch_line_ref",
        )
    if ref.edge_ref is not None and ref.edge_ref.shape_type != SubShapeType.EDGE:
        raise HTTPException(status_code=422, detail=f"{field_name} edge_ref must have shape_type=EDGE")
    if ref.face_ref is not None and ref.face_ref.shape_type != SubShapeType.FACE:
        raise HTTPException(status_code=422, detail=f"{field_name} face_ref must have shape_type=FACE")


def _validate_pattern_circular_payload(
    axis: PatternAxisRef | None, count_angular: int, angle_total: float
) -> None:
    """Pattern/Mirror scoping's Phase 4: validates a Circular
    `PatternFeature`'s own fields (`pattern_type == CIRCULAR`) - `axis` is
    required and must be well-formed; `count_angular` must be at least 2
    (a single-instance "pattern" produces no new Body beyond the untouched
    seed, the identical no-op guard Rectangular's own `count_1*count_2>=2`
    check enforces - there is no second dimension here to make a product
    of, so this checks `count_angular` alone); `angle_total` must be in
    `(0, 360]` (0 or negative sweeps nothing, more than a full turn
    overlaps itself - mirrors `RevolveFeature.angle`'s own identical
    range)."""
    if axis is None:
        raise HTTPException(
            status_code=422,
            detail="PatternFeature requires an axis when pattern_type is circular",
        )
    _validate_pattern_axis_ref(axis)
    if count_angular < 2:
        raise HTTPException(
            status_code=422,
            detail="PatternFeature count_angular must be >= 2 - otherwise no new Body is produced "
            "beyond the existing seed",
        )
    if count_angular > _PATTERN_MAX_TOTAL_INSTANCES:
        raise HTTPException(
            status_code=422,
            detail=f"PatternFeature count_angular must not exceed {_PATTERN_MAX_TOTAL_INSTANCES} "
            f"(got {count_angular})",
        )
    if angle_total <= 0 or angle_total > 360:
        raise HTTPException(status_code=422, detail="PatternFeature angle_total must be > 0 and <= 360")


def _validate_pattern_skip_indices(skip_indices: list[int], total_count: int) -> None:
    """Pattern/Mirror scoping's Phase 3: every entry of `skip_indices` must
    be a real, would-otherwise-be-created instance index - the same linear
    index (Rectangular's flattened `i * count_2 + j`, or Circular's own
    angular-step `i`) `app.document.pattern._rectangular_instances`/
    `_circular_instances` use. `0` (the untouched seed - never created in
    the first place, so there is nothing there to suppress) and anything
    `>= total_count` (Rectangular's own `count_1 * count_2`, Circular's own
    `count_angular`) are both rejected outright rather than silently
    ignored - the same "fail closed, don't let a stale/off-by-one index
    quietly do nothing" discipline every other Pattern validator here
    already follows."""
    for index in skip_indices:
        if index <= 0 or index >= total_count:
            raise HTTPException(
                status_code=422,
                detail=f"skip_indices entries must be >= 1 and < the pattern's own total instance count "
                f"(got {index})",
            )


def _validate_pattern_payload(
    pattern_type: PatternType,
    direction_1: PatternDirectionRef | None,
    count_1: int,
    count_2: int,
    direction_2: PatternDirectionRef | None,
    axis: PatternAxisRef | None,
    count_angular: int,
    angle_total: float,
    skip_indices: list[int],
) -> None:
    """Pattern/Mirror scoping's Phase 4: the single entry point both
    `create_pattern_feature`/`update_pattern_feature` call - dispatches to
    `_validate_pattern_rectangular_payload`/`_validate_pattern_circular_
    payload` per `pattern_type`, so which fields are actually required for
    a given Pattern never has to be re-derived at either call site (same
    "payload shape validated by the API layer" split
    `_validate_create_plane_payload` already uses for its own six
    construction methods). `_validate_pattern_skip_indices` (Phase 3) is
    validated against whichever total-instance-count the resolved
    `pattern_type` implies."""
    if pattern_type == PatternType.CIRCULAR:
        _validate_pattern_circular_payload(axis, count_angular, angle_total)
        _validate_pattern_skip_indices(skip_indices, count_angular)
    else:
        _validate_pattern_rectangular_payload(direction_1, count_1, count_2, direction_2)
        _validate_pattern_skip_indices(skip_indices, count_1 * count_2)


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


def _validate_surface_payload(
    part: Part, sketch_feature_id: str, direction_ref: PatternDirectionRef | None
) -> None:
    """Validates a `SurfaceFeature`'s own two structural preconditions -
    `sketch_feature_id` resolves to a SketchFeature in this Part (unlike
    `_require_closed_sketch_feature`, this does NOT require a currently
    extrudable closed profile: a Surface also accepts a single open wire -
    see `app.document.surface.resolve_surface_from_bodies` - so a stale/
    edited-away wire is instead tolerated lazily, the same "skip, don't
    fail the whole /mesh request" resilience `compute_part_bodies` already
    gives Extrude/Revolve/Sweep), and `direction_ref` (if set) is
    structurally well-formed via the identical `_validate_pattern_
    direction_ref` check `PatternFeature.direction_1`/`direction_2` already
    use for the same `PatternDirectionRef` type."""
    sketch_feature = part.get_feature(sketch_feature_id)
    if not isinstance(sketch_feature, SketchFeature):
        raise HTTPException(
            status_code=400,
            detail="SurfaceFeature sketch_feature_id does not refer to a SketchFeature in this Part",
        )
    if direction_ref is not None:
        _validate_pattern_direction_ref(direction_ref, "direction_ref")


_SWEEP_PATH_ENTITY_TYPES = frozenset(
    {SketchEntityType.LINE, SketchEntityType.ARC, SketchEntityType.ELLIPSE, SketchEntityType.SPLINE}
)


def _validate_sweep_path_refs(path_refs: list[SketchEntityRef]) -> None:
    """A SweepFeature must name at least one `path_refs` entry (422,
    mirroring Cut's own "at least one target_body_ids entry" check in
    `_validate_target_body_ids`) and every named ref must be a Line/Arc/
    Ellipse/Spline (422, mirroring `_validate_fillet_edge_refs`'s own
    `shape_type == EDGE` check) - these are payload-shape checks. Whether
    the named entities actually resolve, chain into one connected path
    (open or closed), or - for a closed/standalone Ellipse - stand alone,
    is a referential/geometric check made by `app.document.sweep.resolve_
    sweep` instead (the same "payload shape in the router, resolution in
    the OCCT module" split every other structured Feature error in this
    codebase already uses).

    On-device feedback ("unable to select an arc as the sweep path...
    ellipses and splines should also be valid targets"): this used to
    reject anything but LINE right here, before `app.document.sweep`'s own
    `_resolve_path_segment` (which already handles all four types) ever
    got a chance to run - the actual geometry support was reachable from
    neither the client nor a direct API call until this gate widened too."""
    if not path_refs:
        raise HTTPException(
            status_code=422,
            detail="SweepFeature requires at least one path_refs entry",
        )
    for ref in path_refs:
        if ref.entity_type not in _SWEEP_PATH_ENTITY_TYPES:
            raise HTTPException(
                status_code=422,
                detail="path_refs entries must have entity_type one of line, arc, ellipse, spline",
            )


def _validate_loft_sections(sections: list[LoftSection]) -> None:
    """`docs/gear-design/04-helical-herringbone-loft.md` (4b): a `LoftFeature`
    must name at least 2 `sections` (422, mirroring `_validate_sweep_path_
    refs`'s own "at least one entry" convention) - there is nothing to loft
    *between* with fewer than 2. Whether each section actually resolves to
    exactly one loftable Profile (and, if `reference_point` is set, a real
    Point in that same section's own Sketch) is a referential/geometric
    check made by `app.document.loft.resolve_loft` instead (the same
    "payload shape in the router, resolution in the OCCT module" split
    every other structured Feature error in this codebase already uses)."""
    if len(sections) < 2:
        raise HTTPException(
            status_code=422,
            detail="LoftFeature requires at least 2 sections",
        )


def _validate_loft_thickness(thickness: float | None) -> None:
    """A `LoftFeatureCreate`/`Update.thickness`, if provided at all, must be
    nonzero - zero has no meaningful "thicken by nothing into a solid"
    interpretation (a plain-400 convention, mirroring `_validate_fillet_
    radius`'s own bare numeric-field check with no structured error type).
    Its sign is meaningful (which side of the lofted shell the material is
    added to - see `app.document.loft.resolve_loft_from_bodies`), so unlike
    a radius this is not rejected for being negative, only for being 0."""
    if thickness is not None and thickness == 0:
        raise HTTPException(status_code=400, detail="thickness must not be 0")


def _validate_loft_guide_curve_refs(guide_curve_refs: list[SketchEntityRef]) -> None:
    """A `LoftFeatureCreate`/`Update.guide_curve_refs`, if provided at all,
    must name only Line/Arc/Ellipse/Spline entities - mirrors `_validate_
    sweep_path_refs`'s own identical entity-type gate exactly (this reuses
    the very same `_SWEEP_PATH_ENTITY_TYPES` set and the very same
    resolution machinery, `app.document.sweep.resolve_path_wire`, just as a
    rail rather than an extrusion direction - see `LoftFeature.guide_curve_
    refs`'s own docstring). Unlike a Sweep's `path_refs`, an empty list is
    perfectly valid here (it means "no guide curve", not "nothing to loft
    along") - so, unlike `_validate_sweep_path_refs`, there is no "at least
    one entry" rule. Whether the named entities actually resolve, chain
    into one connected path, and (once every section requires an
    `alignment_point`, see `app.document.loft._apply_alignment_point_
    translation`) cross each section's own plane exactly once is a
    referential/geometric check made by `app.document.loft.resolve_loft`
    instead, same "payload shape in the router, resolution in the OCCT
    module" split every other structured Feature error here already uses."""
    for ref in guide_curve_refs:
        if ref.entity_type not in _SWEEP_PATH_ENTITY_TYPES:
            raise HTTPException(
                status_code=422,
                detail="guide_curve_refs entries must have entity_type one of line, arc, ellipse, spline",
            )


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


def _default_plane_ref() -> PlaneRef:
    """`docs/gear-design/00-conventions.md`'s positioning resolution: a
    `GearFeature` created without an explicit `plane_ref` anchors to the
    fixed XY plane - resolves cleanly whether or not a Part already has
    any geometry, since a fixed plane needs none. The Gear Design client
    screen still always shows and pre-fills this choice rather than hiding
    it (see that conventions doc) - this is only the API-level fallback
    for a caller that omits the field entirely."""
    return PlaneRef(fixed_plane=Plane.XY)


def _validate_gear_feature_payload(is_internal: bool, outer_diameter: float | None) -> None:
    """`docs/gear-design/02-gear-feature.md`: `outer_diameter` is required
    for an internal gear (the ring's own rim diameter - there is no other
    way to know how far the annulus extends) and meaningless for an
    external one (nothing to be a rim of) - checked here, at payload-shape
    time, rather than only surfacing later as a `resolve_gear`
    `invalid_gear_parameters` failure, matching this codebase's "payload
    shape checked by the router, referential/geometric validity checked by
    the resolver" split every other structured Feature validation here
    already uses."""
    if is_internal and outer_diameter is None:
        raise HTTPException(status_code=422, detail="outer_diameter is required when is_internal is true")
    if not is_internal and outer_diameter is not None:
        raise HTTPException(
            status_code=422, detail="outer_diameter must not be supplied when is_internal is false"
        )


def _validate_gear_chain_member_payload(member: GearChainMemberSpec, group_ids: set[str], *, allow_rack: bool) -> None:
    if member.group_id not in group_ids:
        raise HTTPException(
            status_code=422, detail=f"group_id {member.group_id!r} does not refer to a group on this chain"
        )
    if member.member_type == GearChainMemberType.RACK and not allow_rack:
        raise HTTPException(status_code=422, detail="a compound stage's members cannot be a rack")
    if member.member_type == GearChainMemberType.INTERNAL and member.outer_diameter is None:
        raise HTTPException(status_code=422, detail="outer_diameter is required for an internal chain member")
    if member.member_type != GearChainMemberType.INTERNAL and member.outer_diameter is not None:
        raise HTTPException(
            status_code=422, detail="outer_diameter must not be supplied for a non-internal chain member"
        )


def _validate_gear_chain_stages(groups: list[GearGroup], stages: list[GearChainStage]) -> None:
    """`docs/gear-design/05-gear-chain-and-planetary.md`: the payload-shape
    half of `GearChainFeature` validation (referential/geometric validity -
    group-id *adjacency* matching, module compatibility, actual
    resolvability - is `app.document.gear_chain.resolve_gear_chain`'s job
    instead, the same "payload shape in the router, resolution in the OCCT
    module" split every other structured Feature validation here already
    uses):

    - At least 2 stages (there is no chain otherwise).
    - Each stage sets exactly one of `member` or both `compound_member_a`/
      `compound_member_b` (never neither, never all three) - mirrors
      `_validate_plane_ref`'s own "exactly one of N" convention.
    - A compound member is never `RACK` (no coaxial-stacking concept for a
      rack).
    - `INTERNAL` (single-member or either compound member) is rejected
      anywhere but the chain's final stage - `05-gear-chain-and-planetary.
      md`'s own deliberate restriction (nothing meaningfully continues past
      a ring on this codebase's model - see `PlanetaryGearFeature` for the
      branching topology that does).
    - `RACK` (single-member only) is only allowed at the chain's first or
      last stage - avoids the double-sided-rack orientation ambiguity a
      mid-chain rack would create (see `app.document.gear_chain_math.
      ChainStageSpec`'s own docstring); two racks at opposite ends of a
      2-stage chain would be adjacent to each other, which `gear_chain_
      math._segment_distance` itself already rejects (surfaced as
      `invalid_gear_chain_parameters` at resolve time, not pre-checked
      here).
    - The last stage's `turn_angle_degrees` must be `0.0` - Spike 1's own
      flagged loose end (its own value is geometrically inert on the last
      stage, since no segment leaves it): this build's resolution is to
      reject a nonzero value outright rather than silently accept a
      no-op, matching this codebase's general "fail closed on a
      structurally meaningless input" convention (e.g. `PlaneRef`'s own
      "exactly one of N" checks) rather than a soft warning."""
    if len(stages) < 2:
        raise HTTPException(status_code=422, detail="GearChainFeature requires at least 2 stages")

    group_ids = {g.id for g in groups}
    last_index = len(stages) - 1
    for i, stage in enumerate(stages):
        is_single = stage.member is not None
        is_compound = stage.compound_member_a is not None or stage.compound_member_b is not None
        if is_single == is_compound:
            raise HTTPException(
                status_code=422,
                detail=f"stage {i} must set exactly one of member or (compound_member_a and compound_member_b)",
            )
        if is_compound and (stage.compound_member_a is None or stage.compound_member_b is None):
            raise HTTPException(
                status_code=422, detail=f"stage {i} is compound but is missing one of its two members"
            )

        members = [stage.compound_member_a, stage.compound_member_b] if is_compound else [stage.member]
        for member in members:
            _validate_gear_chain_member_payload(member, group_ids, allow_rack=not is_compound)
            if member.member_type == GearChainMemberType.INTERNAL and i != last_index:
                raise HTTPException(
                    status_code=422,
                    detail=f"stage {i}: an internal (ring) member is only allowed on the chain's last stage",
                )
            if member.member_type == GearChainMemberType.RACK and i not in (0, last_index):
                raise HTTPException(
                    status_code=422,
                    detail=f"stage {i}: a rack stage is only allowed at the first or last position",
                )
        if is_compound and stage.compound_member_a.group_id == stage.compound_member_b.group_id:
            raise HTTPException(
                status_code=422,
                detail=f"stage {i}: a compound stage's two members must use different groups",
            )

    if stages[last_index].turn_angle_degrees != 0.0:
        raise HTTPException(
            status_code=422,
            detail="the last stage's turn_angle_degrees is geometrically inert (no segment leaves the "
            "last stage) and must be 0.0",
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
    elif plane_type == PlaneType.NORMAL_TO_CURVE_AT_POINT:
        # On-device feedback ("allow 'point and curve' as a valid
        # combination to create a plane, on point and normal to arc"):
        # reuses `line_ref`/`point_ref` verbatim (see `PlaneType`'s own doc
        # comment) - `line_ref` names the Arc here despite the field's name.
        if line_ref is None or point_ref is None or not other_fields_empty({"line_ref", "point_ref"}):
            raise HTTPException(
                status_code=422,
                detail="NORMAL_TO_CURVE_AT_POINT requires both line_ref and point_ref, and nothing else",
            )
        if line_ref.entity_type != SketchEntityType.ARC:
            raise HTTPException(status_code=422, detail="line_ref must have entity_type=ARC")
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


@router.post("/new", response_model=NativeImportResponse, status_code=201)
def start_new_document() -> NativeImportResponse:
    """Bug fix (on-device feedback): starts a fresh, empty Document (and
    clears the Sketch store) for the current session - a full replace, the
    same "whatever was open before is discarded entirely" semantics as
    `import_native_document`, just with an empty Document instead of file
    contents.

    `create_part` below is strictly additive - it always adds onto
    whatever Document the current session already has (see
    `app.document.store.get_document`), with no reset of its own. Before
    this endpoint existed, the client's "New Part"/cold-launch flow called
    `create_part` directly with nothing to reset the Document first, so
    every "New Part" press within one running session kept silently
    piling another Part onto the *same* Document rather than starting a
    genuinely independent one. Native Save then exported the whole pile
    (every Part ever created that session, not just the one being worked
    on), and native Open always displayed only the first Part in that pile
    (`NativeImportResultDto`'s own doc comment) - so a later Part could
    survive inside a saved file's data yet never be reachable again,
    reading as "Save keeps reproducing the first file." The client now
    calls this endpoint immediately before its first `create_part` of a
    "New Part"/cold-launch flow (see `PartScreen._loadPart`), so that
    Part is always the sole Part in a brand-new Document."""
    document = Document(id=str(uuid.uuid4()))
    replace_document(document)
    replace_all_sketches({})
    return NativeImportResponse(document_id=document.id, part_ids=[])


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


def _get_sketch_feature_or_404(part: Part, feature_id: str) -> SketchFeature:
    feature = part.get_feature(feature_id)
    if not isinstance(feature, SketchFeature):
        raise HTTPException(
            status_code=400,
            detail="feature_id does not refer to a SketchFeature in this Part",
        )
    return feature


@router.post(
    "/parts/{part_id}/features/sketch/{feature_id}/external-references",
    response_model=PointResponse,
    status_code=201,
)
def create_external_vertex_reference(
    part_id: str, feature_id: str, payload: ExternalVertexReferenceCreate
) -> PointResponse:
    """Sketcher-roadmap Phase 4.3 v1: the centre-point circle tool's sibling
    for body geometry - materializes `payload` (a Body vertex) as a real
    Point in this SketchFeature's own Sketch, so every existing dimension/
    ghost/undo/persistence code path (all of it Sketch-Point-id-shaped,
    see the roadmap doc's own reasoning) works against it unmodified from
    here on. Fails closed with the same structured `missing_reference` 422
    every other `SubShapeRef` resolution already uses (via
    `resolve_external_vertex_position` -> `resolve_subshape_from_bodies`)
    if `payload` doesn't resolve against this Part's current Bodies.

    Only ever reachable for a Part-backed Sketch (unlike the standalone
    `/sketch` API's own point-creation endpoints) - a bare Sketch created
    directly via that API has no Bodies to reference at all, which is
    exactly why this lives in the document router rather than
    `app.sketch.router`."""
    part = get_part_or_404(part_id)
    sketch_feature = _get_sketch_feature_or_404(part, feature_id)
    sketch = get_sketch_or_404(sketch_feature.sketch_id)
    ref = ExternalVertexReference(body_id=payload.body_id, vertex_index=payload.vertex_index)
    bodies = compute_part_bodies(part)
    x, y = resolve_external_vertex_position(part, sketch, ref, bodies)
    point = sketch.add_external_vertex_reference(x, y, ref)
    return PointResponse(id=point.id, x=point.x, y=point.y, is_locked=sketch.is_point_locked(point.id))


@router.post(
    "/parts/{part_id}/features/sketch/{feature_id}/external-references/edge",
    response_model=ExternalEdgeReferenceResponse,
    status_code=201,
)
def create_external_edge_reference(
    part_id: str, feature_id: str, payload: ExternalEdgeReferenceCreate
) -> ExternalEdgeReferenceResponse:
    """Sketcher-roadmap Phase 4.3 v2: `create_external_vertex_reference`'s
    edge-shaped sibling. Reuses that same vertex-materialize machinery
    *twice* - once per endpoint of `payload` (a Body edge) - rather than
    inventing an edge-specific solver constraint or projection path (per
    the roadmap doc's own v2 scoping): a real, pinned Line between two
    pinned external-reference Points is already rigid with zero new
    machinery, since the Line's own geometry is fully determined by its
    endpoints and `solve_sketch` already re-resolves/re-pins every
    `external_references` entry (v1) on every solve regardless of which
    Sketch entity references it.

    Fails closed with `missing_reference` (edge doesn't resolve) or
    `degenerate_edge` (an edge whose two endpoints are the same Body
    vertex - e.g. a cone apex seam - which would ask for a zero-length
    Line) - both structured 422s, matching every other `SubShapeRef`
    failure mode in this router."""
    part = get_part_or_404(part_id)
    sketch_feature = _get_sketch_feature_or_404(part, feature_id)
    sketch = get_sketch_or_404(sketch_feature.sketch_id)
    bodies = compute_part_bodies(part)
    edge_ref = SubShapeRef(body_id=payload.body_id, shape_type=SubShapeType.EDGE, index=payload.edge_index)
    start_ref, end_ref = edge_endpoint_vertex_refs(bodies, edge_ref)
    if start_ref.index == end_ref.index:
        raise HTTPException(
            status_code=422,
            detail={"type": "degenerate_edge", "body_id": payload.body_id, "index": payload.edge_index},
        )

    start_vertex_ref = ExternalVertexReference(body_id=start_ref.body_id, vertex_index=start_ref.index)
    start_x, start_y = resolve_external_vertex_position(part, sketch, start_vertex_ref, bodies)
    start_point = sketch.add_external_vertex_reference(start_x, start_y, start_vertex_ref)

    end_vertex_ref = ExternalVertexReference(body_id=end_ref.body_id, vertex_index=end_ref.index)
    end_x, end_y = resolve_external_vertex_position(part, sketch, end_vertex_ref, bodies)
    end_point = sketch.add_external_vertex_reference(end_x, end_y, end_vertex_ref)

    # On-device feedback: a materialized Body edge is a reference for
    # dimensioning against, not new solid geometry the user drew - marking
    # it construction keeps it out of profile/extrude detection (see
    # detect_profile's own construction-skip) the same way every other
    # reference-only Line already is.
    line = sketch.add_line(start_point.id, end_point.id, construction=True)
    return ExternalEdgeReferenceResponse(
        line=LineResponse(
            id=line.id,
            start_point_id=line.start_point_id,
            end_point_id=line.end_point_id,
            length=line.length(sketch.points),
            construction=line.construction,
        ),
        start_point=PointResponse(
            id=start_point.id, x=start_point.x, y=start_point.y, is_locked=sketch.is_point_locked(start_point.id)
        ),
        end_point=PointResponse(
            id=end_point.id, x=end_point.x, y=end_point.y, is_locked=sketch.is_point_locked(end_point.id)
        ),
    )


@router.post(
    "/parts/{part_id}/features/sketch/{feature_id}/convert-entities/vertex",
    response_model=PointResponse,
    status_code=201,
)
def convert_body_vertex(part_id: str, feature_id: str, payload: ConvertVertexCreate) -> PointResponse:
    """Sketcher-roadmap Phase 9 v2 (Convert Entities): materializes
    `payload` (a Body vertex) as a real, *associative* Point in this
    SketchFeature's own Sketch - reuses `create_external_vertex_reference`'s
    exact OCCT resolution (`resolve_external_vertex_position`) and its
    exact persistence (`Sketch.add_or_reuse_external_vertex_reference`,
    Convert Entities' own re-pick-idempotent wrapper around
    `add_external_vertex_reference`) - the *only* difference from Phase
    4.3's own reference-picking endpoint is what this Point is *for*: a
    real, non-construction Point meant to participate in ordinary sketch
    geometry (profile detection, Extrude), not a pinned dimensioning
    target. It still gets Phase 4.3's full associative behavior for free,
    since nothing about `external_references`/`solve_sketch`'s pinning/
    `refresh_external_references`/`SketchFeatureResponse.has_lost_
    reference` is construction-status-aware - staleness detection and the
    feature-tree "lost reference" indicator already work for this without
    any changes of their own.

    v1 (frozen, one-time copy, no live link) is gone - this replaces it at
    the same endpoint/wire shape, not a new parallel mode. Like every other
    external-reference Point, this one is pinned (`solve_sketch` never
    moves it) and reports `PointResponse.is_locked=True` so the client's
    own `dragTargetPointIdAt` can exclude it from drag targeting too (on-
    device feedback: "all the converted lines are completely mobile... the
    converted entities should be... locked" - a first version of this
    endpoint reused Phase 4.3's pinning mechanism verbatim but never
    surfaced it to the client this way, so dragging one *looked* possible
    even though the next solve would have snapped it back regardless).

    Same `missing_reference` 422 as the reference-picking endpoint if
    `payload` doesn't resolve against this Part's current Bodies."""
    part = get_part_or_404(part_id)
    sketch_feature = _get_sketch_feature_or_404(part, feature_id)
    sketch = get_sketch_or_404(sketch_feature.sketch_id)
    ref = ExternalVertexReference(body_id=payload.body_id, vertex_index=payload.vertex_index)
    bodies = compute_part_bodies(part)
    x, y = resolve_external_vertex_position(part, sketch, ref, bodies)
    point = sketch.add_or_reuse_external_vertex_reference(x, y, ref)
    return PointResponse(id=point.id, x=point.x, y=point.y, is_locked=sketch.is_point_locked(point.id))


@router.post(
    "/parts/{part_id}/features/sketch/{feature_id}/convert-entities/edge",
    response_model=ConvertEdgeResponse,
    status_code=201,
)
def convert_body_edge(part_id: str, feature_id: str, payload: ConvertEdgeCreate) -> ConvertEdgeResponse:
    """Convert Entities' edge-shaped sibling to `convert_body_vertex` (v2) -
    mirrors `create_external_edge_reference`'s own "resolve both endpoint
    vertices" shape. Its two endpoint Points are associative
    (`add_or_reuse_external_vertex_reference`), same as `convert_body_vertex`
    - see that endpoint's own doc comment for what "associative" gets for
    free (staleness detection, the feature-tree lost-reference indicator)
    and its one known, inherited limitation (drag-then-snap-back).

    On-device feedback ("when I offset a curved edge it creates a straight
    line"): used to *always* connect those two Points with a straight
    Line - correct for the overwhelming majority of edges (which are
    straight), but silently flattened a curved one to its own chord no
    matter what. Now tries `resolve_circular_edge_arc` first: a circular
    Body edge lying flat in this Sketch's own plane resolves as a real,
    non-construction Arc instead (`add_arc(..., construction=False)`,
    same "real, extrude-participating geometry" contract the chord-Line
    path already had) - only falling back to the chord-Line behaviour
    when that returns `None` (not circular at all, or circular but not
    coplanar with this Sketch - e.g. a curve on an unrelated face).

    v1 limitation of the new Arc path specifically: its centre Point is a
    plain, non-associative `add_point` - unlike `start_point`/`end_point`
    (still real external vertex references), nothing currently pins a
    circular edge's own *centre* the way a vertex reference pins a
    corner, so it won't itself track a later change to the Body's shape.

    On-device feedback ("offsetting the circular edge of a cylinder fails
    with a degenerate_edge error"): a *full* circular edge (both
    topological endpoints the same Body vertex - a cylinder's rim, a
    drilled hole, ...) used to always 422 as `degenerate_edge` before ever
    reaching curve-type detection, since it has no two distinct vertices
    for the chord-Line/Arc path's own "resolve both endpoints" shape to
    hang off of. Now checked first, via `resolve_full_circular_edge` (the
    same `resolve_planar_circle` coplanarity math `resolve_circular_edge_
    arc` already uses, minus the CCW-endpoint step a full circle has no
    use for) - a coplanar circular full edge resolves as a real Circle
    (`add_circle`) instead. `degenerate_edge` remains the fallback for a
    genuinely degenerate (zero-length) edge, or a full circular edge that
    isn't coplanar with this Sketch.

    `add_or_reuse_external_vertex_reference`'s own identity-based (not
    position-based) matching is what lets two separately-converted
    adjacent edges end up sharing one real Point at their common Body
    vertex - `edge_endpoint_vertex_refs` resolves both edges' shared
    corner to the *exact same* `(body_id, vertex_index)`, so the reuse
    lookup finds it deterministically, not by floating-point luck - so the
    result can still register as a closed profile for Extrude, same
    reasoning as `trim_circle`'s own point-reuse fix.

    Fails closed with the same `missing_reference`/`degenerate_edge` 422s
    as `create_external_edge_reference`."""
    part = get_part_or_404(part_id)
    sketch_feature = _get_sketch_feature_or_404(part, feature_id)
    sketch = get_sketch_or_404(sketch_feature.sketch_id)
    bodies = compute_part_bodies(part)
    edge_ref = SubShapeRef(body_id=payload.body_id, shape_type=SubShapeType.EDGE, index=payload.edge_index)
    start_ref, end_ref = edge_endpoint_vertex_refs(bodies, edge_ref)
    if start_ref.index == end_ref.index:
        basis = basis_for_sketch(part, sketch, bodies, frozenset())
        circle_params = resolve_full_circular_edge(bodies, edge_ref, basis)
        if circle_params is None:
            raise HTTPException(
                status_code=422,
                detail={"type": "degenerate_edge", "body_id": payload.body_id, "index": payload.edge_index},
            )
        center_x, center_y, radius = circle_params
        center_point = sketch.add_point(center_x, center_y)
        circle = sketch.add_circle(center_point.id, radius=radius, construction=payload.construction)
        # On-device feedback ("converted edges... the converted entities
        # should be projected onto the sketch plane and locked at that
        # projection point"): a full circular Body edge has no vertex of
        # its own to make this centre a live external reference, but it
        # must still be pinned - see `FixedConstraint`'s own doc comment.
        # One call covers the centre, `radius_point_id`, and all four
        # cardinal Points together (`Sketch.add_circle`'s own radius
        # DistanceConstraint starts `provisional`, same as any freshly-
        # drawn Circle - it alone would leave the radius, and so the whole
        # Circle's size, still free to drift/drag) - pinning the centre
        # alone isn't enough to freeze the Circle as a whole, every Point
        # that defines it needs to be.
        sketch.add_fixed_constraint(circle.id)
        center_response = PointResponse(
            id=center_point.id, x=center_point.x, y=center_point.y, is_locked=True
        )
        return ConvertEdgeResponse(
            circle=CircleResponse(
                id=circle.id,
                center_point_id=circle.center_point_id,
                radius_point_id=circle.radius_point_id,
                radius=circle.radius(sketch.points),
                construction=circle.construction,
                cardinal_point_ids=circle.cardinal_point_ids,
                radius_constraint_id=circle.radius_constraint_id,
            ),
            start_point=center_response,
            end_point=center_response,
            center_point=center_response,
        )

    start_vertex_ref = ExternalVertexReference(body_id=start_ref.body_id, vertex_index=start_ref.index)
    start_x, start_y = resolve_external_vertex_position(part, sketch, start_vertex_ref, bodies)
    start_point = sketch.add_or_reuse_external_vertex_reference(start_x, start_y, start_vertex_ref)

    end_vertex_ref = ExternalVertexReference(body_id=end_ref.body_id, vertex_index=end_ref.index)
    end_x, end_y = resolve_external_vertex_position(part, sketch, end_vertex_ref, bodies)
    end_point = sketch.add_or_reuse_external_vertex_reference(end_x, end_y, end_vertex_ref)

    basis = basis_for_sketch(part, sketch, bodies, frozenset())
    arc_params = resolve_circular_edge_arc(bodies, edge_ref, basis, (start_x, start_y), (end_x, end_y))
    if arc_params is not None:
        center_x, center_y, _radius, resolved_start_xy, resolved_end_xy = arc_params
        if resolved_start_xy == (start_x, start_y):
            arc_start_point, arc_end_point = start_point, end_point
        else:
            arc_start_point, arc_end_point = end_point, start_point
        center_point = sketch.add_point(center_x, center_y)
        arc = sketch.add_arc(center_point.id, arc_start_point.id, arc_end_point.id, construction=payload.construction)
        # See the full-circle branch's own identical comment above - an
        # Arc's centre has no Body vertex of its own either. Its start/end
        # Points are already `external_references`-locked (see above), so
        # `add_fixed_constraint`'s own already-locked filter leaves only
        # the centre to actually add here - same net effect as the old
        # centre-only `pinned_point_ids.add`, without hardcoding that this
        # is the only Point Arc needs pinned.
        sketch.add_fixed_constraint(arc.id)
        return ConvertEdgeResponse(
            arc=ArcResponse(
                id=arc.id,
                center_point_id=arc.center_point_id,
                start_point_id=arc.start_point_id,
                end_point_id=arc.end_point_id,
                radius=arc.radius(sketch.points),
                construction=arc.construction,
                radius_constraint_id=arc.radius_constraint_id,
            ),
            start_point=PointResponse(
                id=start_point.id, x=start_point.x, y=start_point.y, is_locked=sketch.is_point_locked(start_point.id)
            ),
            end_point=PointResponse(
                id=end_point.id, x=end_point.x, y=end_point.y, is_locked=sketch.is_point_locked(end_point.id)
            ),
            center_point=PointResponse(id=center_point.id, x=center_point.x, y=center_point.y, is_locked=True),
        )

    line = sketch.add_line(start_point.id, end_point.id, construction=payload.construction)
    return ConvertEdgeResponse(
        line=LineResponse(
            id=line.id,
            start_point_id=line.start_point_id,
            end_point_id=line.end_point_id,
            length=line.length(sketch.points),
            construction=line.construction,
        ),
        start_point=PointResponse(
            id=start_point.id, x=start_point.x, y=start_point.y, is_locked=sketch.is_point_locked(start_point.id)
        ),
        end_point=PointResponse(
            id=end_point.id, x=end_point.x, y=end_point.y, is_locked=sketch.is_point_locked(end_point.id)
        ),
    )


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


@router.post("/parts/{part_id}/surface-features", response_model=SurfaceFeatureResponse, status_code=201)
def create_surface_feature(part_id: str, payload: SurfaceFeatureCreate) -> SurfaceFeatureResponse:
    """Mirrors `create_extrude_feature`'s shape closely - "Extrude but a
    shell instead of a solid" (see `SurfaceFeature`'s own docstring): fails
    closed on payload shape (`_validate_surface_payload`, `_validate_
    extrude_distances`) before ever persisting a SurfaceFeature. Unlike
    Extrude, the backing Sketch is not required to already have a closed
    profile at create time - a Surface also accepts a single open wire,
    resolved lazily by `app.document.surface.resolve_surface_from_bodies`,
    the same "skip, don't fail the whole /mesh request" resilience every
    other Sketch-profile-backed Feature already gets for topology drift."""
    part = get_part_or_404(part_id)
    direction_ref = (
        _pattern_direction_ref_to_domain(payload.direction_ref) if payload.direction_ref else None
    )
    _validate_surface_payload(part, payload.sketch_feature_id, direction_ref)
    _validate_extrude_distances(payload.start_distance, payload.end_distance)
    profile_refs = [_sketch_entity_ref_to_domain(ref) for ref in payload.profile_refs]
    feature = SurfaceFeature(
        id=str(uuid.uuid4()),
        sketch_feature_id=payload.sketch_feature_id,
        start_distance=payload.start_distance,
        end_distance=payload.end_distance,
        direction_ref=direction_ref,
        profile_refs=profile_refs,
    )
    part.add_feature(feature)
    return _feature_response(part, feature)


def _get_surface_feature_or_404(part: Part, feature_id: str) -> SurfaceFeature:
    feature = part.get_feature(feature_id)
    if not isinstance(feature, SurfaceFeature):
        raise HTTPException(status_code=404, detail="Surface feature not found")
    return feature


@router.patch("/parts/{part_id}/surface-features/{feature_id}", response_model=SurfaceFeatureResponse)
def update_surface_feature(
    part_id: str, feature_id: str, payload: SurfaceFeatureUpdate
) -> SurfaceFeatureResponse:
    """Mirrors `update_extrude_feature`'s exact shape - same validate-
    before-mutate discipline, omitted fields keep their current value."""
    part = get_part_or_404(part_id)
    feature = _get_surface_feature_or_404(part, feature_id)

    new_sketch_feature_id = (
        payload.sketch_feature_id if payload.sketch_feature_id is not None else feature.sketch_feature_id
    )
    new_start = payload.start_distance if payload.start_distance is not None else feature.start_distance
    new_end = payload.end_distance if payload.end_distance is not None else feature.end_distance
    new_direction_ref = (
        _pattern_direction_ref_to_domain(payload.direction_ref)
        if payload.direction_ref is not None
        else feature.direction_ref
    )
    new_profile_refs = (
        [_sketch_entity_ref_to_domain(ref) for ref in payload.profile_refs]
        if payload.profile_refs is not None
        else feature.profile_refs
    )
    _validate_surface_payload(part, new_sketch_feature_id, new_direction_ref)
    _validate_extrude_distances(new_start, new_end)

    feature.sketch_feature_id = new_sketch_feature_id
    feature.start_distance = new_start
    feature.end_distance = new_end
    feature.direction_ref = new_direction_ref
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


def _measurement_result_to_schema(result: MeasurementResult) -> MeasurementResultSchema:
    axis = (
        AxisSchema(origin=result.axis_origin, direction=result.axis_direction)
        if result.axis_origin is not None and result.axis_direction is not None
        else None
    )
    return MeasurementResultSchema(
        point=result.point,
        length=result.length,
        area=result.area,
        radius=result.radius,
        diameter=result.diameter,
        center=result.center,
        axis=axis,
        normal=result.normal,
        point_on_face=result.point_on_face,
        distance=result.distance,
        point_a=result.point_a,
        point_b=result.point_b,
        delta=result.delta,
        axis_distance=result.axis_distance,
        axes_parallel=result.axes_parallel,
        normal_distance=result.normal_distance,
        faces_parallel=result.faces_parallel,
    )


@router.post("/parts/{part_id}/measure", response_model=MeasurementResultSchema)
def measure_entities(part_id: str, payload: MeasureRequest) -> MeasurementResultSchema:
    """Measure tool: a stateless, read-only geometry query over 1-2
    already-picked sub-shapes - unlike every `*-features` endpoint in this
    router, this never constructs or persists a `Feature`, so there is
    nothing to validate-then-add and no 201 (default 200, matching
    `preview_loft_feature_coarse`'s own compute-only-endpoint convention -
    nothing was created). `1 <= len(refs) <= 2` is this endpoint's only
    payload-shape validation; `app.document.measure.measure` raises the
    existing `missing_reference` 422 (via `resolve_subshape_from_bodies`) if
    a ref no longer resolves, or the new `measure_failed` 422 if the
    two-entity distance algorithm can't converge on a degenerate pair."""
    part = get_part_or_404(part_id)
    if not 1 <= len(payload.refs) <= 2:
        raise HTTPException(
            status_code=422, detail={"type": "invalid_measure_selection", "count": len(payload.refs)}
        )
    refs = [_subshape_ref_to_domain(ref) for ref in payload.refs]
    result = compute_measurement(part, refs)
    return _measurement_result_to_schema(result)


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


@router.post("/parts/{part_id}/loft-features", response_model=LoftFeatureResponse, status_code=201)
def create_loft_feature(part_id: str, payload: LoftFeatureCreate) -> LoftFeatureResponse:
    """`docs/gear-design/04-helical-herringbone-loft.md` (4b): mirrors
    `create_sweep_feature`'s exact shape - validates the payload shape
    (`_validate_loft_sections`; `_validate_target_body_ids`, widened to
    accept a Body from any of Extrude/Revolve/Sweep/Gear/Rack/Loft) and
    then resolvability (`app.document.loft.resolve_loft`) *before*
    constructing the Feature - fails closed with `invalid_loft_section`/
    `loft_failed`/`missing_reference` rather than ever persisting an
    unresolvable Loft. Its own non-blocking self-intersection `warnings`
    (from that same `resolve_loft` call) are threaded straight into the
    response rather than re-resolved a second time."""
    part = get_part_or_404(part_id)
    sections = [_loft_section_to_domain(section) for section in payload.sections]
    guide_curve_refs = [_sketch_entity_ref_to_domain(ref) for ref in payload.guide_curve_refs]
    _validate_loft_sections(sections)
    _validate_loft_thickness(payload.thickness)
    _validate_loft_guide_curve_refs(guide_curve_refs)
    _validate_target_body_ids(part, payload.mode == LoftMode.CUT, payload.target_body_ids)
    feature = LoftFeature(
        id=str(uuid.uuid4()),
        sections=sections,
        mode=payload.mode,
        ruled=payload.ruled,
        target_body_ids=list(payload.target_body_ids),
        thickness=payload.thickness,
        guide_curve_refs=guide_curve_refs,
    )
    _, warnings = resolve_loft(part, feature)  # raises on an unresolvable/invalid loft
    part.add_feature(feature)
    return _loft_feature_response(part, feature, warnings)


@router.post("/parts/{part_id}/loft-features/coarse-preview", response_model=list[BodyMeshResponse])
def preview_loft_feature_coarse(
    part_id: str, payload: LoftFeatureCreate, quality: float | None = Query(default=None, ge=0.0, le=1.0)
) -> list[BodyMeshResponse]:
    """`docs/lod-strategy/01-design.md` SS4: the 3D coarse analogue of
    `create_loft_feature`, for a not-yet-created `LoftFeature` payload - a
    real but cheap two-section loft (`app.document.loft.resolve_loft_
    coarse`) instead of the full N-section construction. Mirrors `create_
    loft_feature`'s own validate-then-build shape exactly (same scratch
    Feature, same payload validation), but never calls `part.add_feature` -
    nothing is persisted, no Feature is created, no Part state changes."""
    part = get_part_or_404(part_id)
    mesh_quality = DEFAULT_MESH_QUALITY if quality is None else mesh_quality_from_slider(quality)
    sections = [_loft_section_to_domain(section) for section in payload.sections]
    guide_curve_refs = [_sketch_entity_ref_to_domain(ref) for ref in payload.guide_curve_refs]
    _validate_loft_sections(sections)
    _validate_loft_thickness(payload.thickness)
    _validate_loft_guide_curve_refs(guide_curve_refs)
    _validate_target_body_ids(part, payload.mode == LoftMode.CUT, payload.target_body_ids)
    feature = LoftFeature(
        id=str(uuid.uuid4()),
        sections=sections,
        mode=payload.mode,
        ruled=payload.ruled,
        target_body_ids=list(payload.target_body_ids),
        thickness=payload.thickness,
        guide_curve_refs=guide_curve_refs,
    )
    shape = resolve_loft_coarse(part, feature)  # raises on an unresolvable/invalid loft
    return _coarse_preview_response(shape, mesh_quality)


def _get_loft_feature_or_404(part: Part, feature_id: str) -> LoftFeature:
    feature = part.get_feature(feature_id)
    if not isinstance(feature, LoftFeature):
        raise HTTPException(status_code=404, detail="Loft feature not found")
    return feature


@router.patch("/parts/{part_id}/loft-features/{feature_id}", response_model=LoftFeatureResponse)
def update_loft_feature(part_id: str, feature_id: str, payload: LoftFeatureUpdate) -> LoftFeatureResponse:
    """Same validate-before-mutate discipline as `update_sweep_feature`: the
    merged (existing-plus-payload) values are checked against a scratch
    Feature sharing the real one's id before anything on the real, stored
    Feature is touched."""
    part = get_part_or_404(part_id)
    feature = _get_loft_feature_or_404(part, feature_id)

    new_sections = (
        [_loft_section_to_domain(section) for section in payload.sections]
        if payload.sections is not None
        else feature.sections
    )
    new_mode = payload.mode if payload.mode is not None else feature.mode
    new_ruled = payload.ruled if payload.ruled is not None else feature.ruled
    new_target_body_ids = (
        payload.target_body_ids if payload.target_body_ids is not None else feature.target_body_ids
    )
    new_thickness = payload.thickness if payload.thickness is not None else feature.thickness
    new_guide_curve_refs = (
        [_sketch_entity_ref_to_domain(ref) for ref in payload.guide_curve_refs]
        if payload.guide_curve_refs is not None
        else feature.guide_curve_refs
    )
    _validate_loft_sections(new_sections)
    _validate_loft_thickness(new_thickness)
    _validate_loft_guide_curve_refs(new_guide_curve_refs)
    _validate_target_body_ids(part, new_mode == LoftMode.CUT, new_target_body_ids)

    candidate = LoftFeature(
        id=feature.id,
        sections=new_sections,
        mode=new_mode,
        ruled=new_ruled,
        target_body_ids=list(new_target_body_ids),
        thickness=new_thickness,
        guide_curve_refs=new_guide_curve_refs,
    )
    _, warnings = resolve_loft(part, candidate)  # raises on an unresolvable/invalid loft

    feature.sections = candidate.sections
    feature.mode = candidate.mode
    feature.ruled = candidate.ruled
    feature.target_body_ids = candidate.target_body_ids
    feature.thickness = candidate.thickness
    feature.guide_curve_refs = candidate.guide_curve_refs
    return _loft_feature_response(part, feature, warnings)


@router.post("/parts/{part_id}/mirror-features", response_model=MirrorFeatureResponse, status_code=201)
def create_mirror_feature(part_id: str, payload: MirrorFeatureCreate) -> MirrorFeatureResponse:
    """Pattern/Mirror scoping's Phase 1 (`docs/pattern-mirror-scope.md`
    §2.1/§4): mirrors `create_chamfer_feature`'s exact shape - unlocked
    from the start, fails closed (via `_validate_mirror_source_body_ids`/
    `_validate_plane_ref` for payload shape, then `resolve_mirror` for
    referential/geometric validity) before ever persisting an unresolvable
    Mirror."""
    part = get_part_or_404(part_id)
    source_body_ids = list(payload.source_body_ids)
    source_feature_ids = list(payload.source_feature_ids)
    mirror_plane = _plane_ref_to_domain(payload.mirror_plane)
    _validate_mirror_source_body_ids(part, source_body_ids, source_feature_ids, payload.tool_feature_id)
    _validate_plane_ref(part, mirror_plane)
    _validate_tool_feature_id(
        part, payload.tool_feature_id, source_body_ids, source_feature_ids, payload.merge, "MirrorFeature"
    )
    feature = MirrorFeature(
        id=str(uuid.uuid4()),
        source_body_ids=source_body_ids,
        mirror_plane=mirror_plane,
        source_feature_ids=source_feature_ids,
        merge=payload.merge,
        tool_feature_id=payload.tool_feature_id,
    )
    resolve_mirror(part, feature)  # raises on an unresolvable reference; result unused here
    part.add_feature(feature)
    return _feature_response(part, feature)


def _get_mirror_feature_or_404(part: Part, feature_id: str) -> MirrorFeature:
    feature = part.get_feature(feature_id)
    if not isinstance(feature, MirrorFeature):
        raise HTTPException(status_code=404, detail="Mirror feature not found")
    return feature


@router.patch("/parts/{part_id}/mirror-features/{feature_id}", response_model=MirrorFeatureResponse)
def update_mirror_feature(
    part_id: str, feature_id: str, payload: MirrorFeatureUpdate
) -> MirrorFeatureResponse:
    """Mirrors `update_chamfer_feature`'s exact shape - same validate-
    before-mutate discipline against a scratch Feature sharing the real
    one's id."""
    part = get_part_or_404(part_id)
    feature = _get_mirror_feature_or_404(part, feature_id)

    new_source_body_ids = (
        list(payload.source_body_ids) if payload.source_body_ids is not None else feature.source_body_ids
    )
    new_source_feature_ids = (
        list(payload.source_feature_ids)
        if payload.source_feature_ids is not None
        else feature.source_feature_ids
    )
    new_mirror_plane = (
        _plane_ref_to_domain(payload.mirror_plane)
        if payload.mirror_plane is not None
        else feature.mirror_plane
    )
    new_merge = payload.merge if payload.merge is not None else feature.merge
    # Phase 8 (§2.11): `tool_feature_id` follows the same omitted-vs-
    # current convention `mirror_plane`/`direction_1`/`axis` already use on
    # their own Update schemas - `None` (omitted) keeps whatever this
    # Mirror already has; a real value switches into (or re-points within)
    # tool_feature_id mode. There is deliberately no way to switch *out* of
    # tool_feature_id mode via this endpoint (mirrors `PatternFeatureUpdate.
    # pattern_type`'s own immutability - switching modes is delete+recreate,
    # not an edit).
    new_tool_feature_id = (
        payload.tool_feature_id if payload.tool_feature_id is not None else feature.tool_feature_id
    )
    _validate_mirror_source_body_ids(part, new_source_body_ids, new_source_feature_ids, new_tool_feature_id)
    _validate_plane_ref(part, new_mirror_plane)
    _validate_tool_feature_id(
        part, new_tool_feature_id, new_source_body_ids, new_source_feature_ids, new_merge, "MirrorFeature"
    )

    candidate = MirrorFeature(
        id=feature.id,
        source_body_ids=new_source_body_ids,
        mirror_plane=new_mirror_plane,
        source_feature_ids=new_source_feature_ids,
        merge=new_merge,
        tool_feature_id=new_tool_feature_id,
    )
    resolve_mirror(part, candidate)  # raises on an unresolvable reference

    feature.source_body_ids = candidate.source_body_ids
    feature.mirror_plane = candidate.mirror_plane
    feature.source_feature_ids = candidate.source_feature_ids
    feature.merge = candidate.merge
    feature.tool_feature_id = candidate.tool_feature_id
    return _feature_response(part, feature)


@router.post("/parts/{part_id}/merge-features", response_model=MergeFeatureResponse, status_code=201)
def create_merge_feature(part_id: str, payload: MergeFeatureCreate) -> MergeFeatureResponse:
    """The first of the Boolean family (Subtract/Common/Split follow in
    later work): mirrors `create_surface_feature`'s shape (fails closed on
    payload-shape validation alone, no eager OCCT resolve - `MergeFeature`
    has no per-instance geometry of its own to fail the way a Mirror/
    Pattern's realized copies can, just a plain repeated fuse over Bodies
    already known to exist)."""
    part = get_part_or_404(part_id)
    body_ids = list(payload.body_ids)
    _validate_merge_body_ids(part, body_ids)
    feature = MergeFeature(id=str(uuid.uuid4()), body_ids=body_ids)
    part.add_feature(feature)
    return _feature_response(part, feature)


def _get_merge_feature_or_404(part: Part, feature_id: str) -> MergeFeature:
    feature = part.get_feature(feature_id)
    if not isinstance(feature, MergeFeature):
        raise HTTPException(status_code=404, detail="Merge feature not found")
    return feature


@router.patch("/parts/{part_id}/merge-features/{feature_id}", response_model=MergeFeatureResponse)
def update_merge_feature(
    part_id: str, feature_id: str, payload: MergeFeatureUpdate
) -> MergeFeatureResponse:
    """Mirrors `update_surface_feature`'s exact shape - same validate-
    before-mutate discipline, omitted fields keep their current value."""
    part = get_part_or_404(part_id)
    feature = _get_merge_feature_or_404(part, feature_id)

    new_body_ids = list(payload.body_ids) if payload.body_ids is not None else feature.body_ids
    _validate_merge_body_ids(part, new_body_ids)

    feature.body_ids = new_body_ids
    return _feature_response(part, feature)


@router.post("/parts/{part_id}/boolean-features", response_model=BooleanFeatureResponse, status_code=201)
def create_boolean_feature(part_id: str, payload: BooleanFeatureCreate) -> BooleanFeatureResponse:
    """Boolean family, Subtract/Common: mirrors `create_merge_feature`'s
    shape (fails closed on payload-shape validation alone, no eager OCCT
    resolve - like Merge, a `BooleanFeature` has no per-instance geometry
    of its own to fail, just a repeated Cut/Common fold over Bodies already
    known to exist)."""
    part = get_part_or_404(part_id)
    target_body_ids = list(payload.target_body_ids)
    tool_body_ids = list(payload.tool_body_ids)
    _validate_boolean_body_ids(part, target_body_ids, tool_body_ids)
    feature = BooleanFeature(
        id=str(uuid.uuid4()),
        operation=payload.operation,
        target_body_ids=target_body_ids,
        tool_body_ids=tool_body_ids,
        consume_tool_bodies=payload.consume_tool_bodies,
    )
    part.add_feature(feature)
    return _feature_response(part, feature)


def _get_boolean_feature_or_404(part: Part, feature_id: str) -> BooleanFeature:
    feature = part.get_feature(feature_id)
    if not isinstance(feature, BooleanFeature):
        raise HTTPException(status_code=404, detail="Boolean feature not found")
    return feature


@router.patch("/parts/{part_id}/boolean-features/{feature_id}", response_model=BooleanFeatureResponse)
def update_boolean_feature(
    part_id: str, feature_id: str, payload: BooleanFeatureUpdate
) -> BooleanFeatureResponse:
    """Mirrors `update_merge_feature`'s exact shape - same validate-before-
    mutate discipline, omitted fields keep their current value."""
    part = get_part_or_404(part_id)
    feature = _get_boolean_feature_or_404(part, feature_id)

    new_target_body_ids = (
        list(payload.target_body_ids) if payload.target_body_ids is not None else feature.target_body_ids
    )
    new_tool_body_ids = (
        list(payload.tool_body_ids) if payload.tool_body_ids is not None else feature.tool_body_ids
    )
    _validate_boolean_body_ids(part, new_target_body_ids, new_tool_body_ids)

    feature.operation = payload.operation if payload.operation is not None else feature.operation
    feature.target_body_ids = new_target_body_ids
    feature.tool_body_ids = new_tool_body_ids
    feature.consume_tool_bodies = (
        payload.consume_tool_bodies
        if payload.consume_tool_bodies is not None
        else feature.consume_tool_bodies
    )
    return _feature_response(part, feature)


@router.post(
    "/parts/{part_id}/delete-body-features", response_model=DeleteBodyFeatureResponse, status_code=201
)
def create_delete_body_feature(
    part_id: str, payload: DeleteBodyFeatureCreate
) -> DeleteBodyFeatureResponse:
    """Direct Editing family (first entry): mirrors `create_merge_feature`'s
    shape (fails closed on payload-shape validation alone, no eager OCCT
    resolve - `DeleteBodyFeature` has no per-instance geometry of its own to
    fail, it's a plain removal from `bodies` - see `app.document.
    delete_body.apply_delete_body_to_bodies`)."""
    part = get_part_or_404(part_id)
    body_ids = list(payload.body_ids)
    _validate_delete_body_ids(part, body_ids)
    feature = DeleteBodyFeature(id=str(uuid.uuid4()), body_ids=body_ids)
    part.add_feature(feature)
    return _feature_response(part, feature)


def _get_delete_body_feature_or_404(part: Part, feature_id: str) -> DeleteBodyFeature:
    feature = part.get_feature(feature_id)
    if not isinstance(feature, DeleteBodyFeature):
        raise HTTPException(status_code=404, detail="Delete body feature not found")
    return feature


@router.patch(
    "/parts/{part_id}/delete-body-features/{feature_id}", response_model=DeleteBodyFeatureResponse
)
def update_delete_body_feature(
    part_id: str, feature_id: str, payload: DeleteBodyFeatureUpdate
) -> DeleteBodyFeatureResponse:
    """Mirrors `update_merge_feature`'s exact shape - same validate-before-
    mutate discipline, omitted fields keep their current value."""
    part = get_part_or_404(part_id)
    feature = _get_delete_body_feature_or_404(part, feature_id)

    new_body_ids = list(payload.body_ids) if payload.body_ids is not None else feature.body_ids
    _validate_delete_body_ids(part, new_body_ids)

    feature.body_ids = new_body_ids
    return _feature_response(part, feature)


@router.post(
    "/parts/{part_id}/scale-body-features", response_model=ScaleBodyFeatureResponse, status_code=201
)
def create_scale_body_feature(part_id: str, payload: ScaleBodyFeatureCreate) -> ScaleBodyFeatureResponse:
    """Direct Editing family (second entry): mirrors `create_fillet_
    feature`'s shape (fails closed on payload-shape validation, then
    resolvability, before ever persisting an unresolvable Scale) rather
    than `create_merge_feature`'s shape - a Scale has real per-instance
    geometry of its own that can fail (a missing body_id, or a degenerate
    transform), unlike Merge/Boolean/Delete Body."""
    part = get_part_or_404(part_id)
    _validate_scale_body_factor(part, payload.body_id, payload.factor)
    feature = ScaleBodyFeature(id=str(uuid.uuid4()), body_id=payload.body_id, factor=payload.factor)
    resolve_scale_body(part, feature)  # raises on an unresolvable/degenerate scale; result unused here
    part.add_feature(feature)
    return _feature_response(part, feature)


def _get_scale_body_feature_or_404(part: Part, feature_id: str) -> ScaleBodyFeature:
    feature = part.get_feature(feature_id)
    if not isinstance(feature, ScaleBodyFeature):
        raise HTTPException(status_code=404, detail="Scale body feature not found")
    return feature


@router.patch(
    "/parts/{part_id}/scale-body-features/{feature_id}", response_model=ScaleBodyFeatureResponse
)
def update_scale_body_feature(
    part_id: str, feature_id: str, payload: ScaleBodyFeatureUpdate
) -> ScaleBodyFeatureResponse:
    """Same validate-before-mutate discipline as `update_fillet_feature`:
    the merged (existing-plus-payload) values are checked against a scratch
    Feature sharing the real one's id (`resolve_scale_body` excludes that
    id from its own "current bodies" computation for exactly this reason)
    before anything on the real, stored Feature is touched."""
    part = get_part_or_404(part_id)
    feature = _get_scale_body_feature_or_404(part, feature_id)

    new_body_id = payload.body_id if payload.body_id is not None else feature.body_id
    new_factor = payload.factor if payload.factor is not None else feature.factor
    _validate_scale_body_factor(part, new_body_id, new_factor)

    candidate = ScaleBodyFeature(id=feature.id, body_id=new_body_id, factor=new_factor)
    resolve_scale_body(part, candidate)  # raises on an unresolvable/degenerate scale

    feature.body_id = candidate.body_id
    feature.factor = candidate.factor
    return _feature_response(part, feature)


@router.post(
    "/parts/{part_id}/move-body-features", response_model=MoveBodyFeatureResponse, status_code=201
)
def create_move_body_feature(part_id: str, payload: MoveBodyFeatureCreate) -> MoveBodyFeatureResponse:
    """Direct Editing family (third entry, "Move/Copy Body"): mirrors
    `create_scale_body_feature`'s shape (fails closed on payload-shape
    validation, then resolvability, before ever persisting an unresolvable
    Move/Copy)."""
    part = get_part_or_404(part_id)
    rotation_axis = (
        _pattern_axis_ref_to_domain(payload.rotation_axis) if payload.rotation_axis is not None else None
    )
    _validate_move_body_payload(part, payload.body_id, rotation_axis)
    feature = MoveBodyFeature(
        id=str(uuid.uuid4()),
        body_id=payload.body_id,
        delta=payload.delta,
        rotation_axis=rotation_axis,
        rotation_angle_degrees=payload.rotation_angle_degrees,
        make_copy=payload.make_copy,
    )
    resolve_move_body(part, feature)  # raises on an unresolvable/degenerate move; result unused here
    part.add_feature(feature)
    return _feature_response(part, feature)


def _get_move_body_feature_or_404(part: Part, feature_id: str) -> MoveBodyFeature:
    feature = part.get_feature(feature_id)
    if not isinstance(feature, MoveBodyFeature):
        raise HTTPException(status_code=404, detail="Move body feature not found")
    return feature


@router.patch(
    "/parts/{part_id}/move-body-features/{feature_id}", response_model=MoveBodyFeatureResponse
)
def update_move_body_feature(
    part_id: str, feature_id: str, payload: MoveBodyFeatureUpdate
) -> MoveBodyFeatureResponse:
    """Same validate-before-mutate discipline as `update_scale_body_
    feature`: the merged (existing-plus-payload) values are checked against
    a scratch Feature sharing the real one's id before anything on the
    real, stored Feature is touched. `rotation_axis`/`make_copy` follow this
    file's own established "payload value if not None, else current" rule
    (see `update_pattern_feature`'s own `axis` field for the identical
    can-legitimately-be-None-but-omitted-still-means-keep-current
    convention already accepted in this codebase)."""
    part = get_part_or_404(part_id)
    feature = _get_move_body_feature_or_404(part, feature_id)

    new_body_id = payload.body_id if payload.body_id is not None else feature.body_id
    new_delta = payload.delta if payload.delta is not None else feature.delta
    new_rotation_axis = (
        _pattern_axis_ref_to_domain(payload.rotation_axis)
        if payload.rotation_axis is not None
        else feature.rotation_axis
    )
    new_rotation_angle_degrees = (
        payload.rotation_angle_degrees
        if payload.rotation_angle_degrees is not None
        else feature.rotation_angle_degrees
    )
    new_make_copy = payload.make_copy if payload.make_copy is not None else feature.make_copy
    _validate_move_body_payload(part, new_body_id, new_rotation_axis)

    candidate = MoveBodyFeature(
        id=feature.id,
        body_id=new_body_id,
        delta=new_delta,
        rotation_axis=new_rotation_axis,
        rotation_angle_degrees=new_rotation_angle_degrees,
        make_copy=new_make_copy,
    )
    resolve_move_body(part, candidate)  # raises on an unresolvable/degenerate move

    feature.body_id = candidate.body_id
    feature.delta = candidate.delta
    feature.rotation_axis = candidate.rotation_axis
    feature.rotation_angle_degrees = candidate.rotation_angle_degrees
    feature.make_copy = candidate.make_copy
    return _feature_response(part, feature)


@router.post(
    "/parts/{part_id}/delete-face-features", response_model=DeleteFaceFeatureResponse, status_code=201
)
def create_delete_face_feature(
    part_id: str, payload: DeleteFaceFeatureCreate
) -> DeleteFaceFeatureResponse:
    """Direct Editing family (fourth entry): mirrors `create_fillet_
    feature`'s shape (fails closed on payload-shape validation, then
    resolvability, before ever persisting an unresolvable removal) - a
    Delete Face has real per-instance geometry of its own that can fail
    (an ill-defined removal - see `app.document.delete_face`'s own
    fail-closed contract)."""
    part = get_part_or_404(part_id)
    face_refs = [_subshape_ref_to_domain(r) for r in payload.face_refs]
    _validate_face_refs(face_refs)
    feature = DeleteFaceFeature(id=str(uuid.uuid4()), face_refs=face_refs)
    resolve_delete_face(part, feature)  # raises on an unresolvable/ill-defined removal
    part.add_feature(feature)
    return _feature_response(part, feature)


def _get_delete_face_feature_or_404(part: Part, feature_id: str) -> DeleteFaceFeature:
    feature = part.get_feature(feature_id)
    if not isinstance(feature, DeleteFaceFeature):
        raise HTTPException(status_code=404, detail="Delete face feature not found")
    return feature


@router.patch(
    "/parts/{part_id}/delete-face-features/{feature_id}", response_model=DeleteFaceFeatureResponse
)
def update_delete_face_feature(
    part_id: str, feature_id: str, payload: DeleteFaceFeatureUpdate
) -> DeleteFaceFeatureResponse:
    """Same validate-before-mutate discipline as `update_fillet_feature`:
    the merged (existing-plus-payload) value is checked against a scratch
    Feature sharing the real one's id (`resolve_delete_face` excludes that
    id from its own "current bodies" computation for exactly this reason)
    before anything on the real, stored Feature is touched."""
    part = get_part_or_404(part_id)
    feature = _get_delete_face_feature_or_404(part, feature_id)

    new_face_refs = (
        [_subshape_ref_to_domain(r) for r in payload.face_refs]
        if payload.face_refs is not None
        else feature.face_refs
    )
    _validate_face_refs(new_face_refs)

    candidate = DeleteFaceFeature(id=feature.id, face_refs=new_face_refs)
    resolve_delete_face(part, candidate)  # raises on an unresolvable/ill-defined removal

    feature.face_refs = candidate.face_refs
    return _feature_response(part, feature)


@router.post(
    "/parts/{part_id}/move-face-features", response_model=MoveFaceFeatureResponse, status_code=201
)
def create_move_face_feature(part_id: str, payload: MoveFaceFeatureCreate) -> MoveFaceFeatureResponse:
    """Direct Editing family (fifth/last entry): mirrors `create_fillet_
    feature`'s shape (fails closed on payload-shape validation, then
    resolvability, before ever persisting an unresolvable move) - the
    highest technical-risk member of this family, see `app.document.
    move_face`'s own module docstring for the OCCT technique."""
    part = get_part_or_404(part_id)
    face_refs = [_subshape_ref_to_domain(r) for r in payload.face_refs]
    direction_ref = (
        _pattern_direction_ref_to_domain(payload.direction_ref)
        if payload.direction_ref is not None
        else None
    )
    _validate_move_face_payload(
        face_refs, payload.offset_distance, payload.delta, direction_ref, payload.direction_distance
    )
    feature = MoveFaceFeature(
        id=str(uuid.uuid4()),
        face_refs=face_refs,
        offset_distance=payload.offset_distance,
        delta=payload.delta,
        direction_ref=direction_ref,
        direction_distance=payload.direction_distance,
    )
    resolve_move_face(part, feature)  # raises on an unresolvable/degenerate move; result unused here
    part.add_feature(feature)
    return _feature_response(part, feature)


def _get_move_face_feature_or_404(part: Part, feature_id: str) -> MoveFaceFeature:
    feature = part.get_feature(feature_id)
    if not isinstance(feature, MoveFaceFeature):
        raise HTTPException(status_code=404, detail="Move face feature not found")
    return feature


@router.patch(
    "/parts/{part_id}/move-face-features/{feature_id}", response_model=MoveFaceFeatureResponse
)
def update_move_face_feature(
    part_id: str, feature_id: str, payload: MoveFaceFeatureUpdate
) -> MoveFaceFeatureResponse:
    """Same validate-before-mutate discipline as `update_fillet_feature`.
    Unlike every other Direct Editing Update endpoint, the three mode
    fields (`offset_distance`/`delta`/`direction_ref`+`direction_distance`)
    are not merged independently - supplying any field belonging to a mode
    switches to that mode wholesale, clearing the other two modes' own
    fields, matching `MoveFaceFeatureUpdate`'s own docstring (mirrors
    `SplitFeatureUpdate.tool` always being replaced as a whole). Supplying
    no mode field at all (e.g. a `face_refs`-only PATCH) keeps the
    Feature's current mode entirely."""
    part = get_part_or_404(part_id)
    feature = _get_move_face_feature_or_404(part, feature_id)

    new_face_refs = (
        [_subshape_ref_to_domain(r) for r in payload.face_refs]
        if payload.face_refs is not None
        else feature.face_refs
    )

    if payload.offset_distance is not None:
        new_offset_distance: float | None = payload.offset_distance
        new_delta: tuple[float, float, float] | None = None
        new_direction_ref = None
        new_direction_distance: float | None = None
    elif payload.delta is not None:
        new_offset_distance = None
        new_delta = payload.delta
        new_direction_ref = None
        new_direction_distance = None
    elif payload.direction_ref is not None or payload.direction_distance is not None:
        new_offset_distance = None
        new_delta = None
        new_direction_ref = (
            _pattern_direction_ref_to_domain(payload.direction_ref)
            if payload.direction_ref is not None
            else feature.direction_ref
        )
        new_direction_distance = (
            payload.direction_distance
            if payload.direction_distance is not None
            else feature.direction_distance
        )
    else:
        new_offset_distance = feature.offset_distance
        new_delta = feature.delta
        new_direction_ref = feature.direction_ref
        new_direction_distance = feature.direction_distance

    _validate_move_face_payload(
        new_face_refs, new_offset_distance, new_delta, new_direction_ref, new_direction_distance
    )

    candidate = MoveFaceFeature(
        id=feature.id,
        face_refs=new_face_refs,
        offset_distance=new_offset_distance,
        delta=new_delta,
        direction_ref=new_direction_ref,
        direction_distance=new_direction_distance,
    )
    resolve_move_face(part, candidate)  # raises on an unresolvable/degenerate move

    feature.face_refs = candidate.face_refs
    feature.offset_distance = candidate.offset_distance
    feature.delta = candidate.delta
    feature.direction_ref = candidate.direction_ref
    feature.direction_distance = candidate.direction_distance
    return _feature_response(part, feature)


@router.post("/parts/{part_id}/split-features", response_model=SplitFeatureResponse, status_code=201)
def create_split_feature(part_id: str, payload: SplitFeatureCreate) -> SplitFeatureResponse:
    """Boolean family, fourth/last entry: mirrors `create_mirror_feature`'s
    shape - unlocked from the start, fails closed (via `_validate_split_
    target_body_id`/`_validate_split_tool_ref` for payload shape, then
    `resolve_split` for referential/geometric validity - including the
    tool's own resolvability) before ever persisting an unresolvable
    Split."""
    part = get_part_or_404(part_id)
    tool = _split_tool_ref_to_domain(payload.tool)
    _validate_split_target_body_id(part, payload.target_body_id)
    _validate_split_tool_ref(part, tool)
    feature = SplitFeature(id=str(uuid.uuid4()), target_body_id=payload.target_body_id, tool=tool)
    resolve_split(part, feature)  # raises on an unresolvable reference; result unused here
    part.add_feature(feature)
    return _feature_response(part, feature)


def _get_split_feature_or_404(part: Part, feature_id: str) -> SplitFeature:
    feature = part.get_feature(feature_id)
    if not isinstance(feature, SplitFeature):
        raise HTTPException(status_code=404, detail="Split feature not found")
    return feature


@router.patch("/parts/{part_id}/split-features/{feature_id}", response_model=SplitFeatureResponse)
def update_split_feature(
    part_id: str, feature_id: str, payload: SplitFeatureUpdate
) -> SplitFeatureResponse:
    """Mirrors `update_mirror_feature`'s exact shape - same validate-
    before-mutate discipline against a scratch Feature sharing the real
    one's id."""
    part = get_part_or_404(part_id)
    feature = _get_split_feature_or_404(part, feature_id)

    new_target_body_id = (
        payload.target_body_id if payload.target_body_id is not None else feature.target_body_id
    )
    new_tool = _split_tool_ref_to_domain(payload.tool) if payload.tool is not None else feature.tool
    _validate_split_target_body_id(part, new_target_body_id)
    _validate_split_tool_ref(part, new_tool)

    candidate = SplitFeature(id=feature.id, target_body_id=new_target_body_id, tool=new_tool)
    resolve_split(part, candidate)  # raises on an unresolvable reference

    feature.target_body_id = candidate.target_body_id
    feature.tool = candidate.tool
    return _feature_response(part, feature)


@router.post("/parts/{part_id}/gear-features", response_model=GearFeatureResponse, status_code=201)
def create_gear_feature(part_id: str, payload: GearFeatureCreate) -> GearFeatureResponse:
    """`docs/gear-design/02-gear-feature.md`: mirrors `create_mirror_
    feature`'s exact shape - unlocked from the start, fails closed (via
    `_validate_gear_feature_payload`/`_validate_plane_ref`/
    `_validate_target_body_ids` for payload shape, then `resolve_gear` for
    referential/geometric validity - including every `gear_math`-raised
    `invalid_gear_parameters` failure) before ever persisting an
    unresolvable Gear."""
    part = get_part_or_404(part_id)
    _validate_gear_feature_payload(payload.is_internal, payload.outer_diameter)
    plane_ref = _plane_ref_to_domain(payload.plane_ref) if payload.plane_ref is not None else _default_plane_ref()
    _validate_plane_ref(part, plane_ref)
    _validate_target_body_ids(part, payload.gear_type == GearType.CUT, payload.target_body_ids)
    feature = GearFeature(
        id=str(uuid.uuid4()),
        plane_ref=plane_ref,
        gear_type=payload.gear_type,
        is_internal=payload.is_internal,
        module=payload.module,
        tooth_count=payload.tooth_count,
        face_width=payload.face_width,
        pressure_angle_degrees=payload.pressure_angle_degrees,
        profile_shift=payload.profile_shift,
        backlash=payload.backlash,
        root_fillet_radius=payload.root_fillet_radius,
        outer_diameter=payload.outer_diameter,
        target_body_ids=list(payload.target_body_ids),
        helix_angle_degrees=payload.helix_angle_degrees,
        herringbone=payload.herringbone,
        points_per_flank=payload.points_per_flank,
    )
    _, warnings = resolve_gear(part, feature)  # raises on an unresolvable/invalid gear
    part.add_feature(feature)
    return _gear_feature_response(part, feature, warnings)


@router.post("/parts/{part_id}/gear-features/coarse-preview", response_model=list[BodyMeshResponse])
def preview_gear_feature_coarse(
    part_id: str, payload: GearFeatureCreate, quality: float | None = Query(default=None, ge=0.0, le=1.0)
) -> list[BodyMeshResponse]:
    """`docs/lod-strategy/01-design.md` SS4: the 3D analogue of `/gear/
    preview` for a not-yet-created `GearFeature` - a real coarse solid
    (`app.document.gear.resolve_gear_coarse`) instead of a 2D outline.
    Mirrors `create_gear_feature`'s own validate-then-build shape exactly
    (same scratch Feature, same payload validation), but never calls
    `part.add_feature` - nothing is persisted, no Feature is created, no
    Part state changes; `part_id` is used only to resolve `plane_ref`
    against this Part's own already-real geometry."""
    part = get_part_or_404(part_id)
    mesh_quality = DEFAULT_MESH_QUALITY if quality is None else mesh_quality_from_slider(quality)
    _validate_gear_feature_payload(payload.is_internal, payload.outer_diameter)
    plane_ref = _plane_ref_to_domain(payload.plane_ref) if payload.plane_ref is not None else _default_plane_ref()
    _validate_plane_ref(part, plane_ref)
    _validate_target_body_ids(part, payload.gear_type == GearType.CUT, payload.target_body_ids)
    feature = GearFeature(
        id=str(uuid.uuid4()),
        plane_ref=plane_ref,
        gear_type=payload.gear_type,
        is_internal=payload.is_internal,
        module=payload.module,
        tooth_count=payload.tooth_count,
        face_width=payload.face_width,
        pressure_angle_degrees=payload.pressure_angle_degrees,
        profile_shift=payload.profile_shift,
        backlash=payload.backlash,
        root_fillet_radius=payload.root_fillet_radius,
        outer_diameter=payload.outer_diameter,
        target_body_ids=list(payload.target_body_ids),
        helix_angle_degrees=payload.helix_angle_degrees,
        herringbone=payload.herringbone,
        points_per_flank=payload.points_per_flank,
    )
    shape = resolve_gear_coarse(part, feature)  # raises on an unresolvable/invalid gear
    return _coarse_preview_response(shape, mesh_quality)


def _get_gear_feature_or_404(part: Part, feature_id: str) -> GearFeature:
    feature = part.get_feature(feature_id)
    if not isinstance(feature, GearFeature):
        raise HTTPException(status_code=404, detail="Gear feature not found")
    return feature


@router.patch("/parts/{part_id}/gear-features/{feature_id}", response_model=GearFeatureResponse)
def update_gear_feature(part_id: str, feature_id: str, payload: GearFeatureUpdate) -> GearFeatureResponse:
    """Mirrors `update_mirror_feature`'s exact shape - same validate-
    before-mutate discipline against a scratch Feature sharing the real
    one's id. `plane_ref` follows the same omitted-vs-current convention
    every other Update schema here uses - omitted keeps the Feature's
    existing plane, an explicit value replaces it; there is no way to
    revert to the XY default via this endpoint once a real value has been
    set, matching `MirrorFeatureUpdate.mirror_plane`'s own behaviour."""
    part = get_part_or_404(part_id)
    feature = _get_gear_feature_or_404(part, feature_id)

    new_plane_ref = _plane_ref_to_domain(payload.plane_ref) if payload.plane_ref is not None else feature.plane_ref
    new_gear_type = payload.gear_type if payload.gear_type is not None else feature.gear_type
    new_is_internal = payload.is_internal if payload.is_internal is not None else feature.is_internal
    new_module = payload.module if payload.module is not None else feature.module
    new_tooth_count = payload.tooth_count if payload.tooth_count is not None else feature.tooth_count
    new_face_width = payload.face_width if payload.face_width is not None else feature.face_width
    new_pressure_angle_degrees = (
        payload.pressure_angle_degrees
        if payload.pressure_angle_degrees is not None
        else feature.pressure_angle_degrees
    )
    new_profile_shift = payload.profile_shift if payload.profile_shift is not None else feature.profile_shift
    new_backlash = payload.backlash if payload.backlash is not None else feature.backlash
    new_root_fillet_radius = (
        payload.root_fillet_radius if payload.root_fillet_radius is not None else feature.root_fillet_radius
    )
    new_outer_diameter = (
        payload.outer_diameter if payload.outer_diameter is not None else feature.outer_diameter
    )
    new_target_body_ids = (
        list(payload.target_body_ids) if payload.target_body_ids is not None else feature.target_body_ids
    )
    new_helix_angle_degrees = (
        payload.helix_angle_degrees if payload.helix_angle_degrees is not None else feature.helix_angle_degrees
    )
    new_herringbone = payload.herringbone if payload.herringbone is not None else feature.herringbone
    new_points_per_flank = (
        payload.points_per_flank if payload.points_per_flank is not None else feature.points_per_flank
    )

    _validate_gear_feature_payload(new_is_internal, new_outer_diameter)
    _validate_plane_ref(part, new_plane_ref)
    _validate_target_body_ids(part, new_gear_type == GearType.CUT, new_target_body_ids)

    candidate = GearFeature(
        id=feature.id,
        plane_ref=new_plane_ref,
        gear_type=new_gear_type,
        is_internal=new_is_internal,
        module=new_module,
        tooth_count=new_tooth_count,
        face_width=new_face_width,
        pressure_angle_degrees=new_pressure_angle_degrees,
        profile_shift=new_profile_shift,
        backlash=new_backlash,
        root_fillet_radius=new_root_fillet_radius,
        outer_diameter=new_outer_diameter,
        target_body_ids=new_target_body_ids,
        helix_angle_degrees=new_helix_angle_degrees,
        herringbone=new_herringbone,
        points_per_flank=new_points_per_flank,
    )
    _, warnings = resolve_gear(part, candidate)  # raises on an unresolvable/invalid gear

    feature.plane_ref = candidate.plane_ref
    feature.gear_type = candidate.gear_type
    feature.is_internal = candidate.is_internal
    feature.module = candidate.module
    feature.tooth_count = candidate.tooth_count
    feature.face_width = candidate.face_width
    feature.pressure_angle_degrees = candidate.pressure_angle_degrees
    feature.profile_shift = candidate.profile_shift
    feature.backlash = candidate.backlash
    feature.root_fillet_radius = candidate.root_fillet_radius
    feature.outer_diameter = candidate.outer_diameter
    feature.target_body_ids = candidate.target_body_ids
    feature.helix_angle_degrees = candidate.helix_angle_degrees
    feature.herringbone = candidate.herringbone
    feature.points_per_flank = candidate.points_per_flank
    return _gear_feature_response(part, feature, warnings)


@router.post("/parts/{part_id}/rack-features", response_model=RackFeatureResponse, status_code=201)
def create_rack_feature(part_id: str, payload: RackFeatureCreate) -> RackFeatureResponse:
    """`docs/gear-design/03-rack.md`: mirrors `create_gear_feature`'s exact
    shape - unlike a Gear there is no internal/external discriminator to
    check, so this skips straight to `_validate_plane_ref`/
    `_validate_target_body_ids` for payload shape, then `resolve_rack` for
    referential/geometric validity (including every `gear_math`-raised
    `invalid_rack_parameters` failure) before ever persisting an
    unresolvable Rack."""
    part = get_part_or_404(part_id)
    plane_ref = _plane_ref_to_domain(payload.plane_ref) if payload.plane_ref is not None else _default_plane_ref()
    _validate_plane_ref(part, plane_ref)
    _validate_target_body_ids(part, payload.rack_type == RackType.CUT, payload.target_body_ids)
    feature = RackFeature(
        id=str(uuid.uuid4()),
        plane_ref=plane_ref,
        rack_type=payload.rack_type,
        module=payload.module,
        tooth_count=payload.tooth_count,
        face_width=payload.face_width,
        pressure_angle_degrees=payload.pressure_angle_degrees,
        backlash=payload.backlash,
        backing_height=payload.backing_height,
        target_body_ids=list(payload.target_body_ids),
    )
    resolve_rack(part, feature)  # raises on an unresolvable/invalid rack; result unused here
    part.add_feature(feature)
    return _feature_response(part, feature)


def _get_rack_feature_or_404(part: Part, feature_id: str) -> RackFeature:
    feature = part.get_feature(feature_id)
    if not isinstance(feature, RackFeature):
        raise HTTPException(status_code=404, detail="Rack feature not found")
    return feature


@router.patch("/parts/{part_id}/rack-features/{feature_id}", response_model=RackFeatureResponse)
def update_rack_feature(part_id: str, feature_id: str, payload: RackFeatureUpdate) -> RackFeatureResponse:
    """Mirrors `update_gear_feature`'s exact shape - same validate-before-
    mutate discipline against a scratch Feature sharing the real one's id.
    `plane_ref` follows the same omitted-vs-current convention every other
    Update schema here uses."""
    part = get_part_or_404(part_id)
    feature = _get_rack_feature_or_404(part, feature_id)

    new_plane_ref = _plane_ref_to_domain(payload.plane_ref) if payload.plane_ref is not None else feature.plane_ref
    new_rack_type = payload.rack_type if payload.rack_type is not None else feature.rack_type
    new_module = payload.module if payload.module is not None else feature.module
    new_tooth_count = payload.tooth_count if payload.tooth_count is not None else feature.tooth_count
    new_face_width = payload.face_width if payload.face_width is not None else feature.face_width
    new_pressure_angle_degrees = (
        payload.pressure_angle_degrees
        if payload.pressure_angle_degrees is not None
        else feature.pressure_angle_degrees
    )
    new_backlash = payload.backlash if payload.backlash is not None else feature.backlash
    new_backing_height = (
        payload.backing_height if payload.backing_height is not None else feature.backing_height
    )
    new_target_body_ids = (
        list(payload.target_body_ids) if payload.target_body_ids is not None else feature.target_body_ids
    )

    _validate_plane_ref(part, new_plane_ref)
    _validate_target_body_ids(part, new_rack_type == RackType.CUT, new_target_body_ids)

    candidate = RackFeature(
        id=feature.id,
        plane_ref=new_plane_ref,
        rack_type=new_rack_type,
        module=new_module,
        tooth_count=new_tooth_count,
        face_width=new_face_width,
        pressure_angle_degrees=new_pressure_angle_degrees,
        backlash=new_backlash,
        backing_height=new_backing_height,
        target_body_ids=new_target_body_ids,
    )
    resolve_rack(part, candidate)  # raises on an unresolvable/invalid rack

    feature.plane_ref = candidate.plane_ref
    feature.rack_type = candidate.rack_type
    feature.module = candidate.module
    feature.tooth_count = candidate.tooth_count
    feature.face_width = candidate.face_width
    feature.pressure_angle_degrees = candidate.pressure_angle_degrees
    feature.backlash = candidate.backlash
    feature.backing_height = candidate.backing_height
    feature.target_body_ids = candidate.target_body_ids
    return _feature_response(part, feature)


@router.post("/parts/{part_id}/bevel-gear-features", response_model=BevelGearFeatureResponse, status_code=201)
def create_bevel_gear_feature(part_id: str, payload: BevelGearFeatureCreate) -> BevelGearFeatureResponse:
    """`docs/gear-design/10-bevel-gear.md`: mirrors `create_rack_feature`'s
    exact shape - no internal/external discriminator to check (unlike
    Gear), so this skips straight to `_validate_plane_ref`/
    `_validate_target_body_ids` for payload shape, then `resolve_bevel_
    gear` for referential/geometric validity (including every `bevel_
    math`-raised `invalid_bevel_parameters` failure, and every OCCT-
    construction `bevel_failed` failure) before ever persisting an
    unresolvable bevel gear."""
    part = get_part_or_404(part_id)
    plane_ref = _plane_ref_to_domain(payload.plane_ref) if payload.plane_ref is not None else _default_plane_ref()
    _validate_plane_ref(part, plane_ref)
    _validate_target_body_ids(part, payload.bevel_type == BevelGearType.CUT, payload.target_body_ids)
    feature = BevelGearFeature(
        id=str(uuid.uuid4()),
        plane_ref=plane_ref,
        bevel_type=payload.bevel_type,
        module=payload.module,
        tooth_count=payload.tooth_count,
        face_width=payload.face_width,
        pitch_cone_angle_degrees=payload.pitch_cone_angle_degrees,
        pressure_angle_degrees=payload.pressure_angle_degrees,
        backlash=payload.backlash,
        profile_shift=payload.profile_shift,
        target_body_ids=list(payload.target_body_ids),
        points_per_flank=payload.points_per_flank,
        spiral_angle_degrees=payload.spiral_angle_degrees,
        spiral_hand=payload.spiral_hand,
    )
    _, warnings = resolve_bevel_gear(part, feature)  # raises on an unresolvable/invalid bevel gear
    part.add_feature(feature)
    return _bevel_gear_feature_response(part, feature, warnings)


@router.post("/parts/{part_id}/bevel-gear-features/coarse-preview", response_model=list[BodyMeshResponse])
def preview_bevel_gear_feature_coarse(
    part_id: str, payload: BevelGearFeatureCreate, quality: float | None = Query(default=None, ge=0.0, le=1.0)
) -> list[BodyMeshResponse]:
    """`docs/lod-strategy/01-design.md` SS4: mirrors `preview_gear_feature_
    coarse`'s own shape exactly, for a not-yet-created `BevelGearFeature` -
    same `create_bevel_gear_feature` validate-then-build path, but built
    via `app.document.bevel.resolve_bevel_gear_coarse` and never
    persisted."""
    part = get_part_or_404(part_id)
    mesh_quality = DEFAULT_MESH_QUALITY if quality is None else mesh_quality_from_slider(quality)
    plane_ref = _plane_ref_to_domain(payload.plane_ref) if payload.plane_ref is not None else _default_plane_ref()
    _validate_plane_ref(part, plane_ref)
    _validate_target_body_ids(part, payload.bevel_type == BevelGearType.CUT, payload.target_body_ids)
    feature = BevelGearFeature(
        id=str(uuid.uuid4()),
        plane_ref=plane_ref,
        bevel_type=payload.bevel_type,
        module=payload.module,
        tooth_count=payload.tooth_count,
        face_width=payload.face_width,
        pitch_cone_angle_degrees=payload.pitch_cone_angle_degrees,
        pressure_angle_degrees=payload.pressure_angle_degrees,
        backlash=payload.backlash,
        profile_shift=payload.profile_shift,
        target_body_ids=list(payload.target_body_ids),
        points_per_flank=payload.points_per_flank,
        spiral_angle_degrees=payload.spiral_angle_degrees,
        spiral_hand=payload.spiral_hand,
    )
    shape = resolve_bevel_gear_coarse(part, feature)  # raises on an unresolvable/invalid bevel gear
    return _coarse_preview_response(shape, mesh_quality)


def _get_bevel_gear_feature_or_404(part: Part, feature_id: str) -> BevelGearFeature:
    feature = part.get_feature(feature_id)
    if not isinstance(feature, BevelGearFeature):
        raise HTTPException(status_code=404, detail="Bevel gear feature not found")
    return feature


@router.patch("/parts/{part_id}/bevel-gear-features/{feature_id}", response_model=BevelGearFeatureResponse)
def update_bevel_gear_feature(part_id: str, feature_id: str, payload: BevelGearFeatureUpdate) -> BevelGearFeatureResponse:
    """Mirrors `update_rack_feature`'s exact shape - same validate-before-
    mutate discipline against a scratch Feature sharing the real one's id."""
    part = get_part_or_404(part_id)
    feature = _get_bevel_gear_feature_or_404(part, feature_id)

    new_plane_ref = _plane_ref_to_domain(payload.plane_ref) if payload.plane_ref is not None else feature.plane_ref
    new_bevel_type = payload.bevel_type if payload.bevel_type is not None else feature.bevel_type
    new_module = payload.module if payload.module is not None else feature.module
    new_tooth_count = payload.tooth_count if payload.tooth_count is not None else feature.tooth_count
    new_face_width = payload.face_width if payload.face_width is not None else feature.face_width
    new_pitch_cone_angle_degrees = (
        payload.pitch_cone_angle_degrees
        if payload.pitch_cone_angle_degrees is not None
        else feature.pitch_cone_angle_degrees
    )
    new_pressure_angle_degrees = (
        payload.pressure_angle_degrees
        if payload.pressure_angle_degrees is not None
        else feature.pressure_angle_degrees
    )
    new_backlash = payload.backlash if payload.backlash is not None else feature.backlash
    new_profile_shift = payload.profile_shift if payload.profile_shift is not None else feature.profile_shift
    new_target_body_ids = (
        list(payload.target_body_ids) if payload.target_body_ids is not None else feature.target_body_ids
    )
    new_points_per_flank = (
        payload.points_per_flank if payload.points_per_flank is not None else feature.points_per_flank
    )
    new_spiral_angle_degrees = (
        payload.spiral_angle_degrees if payload.spiral_angle_degrees is not None else feature.spiral_angle_degrees
    )
    new_spiral_hand = payload.spiral_hand if payload.spiral_hand is not None else feature.spiral_hand

    _validate_plane_ref(part, new_plane_ref)
    _validate_target_body_ids(part, new_bevel_type == BevelGearType.CUT, new_target_body_ids)

    candidate = BevelGearFeature(
        id=feature.id,
        plane_ref=new_plane_ref,
        bevel_type=new_bevel_type,
        module=new_module,
        tooth_count=new_tooth_count,
        face_width=new_face_width,
        pitch_cone_angle_degrees=new_pitch_cone_angle_degrees,
        pressure_angle_degrees=new_pressure_angle_degrees,
        backlash=new_backlash,
        profile_shift=new_profile_shift,
        target_body_ids=new_target_body_ids,
        points_per_flank=new_points_per_flank,
        spiral_angle_degrees=new_spiral_angle_degrees,
        spiral_hand=new_spiral_hand,
    )
    _, warnings = resolve_bevel_gear(part, candidate)  # raises on an unresolvable/invalid bevel gear

    feature.plane_ref = candidate.plane_ref
    feature.bevel_type = candidate.bevel_type
    feature.module = candidate.module
    feature.tooth_count = candidate.tooth_count
    feature.face_width = candidate.face_width
    feature.pitch_cone_angle_degrees = candidate.pitch_cone_angle_degrees
    feature.pressure_angle_degrees = candidate.pressure_angle_degrees
    feature.backlash = candidate.backlash
    feature.profile_shift = candidate.profile_shift
    feature.target_body_ids = candidate.target_body_ids
    feature.points_per_flank = candidate.points_per_flank
    feature.spiral_angle_degrees = candidate.spiral_angle_degrees
    feature.spiral_hand = candidate.spiral_hand
    return _bevel_gear_feature_response(part, feature, warnings)


@router.post("/parts/{part_id}/gear-chain-features", response_model=GearChainFeatureResponse, status_code=201)
def create_gear_chain_feature(part_id: str, payload: GearChainFeatureCreate) -> GearChainFeatureResponse:
    """`docs/gear-design/05-gear-chain-and-planetary.md`: mirrors
    `create_loft_feature`'s exact shape - validates payload shape
    (`_validate_gear_chain_stages`/`_validate_plane_ref`), then
    resolvability (`app.document.gear_chain.resolve_gear_chain` - bent-path
    positioning, group-adjacency/module matching, per-stage OCCT
    construction, and the compound-join connected-solid-count BLOCKING
    check) before ever persisting an unresolvable chain. Non-blocking
    interference/compound-join `warnings` are threaded straight into the
    response, same as Loft's own self-intersection warnings."""
    part = get_part_or_404(part_id)
    groups = [_gear_group_to_domain(g) for g in payload.groups]
    stages = [_gear_chain_stage_to_domain(s) for s in payload.stages]
    _validate_gear_chain_stages(groups, stages)
    plane_ref = _plane_ref_to_domain(payload.plane_ref) if payload.plane_ref is not None else _default_plane_ref()
    _validate_plane_ref(part, plane_ref)
    feature = GearChainFeature(
        id=str(uuid.uuid4()),
        plane_ref=plane_ref,
        groups=groups,
        stages=stages,
        start_direction_degrees=payload.start_direction_degrees,
        print_clearance_margin=payload.print_clearance_margin,
    )
    _, warnings = resolve_gear_chain(part, feature)  # raises on an unresolvable/invalid chain
    part.add_feature(feature)
    return _gear_chain_feature_response(part, feature, warnings)


@router.post("/parts/{part_id}/gear-chain-features/coarse-preview", response_model=list[BodyMeshResponse])
def preview_gear_chain_feature_coarse(
    part_id: str, payload: GearChainFeatureCreate, quality: float | None = Query(default=None, ge=0.0, le=1.0)
) -> list[BodyMeshResponse]:
    """`docs/lod-strategy/01-design.md` SS4: mirrors `preview_gear_feature_
    coarse`'s own shape exactly, for a not-yet-created `GearChainFeature` -
    same `create_gear_chain_feature` validate-then-build path, but built
    via `app.document.gear_chain.resolve_gear_chain_coarse` and never
    persisted. Every stage's own member(s) come back as their own entry
    (`_coarse_preview_response`), same as the real chain's own multi-Body
    compound."""
    part = get_part_or_404(part_id)
    mesh_quality = DEFAULT_MESH_QUALITY if quality is None else mesh_quality_from_slider(quality)
    groups = [_gear_group_to_domain(g) for g in payload.groups]
    stages = [_gear_chain_stage_to_domain(s) for s in payload.stages]
    _validate_gear_chain_stages(groups, stages)
    plane_ref = _plane_ref_to_domain(payload.plane_ref) if payload.plane_ref is not None else _default_plane_ref()
    _validate_plane_ref(part, plane_ref)
    feature = GearChainFeature(
        id=str(uuid.uuid4()),
        plane_ref=plane_ref,
        groups=groups,
        stages=stages,
        start_direction_degrees=payload.start_direction_degrees,
        print_clearance_margin=payload.print_clearance_margin,
    )
    shape = resolve_gear_chain_coarse(part, feature)  # raises on an unresolvable/invalid chain
    return _coarse_preview_response(shape, mesh_quality)


def _get_gear_chain_feature_or_404(part: Part, feature_id: str) -> GearChainFeature:
    feature = part.get_feature(feature_id)
    if not isinstance(feature, GearChainFeature):
        raise HTTPException(status_code=404, detail="Gear chain feature not found")
    return feature


@router.patch("/parts/{part_id}/gear-chain-features/{feature_id}", response_model=GearChainFeatureResponse)
def update_gear_chain_feature(
    part_id: str, feature_id: str, payload: GearChainFeatureUpdate
) -> GearChainFeatureResponse:
    """Mirrors `update_loft_feature`'s exact shape - same validate-before-
    mutate discipline against a scratch Feature sharing the real one's id."""
    part = get_part_or_404(part_id)
    feature = _get_gear_chain_feature_or_404(part, feature_id)

    new_plane_ref = _plane_ref_to_domain(payload.plane_ref) if payload.plane_ref is not None else feature.plane_ref
    new_groups = (
        [_gear_group_to_domain(g) for g in payload.groups] if payload.groups is not None else feature.groups
    )
    new_stages = (
        [_gear_chain_stage_to_domain(s) for s in payload.stages] if payload.stages is not None else feature.stages
    )
    new_start_direction_degrees = (
        payload.start_direction_degrees
        if payload.start_direction_degrees is not None
        else feature.start_direction_degrees
    )
    new_print_clearance_margin = (
        payload.print_clearance_margin
        if payload.print_clearance_margin is not None
        else feature.print_clearance_margin
    )

    _validate_gear_chain_stages(new_groups, new_stages)
    _validate_plane_ref(part, new_plane_ref)

    candidate = GearChainFeature(
        id=feature.id,
        plane_ref=new_plane_ref,
        groups=new_groups,
        stages=new_stages,
        start_direction_degrees=new_start_direction_degrees,
        print_clearance_margin=new_print_clearance_margin,
    )
    _, warnings = resolve_gear_chain(part, candidate)  # raises on an unresolvable/invalid chain

    feature.plane_ref = candidate.plane_ref
    feature.groups = candidate.groups
    feature.stages = candidate.stages
    feature.start_direction_degrees = candidate.start_direction_degrees
    feature.print_clearance_margin = candidate.print_clearance_margin
    return _gear_chain_feature_response(part, feature, warnings)


@router.post(
    "/parts/{part_id}/planetary-gear-features", response_model=PlanetaryGearFeatureResponse, status_code=201
)
def create_planetary_gear_feature(part_id: str, payload: PlanetaryGearFeatureCreate) -> PlanetaryGearFeatureResponse:
    """`docs/gear-design/05-gear-chain-and-planetary.md`: mirrors
    `create_gear_feature`'s exact shape - unlike a chain there is no
    payload-shape validation to do beyond `_validate_plane_ref` (sun/ring/
    planet tooth counts have no discriminated-union shape to check); every
    real check (derived planet tooth count, the assembly condition, planet-
    planet interference) is `app.document.planetary_gear.resolve_planetary`'s
    job, and a failure there BLOCKS creation outright (`00-conventions.md`'s
    validation-banner exception - there is no valid planet gear to draw at
    all for an invalid combination, not a quality tradeoff)."""
    part = get_part_or_404(part_id)
    plane_ref = _plane_ref_to_domain(payload.plane_ref) if payload.plane_ref is not None else _default_plane_ref()
    _validate_plane_ref(part, plane_ref)
    feature = PlanetaryGearFeature(
        id=str(uuid.uuid4()),
        plane_ref=plane_ref,
        module=payload.module,
        sun_tooth_count=payload.sun_tooth_count,
        ring_tooth_count=payload.ring_tooth_count,
        planet_count=payload.planet_count,
        face_width=payload.face_width,
        ring_outer_diameter=payload.ring_outer_diameter,
        pressure_angle_degrees=payload.pressure_angle_degrees,
    )
    resolve_planetary(part, feature)  # raises (blocking) on an invalid/unresolvable planetary set
    part.add_feature(feature)
    return _feature_response(part, feature)


@router.post("/parts/{part_id}/planetary-gear-features/coarse-preview", response_model=list[BodyMeshResponse])
def preview_planetary_gear_feature_coarse(
    part_id: str, payload: PlanetaryGearFeatureCreate, quality: float | None = Query(default=None, ge=0.0, le=1.0)
) -> list[BodyMeshResponse]:
    """`docs/lod-strategy/01-design.md` SS4: mirrors `preview_gear_feature_
    coarse`'s own shape exactly, for a not-yet-created `PlanetaryGearFeature`
    - same `create_planetary_gear_feature` validate-then-build path, but
    built via `app.document.planetary_gear.resolve_planetary_coarse` and
    never persisted. Sun/ring/every planet come back as their own entry
    (`_coarse_preview_response`), same as the real assembly's own multi-Body
    compound."""
    part = get_part_or_404(part_id)
    mesh_quality = DEFAULT_MESH_QUALITY if quality is None else mesh_quality_from_slider(quality)
    plane_ref = _plane_ref_to_domain(payload.plane_ref) if payload.plane_ref is not None else _default_plane_ref()
    _validate_plane_ref(part, plane_ref)
    feature = PlanetaryGearFeature(
        id=str(uuid.uuid4()),
        plane_ref=plane_ref,
        module=payload.module,
        sun_tooth_count=payload.sun_tooth_count,
        ring_tooth_count=payload.ring_tooth_count,
        planet_count=payload.planet_count,
        face_width=payload.face_width,
        ring_outer_diameter=payload.ring_outer_diameter,
        pressure_angle_degrees=payload.pressure_angle_degrees,
    )
    shape = resolve_planetary_coarse(part, feature)  # raises (blocking) on an invalid/unresolvable planetary set
    return _coarse_preview_response(shape, mesh_quality)


def _get_planetary_gear_feature_or_404(part: Part, feature_id: str) -> PlanetaryGearFeature:
    feature = part.get_feature(feature_id)
    if not isinstance(feature, PlanetaryGearFeature):
        raise HTTPException(status_code=404, detail="Planetary gear feature not found")
    return feature


@router.patch("/parts/{part_id}/planetary-gear-features/{feature_id}", response_model=PlanetaryGearFeatureResponse)
def update_planetary_gear_feature(
    part_id: str, feature_id: str, payload: PlanetaryGearFeatureUpdate
) -> PlanetaryGearFeatureResponse:
    """Mirrors `update_gear_feature`'s exact shape - same validate-before-
    mutate discipline against a scratch Feature sharing the real one's id."""
    part = get_part_or_404(part_id)
    feature = _get_planetary_gear_feature_or_404(part, feature_id)

    new_plane_ref = _plane_ref_to_domain(payload.plane_ref) if payload.plane_ref is not None else feature.plane_ref
    new_module = payload.module if payload.module is not None else feature.module
    new_sun_tooth_count = payload.sun_tooth_count if payload.sun_tooth_count is not None else feature.sun_tooth_count
    new_ring_tooth_count = (
        payload.ring_tooth_count if payload.ring_tooth_count is not None else feature.ring_tooth_count
    )
    new_planet_count = payload.planet_count if payload.planet_count is not None else feature.planet_count
    new_face_width = payload.face_width if payload.face_width is not None else feature.face_width
    new_ring_outer_diameter = (
        payload.ring_outer_diameter if payload.ring_outer_diameter is not None else feature.ring_outer_diameter
    )
    new_pressure_angle_degrees = (
        payload.pressure_angle_degrees
        if payload.pressure_angle_degrees is not None
        else feature.pressure_angle_degrees
    )

    _validate_plane_ref(part, new_plane_ref)

    candidate = PlanetaryGearFeature(
        id=feature.id,
        plane_ref=new_plane_ref,
        module=new_module,
        sun_tooth_count=new_sun_tooth_count,
        ring_tooth_count=new_ring_tooth_count,
        planet_count=new_planet_count,
        face_width=new_face_width,
        ring_outer_diameter=new_ring_outer_diameter,
        pressure_angle_degrees=new_pressure_angle_degrees,
    )
    resolve_planetary(part, candidate)  # raises (blocking) on an invalid/unresolvable planetary set

    feature.plane_ref = candidate.plane_ref
    feature.module = candidate.module
    feature.sun_tooth_count = candidate.sun_tooth_count
    feature.ring_tooth_count = candidate.ring_tooth_count
    feature.planet_count = candidate.planet_count
    feature.face_width = candidate.face_width
    feature.ring_outer_diameter = candidate.ring_outer_diameter
    feature.pressure_angle_degrees = candidate.pressure_angle_degrees
    return _feature_response(part, feature)


@router.post("/parts/{part_id}/bevel-pair-features", response_model=BevelPairFeatureResponse, status_code=201)
def create_bevel_pair_feature(part_id: str, payload: BevelPairFeatureCreate) -> BevelPairFeatureResponse:
    """`docs/gear-design/11-bevel-pair.md`: mirrors `create_planetary_gear_
    feature`'s exact shape - no payload-shape validation beyond `_validate_
    plane_ref` (member tooth counts have no discriminated-union shape to
    check); every real check (the pitch-cone-split formula's own domain,
    both members' own bevel_math validation, OCCT construction) is `app.
    document.bevel_pair.resolve_bevel_pair`'s job, raising the structured
    `invalid_bevel_pair_parameters`/`bevel_failed` errors before ever
    persisting an unresolvable pair."""
    part = get_part_or_404(part_id)
    plane_ref = _plane_ref_to_domain(payload.plane_ref) if payload.plane_ref is not None else _default_plane_ref()
    _validate_plane_ref(part, plane_ref)
    feature = BevelPairFeature(
        id=str(uuid.uuid4()),
        plane_ref=plane_ref,
        module=payload.module,
        member_1=_bevel_pair_member_to_domain(payload.member_1),
        member_2=_bevel_pair_member_to_domain(payload.member_2),
        face_width=payload.face_width,
        pressure_angle_degrees=payload.pressure_angle_degrees,
        shaft_angle_degrees=payload.shaft_angle_degrees,
        backlash=payload.backlash,
        points_per_flank=payload.points_per_flank,
        spiral_angle_degrees=payload.spiral_angle_degrees,
    )
    _, warnings = resolve_bevel_pair(part, feature)  # raises on an unresolvable/invalid bevel pair
    part.add_feature(feature)
    return _bevel_pair_feature_response(part, feature, warnings)


@router.post("/parts/{part_id}/bevel-pair-features/coarse-preview", response_model=list[BodyMeshResponse])
def preview_bevel_pair_feature_coarse(
    part_id: str, payload: BevelPairFeatureCreate, quality: float | None = Query(default=None, ge=0.0, le=1.0)
) -> list[BodyMeshResponse]:
    """`docs/lod-strategy/01-design.md` SS4: mirrors `preview_gear_feature_
    coarse`'s own shape exactly, for a not-yet-created `BevelPairFeature` -
    same `create_bevel_pair_feature` validate-then-build path, but built via
    `app.document.bevel_pair.resolve_bevel_pair_coarse` (two cones, no
    meshing-phase search) and never persisted. Both members come back as
    their own entry (`_coarse_preview_response`), same as the real pair's
    own 2-Body compound."""
    part = get_part_or_404(part_id)
    mesh_quality = DEFAULT_MESH_QUALITY if quality is None else mesh_quality_from_slider(quality)
    plane_ref = _plane_ref_to_domain(payload.plane_ref) if payload.plane_ref is not None else _default_plane_ref()
    _validate_plane_ref(part, plane_ref)
    feature = BevelPairFeature(
        id=str(uuid.uuid4()),
        plane_ref=plane_ref,
        module=payload.module,
        member_1=_bevel_pair_member_to_domain(payload.member_1),
        member_2=_bevel_pair_member_to_domain(payload.member_2),
        face_width=payload.face_width,
        pressure_angle_degrees=payload.pressure_angle_degrees,
        shaft_angle_degrees=payload.shaft_angle_degrees,
        backlash=payload.backlash,
        points_per_flank=payload.points_per_flank,
        spiral_angle_degrees=payload.spiral_angle_degrees,
    )
    shape = resolve_bevel_pair_coarse(part, feature)  # raises on an unresolvable/invalid bevel pair
    return _coarse_preview_response(shape, mesh_quality)


@router.post("/parts/{part_id}/bevel-pair-features/jobs", response_model=JobCreateResponse, status_code=202)
def create_bevel_pair_feature_job(part_id: str, payload: BevelPairFeatureCreate) -> JobCreateResponse:
    """`docs/lod-strategy/02-phase2-design.md` SS4: job-mode counterpart to
    `create_bevel_pair_feature` - a separate route, not a query flag,
    because the response shape genuinely differs (an immediate `{job_id,
    status}` here vs. the full synchronous 201 there). Only the cheap,
    synchronous part of `create_bevel_pair_feature` runs on this request
    (payload-shape validation, `_validate_plane_ref`, building the `Bevel
    PairFeature` object itself - no OCCT yet); `app.document.jobs.submit_
    bevel_pair_job` hands the real build (`resolve_bevel_pair` - the same
    call the synchronous endpoint makes, cancellation-aware this time - plus
    persisting via `part.add_feature` on success) to a dedicated background
    thread and returns immediately. `202 Accepted` (not `201 Created`) - the
    Feature does not exist yet, only the job tracking its eventual creation
    does.

    Every other Feature type's create endpoint, and `create_bevel_pair_
    feature`/`preview_bevel_pair_feature_coarse` above, are completely
    untouched by this endpoint's existence."""
    part = get_part_or_404(part_id)
    plane_ref = _plane_ref_to_domain(payload.plane_ref) if payload.plane_ref is not None else _default_plane_ref()
    _validate_plane_ref(part, plane_ref)
    feature = BevelPairFeature(
        id=str(uuid.uuid4()),
        plane_ref=plane_ref,
        module=payload.module,
        member_1=_bevel_pair_member_to_domain(payload.member_1),
        member_2=_bevel_pair_member_to_domain(payload.member_2),
        face_width=payload.face_width,
        pressure_angle_degrees=payload.pressure_angle_degrees,
        shaft_angle_degrees=payload.shaft_angle_degrees,
        backlash=payload.backlash,
        points_per_flank=payload.points_per_flank,
        spiral_angle_degrees=payload.spiral_angle_degrees,
    )
    job = submit_bevel_pair_job(part_id, part, feature)  # raises 409 if a job is already running
    return JobCreateResponse(job_id=job.id, status="running")


@router.post("/parts/{part_id}/planetary-gear-features/jobs", response_model=JobCreateResponse, status_code=202)
def create_planetary_gear_feature_job(part_id: str, payload: PlanetaryGearFeatureCreate) -> JobCreateResponse:
    """LOD Phase 2 chunk 3 - job-mode counterpart to `create_planetary_gear_
    feature`, mirroring `create_bevel_pair_feature_job` above exactly (same
    reasoning for the separate route/`202`/background-thread shape - see
    that endpoint's own docstring). Only the cheap, synchronous part of
    `create_planetary_gear_feature` runs on this request (payload-shape
    validation, `_validate_plane_ref`, building the `PlanetaryGearFeature`
    object itself - no OCCT yet); `app.document.jobs.submit_planetary_job`
    hands the real build (`resolve_planetary`, now cancellation-aware -
    chunk 1's own pooling plus this chunk's `cancellation` threading) to a
    dedicated background thread.

    `preview_planetary_gear_feature_coarse` above and every other Feature
    type's own synchronous create endpoint are completely untouched."""
    part = get_part_or_404(part_id)
    plane_ref = _plane_ref_to_domain(payload.plane_ref) if payload.plane_ref is not None else _default_plane_ref()
    _validate_plane_ref(part, plane_ref)
    feature = PlanetaryGearFeature(
        id=str(uuid.uuid4()),
        plane_ref=plane_ref,
        module=payload.module,
        sun_tooth_count=payload.sun_tooth_count,
        ring_tooth_count=payload.ring_tooth_count,
        planet_count=payload.planet_count,
        face_width=payload.face_width,
        ring_outer_diameter=payload.ring_outer_diameter,
        pressure_angle_degrees=payload.pressure_angle_degrees,
    )
    job = submit_planetary_job(part_id, part, feature)  # raises 409 if a job is already running
    return JobCreateResponse(job_id=job.id, status="running")


@router.get("/parts/{part_id}/jobs/{job_id}", response_model=JobStatusResponse)
def get_job_status(part_id: str, job_id: str) -> JobStatusResponse:
    """Polls a job's current state (`app.document.jobs.get_job` - a cheap
    dict lookup, never re-runs any part of the build) - shared by every
    job-mode Feature type (`BevelPairFeature`, `PlanetaryGearFeature`), one
    handler/route for both rather than a duplicate poll endpoint per type.
    On `succeeded`, embeds the exact same response shape the matching
    synchronous create endpoint itself returns, dispatched by the job's own
    actual Feature type: `_bevel_pair_feature_response` (with the job's own
    already-known `warnings` - no re-resolution) for a `BevelPairFeature`
    job, `_feature_response` (cheap - no OCCT, `PlanetaryGearFeatureResponse`
    has no `warnings` field to begin with) for a `PlanetaryGearFeature` one.
    On `failed`, `error` carries the same structured `{"type": ..., "detail":
    ...}` shape the synchronous endpoint's own `HTTPException` would have
    raised."""
    job = get_job(part_id, job_id)
    if job.status is JobStatus.SUCCEEDED:
        if isinstance(job.feature, BevelPairFeature):
            result = _bevel_pair_feature_response(job.part, job.feature, job.warnings)
        else:
            result = _feature_response(job.part, job.feature)
        return JobStatusResponse(job_id=job.id, status=job.status.value, result=result)
    if job.status is JobStatus.FAILED:
        return JobStatusResponse(job_id=job.id, status=job.status.value, error=job.error)
    return JobStatusResponse(job_id=job.id, status=job.status.value)


@router.post("/parts/{part_id}/jobs/{job_id}/cancel", response_model=JobCancelResponse)
def cancel_job_endpoint(part_id: str, job_id: str) -> JobCancelResponse:
    """Requests cancellation of an in-flight job (`app.document.jobs.
    cancel_job` - `404` if the job doesn't exist/belong to this Part, `409`
    if it already reached a terminal state) - shared by every job-mode
    Feature type, same reasoning as `get_job_status` above. The Feature is
    never added to the Part if cancelled before the build completes and
    persists - see `app.document.jobs._run_job`'s own final pre-persist
    check."""
    job = cancel_job(part_id, job_id)
    return JobCancelResponse(job_id=job.id, status=job.status.value)


def _get_bevel_pair_feature_or_404(part: Part, feature_id: str) -> BevelPairFeature:
    feature = part.get_feature(feature_id)
    if not isinstance(feature, BevelPairFeature):
        raise HTTPException(status_code=404, detail="Bevel pair feature not found")
    return feature


@router.patch("/parts/{part_id}/bevel-pair-features/{feature_id}", response_model=BevelPairFeatureResponse)
def update_bevel_pair_feature(part_id: str, feature_id: str, payload: BevelPairFeatureUpdate) -> BevelPairFeatureResponse:
    """Mirrors `update_planetary_gear_feature`'s exact shape - same
    validate-before-mutate discipline against a scratch Feature sharing
    the real one's id."""
    part = get_part_or_404(part_id)
    feature = _get_bevel_pair_feature_or_404(part, feature_id)

    new_plane_ref = _plane_ref_to_domain(payload.plane_ref) if payload.plane_ref is not None else feature.plane_ref
    new_module = payload.module if payload.module is not None else feature.module
    new_member_1 = (
        _bevel_pair_member_to_domain(payload.member_1) if payload.member_1 is not None else feature.member_1
    )
    new_member_2 = (
        _bevel_pair_member_to_domain(payload.member_2) if payload.member_2 is not None else feature.member_2
    )
    new_face_width = payload.face_width if payload.face_width is not None else feature.face_width
    new_pressure_angle_degrees = (
        payload.pressure_angle_degrees
        if payload.pressure_angle_degrees is not None
        else feature.pressure_angle_degrees
    )
    new_shaft_angle_degrees = (
        payload.shaft_angle_degrees if payload.shaft_angle_degrees is not None else feature.shaft_angle_degrees
    )
    new_backlash = payload.backlash if payload.backlash is not None else feature.backlash
    new_points_per_flank = (
        payload.points_per_flank if payload.points_per_flank is not None else feature.points_per_flank
    )
    new_spiral_angle_degrees = (
        payload.spiral_angle_degrees if payload.spiral_angle_degrees is not None else feature.spiral_angle_degrees
    )

    _validate_plane_ref(part, new_plane_ref)

    candidate = BevelPairFeature(
        id=feature.id,
        plane_ref=new_plane_ref,
        module=new_module,
        member_1=new_member_1,
        member_2=new_member_2,
        face_width=new_face_width,
        pressure_angle_degrees=new_pressure_angle_degrees,
        shaft_angle_degrees=new_shaft_angle_degrees,
        backlash=new_backlash,
        points_per_flank=new_points_per_flank,
        spiral_angle_degrees=new_spiral_angle_degrees,
    )
    _, warnings = resolve_bevel_pair(part, candidate)  # raises on an unresolvable/invalid bevel pair

    feature.plane_ref = candidate.plane_ref
    feature.module = candidate.module
    feature.member_1 = candidate.member_1
    feature.member_2 = candidate.member_2
    feature.face_width = candidate.face_width
    feature.pressure_angle_degrees = candidate.pressure_angle_degrees
    feature.shaft_angle_degrees = candidate.shaft_angle_degrees
    feature.backlash = candidate.backlash
    feature.points_per_flank = candidate.points_per_flank
    feature.spiral_angle_degrees = candidate.spiral_angle_degrees
    return _bevel_pair_feature_response(part, feature, warnings)


def _invalid_gear_preview_parameters(detail: str) -> HTTPException:
    """Mirrors `app.document.gear._invalid_gear_parameters`'s convention -
    a `gear_math`-rejected parameter combination has no valid geometry to
    draw at all, so `/gear/preview` blocks (422) rather than returning a
    warning, per `00-conventions.md`'s stated exception to the non-blocking
    validation-banner rule."""
    return HTTPException(status_code=422, detail={"type": "invalid_gear_preview_parameters", "detail": detail})


def _preview_transform_profile(
    points: list[tuple[float, float]], center: tuple[float, float], angle: float = 0.0
) -> list[tuple[float, float]]:
    """Rotates (about the profile's own local origin) then translates a raw
    `gear_math`/`rack_tooth_geometry` profile (always centred on its own
    local origin) into a chain/planetary preview's shared 2D frame - the
    one transform every other preview response already spares the client
    (`00-conventions.md`'s "don't duplicate the math client-side" point),
    generalized here from "translate only" to "rotate then translate" for a
    rack member, whose own length axis isn't generally aligned with the
    chain's local x axis."""
    if angle == 0.0:
        return [(center[0] + x, center[1] + y) for x, y in points]
    cos_a, sin_a = math.cos(angle), math.sin(angle)
    return [(center[0] + x * cos_a - y * sin_a, center[1] + x * sin_a + y * cos_a) for x, y in points]


def _preview_rack_rotation(resolved_stage, start_direction_degrees: float) -> float:
    """Mirrors `app.document.gear_chain._rack_rotation` exactly (a rack's
    own length axis is perpendicular to its one adjacent chain segment) -
    small, deliberate duplication of that OCCT-adjacent module's private
    helper rather than importing it, matching every other branch of
    `_gear_preview_response` below (which already duplicates `resolve_gear`/
    `resolve_rack`'s own cheap math rather than calling into them)."""
    orientation = resolved_stage.incoming_direction
    if orientation is None:
        orientation = resolved_stage.outgoing_direction
    if orientation is None:
        orientation = math.radians(start_direction_degrees)
    return orientation + math.pi / 2


def _chain_member_math_spec(member: GearChainMemberSpec, group: GearGroup) -> ChainMemberSpec:
    """Mirrors `app.document.gear_chain._member_to_math_spec` exactly - see
    `_preview_rack_rotation`'s own docstring for why this is duplicated
    rather than imported."""
    return ChainMemberSpec(
        kind=ChainMemberKind(member.member_type.value),
        module=group.module,
        pressure_angle_degrees=group.pressure_angle_degrees,
        tooth_count=member.tooth_count,
        face_width=member.face_width,
        outer_diameter=member.outer_diameter,
    )


def _chain_stage_math_spec(stage: GearChainStage, groups: dict[str, GearGroup]) -> ChainStageSpec:
    """Mirrors `app.document.gear_chain._build_stage_specs`'s own per-stage
    conversion (see `_preview_rack_rotation`'s docstring)."""
    if stage.is_compound:
        return ChainStageSpec(
            turn_angle_degrees=stage.turn_angle_degrees,
            compound_member_a=_chain_member_math_spec(
                stage.compound_member_a, groups[stage.compound_member_a.group_id]
            ),
            compound_member_b=_chain_member_math_spec(
                stage.compound_member_b, groups[stage.compound_member_b.group_id]
            ),
        )
    return ChainStageSpec(
        turn_angle_degrees=stage.turn_angle_degrees,
        member=_chain_member_math_spec(stage.member, groups[stage.member.group_id]),
    )


# One meshing junction's propagated phase state - mirrors `app.document.
# gear_chain._PhaseState` exactly (kind, pitch_radius-or-None-for-rack,
# phase-value; see `_preview_rack_rotation`'s docstring for why this is
# duplicated rather than imported).
_PreviewPhaseState = tuple[ChainMemberKind, float | None, float]


def _preview_member_phase(
    member_spec: ChainMemberSpec, predecessor: _PreviewPhaseState | None, incoming_direction: float | None
) -> float:
    """Mirrors `app.document.gear_chain._member_phase` exactly (see
    `_preview_rack_rotation`'s own docstring for why this is duplicated
    rather than imported) - the phase value (radians for a round EXTERNAL/
    INTERNAL member, mm along its own rotated tooth-row axis for a RACK) to
    apply to `member_spec` so one of its own tooth gaps sits at the
    meshing contact point with `predecessor` - `0.0` for the first member
    in a chain (`predecessor is None`), matching `meshing_phase_base`'s own
    documented zero-reference baseline."""
    is_rack = member_spec.kind == ChainMemberKind.RACK
    radius = None if is_rack else pitch_radius(member_spec)
    if predecessor is None:
        return 0.0
    predecessor_kind, predecessor_radius, predecessor_phase = predecessor
    assert incoming_direction is not None
    base_value = (
        rack_meshing_phase_base(member_spec.tooth_count, math.pi * member_spec.module)
        if is_rack
        else meshing_phase_base(member_spec.tooth_count, predecessor_kind, incoming_direction)
    )
    return propagate_meshing_phase(
        predecessor_kind, predecessor_radius, predecessor_phase, member_spec.kind, radius, incoming_direction, base_value
    )


def _preview_member_outline(
    stage_index: int,
    label: str,
    member_spec: ChainMemberSpec,
    group_id: str | None,
    display_color: str | None,
    center: tuple[float, float],
    rotation: float = 0.0,
) -> GearPreviewMember:
    """One physical member's `GearPreviewMember` - the tooth outline (raw
    `gear_math` points, transformed into the shared preview frame via
    `_preview_transform_profile`) plus its reference-circle numbers, shared
    by the chain and planetary preview builders below."""
    if member_spec.kind == ChainMemberKind.RACK:
        rack_geometry = rack_tooth_geometry(
            module=member_spec.module, pressure_angle_degrees=member_spec.pressure_angle_degrees
        )
        outline_points = _preview_transform_profile(
            full_rack_profile_points(rack_geometry, member_spec.tooth_count), center, rotation
        )
        return GearPreviewMember(
            stage_index=stage_index,
            label=label,
            member_type="rack",
            group_id=group_id,
            display_color=display_color,
            center=center,
            outline_points=outline_points,
        )

    is_internal = member_spec.kind == ChainMemberKind.INTERNAL
    geometry = spur_gear_geometry(
        module=member_spec.module,
        tooth_count=member_spec.tooth_count,
        pressure_angle_degrees=member_spec.pressure_angle_degrees,
        is_internal=is_internal,
    )
    outline_points = _preview_transform_profile(full_gear_profile_points(geometry), center, rotation)
    return GearPreviewMember(
        stage_index=stage_index,
        label=label,
        member_type=member_spec.kind.value,
        group_id=group_id,
        display_color=display_color,
        center=center,
        outline_points=outline_points,
        pitch_radius=geometry.pitch_radius,
        base_radius=geometry.base_radius,
        addendum_radius=geometry.addendum_radius,
        dedendum_radius=geometry.dedendum_radius,
        outer_radius=(member_spec.outer_diameter / 2) if is_internal and member_spec.outer_diameter else None,
    )


def _gear_preview_chain_response(payload: GearPreviewChainRequest) -> GearPreviewChainResult:
    """`docs/gear-design/08-entry-screen-and-preview.md`'s "Chain/planetary/
    bevel-pair preview" extension, the `GearChainFeature` half - reuses
    `_validate_gear_chain_stages` (the exact payload-shape validation
    `create_gear_chain_feature` itself runs) and `app.document.
    gear_chain_math.resolve_chain` (the real bent-path positioning +
    interference math, `05-gear-chain-and-planetary.md`'s own Spike 1) so
    the preview and the real Feature agree on every rejection and every
    resolved position - only the OCCT solid construction itself
    (`app.document.gear_chain.resolve_gear_chain_from_bodies`) is
    deliberately not run here."""
    groups = [_gear_group_to_domain(g) for g in payload.groups]
    stages = [_gear_chain_stage_to_domain(s) for s in payload.stages]
    _validate_gear_chain_stages(groups, stages)
    groups_by_id = {g.id: g for g in groups}

    try:
        stage_specs = [_chain_stage_math_spec(stage, groups_by_id) for stage in stages]
        resolved = resolve_chain_positions_and_interference(
            stage_specs, payload.start_direction_degrees, payload.print_clearance_margin
        )

        members: list[GearPreviewMember] = []
        # Propagated meshing-phase state, carried stage to stage - mirrors
        # `app.document.gear_chain.resolve_gear_chain_from_bodies`'s own
        # `prev_state` loop variable exactly (see `_preview_member_phase`'s
        # docstring for why this duplication exists).
        prev_state: _PreviewPhaseState | None = None
        for i, (stage, spec, resolved_stage) in enumerate(zip(stages, stage_specs, resolved.stages)):
            if spec.is_compound:
                rotation_a = _preview_member_phase(spec.compound_member_a, prev_state, resolved_stage.incoming_direction)
                # `compound_member_b` (the outgoing-facing member) gets a
                # fixed 0.0 reference, decoupled from `compound_member_a`'s
                # own rotation - mirrors `resolve_gear_chain_from_bodies`'s
                # own decoupling exactly (see that function's inline
                # comment for why: no shared-shaft "keyed at a specific
                # relative angle" constraint exists here to preserve).
                prev_state = (spec.compound_member_b.kind, pitch_radius(spec.compound_member_b), 0.0)
                members.append(
                    _preview_member_outline(
                        i,
                        "a",
                        spec.compound_member_a,
                        stage.compound_member_a.group_id,
                        groups_by_id[stage.compound_member_a.group_id].display_color,
                        resolved_stage.center,
                        rotation_a,
                    )
                )
                members.append(
                    _preview_member_outline(
                        i,
                        "b",
                        spec.compound_member_b,
                        stage.compound_member_b.group_id,
                        groups_by_id[stage.compound_member_b.group_id].display_color,
                        resolved_stage.center,
                    )
                )
            else:
                phase = _preview_member_phase(spec.member, prev_state, resolved_stage.incoming_direction)
                is_rack = spec.member.kind == ChainMemberKind.RACK
                rotation = (
                    _preview_rack_rotation(resolved_stage, payload.start_direction_degrees) if is_rack else phase
                )
                prev_state = (spec.member.kind, None if is_rack else pitch_radius(spec.member), phase)
                members.append(
                    _preview_member_outline(
                        i,
                        "single",
                        spec.member,
                        stage.member.group_id,
                        groups_by_id[stage.member.group_id].display_color,
                        resolved_stage.center,
                        rotation,
                    )
                )
    except GearGeometryError as exc:
        raise _invalid_gear_preview_parameters(str(exc)) from exc

    interference_findings = [
        GearPreviewInterferenceFinding(
            stage_index_a=finding.stage_index_a,
            member_label_a=finding.member_label_a,
            stage_index_b=finding.stage_index_b,
            member_label_b=finding.member_label_b,
            gap=finding.gap,
            kind=finding.kind,
        )
        for finding in resolved.interference_findings
    ]

    def _link(from_index: int, to_index: int, kind: Literal["mesh", "compound"], link_ratio: LinkRatio) -> GearPreviewLink:
        return GearPreviewLink(
            from_stage_index=from_index,
            to_stage_index=to_index,
            kind=kind,
            ratio=link_ratio.ratio,
            reverses_direction=link_ratio.reverses,
            linear_mm_per_revolution=link_ratio.linear_mm_per_revolution,
        )

    links: list[GearPreviewLink] = []
    mesh_ratios: list[LinkRatio] = []
    for k in range(len(stage_specs) - 1):
        if stage_specs[k].is_compound:
            links.append(
                _link(k, k, "compound", compound_transition_ratio(stage_specs[k].compound_member_a, stage_specs[k].compound_member_b))
            )
        mesh_ratio = mesh_link_ratio(stage_specs[k].outgoing_member(), stage_specs[k + 1].incoming_member())
        mesh_ratios.append(mesh_ratio)
        links.append(_link(k, k + 1, "mesh", mesh_ratio))
    if stage_specs and stage_specs[-1].is_compound:
        last = len(stage_specs) - 1
        links.append(
            _link(
                last,
                last,
                "compound",
                compound_transition_ratio(stage_specs[last].compound_member_a, stage_specs[last].compound_member_b),
            )
        )

    return GearPreviewChainResult(
        members=members,
        interference_findings=interference_findings,
        links=links,
        overall_ratio=chain_overall_ratio(mesh_ratios),
    )


def _gear_preview_planetary_response(payload: GearPreviewPlanetaryRequest) -> GearPreviewPlanetaryResult:
    """`docs/gear-design/08-entry-screen-and-preview.md`'s "Chain/planetary/
    bevel-pair preview" extension, the `PlanetaryGearFeature` half - reuses
    the exact same `gear_math` calls and orbit-radius/even-spacing
    positioning `app.document.planetary_gear.resolve_planetary_from_bodies`
    itself uses (that positioning is already pure arithmetic, no OCCT, so
    it's duplicated here rather than the OCCT solid construction, per this
    module's established "duplicate the cheap math" precedent)."""
    try:
        planet_tooth_count = planetary_planet_tooth_count(payload.sun_tooth_count, payload.ring_tooth_count)
        sun_geometry = spur_gear_geometry(
            module=payload.module,
            tooth_count=payload.sun_tooth_count,
            pressure_angle_degrees=payload.pressure_angle_degrees,
            is_internal=False,
        )
        ring_geometry = spur_gear_geometry(
            module=payload.module,
            tooth_count=payload.ring_tooth_count,
            pressure_angle_degrees=payload.pressure_angle_degrees,
            is_internal=True,
        )
        planet_geometry = spur_gear_geometry(
            module=payload.module,
            tooth_count=planet_tooth_count,
            pressure_angle_degrees=payload.pressure_angle_degrees,
            is_internal=False,
        )
        validate_planetary_assembly(
            sun_teeth=payload.sun_tooth_count,
            ring_teeth=payload.ring_tooth_count,
            planet_count=payload.planet_count,
            planet_pitch_radius=planet_geometry.pitch_radius,
            planet_addendum_radius=planet_geometry.addendum_radius,
        )
    except GearGeometryError as exc:
        raise _invalid_gear_preview_parameters(str(exc)) from exc

    if payload.face_width <= 0:
        raise _invalid_gear_preview_parameters(f"face_width must be positive, got {payload.face_width!r}")
    if payload.ring_outer_diameter / 2 <= ring_geometry.dedendum_radius:
        raise _invalid_gear_preview_parameters(
            f"ring_outer_diameter ({payload.ring_outer_diameter!r}) must exceed the ring's own tooth profile "
            f"outer reach (dedendum diameter {ring_geometry.dedendum_radius * 2!r})"
        )

    # Meshing-phase alignment - mirrors `app.document.planetary_gear.
    # resolve_planetary_from_bodies`'s own phase-computation block exactly
    # (see that function's inline comment for the full derivation/real-OCCT
    # verification this reuses) - duplicated here rather than imported, per
    # this module's established "duplicate the cheap math" precedent
    # (`_preview_rack_rotation`'s own docstring).
    sun_rotation = 0.0
    planet_0_azimuth = 0.0
    planet_0_base = meshing_phase_base(planet_tooth_count, ChainMemberKind.EXTERNAL, planet_0_azimuth)
    planet_0_rotation = propagate_meshing_phase(
        ChainMemberKind.EXTERNAL,
        sun_geometry.pitch_radius,
        sun_rotation,
        ChainMemberKind.EXTERNAL,
        planet_geometry.pitch_radius,
        planet_0_azimuth,
        planet_0_base,
    )
    ring_azimuth = planet_0_azimuth + math.pi
    ring_base = meshing_phase_base(payload.ring_tooth_count, ChainMemberKind.EXTERNAL, ring_azimuth)
    ring_rotation = propagate_meshing_phase(
        ChainMemberKind.EXTERNAL,
        planet_geometry.pitch_radius,
        planet_0_rotation,
        ChainMemberKind.INTERNAL,
        ring_geometry.pitch_radius,
        ring_azimuth,
        ring_base,
    )

    members = [
        GearPreviewMember(
            stage_index=0,
            label="sun",
            member_type="external",
            center=(0.0, 0.0),
            outline_points=_preview_transform_profile(full_gear_profile_points(sun_geometry), (0.0, 0.0), sun_rotation),
            pitch_radius=sun_geometry.pitch_radius,
            base_radius=sun_geometry.base_radius,
            addendum_radius=sun_geometry.addendum_radius,
            dedendum_radius=sun_geometry.dedendum_radius,
        ),
        GearPreviewMember(
            stage_index=1,
            label="ring",
            member_type="internal",
            center=(0.0, 0.0),
            outline_points=_preview_transform_profile(full_gear_profile_points(ring_geometry), (0.0, 0.0), ring_rotation),
            pitch_radius=ring_geometry.pitch_radius,
            base_radius=ring_geometry.base_radius,
            addendum_radius=ring_geometry.addendum_radius,
            dedendum_radius=ring_geometry.dedendum_radius,
            outer_radius=payload.ring_outer_diameter / 2,
        ),
    ]
    orbit_radius = sun_geometry.pitch_radius + planet_geometry.pitch_radius
    planet_outline = full_gear_profile_points(planet_geometry)
    for i in range(payload.planet_count):
        angle = 2 * math.pi * i / payload.planet_count
        center = (orbit_radius * math.cos(angle), orbit_radius * math.sin(angle))
        planet_base = meshing_phase_base(planet_tooth_count, ChainMemberKind.EXTERNAL, angle)
        planet_rotation = propagate_meshing_phase(
            ChainMemberKind.EXTERNAL,
            sun_geometry.pitch_radius,
            sun_rotation,
            ChainMemberKind.EXTERNAL,
            planet_geometry.pitch_radius,
            angle,
            planet_base,
        )
        members.append(
            GearPreviewMember(
                stage_index=2 + i,
                label=f"planet_{i}",
                member_type="external",
                center=center,
                outline_points=_preview_transform_profile(planet_outline, center, planet_rotation),
                pitch_radius=planet_geometry.pitch_radius,
                base_radius=planet_geometry.base_radius,
                addendum_radius=planet_geometry.addendum_radius,
                dedendum_radius=planet_geometry.dedendum_radius,
            )
        )

    sun_spec = ChainMemberSpec(ChainMemberKind.EXTERNAL, payload.module, payload.pressure_angle_degrees, payload.sun_tooth_count, payload.face_width)
    planet_spec = ChainMemberSpec(ChainMemberKind.EXTERNAL, payload.module, payload.pressure_angle_degrees, planet_tooth_count, payload.face_width)
    ring_spec = ChainMemberSpec(
        ChainMemberKind.INTERNAL, payload.module, payload.pressure_angle_degrees, payload.ring_tooth_count,
        payload.face_width, payload.ring_outer_diameter,
    )
    sun_to_planet = mesh_link_ratio(sun_spec, planet_spec)
    planet_to_ring = mesh_link_ratio(planet_spec, ring_spec)

    return GearPreviewPlanetaryResult(
        members=members, sun_to_planet_ratio=sun_to_planet.ratio, planet_to_ring_ratio=planet_to_ring.ratio
    )


def _bevel_member_schematic(label: str, axis_angle_degrees: float, geometry: BevelGearGeometry) -> GearPreviewBevelMember:
    """`GearPreviewBevelMember`'s own axial-cross-section schematic (see
    that schema's docstring for why this is an envelope, not a tooth
    outline) - built in the member's own local frame (axis along local +x)
    then rotated by `axis_angle_degrees` about the shared apex at the
    origin, mirroring `_preview_transform_profile`'s rotate-then-translate
    shape with a translation of `(0, 0)` (both a pair's members' apexes
    coincide there, per `11-bevel-pair.md`).

    The 8-point outline traces the full symmetric-about-the-axis envelope:
    from the inner face-cone corner out along the face cone to the outer
    face-cone corner, across to the outer root-cone corner, in along the
    root cone to the inner root-cone corner, across the axis to the
    mirrored inner root-cone corner, and back out along the mirrored
    boundary to close - the same closed "picture-frame wedge" shape a real
    bevel-gear engineering drawing's axial half-section shows, both sides
    of the axis rather than just one."""
    face = geometry.face_cone_angle
    root = geometry.root_cone_angle
    pitch = geometry.pitch_cone_angle
    outer = geometry.cone_distance
    inner = geometry.inner_cone_distance

    def point(radius: float, angle: float) -> tuple[float, float]:
        return (radius * math.cos(angle), radius * math.sin(angle))

    local_outline = [
        point(inner, face),
        point(outer, face),
        point(outer, root),
        point(inner, root),
        point(inner, -root),
        point(outer, -root),
        point(outer, -face),
        point(inner, -face),
    ]
    local_pitch_line = (point(inner, pitch), point(outer, pitch))

    axis_angle = math.radians(axis_angle_degrees)
    outline_points = _preview_transform_profile(local_outline, (0.0, 0.0), axis_angle)
    pitch_line = tuple(_preview_transform_profile(list(local_pitch_line), (0.0, 0.0), axis_angle))

    return GearPreviewBevelMember(
        label=label,
        axis_angle_degrees=axis_angle_degrees,
        outline_points=outline_points,
        pitch_line=pitch_line,
        pitch_cone_angle_degrees=math.degrees(pitch),
        cone_distance=outer,
        inner_cone_distance=inner,
        pitch_radius=geometry.pitch_radius,
        face_width=geometry.face_width,
        effective_profile_shift=geometry.profile_shift,
    )


def _bevel_face_width_warning(label: str, geometry: BevelGearGeometry) -> str | None:
    """`10-bevel-gear.md`'s own face-width-vs-cone-distance non-blocking
    warning - the same `max_recommended_face_width = cone_distance / 3`
    rule-of-thumb `app.document.bevel.resolve_bevel_gear_from_bodies`
    itself surfaces, reproduced here so the preview flags it before
    Create, per `00-conventions.md`'s validation-banner convention."""
    max_face_width = max_recommended_face_width(geometry.cone_distance)
    if geometry.face_width > max_face_width:
        return (
            f"{label}: face_width ({geometry.face_width!r}) exceeds the recommended maximum "
            f"({max_face_width:.3f}, cone_distance/3) - the tooth thins toward degeneracy near the apex"
        )
    return None


def _gear_preview_bevel_gear_response(payload: GearPreviewBevelGearRequest) -> tuple[GearPreviewBevelMember, list[str]]:
    """`docs/gear-design/08-entry-screen-and-preview.md`'s "Chain/planetary/
    bevel-pair preview" extension, the standalone `BevelGearFeature` half -
    reuses `bevel_math.bevel_gear_geometry` directly (the same function
    `app.document.bevel.resolve_bevel_gear_from_bodies` calls), skipping
    only the OCCT shell/solid assembly itself."""
    try:
        geometry = bevel_gear_geometry(
            module=payload.module,
            tooth_count=payload.tooth_count,
            face_width=payload.face_width,
            pressure_angle_degrees=payload.pressure_angle_degrees,
            backlash=payload.backlash,
            profile_shift=payload.profile_shift,
            # shaft_angle_degrees deliberately omitted (defaults to 90.0,
            # unused) - passing pitch_cone_angle_degrees directly skips
            # the mate_tooth_count/shaft_angle_degrees-derived path
            # entirely, per bevel_gear_geometry's own docstring.
            pitch_cone_angle_degrees=payload.pitch_cone_angle_degrees,
        )
    except GearGeometryError as exc:
        raise _invalid_gear_preview_parameters(str(exc)) from exc

    warning = _bevel_face_width_warning("single", geometry)
    return _bevel_member_schematic("single", 0.0, geometry), ([warning] if warning else [])


def _gear_preview_bevel_pair_response(payload: GearPreviewBevelPairRequest) -> tuple[GearPreviewBevelPairResult, list[str]]:
    """The `BevelPairFeature` half - reuses `bevel_math.pitch_cone_half_
    angles` + `bevel_gear_geometry`'s `pitch_cone_angle_degrees` direct-
    field path in the exact same order `app.document.bevel_pair.resolve_
    bevel_pair_from_bodies` itself calls them, so preview and Create derive
    identical cone angles for identical inputs. `profile_shift` resolution
    (`None` -> auto) goes through `bevel_pair.resolve_member_profile_
    shifts` too, for the same reason - a preview with an unresolved `None`
    passed straight into `bevel_gear_geometry` would crash (that function's
    own `profile_shift: float` has no `None` handling), and resolving it
    differently from Create would make the preview lie about what Create
    would actually build."""
    try:
        gamma_1, gamma_2 = pitch_cone_half_angles(
            payload.member_1.tooth_count, payload.member_2.tooth_count, payload.shaft_angle_degrees
        )
        profile_shift_1, profile_shift_2 = resolve_member_profile_shifts(
            module=payload.module,
            tooth_count_1=payload.member_1.tooth_count,
            tooth_count_2=payload.member_2.tooth_count,
            face_width=payload.face_width,
            pressure_angle_degrees=payload.pressure_angle_degrees,
            shaft_angle_degrees=payload.shaft_angle_degrees,
            backlash=payload.backlash,
            profile_shift_1=payload.member_1.profile_shift,
            profile_shift_2=payload.member_2.profile_shift,
            gamma_1=gamma_1,
            gamma_2=gamma_2,
        )
        geometry_1 = bevel_gear_geometry(
            module=payload.module,
            tooth_count=payload.member_1.tooth_count,
            face_width=payload.face_width,
            pressure_angle_degrees=payload.pressure_angle_degrees,
            backlash=payload.backlash,
            profile_shift=profile_shift_1,
            pitch_cone_angle_degrees=math.degrees(gamma_1),
        )
        geometry_2 = bevel_gear_geometry(
            module=payload.module,
            tooth_count=payload.member_2.tooth_count,
            face_width=payload.face_width,
            pressure_angle_degrees=payload.pressure_angle_degrees,
            backlash=payload.backlash,
            profile_shift=profile_shift_2,
            pitch_cone_angle_degrees=math.degrees(gamma_2),
        )
    except GearGeometryError as exc:
        raise _invalid_gear_preview_parameters(str(exc)) from exc

    warnings = [
        w
        for w in (
            _bevel_face_width_warning("member_1", geometry_1),
            _bevel_face_width_warning("member_2", geometry_2),
            # `docs/gear-design/13-spiral-bevel-pair.md`'s own Spike C §3 -
            # cheap, pure math (no OCCT), so the preview can surface a
            # hand-of-spiral mismatch before Create even though its own
            # axial-cross-section envelope can't show spiral curvature
            # itself (unaffected - see GearPreviewBevelMember's own
            # docstring / 12-spiral-bevel-gear.md's "Preview stays
            # unchanged" finding).
            spiral_hand_mismatch_warning(
                payload.spiral_angle_degrees,
                _spiral_hand_from_feature(payload.member_1.spiral_hand),
                _spiral_hand_from_feature(payload.member_2.spiral_hand),
            ),
        )
        if w
    ]
    members = [
        _bevel_member_schematic("member_1", 0.0, geometry_1),
        _bevel_member_schematic("member_2", payload.shaft_angle_degrees, geometry_2),
    ]
    mesh_preview = bevel_pair_mesh_preview(geometry_1, geometry_2)
    return (
        GearPreviewBevelPairResult(
            members=members,
            shaft_angle_degrees=payload.shaft_angle_degrees,
            mesh_preview=BevelPairMeshPreviewResult(
                member_1_teeth=mesh_preview.member_1_teeth,
                member_2_teeth=mesh_preview.member_2_teeth,
                center_1=mesh_preview.center_1,
                center_2=mesh_preview.center_2,
                pitch_radius_1=mesh_preview.pitch_radius_1,
                pitch_radius_2=mesh_preview.pitch_radius_2,
            ),
        ),
        warnings,
    )


def _gear_preview_response(payload: GearPreviewRequest) -> GearPreviewResponse:
    """`docs/gear-design/08-entry-screen-and-preview.md`: the actual math
    behind `/gear/preview` - runs only `gear_math`/`gear_chain_math` (no
    OCCT, no tessellation), shared by the GET and POST routes below.
    `"chain"`/`"planetary"` reuse `_gear_preview_chain_response`/
    `_gear_preview_planetary_response` above, `"bevel_gear"`/`"bevel_pair"`
    reuse `_gear_preview_bevel_gear_response`/`_gear_preview_bevel_pair_
    response`; a future gear type still adds one more `gear_kind` literal
    value plus one more branch here, not a new endpoint, per this schema's
    own original design."""
    if payload.gear_kind == "chain":
        if payload.chain is None:
            raise _invalid_gear_preview_parameters("chain is required when gear_kind is chain")
        return GearPreviewResponse(gear_kind="chain", chain=_gear_preview_chain_response(payload.chain))

    if payload.gear_kind == "planetary":
        if payload.planetary is None:
            raise _invalid_gear_preview_parameters("planetary is required when gear_kind is planetary")
        return GearPreviewResponse(
            gear_kind="planetary", planetary=_gear_preview_planetary_response(payload.planetary)
        )

    if payload.gear_kind == "bevel_gear":
        if payload.bevel_gear is None:
            raise _invalid_gear_preview_parameters("bevel_gear is required when gear_kind is bevel_gear")
        member, warnings = _gear_preview_bevel_gear_response(payload.bevel_gear)
        return GearPreviewResponse(gear_kind="bevel_gear", bevel_gear=member, warnings=warnings)

    if payload.gear_kind == "bevel_pair":
        if payload.bevel_pair is None:
            raise _invalid_gear_preview_parameters("bevel_pair is required when gear_kind is bevel_pair")
        result, warnings = _gear_preview_bevel_pair_response(payload.bevel_pair)
        return GearPreviewResponse(gear_kind="bevel_pair", bevel_pair=result, warnings=warnings)

    if payload.module is None or payload.tooth_count is None:
        raise _invalid_gear_preview_parameters("module and tooth_count are required for this gear_kind")

    if payload.gear_kind == "rack":
        try:
            rack_geometry = rack_tooth_geometry(
                module=payload.module,
                pressure_angle_degrees=payload.pressure_angle_degrees,
                backlash=payload.backlash,
            )
            outline_points = full_rack_profile_points(rack_geometry, payload.tooth_count)
        except GearGeometryError as exc:
            raise _invalid_gear_preview_parameters(str(exc)) from exc

        backing_height = (
            payload.backing_height
            if payload.backing_height is not None
            else default_rack_backing_height(payload.module)
        )
        if backing_height <= 0:
            raise _invalid_gear_preview_parameters(f"backing_height must be positive, got {backing_height!r}")

        return GearPreviewResponse(
            gear_kind="rack",
            outline_points=outline_points,
            pitch_line_y=0.0,
            addendum_line_y=rack_geometry.addendum_height,
            dedendum_line_y=-rack_geometry.dedendum_height,
            rack_length=gear_math_rack_length(rack_geometry, payload.tooth_count),
        )

    is_internal = payload.gear_kind == "internal"
    if is_internal and payload.outer_diameter is None:
        raise _invalid_gear_preview_parameters("outer_diameter is required when gear_kind is internal")

    resolved_profile_shift = resolve_gear_profile_shift(
        module=payload.module,
        tooth_count=payload.tooth_count,
        pressure_angle_degrees=payload.pressure_angle_degrees,
        backlash=payload.backlash,
        profile_shift=payload.profile_shift,
        is_internal=is_internal,
    )
    try:
        geometry = spur_gear_geometry(
            module=payload.module,
            tooth_count=payload.tooth_count,
            pressure_angle_degrees=payload.pressure_angle_degrees,
            profile_shift=resolved_profile_shift,
            backlash=payload.backlash,
            is_internal=is_internal,
        )
        outline_points = full_gear_profile_points(geometry)
    except GearGeometryError as exc:
        raise _invalid_gear_preview_parameters(str(exc)) from exc

    warnings: list[str] = []
    if not is_internal:
        warning = undercut_warning(payload.tooth_count, payload.pressure_angle_degrees, resolved_profile_shift)
        if warning is not None:
            warnings.append(warning)

    return GearPreviewResponse(
        gear_kind=payload.gear_kind,
        outline_points=outline_points,
        pitch_radius=geometry.pitch_radius,
        base_radius=geometry.base_radius,
        addendum_radius=geometry.addendum_radius,
        dedendum_radius=geometry.dedendum_radius,
        outer_radius=(payload.outer_diameter / 2) if is_internal and payload.outer_diameter else None,
        effective_profile_shift=resolved_profile_shift,
        warnings=warnings,
    )


@router.post("/gear/preview", response_model=GearPreviewResponse)
def preview_gear(payload: GearPreviewRequest) -> GearPreviewResponse:
    """`docs/gear-design/08-entry-screen-and-preview.md`: cheap enough (pure
    `gear_math`, no OCCT/tessellation) to call on every debounced keystroke
    while the Gear Design entry screen's form is being edited - the POST
    body form, for a client sending a full JSON payload."""
    return _gear_preview_response(payload)


@router.get("/gear/preview", response_model=GearPreviewResponse)
def preview_gear_via_query(
    gear_kind: Literal["external", "internal", "rack"] = Query(...),
    module: float = Query(...),
    tooth_count: int = Query(...),
    pressure_angle_degrees: float = Query(20.0),
    profile_shift: float | None = Query(None),
    backlash: float = Query(0.0),
    outer_diameter: float | None = Query(None),
    backing_height: float | None = Query(None),
) -> GearPreviewResponse:
    """Same preview, as a plain query-string GET - convenient for a quick
    manual check (a browser/`curl` URL, no JSON body) without needing a
    second implementation of the actual math."""
    return _gear_preview_response(
        GearPreviewRequest(
            gear_kind=gear_kind,
            module=module,
            tooth_count=tooth_count,
            pressure_angle_degrees=pressure_angle_degrees,
            profile_shift=profile_shift,
            backlash=backlash,
            outer_diameter=outer_diameter,
            backing_height=backing_height,
        )
    )


@router.post("/parts/{part_id}/pattern-features", response_model=PatternFeatureResponse, status_code=201)
def create_pattern_feature(part_id: str, payload: PatternFeatureCreate) -> PatternFeatureResponse:
    """Pattern/Mirror scoping's Phase 2/4 (`docs/pattern-mirror-scope.md`
    §2.2/§2.3/§4): mirrors `create_mirror_feature`'s exact shape - unlocked
    from the start, fails closed (via `_validate_pattern_source_body_ids`/
    `_validate_pattern_payload` for payload shape - itself dispatching on
    `payload.pattern_type` to whichever of Rectangular's/Circular's own
    required fields apply - then `resolve_pattern` for referential/
    geometric validity) before ever persisting an unresolvable Pattern."""
    part = get_part_or_404(part_id)
    source_body_ids = list(payload.source_body_ids)
    source_feature_ids = list(payload.source_feature_ids)
    direction_1 = (
        _pattern_direction_ref_to_domain(payload.direction_1) if payload.direction_1 is not None else None
    )
    direction_2 = (
        _pattern_direction_ref_to_domain(payload.direction_2) if payload.direction_2 is not None else None
    )
    axis = _pattern_axis_ref_to_domain(payload.axis) if payload.axis is not None else None
    _validate_pattern_source_body_ids(part, source_body_ids, source_feature_ids, payload.tool_feature_id)
    _validate_pattern_payload(
        payload.pattern_type,
        direction_1,
        payload.count_1,
        payload.count_2,
        direction_2,
        axis,
        payload.count_angular,
        payload.angle_total,
        payload.skip_indices,
    )
    _validate_tool_feature_id(
        part, payload.tool_feature_id, source_body_ids, source_feature_ids, payload.merge, "PatternFeature"
    )

    feature = PatternFeature(
        id=str(uuid.uuid4()),
        source_body_ids=source_body_ids,
        source_feature_ids=source_feature_ids,
        pattern_type=payload.pattern_type,
        direction_1=direction_1,
        count_1=payload.count_1,
        spacing_1=payload.spacing_1,
        reverse_1=payload.reverse_1,
        direction_2=direction_2,
        count_2=payload.count_2,
        spacing_2=payload.spacing_2,
        reverse_2=payload.reverse_2,
        axis=axis,
        count_angular=payload.count_angular,
        angle_total=payload.angle_total,
        reverse_angular=payload.reverse_angular,
        skip_indices=list(payload.skip_indices),
        merge=payload.merge,
        tool_feature_id=payload.tool_feature_id,
    )
    resolve_pattern(part, feature)  # raises on an unresolvable reference; result unused here
    part.add_feature(feature)
    return _feature_response(part, feature)


@router.post("/parts/{part_id}/pattern-features/coarse-preview", response_model=list[BodyMeshResponse])
def preview_pattern_feature_coarse(
    part_id: str, payload: PatternFeatureCreate, quality: float | None = Query(default=None, ge=0.0, le=1.0)
) -> list[BodyMeshResponse]:
    """`docs/lod-strategy/01-design.md` SS4: the 3D coarse analogue of
    `create_pattern_feature`, for a not-yet-created `PatternFeature`
    payload - every instance realized via the same rigid-transform
    placement the real construction uses, but never fused
    (`app.document.pattern.resolve_pattern_coarse`) - instead of the full
    fuse-chain construction `merge == MergeMode.FUSE_INTO_ONE`/
    `tool_feature_id` would otherwise require. Mirrors `create_pattern_
    feature`'s own validate-then-build shape exactly (same scratch
    Feature, same payload validation), but never calls `part.add_feature` -
    nothing is persisted, no Feature is created, no Part state changes."""
    part = get_part_or_404(part_id)
    mesh_quality = DEFAULT_MESH_QUALITY if quality is None else mesh_quality_from_slider(quality)
    source_body_ids = list(payload.source_body_ids)
    source_feature_ids = list(payload.source_feature_ids)
    direction_1 = (
        _pattern_direction_ref_to_domain(payload.direction_1) if payload.direction_1 is not None else None
    )
    direction_2 = (
        _pattern_direction_ref_to_domain(payload.direction_2) if payload.direction_2 is not None else None
    )
    axis = _pattern_axis_ref_to_domain(payload.axis) if payload.axis is not None else None
    _validate_pattern_source_body_ids(part, source_body_ids, source_feature_ids, payload.tool_feature_id)
    _validate_pattern_payload(
        payload.pattern_type,
        direction_1,
        payload.count_1,
        payload.count_2,
        direction_2,
        axis,
        payload.count_angular,
        payload.angle_total,
        payload.skip_indices,
    )
    _validate_tool_feature_id(
        part, payload.tool_feature_id, source_body_ids, source_feature_ids, payload.merge, "PatternFeature"
    )

    feature = PatternFeature(
        id=str(uuid.uuid4()),
        source_body_ids=source_body_ids,
        source_feature_ids=source_feature_ids,
        pattern_type=payload.pattern_type,
        direction_1=direction_1,
        count_1=payload.count_1,
        spacing_1=payload.spacing_1,
        reverse_1=payload.reverse_1,
        direction_2=direction_2,
        count_2=payload.count_2,
        spacing_2=payload.spacing_2,
        reverse_2=payload.reverse_2,
        axis=axis,
        count_angular=payload.count_angular,
        angle_total=payload.angle_total,
        reverse_angular=payload.reverse_angular,
        skip_indices=list(payload.skip_indices),
        merge=payload.merge,
        tool_feature_id=payload.tool_feature_id,
    )
    shape = resolve_pattern_coarse(part, feature)  # raises on an unresolvable reference
    return _coarse_preview_response(shape, mesh_quality)


def _get_pattern_feature_or_404(part: Part, feature_id: str) -> PatternFeature:
    feature = part.get_feature(feature_id)
    if not isinstance(feature, PatternFeature):
        raise HTTPException(status_code=404, detail="Pattern feature not found")
    return feature


@router.patch("/parts/{part_id}/pattern-features/{feature_id}", response_model=PatternFeatureResponse)
def update_pattern_feature(
    part_id: str, feature_id: str, payload: PatternFeatureUpdate
) -> PatternFeatureResponse:
    """Mirrors `update_mirror_feature`'s exact shape - same validate-before-
    mutate discipline against a scratch Feature sharing the real one's id.
    `pattern_type` itself is never revised (see `PatternFeatureUpdate`'s
    own docstring - switching Rectangular <-> Circular is a delete+
    recreate), so `_validate_pattern_payload` is always called with the
    Feature's own existing, unchangeable `pattern_type`."""
    part = get_part_or_404(part_id)
    feature = _get_pattern_feature_or_404(part, feature_id)

    new_source_body_ids = (
        list(payload.source_body_ids) if payload.source_body_ids is not None else feature.source_body_ids
    )
    new_source_feature_ids = (
        list(payload.source_feature_ids)
        if payload.source_feature_ids is not None
        else feature.source_feature_ids
    )
    new_direction_1 = (
        _pattern_direction_ref_to_domain(payload.direction_1)
        if payload.direction_1 is not None
        else feature.direction_1
    )
    new_count_1 = payload.count_1 if payload.count_1 is not None else feature.count_1
    new_spacing_1 = payload.spacing_1 if payload.spacing_1 is not None else feature.spacing_1
    new_reverse_1 = payload.reverse_1 if payload.reverse_1 is not None else feature.reverse_1
    new_direction_2 = (
        _pattern_direction_ref_to_domain(payload.direction_2)
        if payload.direction_2 is not None
        else feature.direction_2
    )
    new_count_2 = payload.count_2 if payload.count_2 is not None else feature.count_2
    new_spacing_2 = payload.spacing_2 if payload.spacing_2 is not None else feature.spacing_2
    new_reverse_2 = payload.reverse_2 if payload.reverse_2 is not None else feature.reverse_2
    new_axis = _pattern_axis_ref_to_domain(payload.axis) if payload.axis is not None else feature.axis
    new_count_angular = (
        payload.count_angular if payload.count_angular is not None else feature.count_angular
    )
    new_angle_total = payload.angle_total if payload.angle_total is not None else feature.angle_total
    new_reverse_angular = (
        payload.reverse_angular if payload.reverse_angular is not None else feature.reverse_angular
    )
    new_skip_indices = (
        list(payload.skip_indices) if payload.skip_indices is not None else feature.skip_indices
    )
    new_merge = payload.merge if payload.merge is not None else feature.merge
    # Phase 8 (§2.11): mirrors `update_mirror_feature`'s own identical
    # omitted-vs-current convention - see that function's own doc comment.
    new_tool_feature_id = (
        payload.tool_feature_id if payload.tool_feature_id is not None else feature.tool_feature_id
    )

    _validate_pattern_source_body_ids(
        part, new_source_body_ids, new_source_feature_ids, new_tool_feature_id
    )
    _validate_pattern_payload(
        feature.pattern_type,
        new_direction_1,
        new_count_1,
        new_count_2,
        new_direction_2,
        new_axis,
        new_count_angular,
        new_angle_total,
        new_skip_indices,
    )
    _validate_tool_feature_id(
        part, new_tool_feature_id, new_source_body_ids, new_source_feature_ids, new_merge, "PatternFeature"
    )

    candidate = PatternFeature(
        id=feature.id,
        source_body_ids=new_source_body_ids,
        source_feature_ids=new_source_feature_ids,
        pattern_type=feature.pattern_type,
        direction_1=new_direction_1,
        count_1=new_count_1,
        spacing_1=new_spacing_1,
        reverse_1=new_reverse_1,
        direction_2=new_direction_2,
        count_2=new_count_2,
        spacing_2=new_spacing_2,
        reverse_2=new_reverse_2,
        axis=new_axis,
        count_angular=new_count_angular,
        angle_total=new_angle_total,
        reverse_angular=new_reverse_angular,
        skip_indices=new_skip_indices,
        merge=new_merge,
        tool_feature_id=new_tool_feature_id,
    )
    resolve_pattern(part, candidate)  # raises on an unresolvable reference

    feature.source_body_ids = candidate.source_body_ids
    feature.source_feature_ids = candidate.source_feature_ids
    feature.direction_1 = candidate.direction_1
    feature.count_1 = candidate.count_1
    feature.spacing_1 = candidate.spacing_1
    feature.reverse_1 = candidate.reverse_1
    feature.direction_2 = candidate.direction_2
    feature.count_2 = candidate.count_2
    feature.spacing_2 = candidate.spacing_2
    feature.reverse_2 = candidate.reverse_2
    feature.axis = candidate.axis
    feature.count_angular = candidate.count_angular
    feature.angle_total = candidate.angle_total
    feature.reverse_angular = candidate.reverse_angular
    feature.skip_indices = candidate.skip_indices
    feature.merge = candidate.merge
    feature.tool_feature_id = candidate.tool_feature_id
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


@router.get(
    "/parts/{part_id}/features/{feature_id}/cascade-preview",
    response_model=CascadeDeletePreviewResponse,
)
def preview_cascade_delete(part_id: str, feature_id: str) -> CascadeDeletePreviewResponse:
    """On-device feedback: read-only preview of exactly what `DELETE .../
    cascade` above would remove - the same `transitive_dependents` call,
    mutating nothing - so a confirmation dialog can name the real Features
    at risk instead of the stale "everything after this one in the list"
    assumption the client used to make on its own (see `CascadeDeletePreviewResponse`'s
    own docstring)."""
    part = get_part_or_404(part_id)
    _get_feature_or_404(part, feature_id)
    to_delete = transitive_dependents(build_feature_graph(part), feature_id)
    return CascadeDeletePreviewResponse(feature_ids=[f.id for f in part.features if f.id in to_delete])


@router.post("/parts/{part_id}/ai-plan/validate", response_model=PlanValidateResponse)
def validate_ai_plan(part_id: str, payload: PlanValidateRequest) -> PlanValidateResponse:
    """AI Modelling workstream 5 (docs/ai-modelling/05-backend-plan-
    validation.md): given a real, currently-stored Part and a hypothetical
    list of *next* steps (workstream 3's locked plan schema, see
    `app.document.ai_plan_schemas`), reports whether each would resolve
    successfully - without creating or persisting anything against this
    Part. A plain, ordinary compute-only endpoint of the same kind this
    backend already has plenty of (`/gear/preview`, `cascade-preview`
    above), not part of the client-direct AI call itself (see
    docs/ai-modelling/00-conventions.md)."""
    part = get_part_or_404(part_id)
    results = validate_ai_plan_steps(part, payload.steps)
    return PlanValidateResponse(results=results)


@router.get("/parts/{part_id}/mesh", response_model=list[BodyMeshResponse])
def get_part_mesh(
    part_id: str,
    hidden_feature_ids: list[str] = Query(default=[]),
    rollback_excluded_feature_ids: list[str] = Query(default=[]),
    quality: float | None = Query(default=None, ge=0.0, le=1.0),
    tier: Literal["full", "coarse"] = Query(default="full"),
) -> list[BodyMeshResponse]:
    """A1: returns an array of Bodies rather than one combined mesh - each
    entry is one independently-tessellated Body, carrying its own stable
    `body_id` (see app.document.models.ExtrudeFeature's docstring) and its
    own `face_ids`/`edge_ids`/`topology_vertex_ids`, scoped to that Body's
    own tessellation only (not globally unique across the array).

    Placeholder mesh (a fixed box, `body_id="placeholder"`) while the Part
    has no displayable geometry yet, per `Part.produces_displayable_
    geometry` (any Feature that yields a real solid Body *or* a non-solid
    Surface) - always exactly one entry in that case. Once it does, this
    instead recomputes
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
    re-sends whichever apply on every mesh fetch.

    `quality`: the 3D viewport's own Polygon Resolution slider (hamburger
    menu > View > Polygon Resolution, same bottom-sheet-slider UX as Body
    Transparency) - 0.0 (coarsest, fewest triangles) .. 1.0 (finest, most),
    mapped onto real OCCT tessellation tolerances by
    `app.document.mesh_data.mesh_quality_from_slider`. `None` (the default -
    every pre-existing call site, including every test, that never sends
    this param at all) keeps using `DEFAULT_MESH_QUALITY` completely
    unparameterized, so this is purely additive: no existing behavior
    changes unless a client actually opts in by sending a value.

    `tier` (`docs/lod-strategy/01-design.md` SS4): `"full"` (the default -
    every pre-existing call site, unchanged) is everything above. `"coarse"`
    instead returns `BodyMeshResponse`s built from `app.document.extrude.
    compute_part_bodies_coarse` (a cheap real-OCCT primitive - a cylinder or
    cone - standing in for a Gear/BevelGear/BevelPair/GearChain/
    PlanetaryGear Feature's own real construction), filtered down to only
    the Bodies a coarse-eligible Feature produced (`coarse_eligible_
    feature_ids`) and tagged `source="coarse"` - every other Body (an
    Extrude, say, with no coarse builder of its own yet) is left out of a
    `tier="coarse"` response entirely rather than re-served unchanged; a
    client wanting the rest already has (or is concurrently fetching) the
    real `tier="full"` response. `hidden_feature_ids`/`rollback_excluded_
    feature_ids` still apply identically. Never persisted, never affects
    `part`'s own stored state - a pure rendering-layer stand-in, computed
    fresh on every call.

    Known, narrow limitation (a pre-existing ambiguity in this app's own
    Body-identity model, not introduced by this filter): a Gear/BevelGear
    Feature whose `target_body_ids` is non-empty (bossed/cut into an
    already-existing Body rather than starting a new standalone one)
    inherits that existing Body's own id (`_apply_boss_or_cut`'s survivor-
    id tie-break), not its own feature id - `coarse_eligible_feature_ids`'s
    `base_feature_id` lookup then attributes that Body to whichever earlier
    Feature it merged into, not to the Gear/BevelGear itself, so it is
    left out of a `tier="coarse"` response in that specific case. The
    common case (an empty `target_body_ids` - a gear/bevel gear that mints
    its own standalone Body) is unaffected."""
    part = get_part_or_404(part_id)
    mesh_quality = DEFAULT_MESH_QUALITY if quality is None else mesh_quality_from_slider(quality)

    if not part.produces_displayable_geometry:
        box = BRepPrimAPI_MakeBox(10.0, 10.0, 10.0).Shape()
        mesh_data = tessellate_shape(box, mesh_quality)
        return [
            BodyMeshResponse(
                body_id=_PLACEHOLDER_BODY_ID, source="placeholder", mesh=_mesh_vertex_data(mesh_data)
            )
        ]

    hidden = frozenset(hidden_feature_ids)

    if tier == "coarse":
        rollback_excluded = frozenset(rollback_excluded_feature_ids)
        coarse_eligible = coarse_eligible_feature_ids(part)
        bodies = compute_part_bodies_coarse(part, rollback_excluded)
        return [
            BodyMeshResponse(
                body_id=body_id,
                source="coarse",
                mesh=_mesh_vertex_data(tessellate_shape(shape, mesh_quality)),
                hidden=base_feature_id(body_id) in hidden,
            )
            for body_id, shape in bodies.items()
            if base_feature_id(body_id) in coarse_eligible
        ]

    bodies = compute_part_bodies(part, frozenset(rollback_excluded_feature_ids))
    return [
        BodyMeshResponse(
            body_id=body_id,
            source="computed",
            mesh=_mesh_vertex_data(tessellate_shape(shape, mesh_quality)),
            hidden=base_feature_id(body_id) in hidden,
            is_surface=isinstance(part.get_feature(base_feature_id(body_id)), SurfaceFeature),
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
    each format silently emitting an empty/invalid file. Shares `/mesh`'s
    own `produces_displayable_geometry` gate (not `produces_solid_
    geometry`) so a Surface-only Part - which has the same real,
    tessellatable-but-not-solid geometry - can be exported too, same as it
    can now be viewed."""
    if not part.produces_displayable_geometry:
        raise HTTPException(status_code=400, detail="Part has no geometry to export")
    bodies = compute_part_bodies(part)
    if not bodies:
        raise HTTPException(status_code=400, detail="Part has no geometry to export")
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
