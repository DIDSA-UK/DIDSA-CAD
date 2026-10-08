import base64
import binascii
import dataclasses
import logging
import math
import time
import uuid
from typing import Literal

from fastapi import APIRouter, Depends, HTTPException, Query, Response
from OCC.Core.BRepPrimAPI import BRepPrimAPI_MakeBox
from OCC.Core.TopoDS import TopoDS_Shape

from app.document.ai_plan import validate_ai_plan as validate_ai_plan_steps
from app.document.ai_plan_schemas import PlanValidateRequest, PlanValidateResponse
from app.document.assembly import compose_chain, expand_component_pattern_instances
from app.document.assembly_group import GroupSolveResult, solve_group
from app.document.assembly_solver import _quaternion_from_axis_angle
from app.document.bevel_pair import resolve_member_profile_shifts
from app.document.chamfer import resolve_chamfer
from app.document.jobs import JobStatus, cancel_job, get_job
from app.document.reference_history import history_for_part
from app.document.subshape_identity import refresh_feature_subshape_refs
from app.document.create_plane import (
    basis_for_sketch,
    capture_external_reference,
    make_circle_centre_reference,
    make_external_vertex_reference,
    refresh_external_references,
    resolve_create_plane,
    resolve_external_vertex_position,
)
from app.document.extrude import (
    _register_solids,
    apply_rigid_transform_to_shape,
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
from app.document.measure import MeasurementResult, mass_properties as compute_mass_properties, measure as compute_measurement
from app.document.gear import resolve_gear, resolve_gear_profile_shift
from app.document.gear_math import GearGeometryError
from app.document.gear_chain_math import ChainStageSpec
from app.document.bevel_math import pitch_cone_half_angles
from app.document.loft import loft_seam_handles, resolve_loft, resolve_loft_coarse
from app.document.loft_surface import resolve_loft_surface
from app.document.planar_surface import resolve_planar_surface
from app.document.revolve_surface import resolve_revolve_surface
from app.document.ruled_surface import resolve_ruled_surface
from app.document.swept_surface import resolve_swept_surface
from app.document.gear_chain import resolve_gear_chain
from app.document.graph import (
    base_feature_id,
    build_feature_graph,
    excluded_feature_ids_after,
    resolve_feature_produces,
    tool_feature_qualifies,
    transitive_dependents,
)
from app.document.import_geometry import extract_step_metadata, resolve_import
from app.document.mesh import DEFAULT_MESH_QUALITY, MeshData, mesh_quality_from_slider, tessellate_shape
from app.document.mesh_data import BodyTopology, MeshQuality, Triangle
from app.document.mesh_export import AssemblyGlbInstance, encode_assembly_glb, encode_glb, encode_obj, encode_stl
from app.document.mirror import resolve_mirror
from app.document.add_component import AddComponentError, merge_component_into_document
from app.document.native_format import NativeFormatError, export_native, import_native
from app.document.pattern import resolve_pattern, resolve_pattern_coarse
from app.document.step_export import export_step
from app.document.models import (
    BevelGearFeature,
    BevelPairFeature,
    BevelPairMemberSpec,
    BooleanFeature,
    ChamferEdgeOptions,
    ChamferFeature,
    ComponentPattern,
    ComponentPatternAxis,
    ComponentPatternType,
    CreatePlaneFeature,
    CurveFeature,
    CurveType,
    DeleteBodyFeature,
    DeleteFaceFeature,
    Document,
    ExtrudeFeature,
    ExtrudeType,
    Feature,
    FillSurfaceFeature,
    FilletFeature,
    FixedAxis,
    GearChainFeature,
    GearChainMemberSpec,
    GearChainMemberType,
    GearChainStage,
    GearFeature,
    GearGroup,
    ImportFeature,
    ImportSourceFormat,
    KnitSurfaceFeature,
    LoftFeature,
    LoftMode,
    LoftSection,
    LoftSurfaceFeature,
    MaterialAssignment,
    Mate,
    MateEntityRef,
    MeasureEntityRef,
    MateType,
    MergeFeature,
    MergeMode,
    MirrorFeature,
    MoveBodyFeature,
    MoveFaceFeature,
    Occurrence,
    OffsetSourceRef,
    OffsetSurfaceFeature,
    Part,
    PatternAxisRef,
    PatternDirectionRef,
    PatternFeature,
    PatternType,
    PlanarSurfaceFeature,
    PlanetaryGearFeature,
    PlaneRef,
    PlaneType,
    PointRef,
    Produces,
    RackFeature,
    RevolveFeature,
    RevolveMode,
    RevolveSurfaceFeature,
    RigidTransform,
    RuledSurfaceFeature,
    ScaleBodyFeature,
    ShellFeature,
    SketchFeature,
    SketchOrEdgeRef,
    SolidFromSurfacesFeature,
    SplitFeature,
    SplitToolRef,
    SubShapeRef,
    SubShapeType,
    SurfaceFeature,
    SweepFeature,
    SweepMode,
    SweptSurfaceFeature,
    ThickenFeature,
)
from app.document.revolve import resolve_revolve
from app.document.curve import resolve_curve
from app.document.delete_face import resolve_delete_face
from app.document.fill_surface import resolve_fill_surface
from app.document.knit_surface import resolve_knit_surface
from app.document.move_body import resolve_move_body
from app.document.move_face import resolve_move_face
from app.document.offset_surface import resolve_offset_surface
from app.document.scale_body import resolve_scale_body
from app.document.shell import resolve_shell
from app.document.solid_from_surfaces import resolve_solid_from_surfaces
from app.document.thicken import resolve_thicken
from app.document.face_reference import classify_face, face_axis, face_line
from app.document.schemas import (
    BevelGearFeatureResponse,
    BevelPairFeatureResponse,
    JobCancelResponse,
    JobStatusResponse,
    BevelPairMemberSpecSchema,
    AddComponentRequest,
    AddComponentResponse,
    AssemblyBodyGeometry,
    AssemblyMeshResponse,
    AssemblyOccurrenceInstance,
    ComponentPatternAxisSchema,
    ComponentPatternCreate,
    ComponentPatternDirectionFromRefRequest,
    ComponentPatternDirectionFromRefResponse,
    ComponentPatternResponse,
    ComponentPatternUpdate,
    MateCreate,
    MateEntityRefResponse,
    MateResponse,
    MateMotionChart,
    MateMotionDiagnostics,
    MateMotionMember,
    MateMotionQuality,
    MateMotionRequest,
    MateMotionResponse,
    MateSolvePreviewResponse,
    MateUpdate,
    OccurrenceCreate,
    OccurrenceResponse,
    OccurrenceTransformUpdate,
    RigidTransformResponse,
    BodyMeshResponse,
    BooleanFeatureCreate,
    BooleanFeatureResponse,
    BooleanFeatureUpdate,
    CascadeDeletePreviewResponse,
    CascadeDeleteResponse,
    ChamferEdgeOptionsSchema,
    ChamferFeatureCreate,
    ChamferFeatureResponse,
    ChamferFeatureUpdate,
    ConvertEdgeCreate,
    ConvertEdgeResponse,
    ConvertFaceCreate,
    ConvertFaceResponse,
    ConvertVertexCreate,
    CreatePlaneFeatureCreate,
    CreatePlaneFeatureResponse,
    CreatePlaneFeatureUpdate,
    CurveFeatureCreate,
    CurveFeatureResponse,
    CurveFeatureUpdate,
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
    MeasureEntityRefSchema,
    MeasureRequest,
    MeasurementResultSchema,
    ScaleBodyFeatureCreate,
    ScaleBodyFeatureResponse,
    ScaleBodyFeatureUpdate,
    ShellFeatureCreate,
    ShellFeatureResponse,
    ShellFeatureUpdate,
    ExternalEdgeReferenceResponse,
    ExternalEdgeReattach,
    ExternalReferenceReattach,
    ExternalReferenceStatus,
    ExternalVertexReferenceCreate,
    ExtrudeFeatureCreate,
    ExtrudeFeatureResponse,
    ExtrudeFeatureUpdate,
    FeatureResponse,
    FillSurfaceFeatureCreate,
    FillSurfaceFeatureResponse,
    FillSurfaceFeatureUpdate,
    FilletFeatureCreate,
    FilletFeatureResponse,
    FilletFeatureUpdate,
    GearChainFeatureResponse,
    GearChainMemberSpecSchema,
    GearChainStageSchema,
    GearFeatureResponse,
    GearGroupSchema,
    ImportFeatureCreate,
    ImportFeatureResponse,
    KnitSurfaceFeatureCreate,
    KnitSurfaceFeatureResponse,
    KnitSurfaceFeatureUpdate,
    LoftFeatureCreate,
    LoftFeatureResponse,
    LoftSeamHandleSchema,
    LoftFeatureUpdate,
    LoftSectionSchema,
    LoftSurfaceFeatureCreate,
    LoftSurfaceFeatureResponse,
    LoftSurfaceFeatureUpdate,
    MergeFeatureCreate,
    MergeFeatureResponse,
    MergeFeatureUpdate,
    MeshVertexData,
    MirrorFeatureCreate,
    MirrorFeatureResponse,
    MirrorFeatureUpdate,
    NativeImportResponse,
    MassPropertiesResponse,
    MaterialAssignmentSchema,
    MaterialAssignmentUpdate,
    OffsetSourceRefSchema,
    OffsetSurfaceFeatureCreate,
    OffsetSurfaceFeatureResponse,
    OffsetSurfaceFeatureUpdate,
    PartCreate,
    PartResponse,
    PartUpdate,
    PatternAxisRefSchema,
    PatternDirectionRefSchema,
    PatternFeatureCreate,
    PatternFeatureResponse,
    PatternFeatureUpdate,
    PlanarSurfaceFeatureCreate,
    PlanarSurfaceFeatureResponse,
    PlanarSurfaceFeatureUpdate,
    PlanetaryGearFeatureResponse,
    PlaneRefSchema,
    PointRefSchema,
    RackFeatureResponse,
    RevolveFeatureCreate,
    RevolveFeatureResponse,
    RevolveFeatureUpdate,
    RevolveSurfaceFeatureCreate,
    RevolveSurfaceFeatureResponse,
    RevolveSurfaceFeatureUpdate,
    RuledSurfaceFeatureCreate,
    RuledSurfaceFeatureResponse,
    RuledSurfaceFeatureUpdate,
    RuledSurfaceSectionSchema,
    SectionBodyMeshResponse,
    SectionPreviewRequest,
    SketchEntityRefSchema,
    SketchFeatureCreate,
    SketchFeatureResponse,
    SketchOrEdgeRefSchema,
    SolidFromSurfacesFeatureCreate,
    SolidFromSurfacesFeatureResponse,
    SolidFromSurfacesFeatureUpdate,
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
    SweptSurfaceFeatureCreate,
    SweptSurfaceFeatureResponse,
    SweptSurfaceFeatureUpdate,
    ThickenFeatureCreate,
    ThickenFeatureResponse,
    ThickenFeatureUpdate,
)
from app.document.section import SectionBodyTarget, SectionPlaneSpec, compute_section_mesh
from app.document.split import CONNECTABLE_CURVE_ENTITY_TYPES, resolve_split
from app.document.sweep import resolve_sweep
from app.document.store import get_document, get_part_or_404, replace_document
from app.session_context import bind_session_id
from app.sketch.models import ExternalVertexReference, Plane, SketchEntityRef, SketchEntityType
from app.sketch.reference_signature import ReferenceStatus
from app.sketch.profile import Profile, ProfileStatus, detect_profile
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


def _material_assignment_to_schema(assignment: MaterialAssignment) -> MaterialAssignmentSchema:
    return MaterialAssignmentSchema(
        material_id=assignment.material_id, name=assignment.name, density_g_cm3=assignment.density_g_cm3
    )


def _material_assignment_to_domain(schema: MaterialAssignmentSchema) -> MaterialAssignment:
    return MaterialAssignment(
        material_id=schema.material_id, name=schema.name, density_g_cm3=schema.density_g_cm3
    )


def _part_response(part: Part) -> PartResponse:
    return PartResponse(
        id=part.id,
        name=part.name,
        feature_ids=[f.id for f in part.features],
        occurrence_ids=[o.id for o in part.occurrences],
        mate_ids=[m.id for m in part.mates],
        component_pattern_ids=[p.id for p in part.component_patterns],
        part_number=part.part_number,
        description=part.description,
        revision=part.revision,
        remarks=part.remarks,
        supplier=part.supplier,
        supplier_part_number=part.supplier_part_number,
        default_material=(
            _material_assignment_to_schema(part.default_material) if part.default_material is not None else None
        ),
        body_material_assignments={
            body_id: _material_assignment_to_schema(assignment)
            for body_id, assignment in part.body_material_assignments.items()
        },
    )


def _subshape_ref_to_domain(schema: SubShapeRefSchema) -> SubShapeRef:
    return SubShapeRef(body_id=schema.body_id, shape_type=schema.shape_type, index=schema.index)


def _subshape_ref_to_schema(ref: SubShapeRef) -> SubShapeRefSchema:
    return SubShapeRefSchema(body_id=ref.body_id, shape_type=ref.shape_type, index=ref.index)


def _chamfer_edge_options_to_domain(
    options: dict[int, ChamferEdgeOptionsSchema],
) -> dict[int, ChamferEdgeOptions]:
    return {
        i: ChamferEdgeOptions(
            face_ref=_subshape_ref_to_domain(opts.face_ref) if opts.face_ref is not None else None,
            angle=opts.angle,
            flip=opts.flip,
        )
        for i, opts in options.items()
    }


def _chamfer_edge_options_to_schema(
    options: dict[int, ChamferEdgeOptions],
) -> dict[int, ChamferEdgeOptionsSchema]:
    return {
        i: ChamferEdgeOptionsSchema(
            face_ref=_subshape_ref_to_schema(opts.face_ref) if opts.face_ref is not None else None,
            angle=opts.angle,
            flip=opts.flip,
        )
        for i, opts in sorted(options.items())
    }


def _measure_entity_ref_to_domain(schema: MeasureEntityRefSchema) -> MeasureEntityRef:
    return MeasureEntityRef(occurrence_id=schema.occurrence_id, subshape_ref=_subshape_ref_to_domain(schema.subshape_ref))


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
        edge_ref=_subshape_ref_to_domain(schema.edge_ref) if schema.edge_ref else None,
        seam_param=schema.seam_param,
        reverse=schema.reverse,
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
        edge_ref=_subshape_ref_to_schema(section.edge_ref) if section.edge_ref else None,
        seam_param=section.seam_param,
        reverse=section.reverse,
    )


def _validate_loft_section_shape(sections: list[LoftSection], index_offset: int = 0) -> None:
    """On-device feedback ("loft between two edges or edge and sketch
    line"): payload-shape validation for `LoftFeature`/`LoftSurfaceFeature`/
    `RuledSurfaceFeature.sections` - each entry sets exactly one of
    `sketch_feature_id` or `edge_ref` (mirrors `SketchOrEdgeRef`'s own
    "exactly one of two" convention, just spread across `LoftSection`'s
    existing fields rather than one wrapper field, since a section carries
    several other Sketch-only fields alongside its source). An `edge_ref`
    section has no Sketch basis of its own for `reference_point`'s
    rotation or `alignment_point`'s translation to work against - see
    `LoftSection`'s own docstring - so both, and `profile_refs`, must be
    left unset there too."""
    for index, section in enumerate(sections, start=index_offset):
        if (section.sketch_feature_id is None) == (section.edge_ref is None):
            raise HTTPException(
                status_code=400,
                detail=f"sections[{index}] must set exactly one of sketch_feature_id or edge_ref",
            )
        if section.edge_ref is not None and (
            section.profile_refs
            or section.reference_point is not None
            or section.alignment_point is not None
            or section.seam_param is not None
            or section.reverse
        ):
            raise HTTPException(
                status_code=400,
                detail=(
                    f"sections[{index}] is edge_ref-based and cannot also set "
                    "profile_refs/reference_point/alignment_point/seam_param/reverse"
                ),
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


def _sketch_or_edge_ref_to_domain(schema: SketchOrEdgeRefSchema) -> SketchOrEdgeRef:
    """`SketchOrEdgeRefSchema`'s flat `sketch_id`/`entity_type`/`entity_id`
    fields (see its own doc comment for why they're flat, not nested)
    become a real `SketchEntityRef` here - only past this conversion does
    the domain layer see `SketchOrEdgeRef`'s clean two-nested-field shape.
    Neither-set (a malformed payload) becomes a `SketchOrEdgeRef` with
    both fields `None`, caught by `_validate_sketch_or_edge_refs` right
    after this runs at every call site - never reaches `resolve_path_wire`."""
    if schema.curve_feature_id is not None:
        return SketchOrEdgeRef(curve_feature_id=schema.curve_feature_id)
    if schema.edge_ref is not None:
        return SketchOrEdgeRef(edge_ref=_subshape_ref_to_domain(schema.edge_ref))
    if schema.sketch_id is not None and schema.entity_type is not None and schema.entity_id is not None:
        return SketchOrEdgeRef(
            sketch_entity_ref=SketchEntityRef(
                sketch_id=schema.sketch_id, entity_type=schema.entity_type, entity_id=schema.entity_id
            )
        )
    return SketchOrEdgeRef()


def _sketch_or_edge_ref_to_schema(ref: SketchOrEdgeRef) -> SketchOrEdgeRefSchema:
    if ref.curve_feature_id is not None:
        return SketchOrEdgeRefSchema(curve_feature_id=ref.curve_feature_id)
    if ref.edge_ref is not None:
        return SketchOrEdgeRefSchema(edge_ref=_subshape_ref_to_schema(ref.edge_ref))
    assert ref.sketch_entity_ref is not None
    return SketchOrEdgeRefSchema(
        sketch_id=ref.sketch_entity_ref.sketch_id,
        entity_type=ref.sketch_entity_ref.entity_type,
        entity_id=ref.sketch_entity_ref.entity_id,
    )


def _validate_sketch_or_edge_refs(refs: list[SketchOrEdgeRef]) -> None:
    """Payload-shape validation for a `list[SketchOrEdgeRef]` (Sweep/Swept-
    Surface `path_refs`, Loft/Loft-Surface `guide_curve_refs`, Fill Surface
    `boundary_refs`) - each entry must set exactly one of `sketch_entity_
    ref`/`edge_ref`/`curve_feature_id`, mirroring `PointRef`'s identical
    "exactly one of N" convention and its own validation site (`_validate_
    create_plane_payload`)."""
    for index, ref in enumerate(refs):
        set_count = sum(
            1 for value in (ref.sketch_entity_ref, ref.edge_ref, ref.curve_feature_id) if value is not None
        )
        if set_count != 1:
            raise HTTPException(
                status_code=400,
                detail=(
                    f"path_refs[{index}] must set exactly one of "
                    "sketch_entity_ref, edge_ref, or curve_feature_id"
                ),
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


def _offset_source_ref_to_domain(schema: OffsetSourceRefSchema) -> OffsetSourceRef:
    return OffsetSourceRef(
        face_ref=_subshape_ref_to_domain(schema.face_ref) if schema.face_ref else None,
        surface_feature_id=schema.surface_feature_id,
    )


def _offset_source_ref_to_schema(ref: OffsetSourceRef) -> OffsetSourceRefSchema:
    return OffsetSourceRefSchema(
        face_ref=_subshape_ref_to_schema(ref.face_ref) if ref.face_ref else None,
        surface_feature_id=ref.surface_feature_id,
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
        curve_feature_id=feature.curve_feature_id,
        curve_parameter=feature.curve_parameter,
        origin=origin,
        normal=normal,
        x_axis=x_axis,
        y_axis=y_axis,
        locked=part.is_locked(feature.id),
        produces=feature.produces,
    )


def _curve_feature_response(part: Part, feature: CurveFeature) -> CurveFeatureResponse:
    """Mirrors `_create_plane_feature_response`'s own soft-fail-on-read
    convention exactly: `length`/`closed` are resolved live on every read,
    `None` (rather than a raised 500) if `feature` has since become
    unresolvable (a Helix's `axis_ref` or an Intersection curve's own
    Sketch was deleted out from under it) - real validation still happens
    at create/update time (`_validate_curve_payload` plus an explicit
    `resolve_curve` call)."""
    try:
        resolved = resolve_curve(part, feature, excluded_feature_ids_after(part, feature.id))
        length, closed = resolved.length, resolved.closed
    except HTTPException:
        logger.warning("CurveFeature %s could not be resolved for its response", feature.id)
        length, closed = None, None
    return CurveFeatureResponse(
        id=feature.id,
        curve_type=feature.curve_type,
        axis_ref=_plane_ref_to_schema(feature.axis_ref) if feature.axis_ref else None,
        radius=feature.radius,
        pitch=feature.pitch,
        turns=feature.turns,
        right_handed=feature.right_handed,
        sketch_feature_id_a=feature.sketch_feature_id_a,
        profile_refs_a=[_sketch_entity_ref_to_schema(ref) for ref in feature.profile_refs_a],
        sketch_feature_id_b=feature.sketch_feature_id_b,
        profile_refs_b=[_sketch_entity_ref_to_schema(ref) for ref in feature.profile_refs_b],
        length=length,
        closed=closed,
        locked=part.is_locked(feature.id),
        produces=feature.produces,
    )


def _fill_surface_feature_response(part: Part, feature: FillSurfaceFeature) -> FillSurfaceFeatureResponse:
    return FillSurfaceFeatureResponse(
        id=feature.id,
        boundary_refs=[_sketch_or_edge_ref_to_schema(ref) for ref in feature.boundary_refs],
        locked=part.is_locked(feature.id),
        produces=feature.produces,
    )


def _sketch_reference_state(part: Part, feature: SketchFeature) -> dict:
    """Sketcher-roadmap Phase 4.3 v1, widened by the reference-identity overhaul (docs/reference-identity-design.md): the state of `feature`'s own
    Sketch `external_references` against the Part's *current* Bodies, as the kwargs `SketchFeatureResponse` takes: `has_lost_reference` plus the Point
    ids that are lost, potentially moved and (informationally) re-followed, and a reason per flagged id. Same soft-fail-without-raising story as
    `_create_plane_feature_response`'s own `origin`/`normal` resolution: any failure (an unresolvable reference, or the Part's Bodies failing to compute
    at all for an unrelated reason) is treated as "lost" rather than propagating and failing the whole `GET .../features` list. Short-circuits without
    touching OCCT at all for the common case (a Sketch with no external references).

    Bug fix: resolves (and, via `refresh_external_references`, persists) each external reference against `excluded_feature_ids_after`'s own
    causally-consistent snapshot rather than the Part's fully-built one - see that helper's own docstring for the full "why"."""
    sketch = all_sketches().get(feature.sketch_id)
    if sketch is None or not sketch.external_references:
        return {"has_lost_reference": False}
    try:
        excluded = excluded_feature_ids_after(part, feature.id)
        bodies = compute_part_bodies(part, excluded)
        lost_point_ids = refresh_external_references(part, sketch, bodies, excluded, history=history_for_part(part, excluded))
    except HTTPException:
        logger.warning("SketchFeature %s could not refresh its external references", feature.id)
        return {
            "has_lost_reference": True,
            "lost_reference_point_ids": list(sketch.external_references),
            "reference_reasons": {point_id: "refresh_failed" for point_id in sketch.external_references},
        }
    decisions = sketch.external_reference_decisions
    moved = [pid for pid, d in decisions.items() if d.status == ReferenceStatus.POTENTIALLY_MOVED]
    followed = [pid for pid, d in decisions.items() if d.status == ReferenceStatus.FOLLOWED]
    return {
        "has_lost_reference": bool(lost_point_ids),
        "lost_reference_point_ids": lost_point_ids,
        "moved_reference_point_ids": moved,
        "followed_reference_point_ids": followed,
        "reference_reasons": {
            pid: decisions[pid].reason for pid in [*lost_point_ids, *moved, *followed] if pid in decisions and decisions[pid].reason
        },
    }


def _sketch_has_lost_reference(part: Part, feature: SketchFeature) -> bool:
    """Whether `feature`'s Sketch has at least one lost external reference (see `_sketch_reference_state`)."""
    return bool(_sketch_reference_state(part, feature)["has_lost_reference"])


def _feature_response(part: Part, feature: Feature) -> FeatureResponse:
    """Builds `feature`'s response and, for a Feature holding `SubShapeRef`s, first stamps / re-validates them (`refresh_feature_subshape_refs`: signature adopted
    on creation, index re-found after an upstream topology change, never silently rebound) and reports the lost / potentially-moved ones on the response."""
    state = refresh_feature_subshape_refs(part, feature)
    response = _feature_response_unflagged(part, feature)
    if state is not None:
        response.has_lost_reference = response.has_lost_reference or state.has_lost
        response.lost_references = state.lost
        response.moved_references = state.moved
        response.followed_references = state.followed
        response.reference_reasons = {**response.reference_reasons, **state.reasons}
    return response


def _feature_response_unflagged(part: Part, feature: Feature) -> FeatureResponse:
    if isinstance(feature, SketchFeature):
        return SketchFeatureResponse(
            id=feature.id,
            sketch_id=feature.sketch_id,
            plane_feature_id=feature.plane_feature_id,
            **_sketch_reference_state(part, feature),
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
            thickness=feature.thickness,
            thickness_direction=feature.thickness_direction,
            draft_angle=feature.draft_angle,
            draft_outward=feature.draft_outward,
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
    if isinstance(feature, PlanarSurfaceFeature):
        return PlanarSurfaceFeatureResponse(
            id=feature.id,
            sketch_feature_id=feature.sketch_feature_id,
            profile_refs=[_sketch_entity_ref_to_schema(ref) for ref in feature.profile_refs],
            locked=part.is_locked(feature.id),
            produces=feature.produces,
        )
    if isinstance(feature, RevolveSurfaceFeature):
        return RevolveSurfaceFeatureResponse(
            id=feature.id,
            sketch_feature_id=feature.sketch_feature_id,
            axis_ref=_sketch_entity_ref_to_schema(feature.axis_ref),
            angle=feature.angle,
            profile_refs=[_sketch_entity_ref_to_schema(ref) for ref in feature.profile_refs],
            locked=part.is_locked(feature.id),
            produces=feature.produces,
        )
    if isinstance(feature, SweptSurfaceFeature):
        return SweptSurfaceFeatureResponse(
            id=feature.id,
            sketch_feature_id=feature.sketch_feature_id,
            path_refs=[_sketch_or_edge_ref_to_schema(ref) for ref in feature.path_refs],
            profile_refs=[_sketch_entity_ref_to_schema(ref) for ref in feature.profile_refs],
            locked=part.is_locked(feature.id),
            produces=feature.produces,
        )
    if isinstance(feature, RuledSurfaceFeature):
        return RuledSurfaceFeatureResponse(
            id=feature.id,
            sections=[_ruled_surface_section_to_schema(section) for section in feature.sections],
            locked=part.is_locked(feature.id),
            produces=feature.produces,
        )
    if isinstance(feature, ThickenFeature):
        return ThickenFeatureResponse(
            id=feature.id,
            surface_feature_id=feature.surface_feature_id,
            thickness=feature.thickness,
            locked=part.is_locked(feature.id),
            produces=feature.produces,
        )
    if isinstance(feature, KnitSurfaceFeature):
        return KnitSurfaceFeatureResponse(
            id=feature.id,
            surface_feature_ids=list(feature.surface_feature_ids),
            locked=part.is_locked(feature.id),
            produces=feature.produces,
        )
    if isinstance(feature, SolidFromSurfacesFeature):
        return SolidFromSurfacesFeatureResponse(
            id=feature.id,
            surface_feature_ids=list(feature.surface_feature_ids),
            locked=part.is_locked(feature.id),
            produces=feature.produces,
        )
    if isinstance(feature, OffsetSurfaceFeature):
        return OffsetSurfaceFeatureResponse(
            id=feature.id,
            source=_offset_source_ref_to_schema(feature.source),
            distance=feature.distance,
            locked=part.is_locked(feature.id),
            produces=feature.produces,
        )
    if isinstance(feature, CreatePlaneFeature):
        return _create_plane_feature_response(part, feature)
    if isinstance(feature, CurveFeature):
        return _curve_feature_response(part, feature)
    if isinstance(feature, FillSurfaceFeature):
        return _fill_surface_feature_response(part, feature)
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
            edge_options=_chamfer_edge_options_to_schema(feature.edge_options),
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
            path_refs=[_sketch_or_edge_ref_to_schema(ref) for ref in feature.path_refs],
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
            # Bug fix: MirrorFeature.produces is a hardcoded BODY - resolve
            # through its actual sources so a Mirror of a Surface reports
            # SURFACE - see resolve_feature_produces's own doc comment.
            produces=resolve_feature_produces(feature, part),
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
    if isinstance(feature, ShellFeature):
        return ShellFeatureResponse(
            id=feature.id,
            body_id=feature.body_id,
            faces_to_remove=[_subshape_ref_to_schema(r) for r in feature.faces_to_remove],
            thickness=feature.thickness,
            thickness_direction=feature.thickness_direction,
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
            orientation_mode=feature.orientation_mode,
            skip_indices=list(feature.skip_indices),
            merge=feature.merge,
            tool_feature_id=feature.tool_feature_id,
            locked=part.is_locked(feature.id),
            # Bug fix: PatternFeature.produces is a hardcoded BODY - resolve
            # through its actual sources so a Pattern of a Surface reports
            # SURFACE - see resolve_feature_produces's own doc comment.
            produces=resolve_feature_produces(feature, part),
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
    if isinstance(feature, LoftSurfaceFeature):
        return _loft_surface_feature_response(part, feature)
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
        thin_from_closed_profile=feature.thin_from_closed_profile,
        guide_curve_refs=[_sketch_or_edge_ref_to_schema(ref) for ref in feature.guide_curve_refs],
        locked=part.is_locked(feature.id),
        produces=feature.produces,
        warnings=warnings,
    )


def _loft_surface_feature_response(
    part: Part, feature: LoftSurfaceFeature, warnings: list[str] | None = None
) -> LoftSurfaceFeatureResponse:
    """Phase 1 surfacing package: mirrors `_loft_feature_response`'s own
    "warnings only known at create/update time, otherwise re-derived from
    `cached_feature_warnings`" convention exactly - see that function's own
    doc comment for the full reasoning."""
    if warnings is None:
        try:
            compute_part_bodies(part)
            warnings = cached_feature_warnings(part, feature.id)
        except HTTPException:
            logger.warning("LoftSurfaceFeature %s could not be resolved for its response", feature.id)
            warnings = []
    return LoftSurfaceFeatureResponse(
        id=feature.id,
        sections=[_loft_section_to_schema(section) for section in feature.sections],
        ruled=feature.ruled,
        guide_curve_refs=[_sketch_or_edge_ref_to_schema(ref) for ref in feature.guide_curve_refs],
        locked=part.is_locked(feature.id),
        produces=feature.produces,
        warnings=warnings,
    )


def _ruled_surface_section_to_domain(schema: RuledSurfaceSectionSchema) -> LoftSection:
    """Phase 1 surfacing package: builds the real domain `LoftSection` for a
    Ruled Surface's own narrower section schema - `reference_point`/
    `alignment_point` are always `None` (`RuledSurfaceSectionSchema` doesn't
    even expose them - see that schema's own docstring)."""
    return LoftSection(
        sketch_feature_id=schema.sketch_feature_id,
        profile_refs=[_sketch_entity_ref_to_domain(ref) for ref in schema.profile_refs],
        reference_point=None,
        alignment_point=None,
        edge_ref=_subshape_ref_to_domain(schema.edge_ref) if schema.edge_ref else None,
    )


def _ruled_surface_section_to_schema(section: LoftSection) -> RuledSurfaceSectionSchema:
    return RuledSurfaceSectionSchema(
        sketch_feature_id=section.sketch_feature_id,
        profile_refs=[_sketch_entity_ref_to_schema(ref) for ref in section.profile_refs],
        edge_ref=_subshape_ref_to_schema(section.edge_ref) if section.edge_ref else None,
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
        # Bug fix: source_feature.produces alone is always BODY for a
        # MirrorFeature/PatternFeature regardless of source - resolve
        # through the actual sources instead, so a Mirror/Pattern of a
        # Surface is correctly rejected here rather than wrongly accepted as
        # a Merge target - see resolve_feature_produces's own doc comment.
        if source_feature is None or resolve_feature_produces(source_feature, part) != Produces.BODY:
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
    or a Surface in this Part (on-device feedback: "surfaces should be a
    valid target for delete body" - deleting a Surface's shell is exactly
    as shape-agnostic as deleting a Body's solid, a plain dict pop in
    `delete_body.py`; the restriction to `Produces.BODY` only was purely
    this validation's own gap, not a geometry limitation - see
    `_validate_move_body_payload`'s identical fix)."""
    if not body_ids:
        raise HTTPException(
            status_code=422,
            detail="DeleteBodyFeature requires at least 1 body_ids entry - there is nothing to "
            "delete with an empty list",
        )
    for body_id in body_ids:
        source_feature = part.get_feature(base_feature_id(body_id))
        if source_feature is None or resolve_feature_produces(source_feature, part) not in (
            Produces.BODY,
            Produces.SURFACE,
        ):
            raise HTTPException(
                status_code=400,
                detail=f"body_ids entry {body_id!r} does not refer to a Body- or Surface-producing "
                "Feature in this Part",
            )


def _validate_scale_body_factor(part: Part, body_id: str, factor: float) -> None:
    """Direct Editing family (second entry): `ScaleBodyFeature.factor` must
    be strictly positive - zero collapses the Body to a point, a negative
    factor isn't a scale at all (422, same structured-validation-error
    shape `_validate_merge_body_ids`'s fewer-than-2 case uses). `body_id`
    must resolve (via `base_feature_id`, same round-trip tolerance as
    `_validate_delete_body_ids`) to a Feature that currently produces a
    Body or a Surface in this Part - `scale_body.py`'s own
    `BRepBuilderAPI_Transform` call is shape-agnostic, so a Surface's shell
    scales exactly as well as a Body's solid does (same fix as
    `_validate_delete_body_ids`/`_validate_move_body_payload` above)."""
    if factor <= 0:
        raise HTTPException(
            status_code=422,
            detail="ScaleBodyFeature requires factor > 0 - zero or negative is not a scale",
        )
    source_feature = part.get_feature(base_feature_id(body_id))
    if source_feature is None or resolve_feature_produces(source_feature, part) not in (
        Produces.BODY,
        Produces.SURFACE,
    ):
        raise HTTPException(
            status_code=400,
            detail=f"body_id {body_id!r} does not refer to a Body- or Surface-producing Feature "
            "in this Part",
        )


def _validate_move_body_payload(
    part: Part, body_id: str, rotation_axis: PatternAxisRef | None
) -> None:
    """Direct Editing family (third entry, "Move/Copy Body"): `body_id`
    must resolve (via `base_feature_id`, same round-trip tolerance as
    `_validate_scale_body_factor`) to a Feature that currently produces a
    Body or a Surface in this Part (on-device feedback: "surfaces should be
    a valid target for move/copy body" - `resolve_move_body_from_bodies`'s
    own `BRepBuilderAPI_Transform` calls are shape-agnostic, so a Surface's
    shell moves/copies exactly as well as a Body's solid does; the
    restriction to `Produces.BODY` only was purely this validation's own
    gap, not a geometry limitation); `rotation_axis`, if supplied, must have
    exactly one of `edge_ref`/`face_ref`/`sketch_line_ref` set - reuses
    `_validate_pattern_axis_ref` verbatim (already shared with Circular
    Pattern's own `axis` field)."""
    source_feature = part.get_feature(base_feature_id(body_id))
    if source_feature is None or source_feature.produces not in (Produces.BODY, Produces.SURFACE):
        raise HTTPException(
            status_code=400,
            detail=f"body_id {body_id!r} does not refer to a Body- or Surface-producing Feature "
            "in this Part",
        )
    if rotation_axis is not None:
        _validate_pattern_axis_ref(rotation_axis, field_name="rotation_axis")


def _validate_occurrence_transform_payload(
    rotation_axis: tuple[float, float, float], rotation_angle_degrees: float
) -> None:
    """§6 roadmap Phase 10, item `[4]`: mirrors `_validate_move_body_
    payload`'s own guard, one level up. An Occurrence's `rotation_axis` is
    a free world-space vector, never resolved from geometry
    (`RigidTransform`'s own docstring), so unlike `_validate_pattern_axis_ref`
    there is no reference shape to check - only the one payload that would
    otherwise silently do nothing useful while still recording a "rotation":
    a non-zero `rotation_angle_degrees` paired with a zero-length
    `rotation_axis` (`_is_zero_vector`, the same helper `ComponentPattern`'s
    own direction checks already share). Shared verbatim by both the real
    `update_occurrence_transform` PATCH endpoint and `ai_plan.py`'s
    `_handle_move_component` dry-run handler (imported there via a deferred,
    in-function import - the same "leaf validator, deferred import" shape
    `_validate_move_body_payload` already uses for `_handle_move_body`, since
    `ai_plan.py` never imports `router.py` at module scope)."""
    if rotation_angle_degrees != 0.0 and _is_zero_vector(rotation_axis):
        raise HTTPException(
            status_code=422,
            detail="rotation_axis must not be the zero vector when rotation_angle_degrees is non-zero",
        )


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
        # Bug fix: see _validate_merge_body_ids's identical fix above.
        if source_feature is None or resolve_feature_produces(source_feature, part) != Produces.BODY:
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
    # Bug fix: see _validate_merge_body_ids's identical fix above.
    if target_feature is None or resolve_feature_produces(target_feature, part) != Produces.BODY:
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
    SurfaceFeature,
    PlanarSurfaceFeature,
    RevolveSurfaceFeature,
    SweptSurfaceFeature,
    LoftSurfaceFeature,
    RuledSurfaceFeature,
    KnitSurfaceFeature,
    OffsetSurfaceFeature,
    ThickenFeature,
    SolidFromSurfacesFeature,
)
_PATTERN_MIRROR_SOURCE_FEATURE_TYPES_DESCRIPTION = (
    "ExtrudeFeature, RevolveFeature, SweepFeature, ImportFeature, MirrorFeature, PatternFeature, "
    "GearFeature, RackFeature, LoftFeature, GearChainFeature, PlanetaryGearFeature, BevelGearFeature, "
    "BevelPairFeature, SurfaceFeature, PlanarSurfaceFeature, RevolveSurfaceFeature, "
    "SweptSurfaceFeature, LoftSurfaceFeature, RuledSurfaceFeature, KnitSurfaceFeature, "
    "OffsetSurfaceFeature, ThickenFeature, or SolidFromSurfacesFeature"
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


def _validate_uniform_source_produces(
    part: Part, source_body_ids: list[str], source_feature_ids: list[str], feature_type_name: str
) -> None:
    """Bug fix (on-device feedback: "mirrored and patterned surfaces...
    need to be valid targets for thicken and body from surfaces"): once
    `MirrorFeature`/`PatternFeature.produces` became source-aware (see
    `resolve_feature_produces`'s own doc comment) instead of a hardcoded
    `Produces.BODY`, a single Mirror/Pattern mixing solid and surface
    sources together would need a *per-instance* classification nothing
    else in this codebase does (`is_surface`/`produces` is always a
    per-Feature question everywhere else) - simpler and safer to reject a
    mixed source set outright at creation time instead, matching how a
    user would expect one Mirror/Pattern operation to behave (uniform
    sources in, uniform-typed output). Only reachable when `tool_feature_id`
    isn't set (that mode has exactly one source by construction, nothing to
    mix) - both call sites below only call this when `source_body_ids`/
    `source_feature_ids` are what's actually being used."""
    resolved_ids = {base_feature_id(bid) for bid in source_body_ids}
    resolved_ids.update(source_feature_ids)
    produces_seen: set[Produces] = set()
    for source_id in resolved_ids:
        source_feature = part.get_feature(source_id)
        if source_feature is not None:
            produces_seen.add(resolve_feature_produces(source_feature, part))
    if len(produces_seen) > 1:
        raise HTTPException(
            status_code=422,
            detail=f"{feature_type_name} sources must be all Body-producing or all Surface-producing, "
            "not a mix of both",
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
    if tool_feature_id is None:
        _validate_uniform_source_produces(part, source_body_ids, source_feature_ids, "MirrorFeature")


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
    if tool_feature_id is None:
        _validate_uniform_source_produces(part, source_body_ids, source_feature_ids, "PatternFeature")


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


def _validate_profile_refs(sketch_feature: SketchFeature, profile_refs: list[SketchEntityRef]) -> list[Profile]:
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
    check for both Extrude's and Revolve's create/update endpoints.

    Returns the selected profiles (discarded by every caller except
    Extrude's draft check, `_validate_draft_payload`, which needs to know
    how many outer profiles the Extrude will actually use)."""
    sketch = get_sketch_or_404(sketch_feature.sketch_id)
    result = detect_profile(sketch)
    candidates = [result.profile] if result.status == ProfileStatus.CLOSED_LOOP else result.loops
    return select_profiles(candidates, profile_refs)


def _validate_draft_payload(draft_angle: float | None, thickness: float | None, profile_count: int) -> None:
    """Extrude draft (v1): a no-op when `draft_angle` is None (no draft).
    Otherwise:

    - `draft_angle` must lie strictly inside (0, 90) degrees - 0 is "no
      draft" (send `null` instead) and 90 would lay the walls flat onto the
      Sketch plane, a degenerate taper. 400, the same plain numeric-field
      shape as `_validate_thickness_nonzero`/Chamfer's own angle check.
    - Mutually exclusive with thin-wall (`thickness`) - 422, mirroring
      `_validate_tool_feature_payload`'s own "X is mutually exclusive with
      Y" conflict shape. Rejected outright rather than letting either field
      silently win, so a client can't fall into the "looks configured but
      isn't" trap.
    - Only a single outer profile (`profile_count`, from `_validate_
      profile_refs`: the profiles `profile_refs` actually selects, or every
      detected one when it's empty) - 422. A MultiProfile draft is left out
      of v1's scope; `app.document.extrude._solid_for_extrude_feature`
      re-checks this at resolve time in case the Sketch later drifts into
      several loops."""
    if draft_angle is None:
        return
    if not 0 < draft_angle < 90:
        raise HTTPException(status_code=400, detail="draft_angle must be between 0 and 90 degrees (exclusive)")
    if thickness is not None:
        raise HTTPException(
            status_code=422,
            detail="Extrude draft_angle is mutually exclusive with thickness (thin-wall extrude)",
        )
    if profile_count > 1:
        raise HTTPException(
            status_code=422,
            detail="Extrude draft requires a single profile - this Extrude selects "
            f"{profile_count} profiles",
        )


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
    {
        SketchEntityType.LINE,
        SketchEntityType.ARC,
        SketchEntityType.CIRCLE,
        SketchEntityType.ELLIPSE,
        SketchEntityType.SPLINE,
    }
)


def _validate_sweep_path_refs(path_refs: list[SketchOrEdgeRef]) -> None:
    """A SweepFeature must name at least one `path_refs` entry (422,
    mirroring Cut's own "at least one target_body_ids entry" check in
    `_validate_target_body_ids`) and every named ref must be a Line/Arc/
    Circle/Ellipse/Spline (422, mirroring `_validate_fillet_edge_refs`'s
    own `shape_type == EDGE` check) - these are payload-shape checks.
    Whether the named entities actually resolve, chain into one connected
    path (open or closed), or - for a closed/standalone Circle/Ellipse -
    stand alone, is a referential/geometric check made by
    `app.document.sweep.resolve_sweep` instead (the same "payload shape in
    the router, resolution in the OCCT module" split every other
    structured Feature error in this codebase already uses).

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
    _validate_sweep_or_loft_curve_refs(path_refs)


def _validate_swept_surface_path_refs(path_refs: list[SketchOrEdgeRef]) -> None:
    """Phase 1 surfacing package: mirrors `_validate_sweep_path_refs`
    exactly, own error message naming `SweptSurfaceFeature` instead of
    `SweepFeature` so a client can tell which tool's payload failed."""
    if not path_refs:
        raise HTTPException(
            status_code=422,
            detail="SweptSurfaceFeature requires at least one path_refs entry",
        )
    _validate_sweep_or_loft_curve_refs(path_refs)


def _validate_sweep_or_loft_curve_refs(refs: list[SketchOrEdgeRef]) -> None:
    """On-device feedback ("surface tools should support edges, curves, as
    well as sketch lines as inputs"): shared entry-shape check for
    `SweepFeature`/`SweptSurfaceFeature.path_refs` and `LoftFeature`/
    `LoftSurfaceFeature.guide_curve_refs`, all four now `list[SketchOrEdge
    Ref]` - `_validate_sketch_or_edge_refs` checks the generic "exactly one
    of `sketch_entity_ref`/`edge_ref`" shape every such list shares; a
    `sketch_entity_ref` entry is further restricted to the same entity
    types `_resolve_path_segment` already resolves (mirrors this
    function's own pre-existing check); an `edge_ref` entry must actually
    name an edge - any Body edge is a valid curve to sweep/loft along, so
    no further narrowing is needed there."""
    _validate_sketch_or_edge_refs(refs)
    for ref in refs:
        if ref.sketch_entity_ref is not None and ref.sketch_entity_ref.entity_type not in _SWEEP_PATH_ENTITY_TYPES:
            raise HTTPException(
                status_code=422,
                detail="path_refs entries must have entity_type one of line, arc, ellipse, spline",
            )
        if ref.edge_ref is not None and ref.edge_ref.shape_type != SubShapeType.EDGE:
            raise HTTPException(
                status_code=422,
                detail="path_refs edge_ref entries must reference an edge",
            )


def _validate_loft_surface_sections(sections: list[LoftSection]) -> None:
    """Phase 1 surfacing package: mirrors `_validate_loft_sections` exactly,
    own error message naming `LoftSurfaceFeature`."""
    if len(sections) < 2:
        raise HTTPException(
            status_code=422,
            detail="LoftSurfaceFeature requires at least 2 sections",
        )
    _validate_loft_section_shape(sections)


def _validate_ruled_surface_sections(sections: list[LoftSection]) -> None:
    """Phase 1 surfacing package: unlike `_validate_loft_sections`'s own "at
    least 2" rule, a Ruled Surface requires *exactly* 2 - its whole point is
    the narrower, exactly-2-pick UX (see `RuledSurfaceFeature`'s own
    docstring)."""
    if len(sections) != 2:
        raise HTTPException(
            status_code=422,
            detail="RuledSurfaceFeature requires exactly 2 sections",
        )
    _validate_loft_section_shape(sections)


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
    _validate_loft_section_shape(sections)


def _validate_thickness_nonzero(thickness: float | None) -> None:
    """A `LoftFeatureCreate`/`Update.thickness`, if provided at all, must be
    nonzero - zero has no meaningful "thicken by nothing into a solid"
    interpretation (a plain-400 convention, mirroring `_validate_fillet_
    radius`'s own bare numeric-field check with no structured error type).
    Its sign is meaningful (which side of the lofted shell the material is
    added to - see `app.document.loft.resolve_loft_from_bodies`), so unlike
    a radius this is not rejected for being negative, only for being 0."""
    if thickness is not None and thickness == 0:
        raise HTTPException(status_code=400, detail="thickness must not be 0")


def _validate_loft_guide_curve_refs(guide_curve_refs: list[SketchOrEdgeRef]) -> None:
    """A `LoftFeatureCreate`/`Update.guide_curve_refs`, if provided at all,
    must name only Line/Arc/Ellipse/Spline entities or Body edges - mirrors
    `_validate_sweep_or_loft_curve_refs`'s own identical entry-shape gate
    exactly (this reuses the very same `_SWEEP_PATH_ENTITY_TYPES` set and
    the very same resolution machinery, `app.document.sweep.resolve_path_
    wire`, just as a rail rather than an extrusion direction - see
    `LoftFeature.guide_curve_refs`'s own docstring). Unlike a Sweep's
    `path_refs`, an empty list is perfectly valid here (it means "no guide
    curve", not "nothing to loft along") - so, unlike `_validate_sweep_
    path_refs`, there is no "at least one entry" rule. Whether the named
    entities actually resolve, chain into one connected path, and (once
    every section requires an `alignment_point`, see `app.document.loft.
    _apply_alignment_point_translation`) cross each section's own plane
    exactly once is a referential/geometric check made by `app.document.
    loft.resolve_loft` instead, same "payload shape in the router,
    resolution in the OCCT module" split every other structured Feature
    error here already uses."""
    _validate_sweep_or_loft_curve_refs(guide_curve_refs)


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


def _validate_chamfer_edge_options(edge_options: dict[int, ChamferEdgeOptions], edge_count: int) -> None:
    """Feature 3: payload-shape checks for `ChamferFeature.edge_options` -
    every key must index an existing `edge_refs` entry and every `face_ref`
    must be a FACE (422, mirroring `_validate_chamfer_edge_refs`'s own
    shape_type check); `angle`, when set, must lie strictly inside
    `(0, 180)` degrees (400, `_validate_chamfer_distance`'s own plain-400
    convention for a bare numeric-field check). Whether a `face_ref` is
    actually adjacent to its edge is referential, so checked by
    `app.document.chamfer.resolve_chamfer` instead."""
    for index, opts in edge_options.items():
        if not 0 <= index < edge_count:
            raise HTTPException(
                status_code=422,
                detail=f"edge_options key {index} is not a valid edge_refs index",
            )
        if opts.face_ref is not None and opts.face_ref.shape_type != SubShapeType.FACE:
            raise HTTPException(status_code=422, detail="edge_options face_ref must have shape_type=FACE")
        if opts.angle is not None and not 0 < opts.angle < 180:
            raise HTTPException(status_code=400, detail="angle must be between 0 and 180 degrees (exclusive)")


def _validate_shell_thickness(thickness: float) -> None:
    """Mirrors `_validate_chamfer_distance`'s plain-400 convention for a
    bare numeric-field check - a Shell's wall `thickness` is a magnitude
    (its side is chosen by `thickness_direction`, never by sign), so it
    must be strictly positive."""
    if thickness <= 0:
        raise HTTPException(status_code=400, detail="thickness must be greater than 0")


def _validate_shell_faces_to_remove(faces_to_remove: list[SubShapeRef]) -> None:
    """Mirrors `_validate_chamfer_edge_refs` - payload-shape checks only
    (at least one entry, every entry a FACE). Whether they resolve, and
    whether they all belong to the Shell's own `body_id`, is checked by
    `app.document.shell.resolve_shell` instead."""
    if not faces_to_remove:
        raise HTTPException(
            status_code=422,
            detail="ShellFeature requires at least one faces_to_remove entry",
        )
    for ref in faces_to_remove:
        if ref.shape_type != SubShapeType.FACE:
            raise HTTPException(status_code=422, detail="faces_to_remove entries must have shape_type=FACE")


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
    curve_feature_id: str | None = None,
    curve_parameter: float | None = None,
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
        "curve_feature_id": curve_feature_id is None,
        "curve_parameter": curve_parameter is None,
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
    curve_feature_id: str | None = None,
    curve_parameter: float | None = None,
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
            curve_feature_id=curve_feature_id,
            curve_parameter=curve_parameter,
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
    elif plane_type == PlaneType.NORMAL_TO_CURVE_FEATURE_AT_PARAMETER:
        if (
            curve_feature_id is None
            or curve_parameter is None
            or not other_fields_empty({"curve_feature_id", "curve_parameter"})
        ):
            raise HTTPException(
                status_code=422,
                detail="NORMAL_TO_CURVE_FEATURE_AT_PARAMETER requires both curve_feature_id and "
                "curve_parameter, and nothing else",
            )
        if not 0.0 <= curve_parameter <= 1.0:
            raise HTTPException(status_code=422, detail="curve_parameter must be between 0 and 1")
        if not isinstance(part.get_feature(curve_feature_id), CurveFeature):
            raise HTTPException(
                status_code=422, detail="curve_feature_id must name an existing CurveFeature in this Part"
            )
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


def _validate_curve_payload(
    part: Part,
    curve_type: CurveType,
    axis_ref: PlaneRef | None,
    radius: float | None,
    pitch: float | None,
    turns: float | None,
    sketch_feature_id_a: str | None,
    sketch_feature_id_b: str | None,
) -> None:
    """Enforces exactly one combination of fields is supplied, matching
    `curve_type` - same plain-string-422, "malformed combination of
    fields" convention `_validate_create_plane_payload` uses. `profile_
    refs_a`/`_b`/`right_handed` need no such check (they're either always
    optional or always have a valid default), so they aren't passed here."""
    if curve_type == CurveType.HELIX:
        if axis_ref is None or radius is None or pitch is None or turns is None:
            raise HTTPException(
                status_code=422,
                detail="HELIX requires axis_ref, radius, pitch, and turns",
            )
        if sketch_feature_id_a is not None or sketch_feature_id_b is not None:
            raise HTTPException(
                status_code=422,
                detail="HELIX must not set sketch_feature_id_a/sketch_feature_id_b",
            )
        _validate_plane_ref(part, axis_ref)
        if radius <= 0.0:
            raise HTTPException(status_code=422, detail="radius must be positive")
        if pitch == 0.0:
            raise HTTPException(status_code=422, detail="pitch must be non-zero")
        if turns <= 0.0:
            raise HTTPException(status_code=422, detail="turns must be positive")
        return
    assert curve_type == CurveType.INTERSECTION
    if sketch_feature_id_a is None or sketch_feature_id_b is None:
        raise HTTPException(
            status_code=422,
            detail="INTERSECTION requires sketch_feature_id_a and sketch_feature_id_b",
        )
    if axis_ref is not None or radius is not None or pitch is not None or turns is not None:
        raise HTTPException(
            status_code=422,
            detail="INTERSECTION must not set axis_ref/radius/pitch/turns",
        )
    if not isinstance(part.get_feature(sketch_feature_id_a), SketchFeature):
        raise HTTPException(status_code=422, detail="sketch_feature_id_a must name an existing Sketch feature")
    if not isinstance(part.get_feature(sketch_feature_id_b), SketchFeature):
        raise HTTPException(status_code=422, detail="sketch_feature_id_b must name an existing Sketch feature")


def _validate_fill_surface_payload(boundary_refs: list[SketchOrEdgeRef]) -> None:
    """A Fill Surface needs at least 2 boundary curves (fewer can't bound a
    surface at all) and at most 4 (`OCCT BRepOffsetAPI_MakeFilling`'s own
    practical/v1 scope limit for this project - see `FillSurfaceFeature`'s
    own docstring). Each entry's own shape (`sketch_entity_ref`/`edge_ref`/
    `curve_feature_id`) is checked by `_validate_sketch_or_edge_refs`,
    called separately at each call site, same split every other `list[
    SketchOrEdgeRef]` field (`path_refs`, `guide_curve_refs`) already uses."""
    if not 2 <= len(boundary_refs) <= 4:
        raise HTTPException(status_code=422, detail="boundary_refs must have between 2 and 4 entries")


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


@router.patch("/parts/{part_id}", response_model=PartResponse)
def update_part(part_id: str, payload: PartUpdate) -> PartResponse:
    """Part Properties: updates the free-text metadata fields only (Part
    Number/Description/Revision/Remarks/Supplier/Supplier Part Number) -
    material assignment has its own dedicated endpoints below (a whole-
    object replace, not a field-by-field PATCH, since a `MaterialAssignment`
    is always set or cleared as one unit, never partially). Same omitted-
    vs-current-value convention as every `*FeatureUpdate` endpoint.

    Save/project overhaul Phase 2 (`docs/save-project-overhaul-scope.md`
    §3.2): widened to also accept `name` - the assembly tree's own Rename
    action, when renaming a singly-instanced component's own Occurrence
    also renames the Part it resolves to (see `PartUpdate.name`'s own
    docstring for why). Unlike the metadata fields above, an explicitly
    empty/whitespace-only `name` is rejected with a 422 rather than
    silently applied - `Part.name` is a required field with no "cleared"
    state, unlike the `str | None` metadata above that's fine to blank
    out."""
    part = get_part_or_404(part_id)
    if payload.part_number is not None:
        part.part_number = payload.part_number
    if payload.description is not None:
        part.description = payload.description
    if payload.revision is not None:
        part.revision = payload.revision
    if payload.remarks is not None:
        part.remarks = payload.remarks
    if payload.supplier is not None:
        part.supplier = payload.supplier
    if payload.supplier_part_number is not None:
        part.supplier_part_number = payload.supplier_part_number
    if payload.name is not None:
        stripped_name = payload.name.strip()
        if not stripped_name:
            raise HTTPException(status_code=422, detail="name must not be empty")
        part.name = stripped_name
    return _part_response(part)


@router.put("/parts/{part_id}/default-material", response_model=PartResponse)
def set_default_material(part_id: str, payload: MaterialAssignmentUpdate) -> PartResponse:
    """Sets (or, with `material: null`, clears) this Part's own default
    material - the material every Body without its own override resolves to
    (`Part.resolve_material`)."""
    part = get_part_or_404(part_id)
    part.default_material = (
        _material_assignment_to_domain(payload.material) if payload.material is not None else None
    )
    return _part_response(part)


@router.put("/parts/{part_id}/bodies/{body_id}/material", response_model=PartResponse)
def set_body_material(part_id: str, body_id: str, payload: MaterialAssignmentUpdate) -> PartResponse:
    """Sets (or, with `material: null`, clears - reverting to the Part's own
    default) `body_id`'s own material override. A granular per-Body endpoint
    rather than a whole-map replace, to avoid read-modify-write races
    between two overrides being set close together."""
    part = get_part_or_404(part_id)
    if payload.material is not None:
        part.body_material_assignments[body_id] = _material_assignment_to_domain(payload.material)
    else:
        part.body_material_assignments.pop(body_id, None)
    return _part_response(part)


@router.get("/parts/{part_id}/mass-properties", response_model=MassPropertiesResponse)
def get_mass_properties(part_id: str) -> MassPropertiesResponse:
    """Part Properties' Mass field: volume (mm^3) for every current Body,
    mass (g) for whichever also have a resolvable material - explicit/
    on-demand (a full `compute_part_bodies` recompute), never folded into
    the cheap metadata-only `GET /parts/{part_id}`."""
    part = get_part_or_404(part_id)
    body_volumes, body_masses = compute_mass_properties(part)
    return MassPropertiesResponse(body_volumes=body_volumes, body_masses=body_masses)


@router.get("/parts/{part_id}/features", response_model=list[FeatureResponse])
def list_features(part_id: str) -> list[FeatureResponse]:
    part = get_part_or_404(part_id)
    return [_feature_response(part, feature) for feature in part.features]


@router.get("/parts/{part_id}/features/{feature_id}", response_model=FeatureResponse)
def get_feature(part_id: str, feature_id: str) -> FeatureResponse:
    part = get_part_or_404(part_id)
    return _feature_response(part, _get_feature_or_404(part, feature_id))


def _occurrence_response(occurrence: Occurrence) -> OccurrenceResponse:
    return OccurrenceResponse(
        id=occurrence.id,
        external_ref=occurrence.external_ref,
        resolved_part_id=occurrence.part_id,
        name_override=occurrence.name_override,
        transform=RigidTransformResponse(
            translation=occurrence.transform.translation,
            rotation_axis=occurrence.transform.rotation_axis,
            rotation_angle_degrees=occurrence.transform.rotation_angle_degrees,
        ),
        suppressed=occurrence.suppressed,
        hidden=occurrence.hidden,
        fixed=occurrence.fixed,
        color=occurrence.color,
    )


def _mate_entity_ref_response(ref: MateEntityRef) -> MateEntityRefResponse:
    return MateEntityRefResponse(
        occurrence_id=ref.occurrence_id,
        subshape_ref=_subshape_ref_to_schema(ref.subshape_ref) if ref.subshape_ref else None,
        plane_ref=_plane_ref_to_schema(ref.plane_ref) if ref.plane_ref else None,
        point_ref=_point_ref_to_schema(ref.point_ref) if ref.point_ref else None,
    )


def _mate_response(mate: Mate) -> MateResponse:
    return MateResponse(
        id=mate.id,
        type=mate.type.value,
        references=[_mate_entity_ref_response(ref) for ref in mate.references],
        value=mate.value,
        flipped=mate.flipped,
        suppressed=mate.suppressed,
        allow_rotation=mate.allow_rotation,
    )


@router.get("/parts/{part_id}/occurrences", response_model=list[OccurrenceResponse])
def list_occurrences(part_id: str) -> list[OccurrenceResponse]:
    """Assembly support (`docs/assembly-scope.md`): the Assembly tree's own
    "components" list - `part_id`'s own `occurrences`, full detail (unlike
    `PartResponse.occurrence_ids`, ids only). Coexists with `list_features`
    above rather than replacing it - both can return real entries for the
    same Part at once (decision #2)."""
    part = get_part_or_404(part_id)
    return [_occurrence_response(occurrence) for occurrence in part.occurrences]


@router.get("/parts/{part_id}/mates", response_model=list[MateResponse])
def list_mates(part_id: str) -> list[MateResponse]:
    """Assembly support (`docs/assembly-scope.md`): the Assembly tree's own
    Mates list - `part_id`'s own `mates`, full detail (unlike
    `PartResponse.mate_ids`, ids only)."""
    part = get_part_or_404(part_id)
    return [_mate_response(mate) for mate in part.mates]


def _get_occurrence_or_404(part: Part, occurrence_id: str) -> Occurrence:
    for occurrence in part.occurrences:
        if occurrence.id == occurrence_id:
            return occurrence
    raise HTTPException(status_code=404, detail="Occurrence not found")


def _occurrence_is_fixed(occurrence_id: str) -> HTTPException:
    """Structured 422 - same envelope `_mate_solve_did_not_converge` below
    already established - for any attempt to move a `fixed` Occurrence,
    whether a direct gizmo PATCH (`update_occurrence_transform`) or a Mate
    solve targeting it (`solve_for_occurrence`)."""
    return HTTPException(
        status_code=422,
        detail={"type": "occurrence_is_fixed", "occurrence_id": occurrence_id},
    )


@router.patch("/parts/{part_id}/occurrences/{occurrence_id}", response_model=OccurrenceResponse)
def update_occurrence_transform(
    part_id: str, occurrence_id: str, payload: OccurrenceTransformUpdate
) -> OccurrenceResponse:
    """Assembly support Phase 5 (`docs/assembly-scope.md`): the first
    mutation endpoint an Occurrence has ever had - every prior phase's own
    "no backend mutation endpoint exists for Occurrences at all" gap (§2e)
    is real for every *other* field (`hidden`/`suppressed`/`name_override`),
    but Move/Rotate specifically needs `transform` to persist, which is
    what this adds. Whole-value replace (`Occurrence.transform = payload.
    transform`, not a merge) - see `OccurrenceTransformUpdate`'s own
    docstring for why a partial-delta shape doesn't apply here the way a
    Feature's `*Update` schemas' omitted-vs-current convention does.
    Unlike `MoveBodyFeature` (a new Feature/history entry created once, then
    updated in place), there is no "create" step at all - the Occurrence
    already exists, so every drag (debounced client-side, the same
    latency-tolerance shape `MoveBodyFeature` itself already uses) PATCHes
    this same endpoint directly.

    Phase 8 (`docs/assembly-scope.md` §2k) widened this to also accept
    `hidden`, both fields now omitted-means-unchanged - see
    `OccurrenceTransformUpdate`'s own docstring for why.

    Assembly testing bug fix: widened again to also accept `fixed` - and,
    since a "Fix" constraint is meaningless if `transform` could still be
    PATCHed straight past it, a `transform` sent alongside (or against an
    Occurrence already `fixed`, when `fixed` itself is omitted here) is now
    rejected with a structured 422 (`_occurrence_is_fixed`) *before* either
    field is applied - never a partial mutation. Checked against the
    request's own *effective* `fixed` value (`payload.fixed` if given, else
    the Occurrence's current one) so `{transform, fixed: false}` in the same
    call - unfixing and repositioning in one round trip - still works.

    Bug report (assembly testing): widened again to also accept `color` -
    see `OccurrenceTransformUpdate.color`'s own docstring for its
    `None`-omitted/`""`-clears/anything-else-stored-verbatim tri-state.

    Save/project overhaul Phase 2 (`docs/save-project-overhaul-scope.md`
    §3.2): widened again to also accept `name_override` - the assembly
    tree's own Rename action, closing the last of the three fields §2e's
    docstring above originally flagged as having no mutation path
    (`suppressed` still doesn't - nothing needs it yet). Same tri-state as
    `color`."""
    part = get_part_or_404(part_id)
    occurrence = _get_occurrence_or_404(part, occurrence_id)
    effective_fixed = payload.fixed if payload.fixed is not None else occurrence.fixed
    if payload.transform is not None and effective_fixed:
        raise _occurrence_is_fixed(occurrence_id)
    if payload.transform is not None:
        _validate_occurrence_transform_payload(
            payload.transform.rotation_axis, payload.transform.rotation_angle_degrees
        )
        occurrence.transform = RigidTransform(
            translation=payload.transform.translation,
            rotation_axis=payload.transform.rotation_axis,
            rotation_angle_degrees=payload.transform.rotation_angle_degrees,
        )
    if payload.hidden is not None:
        occurrence.hidden = payload.hidden
    if payload.fixed is not None:
        occurrence.fixed = payload.fixed
    if payload.color is not None:
        occurrence.color = payload.color or None
    if payload.name_override is not None:
        occurrence.name_override = payload.name_override or None
    return _occurrence_response(occurrence)


@router.post("/parts/{part_id}/occurrences", response_model=OccurrenceResponse, status_code=201)
def create_occurrence(part_id: str, payload: OccurrenceCreate) -> OccurrenceResponse:
    """Restores a fully-known `Occurrence` onto `part_id` - see
    `OccurrenceCreate`'s own docstring for why `id` is client-supplied
    (unlike `create_mate`/`create_component_pattern`'s own server-generated
    ids) and why this endpoint exists at all (Assembly-lens "Undo" after an
    Occurrence delete, `docs/assembly-scope.md`). 409s on a duplicate id -
    restoring is expected to target a fresh id (whatever `delete_occurrence`
    just removed), never to silently overwrite an already-live Occurrence.

    Bug fix (assembly testing: delete-then-undo reporting "file could not be
    found"): `payload.resolved_part_id` is trusted as the restored
    Occurrence's own `part_id` only when it names a `Part` already present
    in `document.parts` - the same trust boundary `import_native`'s own
    cross-reference resolution already applies for this exact field
    (`Occurrence.part_id`'s own docstring). Anything else (omitted, or
    naming a Part this Document doesn't have) leaves `part_id` at `None`,
    the pre-existing "unresolved until the next full reimport" behavior -
    this never *weakens* resolution, only closes the gap where a
    genuinely-still-open Part's own id was being dropped for no reason."""
    part = get_part_or_404(part_id)
    if any(occurrence.id == payload.id for occurrence in part.occurrences):
        raise HTTPException(status_code=409, detail=f"Occurrence '{payload.id}' already exists")
    transform = (
        RigidTransform(
            translation=payload.transform.translation,
            rotation_axis=payload.transform.rotation_axis,
            rotation_angle_degrees=payload.transform.rotation_angle_degrees,
        )
        if payload.transform is not None
        else RigidTransform()
    )
    document = get_document()
    resolved_part_id = (
        payload.resolved_part_id if payload.resolved_part_id in document.parts else None
    )
    occurrence = Occurrence(
        id=payload.id,
        part_id=resolved_part_id,
        external_ref=payload.external_ref,
        name_override=payload.name_override,
        transform=transform,
        suppressed=payload.suppressed,
        hidden=payload.hidden,
        fixed=payload.fixed,
        color=payload.color,
    )
    part.occurrences.append(occurrence)
    return _occurrence_response(occurrence)


@router.delete("/parts/{part_id}/occurrences/{occurrence_id}", status_code=204)
def delete_occurrence(part_id: str, occurrence_id: str) -> Response:
    """Removes `occurrence_id` from `part_id` - the first delete an
    Occurrence has ever had (`docs/assembly-scope.md`: every prior mutation
    was a `PATCH`; Mates/ComponentPatterns both had real `DELETE` endpoints
    long before an Occurrence itself did). Cascades: any Mate referencing
    this Occurrence in either of its two `references` (`create_mate`'s own
    "exactly 2 references" invariant means checking both is exhaustive),
    and any ComponentPattern naming it in `source_occurrence_ids` (even as
    one of several - a multi-source pattern loses one of its sources here
    the same "whole feature, not a partial mutation" way a single-source one
    does, keeping the client's own pre-delete warning dialog simple and
    exhaustively enumerable), are removed in full rather than left dangling
    or silently shrunk. Same-Part-scoped only - both Mate and ComponentPattern
    references are already validated at creation time to only ever name a
    top-level Occurrence of this same Part (`_validate_mate_entity_ref`/
    `_validate_component_pattern_source_occurrence_ids`), so no cross-Part
    walk is needed here either."""
    part = get_part_or_404(part_id)
    occurrence = _get_occurrence_or_404(part, occurrence_id)
    part.mates = [m for m in part.mates if not any(r.occurrence_id == occurrence_id for r in m.references)]
    part.component_patterns = [
        p for p in part.component_patterns if occurrence_id not in p.source_occurrence_ids
    ]
    part.occurrences.remove(occurrence)
    return Response(status_code=204)


def _mate_entity_ref_to_domain(schema: MateEntityRefResponse) -> MateEntityRef:
    return MateEntityRef(
        occurrence_id=schema.occurrence_id,
        subshape_ref=_subshape_ref_to_domain(schema.subshape_ref) if schema.subshape_ref else None,
        plane_ref=_plane_ref_to_domain(schema.plane_ref) if schema.plane_ref else None,
        point_ref=_point_ref_to_domain(schema.point_ref) if schema.point_ref else None,
    )


def _validate_mate_entity_ref(part: Part, ref: MateEntityRefResponse) -> None:
    """One `MateCreate.references` entry's own payload-shape validation -
    exactly one of `subshape_ref`/`plane_ref`/`point_ref` (mirrors
    `_validate_plane_ref`'s identical "exactly one of N" check for
    `PlaneRef` itself), and `occurrence_id` is either `""` (this Part's own
    root content - Phase 6a/`assembly_solver`'s own convention) or names a
    real, top-level entry in `part.occurrences` (v1 scope: a Mate can only
    ever reference a top-level Occurrence of the currently-open Part, the
    same limit Phase 5's gizmo already has - see `assembly_solver`'s own
    module docstring)."""
    set_count = sum(x is not None for x in (ref.subshape_ref, ref.plane_ref, ref.point_ref))
    if set_count != 1:
        raise HTTPException(
            status_code=422,
            detail="Each mate reference must have exactly one of subshape_ref, plane_ref, or point_ref",
        )
    if ref.occurrence_id == "":
        return
    if not any(occurrence.id == ref.occurrence_id for occurrence in part.occurrences):
        raise HTTPException(
            status_code=422,
            detail={"type": "occurrence_not_found", "occurrence_id": ref.occurrence_id},
        )


def _validate_mate_create(part: Part, payload: MateCreate) -> None:
    """`POST /parts/{part_id}/mates`'s own payload-shape validation - the
    router's job, mirroring every other structured Feature/Mate validation
    split in this codebase (referential/geometric validity is `assembly_
    solver`'s own job, raised lazily the first time a Mate is actually
    solved, the same "resolve, don't pre-validate geometry" philosophy
    `resolve_subshape`'s own docstring already establishes)."""
    if len(payload.references) != 2:
        raise HTTPException(status_code=422, detail="A Mate must have exactly 2 references")
    for ref in payload.references:
        _validate_mate_entity_ref(part, ref)
    if payload.references[0].occurrence_id == payload.references[1].occurrence_id:
        raise HTTPException(status_code=422, detail="A Mate's two references must name different occurrences")
    if payload.type in ("distance", "angle") and payload.value is None:
        raise HTTPException(
            status_code=422,
            detail=f"A {payload.type} Mate requires a value ({'mm' if payload.type == 'distance' else 'degrees'})",
        )


@router.post("/parts/{part_id}/mates", response_model=MateResponse, status_code=201)
def create_mate(part_id: str, payload: MateCreate) -> MateResponse:
    """Phase 6 (`docs/assembly-scope.md` §3): creates a Mate on `part_id` -
    data only, mirroring `Mate`'s own docstring ("this is data only, ...
    solving is `app.document.assembly_solver`'s job"). Does not solve
    anything itself - the client calls `POST .../occurrences/{id}/solve`
    afterward (see that endpoint's own docstring for why solving is a
    separate, explicit step rather than an automatic side effect of
    creating a Mate)."""
    part = get_part_or_404(part_id)
    _validate_mate_create(part, payload)
    mate = Mate(
        id=str(uuid.uuid4()),
        type=MateType(payload.type),
        references=[_mate_entity_ref_to_domain(ref) for ref in payload.references],
        value=payload.value,
        flipped=payload.flipped,
        allow_rotation=payload.allow_rotation,
    )
    part.mates.append(mate)
    return _mate_response(mate)


def _get_mate_or_404(part: Part, mate_id: str) -> Mate:
    for mate in part.mates:
        if mate.id == mate_id:
            return mate
    raise HTTPException(status_code=404, detail="Mate not found")


@router.patch("/parts/{part_id}/mates/{mate_id}", response_model=MateResponse)
def update_mate(part_id: str, mate_id: str, payload: MateUpdate) -> MateResponse:
    """`value`/`flipped`/`suppressed`/`allow_rotation` only - see
    `MateUpdate`'s own docstring for why `type`/`references` aren't editable
    here."""
    part = get_part_or_404(part_id)
    mate = _get_mate_or_404(part, mate_id)
    if payload.value is not None:
        mate.value = payload.value
    if payload.flipped is not None:
        mate.flipped = payload.flipped
    if payload.suppressed is not None:
        mate.suppressed = payload.suppressed
    if payload.allow_rotation is not None:
        mate.allow_rotation = payload.allow_rotation
    return _mate_response(mate)


@router.delete("/parts/{part_id}/mates/{mate_id}", status_code=204)
def delete_mate(part_id: str, mate_id: str) -> Response:
    part = get_part_or_404(part_id)
    mate = _get_mate_or_404(part, mate_id)
    part.mates.remove(mate)
    return Response(status_code=204)


def _component_pattern_axis_response(axis: ComponentPatternAxis | None) -> ComponentPatternAxisSchema | None:
    if axis is None:
        return None
    return ComponentPatternAxisSchema(origin=axis.origin, direction=axis.direction)


def _component_pattern_axis_to_domain(schema: ComponentPatternAxisSchema | None) -> ComponentPatternAxis | None:
    if schema is None:
        return None
    return ComponentPatternAxis(origin=schema.origin, direction=schema.direction)


def _component_pattern_response(pattern: ComponentPattern) -> ComponentPatternResponse:
    return ComponentPatternResponse(
        id=pattern.id,
        source_occurrence_ids=list(pattern.source_occurrence_ids),
        pattern_type=pattern.pattern_type.value,
        direction=pattern.direction,
        count=pattern.count,
        spacing=pattern.spacing,
        reverse=pattern.reverse,
        direction_2=pattern.direction_2,
        count_2=pattern.count_2,
        spacing_2=pattern.spacing_2,
        reverse_2=pattern.reverse_2,
        axis=_component_pattern_axis_response(pattern.axis),
        count_angular=pattern.count_angular,
        angle_total=pattern.angle_total,
        reverse_angular=pattern.reverse_angular,
        skip_indices=list(pattern.skip_indices),
        orient_with_rotation=pattern.orient_with_rotation,
        suppressed=pattern.suppressed,
    )


@router.get("/parts/{part_id}/component-patterns", response_model=list[ComponentPatternResponse])
def list_component_patterns(part_id: str) -> list[ComponentPatternResponse]:
    """Phase 7 (`docs/assembly-scope.md` §3 item 7): the Assembly tree's own
    Component Patterns list - `part_id`'s own `component_patterns`, full
    detail (unlike `PartResponse.component_pattern_ids`, ids only)."""
    part = get_part_or_404(part_id)
    return [_component_pattern_response(pattern) for pattern in part.component_patterns]


def _is_zero_vector(v: tuple[float, float, float]) -> bool:
    return v[0] == 0.0 and v[1] == 0.0 and v[2] == 0.0


def _validate_component_pattern_source_occurrence_ids(part: Part, source_occurrence_ids: list[str]) -> None:
    """`source_occurrence_ids` must be non-empty, and every entry must name
    a real, top-level Occurrence of `part` (this `ComponentPattern`'s own
    owner) - `ComponentPattern`'s own v1 scope limit, the identical
    top-level-only restriction Phase 5's gizmo and `_validate_mate_entity_
    ref` already enforce, satisfied automatically here since `part.
    occurrences` only ever holds top-level entries in the first place."""
    if not source_occurrence_ids:
        raise HTTPException(status_code=422, detail="ComponentPattern requires at least one source_occurrence_id")
    known_ids = {occurrence.id for occurrence in part.occurrences}
    for occurrence_id in source_occurrence_ids:
        if occurrence_id not in known_ids:
            raise HTTPException(
                status_code=422,
                detail={"type": "occurrence_not_found", "occurrence_id": occurrence_id},
            )


def _validate_component_pattern_linear_payload(
    direction: tuple[float, float, float],
    count: int,
    count_2: int,
    direction_2: tuple[float, float, float],
) -> None:
    """Mirrors `_validate_pattern_rectangular_payload`'s own shape, one
    level up: `direction` must be non-zero (a zero vector would otherwise
    silently fall back to `assembly._normalize`'s own +Z default -
    `ComponentPattern`'s docstring on `_linear_pattern_step` says this is
    rejected here rather than defended against there); `count`/`count_2`
    must each be >= 1 (a "pattern" of fewer than one instance in either
    direction is meaningless), their product must be at least 2 (a
    single-instance grid derives nothing beyond the untouched seed, the
    same no-op guard `PatternFeature`'s own count checks already use) and
    capped at `_PATTERN_MAX_TOTAL_INSTANCES`, the same sanity limit
    body-level patterns already share.

    Bug report (assembly testing): `direction_2` only needs to be
    well-formed (non-zero) once `count_2 > 1` actually puts it to use -
    mirrors `_validate_pattern_rectangular_payload`'s own "`direction_2`
    required exactly when `count_2 > 1`" rule, just against a plain vector
    (always present, never `None`) instead of an optional
    `PatternDirectionRef`."""
    if _is_zero_vector(direction):
        raise HTTPException(status_code=422, detail="ComponentPattern direction must not be the zero vector")
    if count < 1 or count_2 < 1:
        raise HTTPException(status_code=422, detail="ComponentPattern count and count_2 must each be >= 1")
    total = count * count_2
    if total < 2:
        raise HTTPException(
            status_code=422,
            detail="ComponentPattern count * count_2 must be >= 2 - otherwise no new instance is produced "
            "beyond the existing source Occurrence(s)",
        )
    if total > _PATTERN_MAX_TOTAL_INSTANCES:
        raise HTTPException(
            status_code=422,
            detail=f"ComponentPattern count * count_2 must not exceed {_PATTERN_MAX_TOTAL_INSTANCES} "
            f"total instances (got {total})",
        )
    if count_2 > 1 and _is_zero_vector(direction_2):
        raise HTTPException(
            status_code=422,
            detail="ComponentPattern direction_2 must not be the zero vector when count_2 > 1",
        )


def _validate_component_pattern_circular_payload(
    axis: ComponentPatternAxis | None, count_angular: int, angle_total: float
) -> None:
    """Mirrors `_validate_pattern_circular_payload`'s own shape - `axis` may
    be omitted (unlike `PatternAxisRef`, `ComponentPatternAxis` has a
    genuinely meaningful default, the world Z axis through the origin, see
    that dataclass's own docstring), but an explicitly-given `axis.direction`
    must still be non-zero. `count_angular`/`angle_total` share the exact
    same no-op/cap/range checks `_validate_pattern_circular_payload` already
    enforces for the body-level equivalent."""
    if axis is not None and _is_zero_vector(axis.direction):
        raise HTTPException(status_code=422, detail="ComponentPattern axis direction must not be the zero vector")
    if count_angular < 2:
        raise HTTPException(
            status_code=422,
            detail="ComponentPattern count_angular must be >= 2 - otherwise no new instance is produced "
            "beyond the existing source Occurrence(s)",
        )
    if count_angular > _PATTERN_MAX_TOTAL_INSTANCES:
        raise HTTPException(
            status_code=422,
            detail=f"ComponentPattern count_angular must not exceed {_PATTERN_MAX_TOTAL_INSTANCES} "
            f"(got {count_angular})",
        )
    if angle_total <= 0 or angle_total > 360:
        raise HTTPException(status_code=422, detail="ComponentPattern angle_total must be > 0 and <= 360")


def _validate_component_pattern_payload(
    pattern_type: ComponentPatternType,
    direction: tuple[float, float, float],
    count: int,
    axis: ComponentPatternAxis | None,
    count_angular: int,
    angle_total: float,
    skip_indices: list[int],
    count_2: int = 1,
    direction_2: tuple[float, float, float] = (0.0, 1.0, 0.0),
) -> None:
    """The single entry point both `create_component_pattern`/`update_
    component_pattern` call - mirrors `_validate_pattern_payload`'s own
    per-`pattern_type` dispatch. `skip_indices` (Phase 11, `[9]`) reuses
    `_validate_pattern_skip_indices` verbatim, against whichever of
    `count * count_2`/`count_angular` is this pattern_type's own actual
    total instance count - the same per-`pattern_type` field selection
    every other check here already makes. `count_2`/`direction_2` default
    to their own inert values so every pre-existing call site (before the
    second direction existed) keeps validating exactly as before."""
    if pattern_type == ComponentPatternType.CIRCULAR:
        _validate_component_pattern_circular_payload(axis, count_angular, angle_total)
        _validate_pattern_skip_indices(skip_indices, count_angular)
    else:
        _validate_component_pattern_linear_payload(direction, count, count_2, direction_2)
        _validate_pattern_skip_indices(skip_indices, count * max(count_2, 1))


@router.post("/parts/{part_id}/component-patterns", response_model=ComponentPatternResponse, status_code=201)
def create_component_pattern(part_id: str, payload: ComponentPatternCreate) -> ComponentPatternResponse:
    """Phase 7 (`docs/assembly-scope.md` §3 item 7): creates a
    `ComponentPattern` on `part_id` - data only, mirroring `ComponentPattern`'s
    own docstring (no derived instance is persisted here - expansion happens
    at `GET /parts/{part_id}/assembly-mesh` fetch time, `app.document.
    assembly.expand_component_pattern_instances`)."""
    part = get_part_or_404(part_id)
    _validate_component_pattern_source_occurrence_ids(part, payload.source_occurrence_ids)
    pattern_type = ComponentPatternType(payload.pattern_type)
    axis = _component_pattern_axis_to_domain(payload.axis)
    _validate_component_pattern_payload(
        pattern_type,
        payload.direction,
        payload.count,
        axis,
        payload.count_angular,
        payload.angle_total,
        payload.skip_indices,
        count_2=payload.count_2,
        direction_2=payload.direction_2,
    )
    pattern = ComponentPattern(
        id=str(uuid.uuid4()),
        source_occurrence_ids=list(payload.source_occurrence_ids),
        pattern_type=pattern_type,
        direction=payload.direction,
        count=payload.count,
        spacing=payload.spacing,
        reverse=payload.reverse,
        direction_2=payload.direction_2,
        count_2=payload.count_2,
        spacing_2=payload.spacing_2,
        reverse_2=payload.reverse_2,
        axis=axis,
        count_angular=payload.count_angular,
        angle_total=payload.angle_total,
        reverse_angular=payload.reverse_angular,
        skip_indices=list(payload.skip_indices),
        orient_with_rotation=payload.orient_with_rotation,
    )
    part.component_patterns.append(pattern)
    return _component_pattern_response(pattern)


def _get_component_pattern_or_404(part: Part, pattern_id: str) -> ComponentPattern:
    for pattern in part.component_patterns:
        if pattern.id == pattern_id:
            return pattern
    raise HTTPException(status_code=404, detail="ComponentPattern not found")


@router.patch("/parts/{part_id}/component-patterns/{pattern_id}", response_model=ComponentPatternResponse)
def update_component_pattern(
    part_id: str, pattern_id: str, payload: ComponentPatternUpdate
) -> ComponentPatternResponse:
    """Partial update - `pattern_type` is never revised (see
    `ComponentPatternUpdate`'s own docstring); every other field can be
    adjusted in place (count/spacing/direction/axis/angle are the normal
    day-to-day tweaks a user makes to an existing pattern). Re-validates the
    fully-merged result the same way `update_pattern_feature` does, not just
    whichever fields this particular payload happened to touch."""
    part = get_part_or_404(part_id)
    pattern = _get_component_pattern_or_404(part, pattern_id)
    if payload.source_occurrence_ids is not None:
        _validate_component_pattern_source_occurrence_ids(part, payload.source_occurrence_ids)
        pattern.source_occurrence_ids = list(payload.source_occurrence_ids)
    if payload.direction is not None:
        pattern.direction = payload.direction
    if payload.count is not None:
        pattern.count = payload.count
    if payload.spacing is not None:
        pattern.spacing = payload.spacing
    if payload.reverse is not None:
        pattern.reverse = payload.reverse
    if payload.direction_2 is not None:
        pattern.direction_2 = payload.direction_2
    if payload.count_2 is not None:
        pattern.count_2 = payload.count_2
    if payload.spacing_2 is not None:
        pattern.spacing_2 = payload.spacing_2
    if payload.reverse_2 is not None:
        pattern.reverse_2 = payload.reverse_2
    if payload.axis is not None:
        pattern.axis = _component_pattern_axis_to_domain(payload.axis)
    if payload.count_angular is not None:
        pattern.count_angular = payload.count_angular
    if payload.angle_total is not None:
        pattern.angle_total = payload.angle_total
    if payload.reverse_angular is not None:
        pattern.reverse_angular = payload.reverse_angular
    if payload.skip_indices is not None:
        pattern.skip_indices = list(payload.skip_indices)
    if payload.orient_with_rotation is not None:
        pattern.orient_with_rotation = payload.orient_with_rotation
    if payload.suppressed is not None:
        pattern.suppressed = payload.suppressed
    _validate_component_pattern_payload(
        pattern.pattern_type,
        pattern.direction,
        pattern.count,
        pattern.axis,
        pattern.count_angular,
        pattern.angle_total,
        pattern.skip_indices,
        count_2=pattern.count_2,
        direction_2=pattern.direction_2,
    )
    return _component_pattern_response(pattern)


@router.delete("/parts/{part_id}/component-patterns/{pattern_id}", status_code=204)
def delete_component_pattern(part_id: str, pattern_id: str) -> Response:
    part = get_part_or_404(part_id)
    pattern = _get_component_pattern_or_404(part, pattern_id)
    part.component_patterns.remove(pattern)
    return Response(status_code=204)


def _mate_solve_did_not_converge(occurrence_id: str, result: GroupSolveResult) -> HTTPException:
    return HTTPException(
        status_code=422,
        detail={"type": "mate_solve_did_not_converge", "occurrence_id": occurrence_id, "dof": result.dof},
    )


def _commit_group(part: Part, result: GroupSolveResult) -> None:
    """Persist every solved member's pose together. All poses were computed (and
    verified by residual) before this runs and each store is a plain attribute
    assignment, so a group is written entirely or - on `converged: false`, which
    never reaches here - not at all."""
    by_id = {o.id: o for o in part.occurrences}
    for occurrence_id, pose in result.poses.items():
        by_id[occurrence_id].transform = pose


@router.post("/parts/{part_id}/occurrences/{occurrence_id}/solve", response_model=OccurrenceResponse)
def solve_for_occurrence(part_id: str, occurrence_id: str) -> OccurrenceResponse:
    """Snaps `occurrence_id` (and, only as its mates require, the occurrences
    mated to it) onto the nearest mate-satisfying configuration
    (`assembly_group.solve_group`, the whole mate-graph component - no longer the
    occurrence alone against frozen peers) and stores it. Non-convergence: 422
    `mate_solve_did_not_converge`, nothing stored. A `fixed` occurrence 422s
    (`occurrence_is_fixed`) - its transform is locked.

    Kept as the gizmo's post-drag / post-`create_mate` snap: the raw dragged pose
    is already stored on the occurrence, so the solve's wish is its stored pose.
    The response is the driven occurrence; followers that moved are visible on
    the next fetch."""
    part = get_part_or_404(part_id)
    occurrence = _get_occurrence_or_404(part, occurrence_id)
    if occurrence.fixed:
        raise _occurrence_is_fixed(occurrence_id)
    result = solve_group(get_document(), part, occurrence_id, None, with_jump=False)
    if not result.converged:
        raise _mate_solve_did_not_converge(occurrence_id, result)
    _commit_group(part, result)
    return _occurrence_response(occurrence)


def _rigid_transform_response(transform: RigidTransform) -> RigidTransformResponse:
    return RigidTransformResponse(
        translation=transform.translation,
        rotation_axis=transform.rotation_axis,
        rotation_angle_degrees=transform.rotation_angle_degrees,
    )


@router.post("/parts/{part_id}/occurrences/{occurrence_id}/mate-motion", response_model=MateMotionResponse)
def mate_motion(part_id: str, occurrence_id: str, payload: MateMotionRequest) -> MateMotionResponse:
    """Constrained drag (`docs/constrained-drag-implementation-plan.md` §3):
    `occurrence_id` is the GRABBED occurrence. Solves its whole mate-graph
    component (`assembly_group.solve_group`) from the wanted pose
    `payload.transform` (else its stored one) and returns the nearest
    mate-satisfying pose of every member, the GROUP dof, per-member mobility and
    an orthonormal free-motion `basis` (`MateMotionResponse`). Stores nothing
    unless `payload.commit` (then every member is written together, one
    transaction). A `fixed` grabbed occurrence 422s like `solve_for_occurrence`;
    non-convergence is `converged: false` with NO basis (not a 4xx), and a
    `commit` with `converged: false` stores nothing.
"""
    part = get_part_or_404(part_id)
    occurrence = _get_occurrence_or_404(part, occurrence_id)
    if occurrence.fixed:
        raise _occurrence_is_fixed(occurrence_id)
    wanted = None
    if payload.transform is not None:
        _validate_occurrence_transform_payload(payload.transform.rotation_axis, payload.transform.rotation_angle_degrees)
        wanted = RigidTransform(
            translation=tuple(payload.transform.translation),
            rotation_axis=tuple(payload.transform.rotation_axis),
            rotation_angle_degrees=payload.transform.rotation_angle_degrees,
        )
    document = get_document()
    started = time.perf_counter()
    reference = None
    if payload.reference:
        reference = {
            r.occurrence_id: RigidTransform(
                translation=tuple(r.transform.translation),
                rotation_axis=tuple(r.transform.rotation_axis),
                rotation_angle_degrees=r.transform.rotation_angle_degrees,
            )
            for r in payload.reference
        }
    result = solve_group(document, part, occurrence_id, wanted, payload.lever_arm, reference=reference)
    solve_ms = (time.perf_counter() - started) * 1000.0
    if not result.converged or result.analysis is None:
        return MateMotionResponse(
            converged=False,
            quality=MateMotionQuality(residual_inf=result.quality.residual_inf),
            diagnostics=MateMotionDiagnostics(solve_ms=solve_ms),
        )
    analysis = result.analysis
    if payload.commit:
        _commit_group(part, result)
    quality = result.quality
    return MateMotionResponse(
        converged=True,
        dof=analysis.dof,
        grounded=analysis.grounded,
        members=[
            MateMotionMember(
                occurrence_id=oid, transform=_rigid_transform_response(result.poses[oid]), mobility=analysis.mobility[oid]
            )
            for oid in analysis.member_ids
        ],
        basis=[[float(x) for x in row] for row in analysis.basis],
        chart=MateMotionChart(lever_arm=analysis.lever_arm),
        quality=MateMotionQuality(
            residual_inf=quality.residual_inf,
            sigma_min=analysis.quality.sigma_min,
            sigma_gap=analysis.quality.sigma_gap,
            max_step=quality.max_step,
            jump=quality.jump,
        ),
        diagnostics=MateMotionDiagnostics(solve_ms=solve_ms),
        committed=payload.commit,
        constraint_model=result.constraint_model if payload.include_constraint_model else None,
    )


@router.post(
    "/parts/{part_id}/occurrences/{occurrence_id}/preview-mate-solve",
    response_model=MateSolvePreviewResponse,
)
def preview_mate_solve_endpoint(
    part_id: str, occurrence_id: str, payload: MateCreate
) -> MateSolvePreviewResponse:
    """Test report item 3 (New Mate ghost preview): a dry-run counterpart to
    `solve_for_occurrence` - solves `payload` (the same shape `POST
    .../mates` accepts) as a *hypothetical* Mate referencing `occurrence_id`,
    against `occurrence_id`'s real peers (both its own already-created Mates
    and `payload` itself), without creating a Mate or mutating
    `occurrence_id`'s own `transform` at all (the hypothetical mate joins
    the group solve as `extra_mates`). `MatePanel` calls this on every type/value/flip/allow-
    rotation change while the user is still picking/adjusting, well before
    ever tapping Confirm.

    Deliberately tolerant where `solve_for_occurrence`/`create_mate` are
    strict: an in-progress payload (missing `value` for `distance`/`angle`,
    a reference the geometry resolver can't yet use for this `type`, a
    still-`fixed` driven Occurrence, or a solve that genuinely doesn't
    converge) reports `converged: false` rather than a 4xx - none of those
    are errors mid-edit, they're just "no ghost to show yet." Only a
    structurally-broken request (unknown `part_id`/`occurrence_id`, not
    exactly 2 references) is a real 404/422, mirroring every other
    endpoint's own payload-shape validation."""
    part = get_part_or_404(part_id)
    occurrence = _get_occurrence_or_404(part, occurrence_id)
    if len(payload.references) != 2:
        raise HTTPException(status_code=422, detail="A Mate must have exactly 2 references")
    if occurrence.fixed:
        return MateSolvePreviewResponse(converged=False, transform=None)
    try:
        for ref in payload.references:
            _validate_mate_entity_ref(part, ref)
        extra_mate = Mate(
            id="preview",
            type=MateType(payload.type),
            references=[_mate_entity_ref_to_domain(ref) for ref in payload.references],
            value=payload.value,
            flipped=payload.flipped,
            allow_rotation=payload.allow_rotation,
        )
        result = solve_group(get_document(), part, occurrence_id, None, extra_mates=(extra_mate,), with_jump=False)
    except HTTPException:
        return MateSolvePreviewResponse(converged=False, transform=None)
    if not result.converged:
        return MateSolvePreviewResponse(converged=False, transform=None)
    return MateSolvePreviewResponse(converged=True, transform=_rigid_transform_response(result.poses[occurrence_id]))


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


def _external_reference_statuses(part: Part, feature: SketchFeature) -> list[ExternalReferenceStatus]:
    sketch = get_sketch_or_404(feature.sketch_id)
    if sketch.external_references:
        excluded = excluded_feature_ids_after(part, feature.id)
        bodies = compute_part_bodies(part, excluded)
        refresh_external_references(part, sketch, bodies, excluded, history=history_for_part(part, excluded))
    out = []
    for point_id, ref in sketch.external_references.items():
        decision = sketch.external_reference_decisions.get(point_id)
        out.append(
            ExternalReferenceStatus(
                point_id=point_id,
                body_id=ref.body_id,
                kind=ref.kind,
                vertex_index=ref.vertex_index,
                status=decision.status.value if decision else "ok",
                reason=decision.reason if decision else "",
                method=decision.method if decision else "",
                candidates=list(decision.candidates) if decision and decision.status == ReferenceStatus.LOST else [],
            )
        )
    return out


@router.get(
    "/parts/{part_id}/features/sketch/{feature_id}/external-references",
    response_model=list[ExternalReferenceStatus],
)
def list_external_references(part_id: str, feature_id: str) -> list[ExternalReferenceStatus]:
    """Reference-identity overhaul: the health of every external reference of this Sketch (see `ExternalReferenceStatus`), after a fresh refresh -
    which Points are lost / potentially moved and why. `GET .../features` carries the same ids as `lost_reference_point_ids` /
    `moved_reference_point_ids`; this is the per-reference detail a "fix this reference" UI needs."""
    part = get_part_or_404(part_id)
    return _external_reference_statuses(part, _get_sketch_feature_or_404(part, feature_id))


@router.post(
    "/parts/{part_id}/features/sketch/{feature_id}/external-references/{point_id}/reattach",
    response_model=PointResponse,
)
def reattach_external_reference(
    part_id: str, feature_id: str, point_id: str, payload: ExternalReferenceReattach
) -> PointResponse:
    """Reference-identity overhaul: points the existing external-reference Point `point_id` at a different Body vertex (the replacement the user picked
    for a lost or potentially-moved reference). Everything built on the Point (lines, dimensions, constraints) stays attached to it; only what it tracks
    changes, and its signature / lineage are re-captured from the new vertex. 404 for a Point that is not an external reference of this Sketch; the usual
    `missing_reference` 422 if the vertex does not exist."""
    part = get_part_or_404(part_id)
    sketch_feature = _get_sketch_feature_or_404(part, feature_id)
    sketch = get_sketch_or_404(sketch_feature.sketch_id)
    if point_id not in sketch.external_references or point_id not in sketch.points:
        raise HTTPException(status_code=404, detail="point_id is not an external reference of this Sketch")
    excluded = excluded_feature_ids_after(part, feature_id)
    bodies = compute_part_bodies(part, excluded)
    existing = sketch.external_references[point_id]
    point = sketch.points[point_id]
    if existing.kind == "circle_centre":
        if payload.edge_index is None:
            raise HTTPException(status_code=422, detail={"type": "edge_required", "point_id": point_id})
        reference = make_circle_centre_reference(
            bodies, payload.body_id, payload.edge_index, history_for_part(part, excluded).lineage_for(payload.body_id, payload.edge_index, "edge")
        )
        sketch.external_references[point_id] = reference
        # `refresh_external_references` moves the Point to the new centre, and the Circle / Arc built on it with it (position and radius); the new edge must lie in
        # this Sketch's plane, otherwise it is refused and the old binding restored.
        lost = refresh_external_references(part, sketch, bodies, excluded)
        if point_id in lost:
            reason = sketch.external_reference_decisions[point_id].reason
            sketch.external_references[point_id] = existing
            raise HTTPException(status_code=422, detail={"type": "not_coplanar" if reason == "not_coplanar" else "reference_lost", "reason": reason})
        sketch.external_reference_decisions.pop(point_id, None)
        return PointResponse(id=point.id, x=point.x, y=point.y, is_locked=True)
    if payload.vertex_index is None:
        raise HTTPException(status_code=422, detail={"type": "vertex_required", "point_id": point_id})
    _reattach_vertex_point(part, sketch, point_id, payload.body_id, payload.vertex_index, bodies, excluded)
    return PointResponse(id=point.id, x=point.x, y=point.y, is_locked=True)


def _reattach_vertex_point(part, sketch, point_id: str, body_id: str, vertex_index: int, bodies: dict, excluded) -> None:
    """Points the vertex-following external-reference Point `point_id` at Body vertex `vertex_index` (re-captured signature and lineage, moved to where it is)."""
    reference = make_external_vertex_reference(bodies, body_id, vertex_index)
    reference = dataclasses.replace(reference, lineage=history_for_part(part, excluded).lineage_for(body_id, vertex_index))
    x, y = resolve_external_vertex_position(part, sketch, reference, bodies, excluded)
    sketch.external_references[point_id] = reference
    sketch.external_reference_decisions.pop(point_id, None)
    point = sketch.points[point_id]
    point.x, point.y = x, y


@router.post(
    "/parts/{part_id}/features/sketch/{feature_id}/external-references/reattach-edge",
    response_model=list[PointResponse],
)
def reattach_external_edge(part_id: str, feature_id: str, payload: ExternalEdgeReattach) -> list[PointResponse]:
    """DIDSA-VR plan, phase 4.1: one pick mends both corners of an edge. `point_ids` are the two external-reference (vertex) Points of one converted / referenced
    edge (a pinned line's ends); `body_id` + `edge_index` the replacement edge. The two Points are matched to the replacement's two end vertices by where they
    are now (the pairing with the smaller total distance, so a line keeps its direction), and each is re-attached exactly as `.../{point_id}/reattach` does
    (the Point and everything built on it keep their ids). All or nothing: if either end cannot be re-attached nothing changes. 422 `degenerate_edge` for an edge
    whose two ends are one vertex; 404 for a Point that is not a vertex reference of this Sketch."""
    part = get_part_or_404(part_id)
    sketch_feature = _get_sketch_feature_or_404(part, feature_id)
    sketch = get_sketch_or_404(sketch_feature.sketch_id)
    if len(set(payload.point_ids)) != 2:
        raise HTTPException(status_code=422, detail={"type": "two_points_required"})
    for point_id in payload.point_ids:
        existing = sketch.external_references.get(point_id)
        if existing is None or point_id not in sketch.points or existing.kind != "vertex":
            raise HTTPException(status_code=404, detail=f"{point_id} is not a vertex reference of this Sketch")
    excluded = excluded_feature_ids_after(part, feature_id)
    bodies = compute_part_bodies(part, excluded)
    start_ref, end_ref = edge_endpoint_vertex_refs(bodies, SubShapeRef(body_id=payload.body_id, shape_type=SubShapeType.EDGE, index=payload.edge_index))
    if start_ref.index == end_ref.index:
        raise HTTPException(status_code=422, detail={"type": "degenerate_edge", "body_id": payload.body_id, "index": payload.edge_index})
    positions = []
    for ref in (start_ref, end_ref):
        vertex = make_external_vertex_reference(bodies, payload.body_id, ref.index)
        positions.append(resolve_external_vertex_position(part, sketch, vertex, bodies, excluded))
    first, second = (sketch.points[i] for i in payload.point_ids)

    def cost(a, b) -> float:
        return math.dist((first.x, first.y), a) + math.dist((second.x, second.y), b)

    swapped = cost(positions[1], positions[0]) < cost(positions[0], positions[1])
    vertex_for = {payload.point_ids[0]: (end_ref if swapped else start_ref).index, payload.point_ids[1]: (start_ref if swapped else end_ref).index}
    saved = {i: (sketch.external_references[i], sketch.points[i].x, sketch.points[i].y) for i in payload.point_ids}
    try:
        for point_id, vertex_index in vertex_for.items():
            _reattach_vertex_point(part, sketch, point_id, payload.body_id, vertex_index, bodies, excluded)
    except HTTPException:
        for point_id, (ref, x, y) in saved.items():
            sketch.external_references[point_id] = ref
            sketch.points[point_id].x, sketch.points[point_id].y = x, y
        raise
    return [PointResponse(id=i, x=sketch.points[i].x, y=sketch.points[i].y, is_locked=True) for i in payload.point_ids]


@router.post(
    "/parts/{part_id}/features/sketch/{feature_id}/external-references/{point_id}/confirm",
    response_model=PointResponse,
)
def confirm_external_reference(part_id: str, feature_id: str, point_id: str) -> PointResponse:
    """Reference-identity overhaul: "yes, this is the right vertex" for a `potentially_moved` reference - re-captures its signature (and lineage) from the
    vertex it is bound to now, so it stops being flagged. 409 if the reference is lost (nothing to confirm: re-attach it instead)."""
    part = get_part_or_404(part_id)
    sketch_feature = _get_sketch_feature_or_404(part, feature_id)
    sketch = get_sketch_or_404(sketch_feature.sketch_id)
    ref = sketch.external_references.get(point_id)
    if ref is None or point_id not in sketch.points:
        raise HTTPException(status_code=404, detail="point_id is not an external reference of this Sketch")
    excluded = excluded_feature_ids_after(part, feature_id)
    bodies = compute_part_bodies(part, excluded)
    lost = refresh_external_references(part, sketch, bodies, excluded, history=history_for_part(part, excluded))
    if point_id in lost:
        raise HTTPException(status_code=409, detail={"type": "reference_lost", "point_id": point_id})
    ref = sketch.external_references[point_id]
    confirmed = capture_external_reference(bodies, ref)
    confirmed = dataclasses.replace(
        confirmed,
        lineage=history_for_part(part, excluded).lineage_for(ref.body_id, ref.vertex_index, "edge" if ref.kind == "circle_centre" else "vertex")
        or ref.lineage,
    )
    sketch.external_references[point_id] = confirmed
    sketch.external_reference_decisions.pop(point_id, None)
    point = sketch.points[point_id]
    return PointResponse(id=point.id, x=point.x, y=point.y, is_locked=True)


def _new_external_reference(
    part: Part, sketch, bodies: dict, excluded: frozenset[str], body_id: str, vertex_index: int
) -> ExternalVertexReference:
    """The `ExternalVertexReference` a creation route stores for (`body_id`, `vertex_index`): carries the vertex's geometric signature and, when OCCT history
    can say, its lineage (reference-identity overhaul, docs/reference-identity-design.md). A vertex the Sketch already tracks is returned as it is (the
    convert-entities routes are re-pick-idempotent, and re-measuring must neither cost a history replay nor replace a healthy signature)."""
    probe = ExternalVertexReference(body_id=body_id, vertex_index=vertex_index)
    for point_id, existing in sketch.external_references.items():
        if existing == probe and point_id in sketch.points:
            return existing
    reference = make_external_vertex_reference(bodies, body_id, vertex_index)
    lineage = history_for_part(part, excluded).lineage_for(body_id, vertex_index)
    return dataclasses.replace(reference, lineage=lineage)


def _new_circle_centre_reference(part: Part, sketch, bodies: dict, excluded: frozenset[str], body_id: str, edge_index: int) -> ExternalVertexReference:
    """`_new_external_reference`'s sibling for the centre of a circular edge (`kind="circle_centre"`, lineage of the EDGE): the
    reference already tracking this edge's centre if the Sketch has one, else a new, signed one."""
    probe = ExternalVertexReference(body_id=body_id, vertex_index=edge_index, kind="circle_centre")
    for point_id, existing in sketch.external_references.items():
        if existing == probe and point_id in sketch.points:
            return existing
    lineage = history_for_part(part, excluded).lineage_for(body_id, edge_index, "edge")
    return make_circle_centre_reference(bodies, body_id, edge_index, lineage)


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
    excluded = excluded_feature_ids_after(part, feature_id)
    bodies = compute_part_bodies(part, excluded)
    ref = _new_external_reference(part, sketch, bodies, excluded, payload.body_id, payload.vertex_index)
    x, y = resolve_external_vertex_position(part, sketch, ref, bodies, excluded)
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
    excluded = excluded_feature_ids_after(part, feature_id)
    bodies = compute_part_bodies(part, excluded)
    edge_ref = SubShapeRef(body_id=payload.body_id, shape_type=SubShapeType.EDGE, index=payload.edge_index)
    start_ref, end_ref = edge_endpoint_vertex_refs(bodies, edge_ref)
    if start_ref.index == end_ref.index:
        raise HTTPException(
            status_code=422,
            detail={"type": "degenerate_edge", "body_id": payload.body_id, "index": payload.edge_index},
        )

    start_vertex_ref = _new_external_reference(part, sketch, bodies, excluded, start_ref.body_id, start_ref.index)
    start_x, start_y = resolve_external_vertex_position(part, sketch, start_vertex_ref, bodies, excluded)
    start_point = sketch.add_external_vertex_reference(start_x, start_y, start_vertex_ref)

    end_vertex_ref = _new_external_reference(part, sketch, bodies, excluded, end_ref.body_id, end_ref.index)
    end_x, end_y = resolve_external_vertex_position(part, sketch, end_vertex_ref, bodies, excluded)
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
    """Convert Entities' vertex route (see `_convert_body_vertex`), plus the Phase 2.1 reference flag on the Point."""
    sketch = get_sketch_or_404(_get_sketch_feature_or_404(get_part_or_404(part_id), feature_id).sketch_id)
    before_points = set(sketch.points)
    response = _convert_body_vertex(part_id, feature_id, payload)
    _flag_converted(sketch, payload.reference, before_points, set(), [response.id], [])
    response.is_reference = sketch.is_reference(response.id)
    return response


def _convert_body_vertex(part_id: str, feature_id: str, payload: ConvertVertexCreate) -> PointResponse:
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
    excluded = excluded_feature_ids_after(part, feature_id)
    bodies = compute_part_bodies(part, excluded)
    ref = _new_external_reference(part, sketch, bodies, excluded, payload.body_id, payload.vertex_index)
    x, y = resolve_external_vertex_position(part, sketch, ref, bodies, excluded)
    point = sketch.add_or_reuse_external_vertex_reference(x, y, ref)
    return PointResponse(id=point.id, x=point.x, y=point.y, is_locked=sketch.is_point_locked(point.id))


def _drop_constraints_between_pinned_points(sketch, constraint_ids: list[str]) -> None:
    """A converted Circle / Arc is pinned in every Point (a live reference or a Fix), so the provisional radius / cardinal-point constraints `add_circle` /
    `add_arc` made for it only relate pinned Points to each other. Each is redundant by construction, and py-slvs reports that as result_code 5, which then
    stops it trusting `converged` for any constraint outside its allowlist (an `at_midpoint` on a neighbouring pinned edge was refused for exactly this).
    Dropping them leaves the shape exactly as pinned and the system with no redundancy. The entity keeps its (now unused) ids: every reader tolerates a missing one."""
    for constraint_id in constraint_ids:
        sketch.constraints.pop(constraint_id, None)


def _flag_converted(sketch, reference: bool, before_points: set, before_entities: set, point_ids: list[str], entity_ids: list[str]) -> None:
    """Phase 2.1: a `reference: true` convert flags what it MADE (Points and entities that were not in the Sketch before the call); something that was already there
    keeps whatever flag it had. An ordinary convert (`reference` false) makes everything it touched real geometry again: it takes a flagged helper over."""
    if reference:
        sketch.mark_reference(*[i for i in point_ids if i not in before_points], *[i for i in entity_ids if i not in before_entities])
    else:
        sketch.unmark_reference(*point_ids, *entity_ids)


@router.post(
    "/parts/{part_id}/features/sketch/{feature_id}/convert-entities/face",
    response_model=ConvertFaceResponse,
    status_code=201,
)
def convert_body_face(part_id: str, feature_id: str, payload: ConvertFaceCreate) -> ConvertFaceResponse:
    """DIDSA-VR plan, phase 2.2: makes a FACE of the part usable in this sketch (see `app.document.face_reference`). A flat face perpendicular to the sketch plane
    becomes a pinned line between its two extreme corners (live vertex references; idempotent, an existing line between the same two Points is reused); a round
    face whose axis is perpendicular to the sketch plane becomes a live centre (`circle_centre` reference of one of its circular edges, no shape). Anything else
    is a structured 422 (`face_not_perpendicular`, `face_axis_not_perpendicular`, `unsupported_face`, `face_has_no_circular_edge`, `degenerate_face`)."""
    part = get_part_or_404(part_id)
    sketch_feature = _get_sketch_feature_or_404(part, feature_id)
    sketch = get_sketch_or_404(sketch_feature.sketch_id)
    excluded = excluded_feature_ids_after(part, feature_id)
    bodies = compute_part_bodies(part, excluded)
    basis = basis_for_sketch(part, sketch, bodies, excluded)
    before_points, before_entities = set(sketch.points), set(sketch.entities)
    kind = classify_face(bodies, payload.body_id, payload.face_index, basis)
    if kind == "centre":
        axis = face_axis(bodies, payload.body_id, payload.face_index, basis)
        centre = sketch.add_or_reuse_external_vertex_reference(
            axis.xy[0], axis.xy[1], _new_circle_centre_reference(part, sketch, bodies, excluded, payload.body_id, axis.edge_index)
        )
        _flag_converted(sketch, payload.reference, before_points, before_entities, [centre.id], [])
        return ConvertFaceResponse(
            kind="centre",
            center_point=PointResponse(id=centre.id, x=centre.x, y=centre.y, is_locked=True, is_reference=sketch.is_reference(centre.id)),
        )
    face = face_line(bodies, payload.body_id, payload.face_index, basis)
    start_ref = _new_external_reference(part, sketch, bodies, excluded, payload.body_id, face.start_vertex)
    start_point = sketch.add_or_reuse_external_vertex_reference(face.start_xy[0], face.start_xy[1], start_ref)
    end_ref = _new_external_reference(part, sketch, bodies, excluded, payload.body_id, face.end_vertex)
    end_point = sketch.add_or_reuse_external_vertex_reference(face.end_xy[0], face.end_xy[1], end_ref)
    line = next((l for l in sketch.lines() if {l.start_point_id, l.end_point_id} == {start_point.id, end_point.id}), None)
    if line is None:
        line = sketch.add_line(start_point.id, end_point.id, construction=payload.construction)
    _flag_converted(sketch, payload.reference, before_points, before_entities, [start_point.id, end_point.id], [line.id])
    return ConvertFaceResponse(
        kind="line",
        line=LineResponse(
            id=line.id,
            start_point_id=line.start_point_id,
            end_point_id=line.end_point_id,
            length=line.length(sketch.points),
            construction=line.construction,
            is_reference=sketch.is_reference(line.id),
        ),
        start_point=PointResponse(id=start_point.id, x=start_point.x, y=start_point.y, is_locked=True, is_reference=sketch.is_reference(start_point.id)),
        end_point=PointResponse(id=end_point.id, x=end_point.x, y=end_point.y, is_locked=True, is_reference=sketch.is_reference(end_point.id)),
    )


@router.post(
    "/parts/{part_id}/features/sketch/{feature_id}/convert-entities/edge",
    response_model=ConvertEdgeResponse,
    status_code=201,
)
def convert_body_edge(part_id: str, feature_id: str, payload: ConvertEdgeCreate) -> ConvertEdgeResponse:
    """Convert Entities' edge route (see `_convert_body_edge` for what it makes), plus the Phase 2.1 reference flag on the Points and the Line / Circle / Arc."""
    sketch = get_sketch_or_404(_get_sketch_feature_or_404(get_part_or_404(part_id), feature_id).sketch_id)
    before_points, before_entities = set(sketch.points), set(sketch.entities)
    response = _convert_body_edge(part_id, feature_id, payload)
    shape = response.line or response.arc or response.circle
    points = [p for p in (response.start_point, response.end_point, response.center_point) if p is not None]
    _flag_converted(sketch, payload.reference, before_points, before_entities, [p.id for p in points], [shape.id] if shape is not None else [])
    for p in points:
        p.is_reference = sketch.is_reference(p.id)
    if shape is not None:
        shape.is_reference = sketch.is_reference(shape.id)
    return response


def _convert_body_edge(part_id: str, feature_id: str, payload: ConvertEdgeCreate) -> ConvertEdgeResponse:
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
    excluded = excluded_feature_ids_after(part, feature_id)
    bodies = compute_part_bodies(part, excluded)
    edge_ref = SubShapeRef(body_id=payload.body_id, shape_type=SubShapeType.EDGE, index=payload.edge_index)
    start_ref, end_ref = edge_endpoint_vertex_refs(bodies, edge_ref)
    if start_ref.index == end_ref.index:
        basis = basis_for_sketch(part, sketch, bodies, excluded)
        circle_params = resolve_full_circular_edge(bodies, edge_ref, basis)
        if circle_params is None:
            raise HTTPException(
                status_code=422,
                detail={"type": "degenerate_edge", "body_id": payload.body_id, "index": payload.edge_index},
            )
        center_x, center_y, radius = circle_params
        # Reference-identity overhaul: the centre is a live reference to the circular edge (`kind="circle_centre"`), so the Circle follows its hole / boss when an
        # upstream edit moves it or changes its diameter - and is flagged, like any reference, when the edge is gone.
        center_point = sketch.add_or_reuse_external_vertex_reference(
            center_x, center_y, _new_circle_centre_reference(part, sketch, bodies, excluded, payload.body_id, payload.edge_index)
        )
        existing_circle = next((c for c in sketch.circles() if c.center_point_id == center_point.id), None)
        if existing_circle is not None:
            # Idempotent per edge, as `convert_body_vertex` is: the same rim converted again answers with the Circle already made (R-E).
            centre_existing = PointResponse(id=center_point.id, x=center_point.x, y=center_point.y, is_locked=True)
            return ConvertEdgeResponse(
                circle=CircleResponse(
                    id=existing_circle.id,
                    center_point_id=existing_circle.center_point_id,
                    radius_point_id=existing_circle.radius_point_id,
                    radius=existing_circle.radius(sketch.points),
                    construction=existing_circle.construction,
                    cardinal_point_ids=existing_circle.cardinal_point_ids,
                    radius_constraint_id=existing_circle.radius_constraint_id,
                ),
                start_point=centre_existing,
                end_point=centre_existing,
                center_point=centre_existing,
            )
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
        _drop_constraints_between_pinned_points(sketch, [circle.radius_constraint_id, *circle.cardinal_constraint_ids])
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

    start_vertex_ref = _new_external_reference(part, sketch, bodies, excluded, start_ref.body_id, start_ref.index)
    start_x, start_y = resolve_external_vertex_position(part, sketch, start_vertex_ref, bodies, excluded)
    start_point = sketch.add_or_reuse_external_vertex_reference(start_x, start_y, start_vertex_ref)

    end_vertex_ref = _new_external_reference(part, sketch, bodies, excluded, end_ref.body_id, end_ref.index)
    end_x, end_y = resolve_external_vertex_position(part, sketch, end_vertex_ref, bodies, excluded)
    end_point = sketch.add_or_reuse_external_vertex_reference(end_x, end_y, end_vertex_ref)

    basis = basis_for_sketch(part, sketch, bodies, excluded)
    arc_params = resolve_circular_edge_arc(bodies, edge_ref, basis, (start_x, start_y), (end_x, end_y))
    if arc_params is not None:
        center_x, center_y, _radius, resolved_start_xy, resolved_end_xy = arc_params
        if resolved_start_xy == (start_x, start_y):
            arc_start_point, arc_end_point = start_point, end_point
        else:
            arc_start_point, arc_end_point = end_point, start_point
        center_point = sketch.add_or_reuse_external_vertex_reference(
            center_x, center_y, _new_circle_centre_reference(part, sketch, bodies, excluded, payload.body_id, payload.edge_index)
        )
        existing_arc = next(
            (
                a
                for a in sketch.arcs()
                if a.center_point_id == center_point.id and {a.start_point_id, a.end_point_id} == {arc_start_point.id, arc_end_point.id}
            ),
            None,
        )
        arc = existing_arc if existing_arc is not None else sketch.add_arc(center_point.id, arc_start_point.id, arc_end_point.id, construction=payload.construction)
        # An Arc's start / end Points are vertex references and (since the reference-identity overhaul) its centre is a circle-centre reference, so every
        # Point of it is already pinned by `external_references`.
        if existing_arc is None:
            try:
                sketch.add_fixed_constraint(arc.id)
            except ValueError:
                pass  # every Point of the Arc is a live reference now (start, end and, since the overhaul, the centre): nothing left to pin
            _drop_constraints_between_pinned_points(sketch, [arc.radius_constraint_id, arc.end_radius_constraint_id])
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

    line = next(
        (l for l in sketch.lines() if {l.start_point_id, l.end_point_id} == {start_point.id, end_point.id}),
        None,
    ) or sketch.add_line(start_point.id, end_point.id, construction=payload.construction)
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
    selected_profiles = _validate_profile_refs(sketch_feature, profile_refs)
    _validate_thickness_nonzero(payload.thickness)
    _validate_draft_payload(payload.draft_angle, payload.thickness, len(selected_profiles))
    feature = ExtrudeFeature(
        id=str(uuid.uuid4()),
        sketch_feature_id=payload.sketch_feature_id,
        extrude_type=payload.extrude_type,
        start_distance=payload.start_distance,
        end_distance=payload.end_distance,
        target_body_ids=list(payload.target_body_ids),
        profile_refs=profile_refs,
        thickness=payload.thickness,
        thickness_direction=payload.thickness_direction,
        draft_angle=payload.draft_angle,
        draft_outward=payload.draft_outward,
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
    selected_profiles = _validate_profile_refs(sketch_feature, new_profile_refs)
    # `thickness`/`draft_angle`: omitted keeps the current value, an
    # explicit `null` clears it - see `ExtrudeFeatureUpdate`'s own docstring.
    fields_set = payload.model_fields_set
    new_thickness = payload.thickness if "thickness" in fields_set else feature.thickness
    _validate_thickness_nonzero(new_thickness)
    new_thickness_direction = (
        payload.thickness_direction if payload.thickness_direction is not None else feature.thickness_direction
    )
    new_draft_angle = payload.draft_angle if "draft_angle" in fields_set else feature.draft_angle
    new_draft_outward = payload.draft_outward if payload.draft_outward is not None else feature.draft_outward
    _validate_draft_payload(new_draft_angle, new_thickness, len(selected_profiles))

    feature.extrude_type = new_extrude_type
    feature.start_distance = new_start
    feature.end_distance = new_end
    feature.target_body_ids = list(new_target_body_ids)
    feature.profile_refs = new_profile_refs
    feature.thickness = new_thickness
    feature.thickness_direction = new_thickness_direction
    feature.draft_angle = new_draft_angle
    feature.draft_outward = new_draft_outward
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


# --- Phase 1 surfacing package: Planar/Revolve/Swept/Loft/Ruled Surface ------


def _validate_planar_surface_payload(part: Part, sketch_feature_id: str) -> None:
    """Planar Surface reuses the same strict closed-profile gate Extrude/
    Revolve/Sweep/Swept Surface already use - see `_require_closed_sketch_
    feature`'s own docstring. No open-chain fallback (unlike SurfaceFeature/
    RevolveSurfaceFeature) - `BRepBuilderAPI_MakeFace` needs a genuinely
    closed wire."""
    _require_closed_sketch_feature(part, sketch_feature_id)


@router.post(
    "/parts/{part_id}/planar-surface-features", response_model=PlanarSurfaceFeatureResponse, status_code=201
)
def create_planar_surface_feature(part_id: str, payload: PlanarSurfaceFeatureCreate) -> PlanarSurfaceFeatureResponse:
    """Phase 1 surfacing package: creates a `PlanarSurfaceFeature` - unlike
    `SurfaceFeature`, eagerly resolves (`app.document.planar_surface.
    resolve_planar_surface`) before persisting, matching this package's own
    dominant fail-closed convention (see `app.document.models.
    PlanarSurfaceFeature`'s own docstring)."""
    part = get_part_or_404(part_id)
    _validate_planar_surface_payload(part, payload.sketch_feature_id)
    profile_refs = [_sketch_entity_ref_to_domain(ref) for ref in payload.profile_refs]
    feature = PlanarSurfaceFeature(
        id=str(uuid.uuid4()),
        sketch_feature_id=payload.sketch_feature_id,
        profile_refs=profile_refs,
    )
    resolve_planar_surface(part, feature)  # raises on an unresolvable/invalid profile
    part.add_feature(feature)
    return _feature_response(part, feature)


def _get_planar_surface_feature_or_404(part: Part, feature_id: str) -> PlanarSurfaceFeature:
    feature = part.get_feature(feature_id)
    if not isinstance(feature, PlanarSurfaceFeature):
        raise HTTPException(status_code=404, detail="Planar surface feature not found")
    return feature


@router.patch(
    "/parts/{part_id}/planar-surface-features/{feature_id}", response_model=PlanarSurfaceFeatureResponse
)
def update_planar_surface_feature(
    part_id: str, feature_id: str, payload: PlanarSurfaceFeatureUpdate
) -> PlanarSurfaceFeatureResponse:
    """Same validate-before-mutate discipline as `update_surface_feature`."""
    part = get_part_or_404(part_id)
    feature = _get_planar_surface_feature_or_404(part, feature_id)

    new_sketch_feature_id = (
        payload.sketch_feature_id if payload.sketch_feature_id is not None else feature.sketch_feature_id
    )
    new_profile_refs = (
        [_sketch_entity_ref_to_domain(ref) for ref in payload.profile_refs]
        if payload.profile_refs is not None
        else feature.profile_refs
    )
    _validate_planar_surface_payload(part, new_sketch_feature_id)

    candidate = PlanarSurfaceFeature(
        id=feature.id, sketch_feature_id=new_sketch_feature_id, profile_refs=new_profile_refs
    )
    resolve_planar_surface(part, candidate)  # raises on an unresolvable/invalid profile

    feature.sketch_feature_id = candidate.sketch_feature_id
    feature.profile_refs = candidate.profile_refs
    return _feature_response(part, feature)


@router.post(
    "/parts/{part_id}/revolve-surface-features", response_model=RevolveSurfaceFeatureResponse, status_code=201
)
def create_revolve_surface_feature(
    part_id: str, payload: RevolveSurfaceFeatureCreate
) -> RevolveSurfaceFeatureResponse:
    """Mirrors `create_revolve_feature`'s shape, minus `mode`/`target_body_
    ids` (a standalone-only Feature - see `app.document.models.
    RevolveSurfaceFeature`'s own docstring). Unlike `RevolveFeature`, the
    backing Sketch is not required to already have a closed profile - a
    single open wire is also valid (mirrors `SurfaceFeature`'s own
    tolerance), so this validates `sketch_feature_id` resolves to a real
    SketchFeature only, rather than `_require_closed_sketch_feature`."""
    part = get_part_or_404(part_id)
    sketch_feature = part.get_feature(payload.sketch_feature_id)
    if not isinstance(sketch_feature, SketchFeature):
        raise HTTPException(
            status_code=400, detail="sketch_feature_id does not refer to a SketchFeature in this Part"
        )
    _validate_revolve_angle(payload.angle)
    feature = RevolveSurfaceFeature(
        id=str(uuid.uuid4()),
        sketch_feature_id=payload.sketch_feature_id,
        axis_ref=_sketch_entity_ref_to_domain(payload.axis_ref),
        angle=payload.angle,
        profile_refs=[_sketch_entity_ref_to_domain(ref) for ref in payload.profile_refs],
    )
    resolve_revolve_surface(part, feature)  # raises on an unresolvable reference or unusable sketch
    part.add_feature(feature)
    return _feature_response(part, feature)


def _get_revolve_surface_feature_or_404(part: Part, feature_id: str) -> RevolveSurfaceFeature:
    feature = part.get_feature(feature_id)
    if not isinstance(feature, RevolveSurfaceFeature):
        raise HTTPException(status_code=404, detail="Revolve surface feature not found")
    return feature


@router.patch(
    "/parts/{part_id}/revolve-surface-features/{feature_id}", response_model=RevolveSurfaceFeatureResponse
)
def update_revolve_surface_feature(
    part_id: str, feature_id: str, payload: RevolveSurfaceFeatureUpdate
) -> RevolveSurfaceFeatureResponse:
    """Same validate-before-mutate discipline as `update_revolve_feature` -
    `sketch_feature_id` is never revised."""
    part = get_part_or_404(part_id)
    feature = _get_revolve_surface_feature_or_404(part, feature_id)

    new_axis_ref = (
        _sketch_entity_ref_to_domain(payload.axis_ref) if payload.axis_ref is not None else feature.axis_ref
    )
    new_angle = payload.angle if payload.angle is not None else feature.angle
    new_profile_refs = (
        [_sketch_entity_ref_to_domain(ref) for ref in payload.profile_refs]
        if payload.profile_refs is not None
        else feature.profile_refs
    )
    _validate_revolve_angle(new_angle)

    candidate = RevolveSurfaceFeature(
        id=feature.id,
        sketch_feature_id=feature.sketch_feature_id,
        axis_ref=new_axis_ref,
        angle=new_angle,
        profile_refs=new_profile_refs,
    )
    resolve_revolve_surface(part, candidate)  # raises on an unresolvable reference or unusable sketch

    feature.axis_ref = candidate.axis_ref
    feature.angle = candidate.angle
    feature.profile_refs = candidate.profile_refs
    return _feature_response(part, feature)


@router.post(
    "/parts/{part_id}/swept-surface-features", response_model=SweptSurfaceFeatureResponse, status_code=201
)
def create_swept_surface_feature(part_id: str, payload: SweptSurfaceFeatureCreate) -> SweptSurfaceFeatureResponse:
    """Mirrors `create_sweep_feature`'s shape, minus `mode`/`target_body_
    ids`. On-device feedback ("swept surface should support an open
    profile sketch"): unlike Extrude/Revolve/Sweep, the backing Sketch is
    no longer required to already have a closed profile - a single open
    chain is also valid (mirrors `RevolveSurfaceFeature`'s/`SurfaceFeature`'s
    own tolerance - see `app.document.swept_surface`'s own module
    docstring), so this validates `sketch_feature_id` resolves to a real
    SketchFeature only, rather than `_require_closed_sketch_feature`."""
    part = get_part_or_404(part_id)
    sketch_feature = part.get_feature(payload.sketch_feature_id)
    if not isinstance(sketch_feature, SketchFeature):
        raise HTTPException(
            status_code=400, detail="sketch_feature_id does not refer to a SketchFeature in this Part"
        )
    path_refs = [_sketch_or_edge_ref_to_domain(ref) for ref in payload.path_refs]
    _validate_swept_surface_path_refs(path_refs)
    feature = SweptSurfaceFeature(
        id=str(uuid.uuid4()),
        sketch_feature_id=payload.sketch_feature_id,
        path_refs=path_refs,
        profile_refs=[_sketch_entity_ref_to_domain(ref) for ref in payload.profile_refs],
    )
    resolve_swept_surface(part, feature)  # raises on an unresolvable reference or unusable path/profile
    part.add_feature(feature)
    return _feature_response(part, feature)


def _get_swept_surface_feature_or_404(part: Part, feature_id: str) -> SweptSurfaceFeature:
    feature = part.get_feature(feature_id)
    if not isinstance(feature, SweptSurfaceFeature):
        raise HTTPException(status_code=404, detail="Swept surface feature not found")
    return feature


@router.patch(
    "/parts/{part_id}/swept-surface-features/{feature_id}", response_model=SweptSurfaceFeatureResponse
)
def update_swept_surface_feature(
    part_id: str, feature_id: str, payload: SweptSurfaceFeatureUpdate
) -> SweptSurfaceFeatureResponse:
    """Same validate-before-mutate discipline as `update_sweep_feature` -
    `sketch_feature_id` is never revised."""
    part = get_part_or_404(part_id)
    feature = _get_swept_surface_feature_or_404(part, feature_id)

    new_path_refs = (
        [_sketch_or_edge_ref_to_domain(ref) for ref in payload.path_refs]
        if payload.path_refs is not None
        else feature.path_refs
    )
    new_profile_refs = (
        [_sketch_entity_ref_to_domain(ref) for ref in payload.profile_refs]
        if payload.profile_refs is not None
        else feature.profile_refs
    )
    _validate_swept_surface_path_refs(new_path_refs)

    candidate = SweptSurfaceFeature(
        id=feature.id,
        sketch_feature_id=feature.sketch_feature_id,
        path_refs=new_path_refs,
        profile_refs=new_profile_refs,
    )
    resolve_swept_surface(part, candidate)  # raises on an unresolvable reference or unusable path/profile

    feature.path_refs = candidate.path_refs
    feature.profile_refs = candidate.profile_refs
    return _feature_response(part, feature)


@router.post(
    "/parts/{part_id}/loft-surface-features", response_model=LoftSurfaceFeatureResponse, status_code=201
)
def create_loft_surface_feature(part_id: str, payload: LoftSurfaceFeatureCreate) -> LoftSurfaceFeatureResponse:
    """Mirrors `create_loft_feature`'s shape, minus `mode`/`target_body_
    ids`/`thickness` - see `app.document.models.LoftSurfaceFeature`'s own
    docstring for the closed-vs-open probing dispatch this eager resolve
    exercises."""
    part = get_part_or_404(part_id)
    sections = [_loft_section_to_domain(section) for section in payload.sections]
    guide_curve_refs = [_sketch_or_edge_ref_to_domain(ref) for ref in payload.guide_curve_refs]
    _validate_loft_surface_sections(sections)
    _validate_loft_guide_curve_refs(guide_curve_refs)
    feature = LoftSurfaceFeature(
        id=str(uuid.uuid4()), sections=sections, ruled=payload.ruled, guide_curve_refs=guide_curve_refs
    )
    _, warnings = resolve_loft_surface(part, feature)  # raises on an unresolvable/invalid loft
    part.add_feature(feature)
    return _loft_surface_feature_response(part, feature, warnings)


def _get_loft_surface_feature_or_404(part: Part, feature_id: str) -> LoftSurfaceFeature:
    feature = part.get_feature(feature_id)
    if not isinstance(feature, LoftSurfaceFeature):
        raise HTTPException(status_code=404, detail="Loft surface feature not found")
    return feature


@router.patch(
    "/parts/{part_id}/loft-surface-features/{feature_id}", response_model=LoftSurfaceFeatureResponse
)
def update_loft_surface_feature(
    part_id: str, feature_id: str, payload: LoftSurfaceFeatureUpdate
) -> LoftSurfaceFeatureResponse:
    """Same validate-before-mutate discipline as `update_loft_feature`."""
    part = get_part_or_404(part_id)
    feature = _get_loft_surface_feature_or_404(part, feature_id)

    new_sections = (
        [_loft_section_to_domain(section) for section in payload.sections]
        if payload.sections is not None
        else feature.sections
    )
    new_ruled = payload.ruled if payload.ruled is not None else feature.ruled
    new_guide_curve_refs = (
        [_sketch_or_edge_ref_to_domain(ref) for ref in payload.guide_curve_refs]
        if payload.guide_curve_refs is not None
        else feature.guide_curve_refs
    )
    _validate_loft_surface_sections(new_sections)
    _validate_loft_guide_curve_refs(new_guide_curve_refs)

    candidate = LoftSurfaceFeature(
        id=feature.id, sections=new_sections, ruled=new_ruled, guide_curve_refs=new_guide_curve_refs
    )
    _, warnings = resolve_loft_surface(part, candidate)  # raises on an unresolvable/invalid loft

    feature.sections = candidate.sections
    feature.ruled = candidate.ruled
    feature.guide_curve_refs = candidate.guide_curve_refs
    return _loft_surface_feature_response(part, feature, warnings)


@router.post(
    "/parts/{part_id}/ruled-surface-features", response_model=RuledSurfaceFeatureResponse, status_code=201
)
def create_ruled_surface_feature(part_id: str, payload: RuledSurfaceFeatureCreate) -> RuledSurfaceFeatureResponse:
    """A thin, UX-only wrapper around Loft Surface's own construction (see
    `app.document.models.RuledSurfaceFeature`'s own docstring) - exactly 2
    sections, `reference_point`/`alignment_point` always `None` (the router
    constructs the real domain `LoftSection` with those two fields always
    unset - `RuledSurfaceSectionSchema` doesn't even expose them)."""
    part = get_part_or_404(part_id)
    sections = [_ruled_surface_section_to_domain(section) for section in payload.sections]
    _validate_ruled_surface_sections(sections)
    feature = RuledSurfaceFeature(id=str(uuid.uuid4()), sections=sections)
    resolve_ruled_surface(part, feature)  # raises on an unresolvable/invalid section pair
    part.add_feature(feature)
    return _feature_response(part, feature)


def _get_ruled_surface_feature_or_404(part: Part, feature_id: str) -> RuledSurfaceFeature:
    feature = part.get_feature(feature_id)
    if not isinstance(feature, RuledSurfaceFeature):
        raise HTTPException(status_code=404, detail="Ruled surface feature not found")
    return feature


@router.patch(
    "/parts/{part_id}/ruled-surface-features/{feature_id}", response_model=RuledSurfaceFeatureResponse
)
def update_ruled_surface_feature(
    part_id: str, feature_id: str, payload: RuledSurfaceFeatureUpdate
) -> RuledSurfaceFeatureResponse:
    """Same validate-before-mutate discipline as every other Phase 1
    surfacing endpoint above."""
    part = get_part_or_404(part_id)
    feature = _get_ruled_surface_feature_or_404(part, feature_id)

    new_sections = (
        [_ruled_surface_section_to_domain(section) for section in payload.sections]
        if payload.sections is not None
        else feature.sections
    )
    _validate_ruled_surface_sections(new_sections)

    candidate = RuledSurfaceFeature(id=feature.id, sections=new_sections)
    resolve_ruled_surface(part, candidate)  # raises on an unresolvable/invalid section pair

    feature.sections = candidate.sections
    return _feature_response(part, feature)


# --- Phase 2 surfacing package: Thicken/Knit Surfaces/Solid from Surfaces/Offset Surface ----


def _validate_surface_feature_ref(part: Part, surface_feature_id: str, field_name: str = "surface_feature_id") -> None:
    """Shared structural check every Phase 2 surface-consuming tool's own
    payload validator uses: `surface_feature_id` must resolve to a real
    Feature in this Part that currently `produces == Produces.SURFACE` -
    mirrors `_validate_split_tool_ref`'s own `surface_feature_id` isinstance
    check, generalized from "must be a SurfaceFeature" to "must produce a
    Surface" (any of the five Phase 1 surface-producing tools, or the
    pre-existing `SurfaceFeature`, all qualify)."""
    source_feature = part.get_feature(surface_feature_id)
    # Bug fix: source_feature.produces alone is always BODY for a
    # MirrorFeature/PatternFeature regardless of source - resolve through
    # the actual sources instead, so Thicken/Solid-from-Surfaces/etc. accept
    # a Mirror/Pattern of a Surface as a valid target - see
    # resolve_feature_produces's own doc comment.
    if source_feature is None or resolve_feature_produces(source_feature, part) != Produces.SURFACE:
        raise HTTPException(
            status_code=400,
            detail=f"{field_name} {surface_feature_id!r} does not refer to a surface-producing "
            "Feature in this Part",
        )


def _validate_thicken_payload(part: Part, surface_feature_id: str) -> None:
    """Structural check only - resolves `surface_feature_id` to a Feature
    with `produces == Produces.SURFACE`. Referential/geometric validity
    (the Feature's own shape actually being thickenable by the given
    thickness) is `app.document.thicken.resolve_thicken`'s own job, same
    "payload shape here, resolution there" split every other tool uses."""
    _validate_surface_feature_ref(part, surface_feature_id)


def _validate_knit_surface_payload(part: Part, surface_feature_ids: list[str]) -> None:
    """A `KnitSurfaceFeature` needs 2+ `surface_feature_ids`, each
    resolving to a surface-producing Feature - mirrors `_validate_loft_
    sections`'s own "at least 2" bare-400 convention."""
    if len(surface_feature_ids) < 2:
        raise HTTPException(
            status_code=400, detail="KnitSurfaceFeature requires at least 2 surface_feature_ids"
        )
    for surface_feature_id in surface_feature_ids:
        _validate_surface_feature_ref(part, surface_feature_id, "surface_feature_ids entry")


def _validate_solid_from_surfaces_payload(part: Part, surface_feature_ids: list[str]) -> None:
    """Identical structural shape to `_validate_knit_surface_payload` -
    watertightness itself is only checked at resolve time (see `app.
    document.solid_from_surfaces`'s own module docstring)."""
    if len(surface_feature_ids) < 2:
        raise HTTPException(
            status_code=400, detail="SolidFromSurfacesFeature requires at least 2 surface_feature_ids"
        )
    for surface_feature_id in surface_feature_ids:
        _validate_surface_feature_ref(part, surface_feature_id, "surface_feature_ids entry")


def _validate_offset_surface_distance(distance: float) -> None:
    """`OffsetSurfaceFeature.distance` must be non-zero - mirrors `_validate_
    move_face_payload`'s own identical `offset_distance == 0.0` rejection
    for `MoveFaceFeature`'s own `offset_distance` mode (the same underlying
    `BRepOffset_MakeOffset` technique) - a zero offset has no meaningful
    "new copy identical to the source" interpretation for this tool."""
    if distance == 0.0:
        raise HTTPException(status_code=422, detail="distance must be non-zero")


def _validate_offset_surface_source(part: Part, source: OffsetSourceRef) -> None:
    """Enforces exactly one of `face_ref`/`surface_feature_id` is supplied,
    matching `OffsetSourceRef`'s own "one of two" convention (see its
    docstring), and that whichever one is supplied is itself well-formed -
    a `face_ref` must have `shape_type=FACE` (same typed-slot check
    `_validate_plane_ref`/`_validate_move_face_payload` already make for a
    bare `SubShapeRef`), a `surface_feature_id` must name a Feature that
    currently `produces == Produces.SURFACE` in this Part. Whether a
    surface-Feature source actually resolves to a single shell (not a
    Compound-of-shells) is a referential/geometric check left to `app.
    document.offset_surface.resolve_offset_surface` instead."""
    set_count = sum(x is not None for x in (source.face_ref, source.surface_feature_id))
    if set_count != 1:
        raise HTTPException(
            status_code=422,
            detail="OffsetSurfaceFeature source must have exactly one of face_ref or surface_feature_id",
        )
    if source.face_ref is not None:
        if source.face_ref.shape_type != SubShapeType.FACE:
            raise HTTPException(status_code=422, detail="source face_ref must have shape_type=FACE")
    else:
        assert source.surface_feature_id is not None
        _validate_surface_feature_ref(part, source.surface_feature_id, "source.surface_feature_id")


@router.post(
    "/parts/{part_id}/thicken-features", response_model=ThickenFeatureResponse, status_code=201
)
def create_thicken_feature(part_id: str, payload: ThickenFeatureCreate) -> ThickenFeatureResponse:
    """Phase 2 surfacing package: creates a `ThickenFeature` - unlocked from
    the start, fails closed (via `_validate_thicken_payload`/`_validate_
    thickness_nonzero` for payload shape, then `resolve_thicken` for
    referential/geometric validity) before ever persisting an unresolvable
    Thicken."""
    part = get_part_or_404(part_id)
    _validate_thicken_payload(part, payload.surface_feature_id)
    _validate_thickness_nonzero(payload.thickness)
    feature = ThickenFeature(
        id=str(uuid.uuid4()),
        surface_feature_id=payload.surface_feature_id,
        thickness=payload.thickness,
    )
    resolve_thicken(part, feature)  # raises on an unresolvable reference or failed thicken
    part.add_feature(feature)
    return _feature_response(part, feature)


def _get_thicken_feature_or_404(part: Part, feature_id: str) -> ThickenFeature:
    feature = part.get_feature(feature_id)
    if not isinstance(feature, ThickenFeature):
        raise HTTPException(status_code=404, detail="Thicken feature not found")
    return feature


@router.patch(
    "/parts/{part_id}/thicken-features/{feature_id}", response_model=ThickenFeatureResponse
)
def update_thicken_feature(
    part_id: str, feature_id: str, payload: ThickenFeatureUpdate
) -> ThickenFeatureResponse:
    """Same validate-before-mutate discipline as every other Phase 2
    surfacing endpoint below."""
    part = get_part_or_404(part_id)
    feature = _get_thicken_feature_or_404(part, feature_id)

    new_surface_feature_id = (
        payload.surface_feature_id if payload.surface_feature_id is not None else feature.surface_feature_id
    )
    new_thickness = payload.thickness if payload.thickness is not None else feature.thickness
    _validate_thicken_payload(part, new_surface_feature_id)
    _validate_thickness_nonzero(new_thickness)

    candidate = ThickenFeature(
        id=feature.id, surface_feature_id=new_surface_feature_id, thickness=new_thickness
    )
    resolve_thicken(part, candidate)  # raises on an unresolvable reference or failed thicken

    feature.surface_feature_id = candidate.surface_feature_id
    feature.thickness = candidate.thickness
    return _feature_response(part, feature)


@router.post(
    "/parts/{part_id}/knit-surface-features", response_model=KnitSurfaceFeatureResponse, status_code=201
)
def create_knit_surface_feature(
    part_id: str, payload: KnitSurfaceFeatureCreate
) -> KnitSurfaceFeatureResponse:
    """Phase 2 surfacing package: creates a `KnitSurfaceFeature` - mirrors
    `create_thicken_feature`'s shape, generalized to a list of 2+ sources."""
    part = get_part_or_404(part_id)
    _validate_knit_surface_payload(part, payload.surface_feature_ids)
    feature = KnitSurfaceFeature(
        id=str(uuid.uuid4()), surface_feature_ids=list(payload.surface_feature_ids)
    )
    resolve_knit_surface(part, feature)  # raises on an unresolvable reference
    part.add_feature(feature)
    return _feature_response(part, feature)


def _get_knit_surface_feature_or_404(part: Part, feature_id: str) -> KnitSurfaceFeature:
    feature = part.get_feature(feature_id)
    if not isinstance(feature, KnitSurfaceFeature):
        raise HTTPException(status_code=404, detail="Knit surface feature not found")
    return feature


@router.patch(
    "/parts/{part_id}/knit-surface-features/{feature_id}", response_model=KnitSurfaceFeatureResponse
)
def update_knit_surface_feature(
    part_id: str, feature_id: str, payload: KnitSurfaceFeatureUpdate
) -> KnitSurfaceFeatureResponse:
    """Same validate-before-mutate discipline as `update_thicken_feature`."""
    part = get_part_or_404(part_id)
    feature = _get_knit_surface_feature_or_404(part, feature_id)

    new_surface_feature_ids = (
        list(payload.surface_feature_ids)
        if payload.surface_feature_ids is not None
        else feature.surface_feature_ids
    )
    _validate_knit_surface_payload(part, new_surface_feature_ids)

    candidate = KnitSurfaceFeature(id=feature.id, surface_feature_ids=new_surface_feature_ids)
    resolve_knit_surface(part, candidate)  # raises on an unresolvable reference

    feature.surface_feature_ids = candidate.surface_feature_ids
    return _feature_response(part, feature)


@router.post(
    "/parts/{part_id}/solid-from-surfaces-features",
    response_model=SolidFromSurfacesFeatureResponse,
    status_code=201,
)
def create_solid_from_surfaces_feature(
    part_id: str, payload: SolidFromSurfacesFeatureCreate
) -> SolidFromSurfacesFeatureResponse:
    """Phase 2 surfacing package: creates a `SolidFromSurfacesFeature` -
    mirrors `create_knit_surface_feature`'s shape - fails closed with a
    structured `not_watertight` 422 (via `resolve_solid_from_surfaces`) for
    a set of surfaces that doesn't actually sew into one closed, valid
    solid, before ever persisting."""
    part = get_part_or_404(part_id)
    _validate_solid_from_surfaces_payload(part, payload.surface_feature_ids)
    feature = SolidFromSurfacesFeature(
        id=str(uuid.uuid4()), surface_feature_ids=list(payload.surface_feature_ids)
    )
    resolve_solid_from_surfaces(part, feature)  # raises not_watertight, or an unresolvable reference
    part.add_feature(feature)
    return _feature_response(part, feature)


def _get_solid_from_surfaces_feature_or_404(part: Part, feature_id: str) -> SolidFromSurfacesFeature:
    feature = part.get_feature(feature_id)
    if not isinstance(feature, SolidFromSurfacesFeature):
        raise HTTPException(status_code=404, detail="Solid from surfaces feature not found")
    return feature


@router.patch(
    "/parts/{part_id}/solid-from-surfaces-features/{feature_id}",
    response_model=SolidFromSurfacesFeatureResponse,
)
def update_solid_from_surfaces_feature(
    part_id: str, feature_id: str, payload: SolidFromSurfacesFeatureUpdate
) -> SolidFromSurfacesFeatureResponse:
    """Same validate-before-mutate discipline as `update_knit_surface_
    feature`."""
    part = get_part_or_404(part_id)
    feature = _get_solid_from_surfaces_feature_or_404(part, feature_id)

    new_surface_feature_ids = (
        list(payload.surface_feature_ids)
        if payload.surface_feature_ids is not None
        else feature.surface_feature_ids
    )
    _validate_solid_from_surfaces_payload(part, new_surface_feature_ids)

    candidate = SolidFromSurfacesFeature(id=feature.id, surface_feature_ids=new_surface_feature_ids)
    resolve_solid_from_surfaces(part, candidate)  # raises not_watertight, or an unresolvable reference

    feature.surface_feature_ids = candidate.surface_feature_ids
    return _feature_response(part, feature)


@router.post(
    "/parts/{part_id}/offset-surface-features", response_model=OffsetSurfaceFeatureResponse, status_code=201
)
def create_offset_surface_feature(
    part_id: str, payload: OffsetSurfaceFeatureCreate
) -> OffsetSurfaceFeatureResponse:
    """Phase 2 surfacing package, last of the four: creates an
    `OffsetSurfaceFeature` - unlocked from the start, fails closed (via
    `_validate_offset_surface_source` for payload shape, then `resolve_
    offset_surface` for referential/geometric validity, including a
    Compound-of-shells source's own `invalid_offset_source` rejection)
    before ever persisting."""
    part = get_part_or_404(part_id)
    source = _offset_source_ref_to_domain(payload.source)
    _validate_offset_surface_source(part, source)
    _validate_offset_surface_distance(payload.distance)
    feature = OffsetSurfaceFeature(id=str(uuid.uuid4()), source=source, distance=payload.distance)
    resolve_offset_surface(part, feature)  # raises on an unresolvable reference or failed offset
    part.add_feature(feature)
    return _feature_response(part, feature)


def _get_offset_surface_feature_or_404(part: Part, feature_id: str) -> OffsetSurfaceFeature:
    feature = part.get_feature(feature_id)
    if not isinstance(feature, OffsetSurfaceFeature):
        raise HTTPException(status_code=404, detail="Offset surface feature not found")
    return feature


@router.patch(
    "/parts/{part_id}/offset-surface-features/{feature_id}", response_model=OffsetSurfaceFeatureResponse
)
def update_offset_surface_feature(
    part_id: str, feature_id: str, payload: OffsetSurfaceFeatureUpdate
) -> OffsetSurfaceFeatureResponse:
    """Same validate-before-mutate discipline as every other Phase 2
    surfacing endpoint above."""
    part = get_part_or_404(part_id)
    feature = _get_offset_surface_feature_or_404(part, feature_id)

    new_source = (
        _offset_source_ref_to_domain(payload.source) if payload.source is not None else feature.source
    )
    new_distance = payload.distance if payload.distance is not None else feature.distance
    _validate_offset_surface_source(part, new_source)
    _validate_offset_surface_distance(new_distance)

    candidate = OffsetSurfaceFeature(id=feature.id, source=new_source, distance=new_distance)
    resolve_offset_surface(part, candidate)  # raises on an unresolvable reference or failed offset

    feature.source = candidate.source
    feature.distance = candidate.distance
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
        payload.curve_feature_id,
        payload.curve_parameter,
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
        curve_feature_id=payload.curve_feature_id,
        curve_parameter=payload.curve_parameter,
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
    new_curve_feature_id = (
        payload.curve_feature_id if payload.curve_feature_id is not None else feature.curve_feature_id
    )
    new_curve_parameter = (
        payload.curve_parameter if payload.curve_parameter is not None else feature.curve_parameter
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
        new_curve_feature_id,
        new_curve_parameter,
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
        curve_feature_id=new_curve_feature_id,
        curve_parameter=new_curve_parameter,
    )
    resolve_create_plane(part, candidate)  # raises on an unresolvable reference

    feature.face_refs = candidate.face_refs
    feature.offset = candidate.offset
    feature.line_ref = candidate.line_ref
    feature.point_ref = candidate.point_ref
    feature.edge_ref = candidate.edge_ref
    feature.vertex_ref = candidate.vertex_ref
    feature.point_refs = candidate.point_refs
    feature.curve_feature_id = candidate.curve_feature_id
    feature.curve_parameter = candidate.curve_parameter
    return _feature_response(part, feature)


@router.post("/parts/{part_id}/curve-features", response_model=CurveFeatureResponse, status_code=201)
def create_curve_feature(part_id: str, payload: CurveFeatureCreate) -> CurveFeatureResponse:
    """Creates a `CurveFeature` (Helix/Intersection curve) - same "validate
    payload shape, then resolvability, before ever persisting" discipline
    `create_create_plane_feature` uses."""
    part = get_part_or_404(part_id)
    axis_ref = _plane_ref_to_domain(payload.axis_ref) if payload.axis_ref else None
    profile_refs_a = [_sketch_entity_ref_to_domain(ref) for ref in payload.profile_refs_a]
    profile_refs_b = [_sketch_entity_ref_to_domain(ref) for ref in payload.profile_refs_b]
    _validate_curve_payload(
        part,
        payload.curve_type,
        axis_ref,
        payload.radius,
        payload.pitch,
        payload.turns,
        payload.sketch_feature_id_a,
        payload.sketch_feature_id_b,
    )
    feature = CurveFeature(
        id=str(uuid.uuid4()),
        curve_type=payload.curve_type,
        axis_ref=axis_ref,
        radius=payload.radius,
        pitch=payload.pitch,
        turns=payload.turns,
        right_handed=payload.right_handed,
        sketch_feature_id_a=payload.sketch_feature_id_a,
        profile_refs_a=profile_refs_a,
        sketch_feature_id_b=payload.sketch_feature_id_b,
        profile_refs_b=profile_refs_b,
    )
    resolve_curve(part, feature)  # raises on an unresolvable reference or failed construction
    part.add_feature(feature)
    return _feature_response(part, feature)


def _get_curve_feature_or_404(part: Part, feature_id: str) -> CurveFeature:
    feature = part.get_feature(feature_id)
    if not isinstance(feature, CurveFeature):
        raise HTTPException(status_code=404, detail="Curve feature not found")
    return feature


@router.patch("/parts/{part_id}/curve-features/{feature_id}", response_model=CurveFeatureResponse)
def update_curve_feature(part_id: str, feature_id: str, payload: CurveFeatureUpdate) -> CurveFeatureResponse:
    """Partial update - `curve_type` itself is never revised (delete+
    recreate to switch, same convention `CreatePlaneFeatureUpdate` uses for
    `plane_type`). Same validate-before-mutate discipline as `update_
    create_plane_feature`."""
    part = get_part_or_404(part_id)
    feature = _get_curve_feature_or_404(part, feature_id)

    new_axis_ref = _plane_ref_to_domain(payload.axis_ref) if payload.axis_ref is not None else feature.axis_ref
    new_radius = payload.radius if payload.radius is not None else feature.radius
    new_pitch = payload.pitch if payload.pitch is not None else feature.pitch
    new_turns = payload.turns if payload.turns is not None else feature.turns
    new_right_handed = payload.right_handed if payload.right_handed is not None else feature.right_handed
    new_sketch_feature_id_a = (
        payload.sketch_feature_id_a if payload.sketch_feature_id_a is not None else feature.sketch_feature_id_a
    )
    new_profile_refs_a = (
        [_sketch_entity_ref_to_domain(ref) for ref in payload.profile_refs_a]
        if payload.profile_refs_a is not None
        else feature.profile_refs_a
    )
    new_sketch_feature_id_b = (
        payload.sketch_feature_id_b if payload.sketch_feature_id_b is not None else feature.sketch_feature_id_b
    )
    new_profile_refs_b = (
        [_sketch_entity_ref_to_domain(ref) for ref in payload.profile_refs_b]
        if payload.profile_refs_b is not None
        else feature.profile_refs_b
    )

    _validate_curve_payload(
        part,
        feature.curve_type,
        new_axis_ref,
        new_radius,
        new_pitch,
        new_turns,
        new_sketch_feature_id_a,
        new_sketch_feature_id_b,
    )
    candidate = CurveFeature(
        id=feature.id,
        curve_type=feature.curve_type,
        axis_ref=new_axis_ref,
        radius=new_radius,
        pitch=new_pitch,
        turns=new_turns,
        right_handed=new_right_handed,
        sketch_feature_id_a=new_sketch_feature_id_a,
        profile_refs_a=new_profile_refs_a,
        sketch_feature_id_b=new_sketch_feature_id_b,
        profile_refs_b=new_profile_refs_b,
    )
    resolve_curve(part, candidate)  # raises on an unresolvable reference or failed construction

    feature.axis_ref = candidate.axis_ref
    feature.radius = candidate.radius
    feature.pitch = candidate.pitch
    feature.turns = candidate.turns
    feature.right_handed = candidate.right_handed
    feature.sketch_feature_id_a = candidate.sketch_feature_id_a
    feature.profile_refs_a = candidate.profile_refs_a
    feature.sketch_feature_id_b = candidate.sketch_feature_id_b
    feature.profile_refs_b = candidate.profile_refs_b
    return _feature_response(part, feature)


@router.post(
    "/parts/{part_id}/fill-surface-features", response_model=FillSurfaceFeatureResponse, status_code=201
)
def create_fill_surface_feature(part_id: str, payload: FillSurfaceFeatureCreate) -> FillSurfaceFeatureResponse:
    part = get_part_or_404(part_id)
    boundary_refs = [_sketch_or_edge_ref_to_domain(ref) for ref in payload.boundary_refs]
    _validate_fill_surface_payload(boundary_refs)
    _validate_sketch_or_edge_refs(boundary_refs)
    feature = FillSurfaceFeature(id=str(uuid.uuid4()), boundary_refs=boundary_refs)
    resolve_fill_surface(part, feature)  # raises on an unresolvable reference or failed construction
    part.add_feature(feature)
    return _feature_response(part, feature)


def _get_fill_surface_feature_or_404(part: Part, feature_id: str) -> FillSurfaceFeature:
    feature = part.get_feature(feature_id)
    if not isinstance(feature, FillSurfaceFeature):
        raise HTTPException(status_code=404, detail="Fill Surface feature not found")
    return feature


@router.patch(
    "/parts/{part_id}/fill-surface-features/{feature_id}", response_model=FillSurfaceFeatureResponse
)
def update_fill_surface_feature(
    part_id: str, feature_id: str, payload: FillSurfaceFeatureUpdate
) -> FillSurfaceFeatureResponse:
    part = get_part_or_404(part_id)
    feature = _get_fill_surface_feature_or_404(part, feature_id)

    new_boundary_refs = (
        [_sketch_or_edge_ref_to_domain(ref) for ref in payload.boundary_refs]
        if payload.boundary_refs is not None
        else feature.boundary_refs
    )
    _validate_fill_surface_payload(new_boundary_refs)
    _validate_sketch_or_edge_refs(new_boundary_refs)
    candidate = FillSurfaceFeature(id=feature.id, boundary_refs=new_boundary_refs)
    resolve_fill_surface(part, candidate)  # raises on an unresolvable reference or failed construction

    feature.boundary_refs = candidate.boundary_refs
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
        body_volumes=result.body_volumes,
        body_masses=result.body_masses,
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
    document = get_document()
    refs = [_measure_entity_ref_to_domain(ref) for ref in payload.refs]
    result = compute_measurement(document, part, refs)
    return _measurement_result_to_schema(result)


@router.post(
    "/parts/{part_id}/component-pattern-direction",
    response_model=ComponentPatternDirectionFromRefResponse,
)
def component_pattern_direction_from_ref(
    part_id: str, payload: ComponentPatternDirectionFromRefRequest
) -> ComponentPatternDirectionFromRefResponse:
    """Bug fix (assembly testing: "pattern component tool: selecting a
    custom line to use as a direction always seems to silently fail and
    fall back to using an X/Y/Z direction vector") - resolves a picked edge
    (see [ComponentPatternDirectionFromRefRequest]'s own doc comment for why
    this is a one-time resolve-to-a-vector endpoint rather than a
    `direction_ref` persisted on `ComponentPattern` itself) into a plain
    direction vector, entirely by reusing the Measure tool's own single-
    entity resolution (`compute_measurement`/`single_shape_geometry`'s
    `axis_direction` - the same fitted line/circle axis direction Measure
    itself already reports for a straight or circular edge) rather than any
    new geometry code. Raises the same `missing_reference` 422 as `/measure`
    if the ref doesn't resolve, or a new `invalid_direction_ref` 422 if it
    resolves to something with no well-defined direction (a vertex, a face,
    or a non-linear/non-circular edge like a spline)."""
    part = get_part_or_404(part_id)
    document = get_document()
    ref = _measure_entity_ref_to_domain(payload.ref)
    result = compute_measurement(document, part, [ref])
    if result.axis_direction is None:
        raise HTTPException(
            status_code=422,
            detail={
                "type": "invalid_direction_ref",
                "occurrence_id": payload.ref.occurrence_id,
                "body_id": payload.ref.subshape_ref.body_id,
                "shape_type": payload.ref.subshape_ref.shape_type.value,
                "index": payload.ref.subshape_ref.index,
            },
        )
    return ComponentPatternDirectionFromRefResponse(direction=result.axis_direction)


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
    edge_options = _chamfer_edge_options_to_domain(payload.edge_options)
    _validate_chamfer_edge_options(edge_options, len(edge_refs))
    feature = ChamferFeature(
        id=str(uuid.uuid4()), edge_refs=edge_refs, distance=payload.distance, edge_options=edge_options
    )
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
    new_edge_options = (
        _chamfer_edge_options_to_domain(payload.edge_options)
        if payload.edge_options is not None
        else feature.edge_options
    )
    _validate_chamfer_edge_options(new_edge_options, len(new_edge_refs))

    candidate = ChamferFeature(
        id=feature.id, edge_refs=new_edge_refs, distance=new_distance, edge_options=new_edge_options
    )
    resolve_chamfer(part, candidate)  # raises on an unresolvable reference

    feature.edge_refs = candidate.edge_refs
    feature.distance = candidate.distance
    feature.edge_options = candidate.edge_options
    return _feature_response(part, feature)


@router.post(
    "/parts/{part_id}/shell-features", response_model=ShellFeatureResponse, status_code=201
)
def create_shell_feature(part_id: str, payload: ShellFeatureCreate) -> ShellFeatureResponse:
    """Mirrors `create_chamfer_feature` exactly - unlocked from the start,
    fails closed (payload shape, then `resolve_shell`'s referential/
    geometric check) before ever persisting an unresolvable Shell."""
    part = get_part_or_404(part_id)
    faces_to_remove = [_subshape_ref_to_domain(ref) for ref in payload.faces_to_remove]
    _validate_shell_faces_to_remove(faces_to_remove)
    _validate_shell_thickness(payload.thickness)
    feature = ShellFeature(
        id=str(uuid.uuid4()),
        body_id=payload.body_id,
        faces_to_remove=faces_to_remove,
        thickness=payload.thickness,
        thickness_direction=payload.thickness_direction,
    )
    resolve_shell(part, feature)  # raises on an unresolvable reference or failed shell
    part.add_feature(feature)
    return _feature_response(part, feature)


def _get_shell_feature_or_404(part: Part, feature_id: str) -> ShellFeature:
    feature = part.get_feature(feature_id)
    if not isinstance(feature, ShellFeature):
        raise HTTPException(status_code=404, detail="Shell feature not found")
    return feature


@router.patch("/parts/{part_id}/shell-features/{feature_id}", response_model=ShellFeatureResponse)
def update_shell_feature(
    part_id: str, feature_id: str, payload: ShellFeatureUpdate
) -> ShellFeatureResponse:
    """Mirrors `update_chamfer_feature` exactly - same validate-before-
    mutate discipline against a scratch Feature sharing the real one's id."""
    part = get_part_or_404(part_id)
    feature = _get_shell_feature_or_404(part, feature_id)

    new_body_id = payload.body_id if payload.body_id is not None else feature.body_id
    new_faces_to_remove = (
        [_subshape_ref_to_domain(ref) for ref in payload.faces_to_remove]
        if payload.faces_to_remove is not None
        else feature.faces_to_remove
    )
    new_thickness = payload.thickness if payload.thickness is not None else feature.thickness
    new_thickness_direction = (
        payload.thickness_direction
        if payload.thickness_direction is not None
        else feature.thickness_direction
    )
    _validate_shell_faces_to_remove(new_faces_to_remove)
    _validate_shell_thickness(new_thickness)

    candidate = ShellFeature(
        id=feature.id,
        body_id=new_body_id,
        faces_to_remove=new_faces_to_remove,
        thickness=new_thickness,
        thickness_direction=new_thickness_direction,
    )
    resolve_shell(part, candidate)  # raises on an unresolvable reference or failed shell

    feature.body_id = candidate.body_id
    feature.faces_to_remove = candidate.faces_to_remove
    feature.thickness = candidate.thickness
    feature.thickness_direction = candidate.thickness_direction
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
    path_refs = [_sketch_or_edge_ref_to_domain(ref) for ref in payload.path_refs]
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
        [_sketch_or_edge_ref_to_domain(ref) for ref in payload.path_refs]
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
    guide_curve_refs = [_sketch_or_edge_ref_to_domain(ref) for ref in payload.guide_curve_refs]
    _validate_loft_sections(sections)
    _validate_thickness_nonzero(payload.thickness)
    _validate_loft_guide_curve_refs(guide_curve_refs)
    _validate_target_body_ids(part, payload.mode == LoftMode.CUT, payload.target_body_ids)
    feature = LoftFeature(
        id=str(uuid.uuid4()),
        sections=sections,
        mode=payload.mode,
        ruled=payload.ruled,
        target_body_ids=list(payload.target_body_ids),
        thickness=payload.thickness,
        thin_from_closed_profile=payload.thin_from_closed_profile,
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
    guide_curve_refs = [_sketch_or_edge_ref_to_domain(ref) for ref in payload.guide_curve_refs]
    _validate_loft_sections(sections)
    _validate_thickness_nonzero(payload.thickness)
    _validate_loft_guide_curve_refs(guide_curve_refs)
    _validate_target_body_ids(part, payload.mode == LoftMode.CUT, payload.target_body_ids)
    feature = LoftFeature(
        id=str(uuid.uuid4()),
        sections=sections,
        mode=payload.mode,
        ruled=payload.ruled,
        target_body_ids=list(payload.target_body_ids),
        thickness=payload.thickness,
        thin_from_closed_profile=payload.thin_from_closed_profile,
        guide_curve_refs=guide_curve_refs,
    )
    shape = resolve_loft_coarse(part, feature)  # raises on an unresolvable/invalid loft
    return _coarse_preview_response(shape, mesh_quality)


def _get_loft_feature_or_404(part: Part, feature_id: str) -> LoftFeature:
    feature = part.get_feature(feature_id)
    if not isinstance(feature, LoftFeature):
        raise HTTPException(status_code=404, detail="Loft feature not found")
    return feature


@router.get("/parts/{part_id}/loft-features/{feature_id}/seam-handles", response_model=list[LoftSeamHandleSchema | None])
def get_loft_seam_handles(part_id: str, feature_id: str) -> list[LoftSeamHandleSchema | None]:
    """Where each closed section of the loft starts, for the viewport's draggable markers."""
    part = get_part_or_404(part_id)
    feature = _get_loft_feature_or_404(part, feature_id)
    handles = loft_seam_handles(part, feature)
    return [None if handle is None else LoftSeamHandleSchema(**handle) for handle in handles]


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
    new_thin_from_closed_profile = (
        payload.thin_from_closed_profile
        if payload.thin_from_closed_profile is not None
        else feature.thin_from_closed_profile
    )
    new_guide_curve_refs = (
        [_sketch_or_edge_ref_to_domain(ref) for ref in payload.guide_curve_refs]
        if payload.guide_curve_refs is not None
        else feature.guide_curve_refs
    )
    _validate_loft_sections(new_sections)
    _validate_thickness_nonzero(new_thickness)
    _validate_loft_guide_curve_refs(new_guide_curve_refs)
    _validate_target_body_ids(part, new_mode == LoftMode.CUT, new_target_body_ids)

    candidate = LoftFeature(
        id=feature.id,
        sections=new_sections,
        mode=new_mode,
        ruled=new_ruled,
        target_body_ids=list(new_target_body_ids),
        thickness=new_thickness,
        thin_from_closed_profile=new_thin_from_closed_profile,
        guide_curve_refs=new_guide_curve_refs,
    )
    _, warnings = resolve_loft(part, candidate)  # raises on an unresolvable/invalid loft

    feature.sections = candidate.sections
    feature.mode = candidate.mode
    feature.ruled = candidate.ruled
    feature.target_body_ids = candidate.target_body_ids
    feature.thickness = candidate.thickness
    feature.thin_from_closed_profile = candidate.thin_from_closed_profile
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
        orientation_mode=payload.orientation_mode,
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
        orientation_mode=payload.orientation_mode,
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
    new_orientation_mode = (
        payload.orientation_mode if payload.orientation_mode is not None else feature.orientation_mode
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
        orientation_mode=new_orientation_mode,
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
    feature.orientation_mode = candidate.orientation_mode
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

    # Part Properties round: a STEP import may carry its own source
    # platform's material designation - pre-fill this Body's own material
    # assignment with it when present (never overwrites an existing
    # assignment, though there can't be one yet for a Feature just created).
    # Only ever covers the common single-solid case - `feature.id` is the
    # resulting Body's own unsuffixed id (see `app.document.extrude.
    # _register_solids`); a multi-solid STEP import's extra `#N`-suffixed
    # Bodies are not covered by this best-effort pre-fill.
    if payload.source_format == ImportSourceFormat.STEP:
        metadata = extract_step_metadata(source_data)
        if metadata is not None and metadata.material is not None:
            part.body_material_assignments.setdefault(feature.id, metadata.material)

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
    docs/ai-modelling/00-conventions.md).

    Multi-part/assembly overhaul, Phase D2 (docs/ai-modelling/13-multi-
    part-assembly-overhaul.md): also passes the current session's own
    `Document` through, so a Mate step's `edge_selector` can resolve
    against a placed Occurrence's own target Part - every Part a composed
    multi-file assembly graph pulled in already lives in this same
    session's `Document.parts` (`get_document()` is a per-session
    singleton), not a new payload this endpoint needs to accept."""
    part = get_part_or_404(part_id)
    results = validate_ai_plan_steps(part, payload.steps, frozenset(payload.disabled_kinds), get_document())
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
    responses = []
    for body_id, shape in bodies.items():
        owning_feature = part.get_feature(base_feature_id(body_id))
        responses.append(
            BodyMeshResponse(
                body_id=body_id,
                source="computed",
                mesh=_mesh_vertex_data(tessellate_shape(shape, mesh_quality)),
                hidden=base_feature_id(body_id) in hidden,
                # Bug fix: owning_feature.produces alone is always BODY for a
                # MirrorFeature/PatternFeature regardless of source - resolve
                # through the actual sources instead, so a Mirror/Pattern of
                # a Surface is correctly grouped under Surfaces in the client
                # Build Tree - see resolve_feature_produces's own doc comment.
                is_surface=owning_feature is not None
                and resolve_feature_produces(owning_feature, part) == Produces.SURFACE,
                is_curve=owning_feature is not None
                and resolve_feature_produces(owning_feature, part) == Produces.CURVE,
            )
        )
    return responses


def _assembly_body_mesh_responses(part: Part, mesh_quality: MeshQuality) -> list[BodyMeshResponse]:
    """The placeholder-or-real-bodies logic `get_part_mesh` above already
    has, factored out so `get_assembly_mesh` (below) can compute one Part's
    own local-space bodies the same way, without `hidden_feature_ids`/
    `rollback_excluded_feature_ids` - those are the currently-open Part's
    own live-editing state (`PartScreen`'s hide/show and B4 rollback), not
    meaningful for a whole-tree scene fetch of Parts the user isn't
    actively editing right now. A Part's `hidden` Body state is still
    reported per-Body below (same as `get_part_mesh`'s own convention) -
    only the *editing-session* exclusions are dropped, not the persisted
    hidden flag itself... except there is no persisted per-Body hidden flag
    on `Part` today (it's purely the client's own `hidden_feature_ids` set,
    per `get_part_mesh`'s own docstring) - so every Body here reports
    `hidden=False`, and it's each client's job to apply its own hide/show
    state when rendering, exactly as it already must for any Part it isn't
    the primary editing target of."""
    if not part.produces_displayable_geometry:
        # No placeholder box here (unlike `get_part_mesh`): in an assembly
        # scene a geometry-less Part - typically the root assembly itself,
        # always emitted as an `occurrence_path=[]` instance - must render
        # as nothing, not a stray 10x10x10 cube at the origin.
        return []

    bodies = compute_part_bodies(part, frozenset())
    responses = []
    for body_id, shape in bodies.items():
        owning_feature = part.get_feature(base_feature_id(body_id))
        responses.append(
            BodyMeshResponse(
                body_id=body_id,
                source="computed",
                mesh=_mesh_vertex_data(tessellate_shape(shape, mesh_quality)),
                is_surface=owning_feature is not None
                and resolve_feature_produces(owning_feature, part) == Produces.SURFACE,
                is_curve=owning_feature is not None
                and resolve_feature_produces(owning_feature, part) == Produces.CURVE,
            )
        )
    return responses


@router.get("/parts/{part_id}/assembly-mesh", response_model=AssemblyMeshResponse)
def get_assembly_mesh(
    part_id: str,
    quality: float | None = Query(default=None, ge=0.0, le=1.0),
) -> AssemblyMeshResponse:
    """Assembly support (`docs/assembly-scope.md` Phase 2): everything
    visible in `part_id`'s own assembly scene - its own local bodies (from
    `part.features`, exactly like `GET /mesh`) *and* every Occurrence's
    resolved geometry, recursively (an Occurrence's target Part can itself
    have its own Occurrences), with world-space transforms already composed
    down from the root (`app.document.assembly.compose_chain`). A Part's
    own local geometry is included as one instance with `occurrence_path=
    []` and the identity transform - it is exactly as much part of the
    assembly view as anything it references, since `occurrences`/`mates`
    coexist with `features` on one Part (decision #2) rather than living on
    a separate node type.

    Requires the full multi-file graph to already be composed into this
    session's `Document` (the client's own compose step, Phase 2 - resolve
    every referenced `.didsa` file, assign each a session-local `part_id`,
    send the composed graph through `POST /import/native`, *then* call this
    endpoint). This backend has no filesystem/SAF access of its own
    (decision #6) - an `Occurrence` whose `part_id` hasn't been resolved
    into `document.parts` yet is silently skipped, not an error, so every
    sibling that *is* resolved still renders. A cyclic graph (an Occurrence
    chain that would revisit a Part already on its own path) is likewise
    skipped defensively rather than erroring the whole response - the
    client's own compose step is the real cycle-detection gate (Phase 2);
    this is a backstop, not the primary validation.

    Geometry is deduplicated by Part id (`AssemblyBodyGeometry`, one entry
    per unique Part actually reachable, reusing `app.document.body_cache`'s
    existing per-Part-id caching - see that module's own docstring) -
    N Occurrences of one Part definition trigger one recompute and ship one
    geometry payload, never N. Every placed instance (`AssemblyOccurrence
    Instance`) then just carries its own `world_transform`, not its own
    copy of the mesh."""
    document = get_document()
    root_part = get_part_or_404(part_id)
    mesh_quality = DEFAULT_MESH_QUALITY if quality is None else mesh_quality_from_slider(quality)

    geometry_by_part_id: dict[str, AssemblyBodyGeometry] = {}
    instances: list[AssemblyOccurrenceInstance] = []

    def _geometry_for(part: Part) -> None:
        if part.id in geometry_by_part_id:
            return
        geometry_by_part_id[part.id] = AssemblyBodyGeometry(
            part_id=part.id, bodies=_assembly_body_mesh_responses(part, mesh_quality)
        )

    def _walk(
        part: Part,
        occurrence_path: list[str],
        transform_chain: list[RigidTransform],
        hidden: bool,
        ancestors: frozenset[str],
        color: str | None = None,
    ) -> None:
        _geometry_for(part)
        world_transform = compose_chain(transform_chain)
        instances.append(
            AssemblyOccurrenceInstance(
                occurrence_path=occurrence_path,
                part_id=part.id,
                world_transform=RigidTransformResponse(
                    translation=world_transform.translation,
                    rotation_axis=world_transform.rotation_axis,
                    rotation_angle_degrees=world_transform.rotation_angle_degrees,
                ),
                hidden=hidden,
                color=color,
            )
        )
        child_ancestors = ancestors | {part.id}
        for occurrence in part.occurrences:
            if occurrence.suppressed or occurrence.part_id is None:
                continue
            child_part = document.parts.get(occurrence.part_id)
            if child_part is None or child_part.id in child_ancestors:
                continue
            _walk(
                child_part,
                [*occurrence_path, occurrence.id],
                [*transform_chain, occurrence.transform],
                occurrence.hidden,
                child_ancestors,
                color=occurrence.color,
            )
        # Phase 7 (`docs/assembly-scope.md` §3 item 7): every ComponentPattern
        # owned by `part` derives its own extra instances on top of each of
        # its `source_occurrence_ids`' real placements - never persisted as
        # new `Occurrence` entries (see `ComponentPattern`'s own docstring),
        # only ever appended to this response. Reuses `_walk` itself for the
        # recursion, so a pattern of a sub-assembly renders that
        # sub-assembly's own nested content at each derived placement exactly
        # like an ordinary Occurrence branch does - `occurrence_path` grows
        # with a synthetic, stable-per-(source, pattern, index) segment
        # rather than a real Occurrence id, since a derived instance was
        # never assigned one of its own.
        for pattern in part.component_patterns:
            if pattern.suppressed:
                continue
            for source_id in pattern.source_occurrence_ids:
                source_occurrence = next((o for o in part.occurrences if o.id == source_id), None)
                if source_occurrence is None or source_occurrence.suppressed or source_occurrence.part_id is None:
                    continue
                pattern_child_part = document.parts.get(source_occurrence.part_id)
                if pattern_child_part is None or pattern_child_part.id in child_ancestors:
                    continue
                derived_transforms = expand_component_pattern_instances(pattern, source_occurrence.transform)
                for index, derived_transform in derived_transforms.items():
                    _walk(
                        pattern_child_part,
                        [*occurrence_path, f"{source_occurrence.id}#pattern:{pattern.id}:{index}"],
                        [*transform_chain, derived_transform],
                        source_occurrence.hidden,
                        child_ancestors,
                        color=source_occurrence.color,
                    )

    _walk(root_part, [], [], hidden=False, ancestors=frozenset())

    return AssemblyMeshResponse(geometry=list(geometry_by_part_id.values()), instances=instances)


def _assembly_glb_part_mesh_data(
    part: Part,
    mesh_quality: MeshQuality,
    tier: Literal["full", "coarse"],
    rollback_excluded: frozenset[str] = frozenset(),
    hidden: frozenset[str] = frozenset(),
) -> MeshData:
    """`assembly-mesh.glb`'s own per-Part geometry lookup - the same
    placeholder-or-real-bodies/`tier="coarse"` logic `_assembly_body_mesh_
    responses` and `get_part_mesh` already have, but returns one merged
    `MeshData` per Part (`_merged_body_mesh_data`) rather than a list of
    per-Body `BodyMeshResponse`s - `encode_assembly_glb` needs exactly one
    glTF mesh per unique Part (per colour - see that function's own
    docstring), not one per Body.

    `rollback_excluded` / `hidden` are `GET /parts/{id}/mesh`'s own two client-side
    exclusion sets (see `get_part_mesh`), for the one Part the client is
    editing (`get_assembly_mesh_glb` passes them for the requested root only):
    `rollback_excluded` is fed straight into `compute_part_bodies` (those
    Features, and everything depending on them, are skipped as if they did not
    exist yet); `hidden` is purely cosmetic - every Body is still computed
    against the real history (so a Plane anchored to a hidden Body's face keeps
    resolving), and a Body whose creating Feature is hidden is just left out of
    the merged mesh. Both default to empty, which is the old behaviour exactly."""
    if not part.produces_displayable_geometry:
        # Empty, not the placeholder box - see `_assembly_body_mesh_responses`.
        return MeshData()

    if tier == "coarse":
        coarse_eligible = coarse_eligible_feature_ids(part)
        bodies = {
            body_id: shape
            for body_id, shape in compute_part_bodies_coarse(part, rollback_excluded).items()
            if base_feature_id(body_id) in coarse_eligible
        }
    else:
        bodies = compute_part_bodies(part, rollback_excluded)
    if hidden:
        bodies = {body_id: shape for body_id, shape in bodies.items() if base_feature_id(body_id) not in hidden}
    return _merged_body_mesh_data(bodies, mesh_quality)


def _walk_assembly_glb_instances(
    document: Document,
    part: Part,
    occurrence_path: list[str],
    transform_chain: list[RigidTransform],
    hidden: bool,
    ancestors: frozenset[str],
    mesh_quality: MeshQuality,
    tier: Literal["full", "coarse"],
    geometry_by_part_id: dict[str, MeshData],
    instances: list[AssemblyGlbInstance],
    color: str | None = None,
    owner_part_id: str = "",
    occurrence_id: str = "",
) -> None:
    """`assembly-mesh.glb`'s own counterpart to `get_assembly_mesh`'s own
    `_walk` (identical traversal shape - resolved-`part_id`/suppressed/cycle
    skips, the same `ComponentPattern` expansion) - deliberately forked
    rather than shared, the same "don't risk the existing, already-tested
    assembly-mesh path" reasoning `_walk_assembly_export_bodies` already
    gives for its own fork. Builds `AssemblyGlbInstance`s (world-space
    translation + quaternion, `encode_assembly_glb`'s own input shape)
    instead of `AssemblyOccurrenceInstance`s, and memoizes each unique
    Part's own merged `MeshData` into `geometry_by_part_id` instead of a
    `BodyMeshResponse` list.

    Milestone 4: `owner_part_id`/`occurrence_id` name *this* instance for
    Mate/Measure purposes (see `AssemblyGlbInstance`'s own docstring) -
    always the immediate parent `Part.id` and the real `Occurrence.id` that
    placed it, one level up, never the deeper `occurrence_path` (that's only
    ever used for pattern-derived instance-id strings, unrelated to this)."""
    if part.id not in geometry_by_part_id:
        geometry_by_part_id[part.id] = _assembly_glb_part_mesh_data(part, mesh_quality, tier)

    world_transform = compose_chain(transform_chain)
    quaternion = _quaternion_from_axis_angle(world_transform.rotation_axis, world_transform.rotation_angle_degrees)
    instances.append(
        AssemblyGlbInstance(
            part_id=part.id,
            translation=world_transform.translation,
            rotation_quaternion=quaternion,
            color=color,
            hidden=hidden,
            owner_part_id=owner_part_id,
            occurrence_id=occurrence_id,
        )
    )

    child_ancestors = ancestors | {part.id}
    for occurrence in part.occurrences:
        if occurrence.suppressed or occurrence.part_id is None:
            continue
        child_part = document.parts.get(occurrence.part_id)
        if child_part is None or child_part.id in child_ancestors:
            continue
        _walk_assembly_glb_instances(
            document,
            child_part,
            [*occurrence_path, occurrence.id],
            [*transform_chain, occurrence.transform],
            occurrence.hidden,
            child_ancestors,
            mesh_quality,
            tier,
            geometry_by_part_id,
            instances,
            color=occurrence.color,
            owner_part_id=part.id,
            occurrence_id=occurrence.id,
        )
    for pattern in part.component_patterns:
        if pattern.suppressed:
            continue
        for source_id in pattern.source_occurrence_ids:
            source_occurrence = next((o for o in part.occurrences if o.id == source_id), None)
            if source_occurrence is None or source_occurrence.suppressed or source_occurrence.part_id is None:
                continue
            pattern_child_part = document.parts.get(source_occurrence.part_id)
            if pattern_child_part is None or pattern_child_part.id in child_ancestors:
                continue
            derived_transforms = expand_component_pattern_instances(pattern, source_occurrence.transform)
            for index, derived_transform in derived_transforms.items():
                _walk_assembly_glb_instances(
                    document,
                    pattern_child_part,
                    [*occurrence_path, f"{source_occurrence.id}#pattern:{pattern.id}:{index}"],
                    [*transform_chain, derived_transform],
                    source_occurrence.hidden,
                    child_ancestors,
                    mesh_quality,
                    tier,
                    geometry_by_part_id,
                    instances,
                    color=source_occurrence.color,
                    owner_part_id=part.id,
                    occurrence_id="",  # pattern-derived copy: no Occurrence entry of its own to reference
                )


@router.get("/parts/{part_id}/assembly-mesh.glb")
def get_assembly_mesh_glb(
    part_id: str,
    quality: float | None = Query(default=None, ge=0.0, le=1.0),
    tier: Literal["full", "coarse"] = Query(default="full"),
    include_hidden: bool = Query(default=False),
    topology: bool = Query(default=True),
    hidden_feature_ids: list[str] = Query(default=[]),
    rollback_excluded_feature_ids: list[str] = Query(default=[]),
) -> Response:
    """`GET /parts/{part_id}/assembly-mesh`'s node-instanced binary glTF
    sibling (`docs/vr-recon-2026-09-24.md` SS2 point 2, sized for real in
    `docs/vr-recon-2-2026-09-24.md` SS3 point 3 - a non-Flutter Quest client
    needs the assembly scene as compact glTF, and one glTF scene per call is
    the locked-in shape, not per-part files). Walks the exact same
    Occurrence/`ComponentPattern` tree `get_assembly_mesh` does
    (`_walk_assembly_glb_instances`, forked the same way `export/assembly-*`
    already forks from `_walk` - see that function's own docstring), but
    emits one `app.document.mesh_export.encode_assembly_glb`-shaped node per
    placed instance pointing at its Part's own shared glTF mesh, instead of
    JSON (`AssemblyMeshResponse`) or a fully-flattened, one-copy-per-instance
    file (`export/assembly-glb`).

    `quality`/`tier` behave exactly as they do on `GET /parts/{id}/mesh` -
    `tier="coarse"` swaps in `compute_part_bodies_coarse` for every Part in
    the scene, `quality` maps through `mesh_quality_from_slider` the same
    way. `include_hidden` (default `False`, new to this endpoint - the JSON
    `assembly-mesh` endpoint always reports every instance's own `hidden`
    flag and leaves filtering to the client) drops any instance whose own
    Occurrence is hidden before encoding, so a Quest client that doesn't
    want to bother decoding-then-discarding hidden geometry doesn't have to;
    `?include_hidden=true` restores the JSON endpoint's "everything, client
    filters" behaviour.

    `topology` (default `True`, VR Measure tool): also carry each Body's real
    edges, vertices and per-face boundary edges in the primitive's `extras`
    (see `app.document.mesh_export.encode_assembly_glb`), so a client can pick
    and name an edge or vertex, not just a face. `?topology=false` leaves
    them out for a client that only picks faces (smaller file).

    `hidden_feature_ids` / `rollback_excluded_feature_ids` (VR design table's
    build tree): the same two client-side exclusion sets `GET /parts/{id}/mesh`
    takes - Hide / Show (cosmetic: the Feature's Body is left out of the mesh
    but everything is still computed against the real history) and rollback
    (the named Features and what depends on them are skipped). They apply to
    the REQUESTED part's own geometry only, never to the placed child Parts of
    an assembly, the same rule the JSON assembly endpoint already states (they
    are the open Part's live-editing state). Both default to empty: the
    response is then byte-identical to before."""
    document = get_document()
    root_part = get_part_or_404(part_id)
    mesh_quality = DEFAULT_MESH_QUALITY if quality is None else mesh_quality_from_slider(quality)

    geometry_by_part_id: dict[str, MeshData] = {}
    if hidden_feature_ids or rollback_excluded_feature_ids:
        # Pre-seeded for the root only: the walk below computes every OTHER part itself and skips any part already in this dict.
        geometry_by_part_id[root_part.id] = _assembly_glb_part_mesh_data(
            root_part,
            mesh_quality,
            tier,
            rollback_excluded=frozenset(rollback_excluded_feature_ids),
            hidden=frozenset(hidden_feature_ids),
        )
    instances: list[AssemblyGlbInstance] = []
    _walk_assembly_glb_instances(
        document,
        root_part,
        [],
        [],
        False,
        frozenset(),
        mesh_quality,
        tier,
        geometry_by_part_id,
        instances,
        owner_part_id=root_part.id,
        occurrence_id="",  # the root's own top-level content, not a placed Occurrence
    )
    visible_instances = instances if include_hidden else [instance for instance in instances if not instance.hidden]

    data = encode_assembly_glb(geometry_by_part_id, visible_instances, include_topology=topology)
    return Response(
        content=data,
        media_type="model/gltf-binary",
        headers={"Content-Disposition": f'attachment; filename="{root_part.name}-assembly.glb"'},
    )


@router.post("/parts/{part_id}/section-preview", response_model=list[SectionBodyMeshResponse])
def preview_section(
    part_id: str, payload: SectionPreviewRequest, quality: float | None = Query(default=None, ge=0.0, le=1.0)
) -> list[SectionBodyMeshResponse]:
    """The sectioning tool's own stateless preview endpoint (`docs/roadmap.
    md`'s "Analysis tools" entry) - trims each of `payload.targets`' own
    current shape (per `GET /mesh`'s own `compute_part_bodies`, resolved
    against each target's own Occurrence - assembly-testing bug fix, see
    `app.document.section.compute_section_mesh`'s own docstring) by the
    intersection of `payload.planes`, and tessellates the result, exactly
    like `_coarse_preview_response` does for a not-yet-created Feature
    payload. Never calls `part.add_feature`, never touches `app.document.
    graph`/`app.document.store` - nothing here is persisted, and nothing
    about `part`'s own stored state changes as a result of calling this,
    matching `app.document.section`'s own module-level "not a Feature"
    framing exactly."""
    part = get_part_or_404(part_id)
    document = get_document()
    mesh_quality = DEFAULT_MESH_QUALITY if quality is None else mesh_quality_from_slider(quality)
    planes = [SectionPlaneSpec(origin=p.origin, normal=p.normal, flipped=p.flipped) for p in payload.planes]
    targets = [SectionBodyTarget(occurrence_id=t.occurrence_id, body_id=t.body_id) for t in payload.targets]
    section_bodies = compute_section_mesh(document, part, targets, planes)
    return [
        SectionBodyMeshResponse(
            occurrence_id=body.occurrence_id,
            body_id=body.body_id,
            mesh=_mesh_vertex_data(tessellate_shape(body.shape, mesh_quality)),
            cut_face_ids=body.cut_face_ids,
        )
        for body in section_bodies
    ]


@router.get("/export/native")
def export_native_document(part_id: str | None = None) -> dict:
    """Native Save: hands back the in-memory Document as a plain JSON dict -
    no cached mesh/geometry (see `app.document.native_format.export_native`'s
    own docstring for the full "pure parametric tree" rationale). Client-
    owned files (locked-in scope): the backend has no project storage of its
    own, this is the client's one chance to read the full state out before
    it writes the actual file to disk.

    `part_id` omitted (default): every Part currently in this session's
    Document - a full session snapshot. `part_id=<id>`: just that one
    Part's own data (its own features *and* its own occurrences/mates, both
    of which can coexist on one Part - see `Part`'s own docstring), which
    is what saving a single file in a multi-file assembly actually needs
    (`docs/assembly-scope.md`) - each `.didsa` file is independently
    saveable, and must never embed the resolved subtree its own
    Occurrences' `external_ref`s point at, since those live in their own
    separate files. 404s for an unknown `part_id`."""
    try:
        return export_native(get_document(), all_sketches(), part_id=part_id)
    except NativeFormatError as exc:
        raise HTTPException(status_code=404, detail=str(exc))


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


@router.post("/parts/{root_part_id}/add-component", response_model=AddComponentResponse)
def add_component(root_part_id: str, payload: AddComponentRequest) -> AddComponentResponse:
    """Adds one new Occurrence of `payload.component` (another native file's
    own already-exported payload - the caller fetched it however it fetches
    files, this backend never resolves a path itself) onto `root_part_id`,
    *without* discarding the rest of the live session's Document the way
    `POST /import/native` (a full replace) would. Backend port of the
    Flutter client's own `add_component.dart::mergeComponentIntoDocument`
    (`app.document.add_component`'s own docstring has the full rationale) -
    built for the VR client, which has no `StorageService`/`ProjectRoot` of
    its own to run that Dart code, and whose Mates tool otherwise has
    nothing to test against beyond whatever single file loaded at startup
    (`DIDSA-VR`'s `docs/status.md`, "Mates: blocked on a multi-body test
    file and no in-VR open/add-parts path").

    404s if `root_part_id` doesn't name a Part in the current session (same
    convention as every other `/parts/{id}/...` endpoint); 422s for anything
    `merge_component_into_document`/`import_native` reject (a schema-version
    mismatch, a component file with no Parts, a self-reference, or malformed
    native data) - the live session is never touched unless the merge and
    the resulting re-import both succeed."""
    get_part_or_404(root_part_id)
    current_payload = export_native(get_document(), all_sketches())
    occurrence_id = payload.occurrence_id or str(uuid.uuid4())
    try:
        merged_payload = merge_component_into_document(
            current_payload=current_payload,
            component_payload=payload.component,
            root_part_id=root_part_id,
            occurrence_id=occurrence_id,
            external_ref=payload.external_ref,
            name_override=payload.name_override,
        )
        document, sketches = import_native(merged_payload)
    except (AddComponentError, NativeFormatError) as exc:
        raise HTTPException(status_code=422, detail=str(exc))
    replace_document(document)
    replace_all_sketches(sketches)
    return AddComponentResponse(document_id=document.id, part_ids=list(document.parts.keys()), occurrence_id=occurrence_id)


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


def _merged_body_mesh_data(bodies: dict[str, object], mesh_quality: MeshQuality = DEFAULT_MESH_QUALITY) -> MeshData:
    """Tessellates every Body in `bodies` and concatenates them into one
    flat `MeshData`, offsetting each Body's own triangle indices past
    whatever's already been appended - a single combined mesh per Part,
    matching a single exported STL/OBJ/glb file (unlike `/mesh`, which
    deliberately keeps Bodies separate for the viewport's own per-Body
    hit-testing - export has no such need). `mesh_quality` defaults to
    `DEFAULT_MESH_QUALITY` for every existing caller (the single-Part export
    endpoints below, none of which take a `quality` param); `assembly-mesh.
    glb`'s own per-Part geometry lookup passes its own resolved `quality`
    through instead.

    Milestone 4: also stamps `merged.face_ids`/`merged.body_ids` (see
    `MeshData.body_ids`'s own docstring for why `face_ids` is carried
    through un-offset while `triangles`' vertex indices are not) so
    `assembly-mesh.glb`'s per-triangle face picking works across a
    multi-Body Part, not just a single-Body one."""
    merged = MeshData()
    for body_id, shape in bodies.items():
        body_mesh = tessellate_shape(shape, mesh_quality)
        offset = len(merged.vertices)
        merged.vertices.extend(body_mesh.vertices)
        merged.normals.extend(body_mesh.normals)
        merged.triangles.extend(
            Triangle(a=t.a + offset, b=t.b + offset, c=t.c + offset) for t in body_mesh.triangles
        )
        merged.face_ids.extend(body_mesh.face_ids)
        merged.body_ids.extend([body_id] * len(body_mesh.triangles))
        if body_mesh.edge_ref_indices:
            # VR Measure tool: edges/vertices stay per Body (see BodyTopology).
            merged.body_topology[body_id] = BodyTopology(
                edges=body_mesh.edges,
                edge_ids=body_mesh.edge_ids,
                edge_ref_indices=body_mesh.edge_ref_indices,
                topology_vertices=body_mesh.topology_vertices,
                topology_vertex_ids=body_mesh.topology_vertex_ids,
                face_edge_ids=body_mesh.face_edge_ids,
                edge_kinds=body_mesh.edge_kinds,
                face_kinds=body_mesh.face_kinds,
            )
    return merged


@router.get("/parts/{part_id}/export/step")
def export_part_step(part_id: str) -> Response:
    """AP242 STEP export (locked-in scope) of every current Body in this
    Part - see `app.document.step_export.export_step`'s own docstring for
    why AP242 is written now even with no PMI/MBD populated yet."""
    part = get_part_or_404(part_id)
    bodies = _export_bodies_or_400(part)
    data = export_step(bodies, part)
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


def _walk_assembly_export_bodies(
    document: Document,
    part: Part,
    occurrence_path: list[str],
    transform_chain: list[RigidTransform],
    ancestors: frozenset[str],
    out: dict[str, TopoDS_Shape],
) -> None:
    """Assembly-audit gap `[29]` (`docs/assembly-scope.md`): the export
    formats' own counterpart to `get_assembly_mesh`'s own `_walk` (same
    traversal shape - resolved-`part_id`/suppressed/cycle skips, the same
    `ComponentPattern` expansion so a pattern's own derived instances are
    included too - deliberately *not* shared code with that function, since
    it produces tessellated mesh data for the viewport while this produces
    real `TopoDS_Shape`s for a file export; forking the two avoids risking
    the existing, already-tested assembly-mesh path for this new one).
    Every placed instance's own Body gets `apply_rigid_transform_to_shape`
    (already built for the Section/Measure tools' own cross-occurrence
    fixes, `extrude.py`) applied with its real composed world transform, and
    is entered into `out` under its own unique key (`occurrence_path` joined
    with the Body id) - unlike `get_assembly_mesh`'s own geometry dedup by
    Part id, every instance gets its own real, correctly-positioned copy
    here, since a file export has no equivalent of "one shared mesh, many
    instance transforms" the way the interactive viewport does."""
    bodies = compute_part_bodies(part)
    world_transform = compose_chain(transform_chain)
    prefix = "/".join(occurrence_path) if occurrence_path else part.id
    for body_id, shape in bodies.items():
        out[f"{prefix}#{body_id}"] = apply_rigid_transform_to_shape(shape, world_transform)
    child_ancestors = ancestors | {part.id}
    for occurrence in part.occurrences:
        if occurrence.suppressed or occurrence.part_id is None:
            continue
        child_part = document.parts.get(occurrence.part_id)
        if child_part is None or child_part.id in child_ancestors:
            continue
        _walk_assembly_export_bodies(
            document,
            child_part,
            [*occurrence_path, occurrence.id],
            [*transform_chain, occurrence.transform],
            child_ancestors,
            out,
        )
    for pattern in part.component_patterns:
        if pattern.suppressed:
            continue
        for source_id in pattern.source_occurrence_ids:
            source_occurrence = next((o for o in part.occurrences if o.id == source_id), None)
            if source_occurrence is None or source_occurrence.suppressed or source_occurrence.part_id is None:
                continue
            pattern_child_part = document.parts.get(source_occurrence.part_id)
            if pattern_child_part is None or pattern_child_part.id in child_ancestors:
                continue
            derived_transforms = expand_component_pattern_instances(pattern, source_occurrence.transform)
            for index, derived_transform in derived_transforms.items():
                _walk_assembly_export_bodies(
                    document,
                    pattern_child_part,
                    [*occurrence_path, f"{source_occurrence.id}#pattern:{pattern.id}:{index}"],
                    [*transform_chain, derived_transform],
                    child_ancestors,
                    out,
                )


def _assembly_export_bodies_or_400(part_id: str) -> tuple[Part, dict[str, TopoDS_Shape]]:
    """[_export_bodies_or_400]'s assembly-scoped sibling - every placed
    instance's own real, world-positioned geometry (including
    `ComponentPattern`-derived ones), not just [part_id]'s own local Bodies.
    400s for a Part with nothing reachable to export at all, the same
    "don't silently emit an empty/invalid file" contract."""
    document = get_document()
    root_part = get_part_or_404(part_id)
    bodies: dict[str, TopoDS_Shape] = {}
    _walk_assembly_export_bodies(document, root_part, [], [], frozenset(), bodies)
    if not bodies:
        raise HTTPException(status_code=400, detail="Part has no geometry to export")
    return root_part, bodies


@router.get("/parts/{part_id}/export/assembly-step")
def export_part_assembly_step(part_id: str) -> Response:
    """Assembly-audit gap `[29]` (`docs/assembly-scope.md`): [export_part_step]'s
    own assembly-aware sibling - every placed Occurrence's real geometry, at
    its real composed world transform, not just [part_id]'s own local
    Bodies (which the plain `export/step` endpoint stays scoped to,
    unchanged, for backward compatibility with every existing caller/test).
    `part=None` (geometry only, no MBD/material metadata) - a per-body
    material resolution would need a Part-per-instance mapping
    `export_step` has no shape for today, and guessing at [root_part]'s own
    default for every instance's material would be actively misleading
    rather than merely incomplete, so this stays geometry-only until that's
    worth building."""
    root_part, bodies = _assembly_export_bodies_or_400(part_id)
    data = export_step(bodies, part=None)
    return Response(
        content=data,
        media_type="application/step",
        headers={"Content-Disposition": f'attachment; filename="{root_part.name}.step"'},
    )


@router.get("/parts/{part_id}/export/assembly-stl")
def export_part_assembly_stl(part_id: str) -> Response:
    root_part, bodies = _assembly_export_bodies_or_400(part_id)
    data = encode_stl(_merged_body_mesh_data(bodies))
    return Response(
        content=data,
        media_type="model/stl",
        headers={"Content-Disposition": f'attachment; filename="{root_part.name}.stl"'},
    )


@router.get("/parts/{part_id}/export/assembly-obj")
def export_part_assembly_obj(part_id: str) -> Response:
    root_part, bodies = _assembly_export_bodies_or_400(part_id)
    data = encode_obj(_merged_body_mesh_data(bodies)).encode("utf-8")
    return Response(
        content=data,
        media_type="text/plain",
        headers={"Content-Disposition": f'attachment; filename="{root_part.name}.obj"'},
    )


@router.get("/parts/{part_id}/export/assembly-glb")
def export_part_assembly_glb(part_id: str) -> Response:
    root_part, bodies = _assembly_export_bodies_or_400(part_id)
    data = encode_glb(_merged_body_mesh_data(bodies))
    return Response(
        content=data,
        media_type="model/gltf-binary",
        headers={"Content-Disposition": f'attachment; filename="{root_part.name}.glb"'},
    )


# Gear-family routes live in gears_routes.py; included last so every helper they import from this module exists.
from app.document.gears_routes import gear_router  # noqa: E402

router.include_router(gear_router)
