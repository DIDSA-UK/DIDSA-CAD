"""Spring feature HTTP routes (create / update), split out of `app/document/router.py` like
`gears_routes.py`: they share the document router's helpers, so `router.py` includes
`spring_router` after its own definitions. Do not import this module directly."""

import uuid

from fastapi import APIRouter, HTTPException

from app.document.models import Part, SpringFeature
from app.document.router import _default_plane_ref, _feature_response, _plane_ref_to_domain, _validate_plane_ref
from app.document.schemas import SpringFeatureCreate, SpringFeatureResponse, SpringFeatureUpdate
from app.document.spring import resolve_spring
from app.document.store import get_part_or_404

spring_router = APIRouter()


@spring_router.post("/parts/{part_id}/spring-features", response_model=SpringFeatureResponse, status_code=201)
def create_spring_feature(part_id: str, payload: SpringFeatureCreate) -> SpringFeatureResponse:
    """Creates a Spring - checked (`spring_layout`'s structured 422 for numbers that make no
    spring) and built before it is kept, as `create_rack_feature`."""
    part = get_part_or_404(part_id)
    plane_ref = _plane_ref_to_domain(payload.plane_ref) if payload.plane_ref is not None else _default_plane_ref()
    _validate_plane_ref(part, plane_ref)
    feature = SpringFeature(
        id=str(uuid.uuid4()),
        plane_ref=plane_ref,
        mean_diameter=payload.mean_diameter,
        wire_diameter=payload.wire_diameter,
        free_length=payload.free_length,
        active_coils=payload.active_coils,
        start_end=payload.start_end,
        finish_end=payload.finish_end,
        right_handed=payload.right_handed,
    )
    resolve_spring(part, feature)  # raises on numbers that make no spring, or a failed build
    part.add_feature(feature)
    return _feature_response(part, feature)


def _get_spring_feature_or_404(part: Part, feature_id: str) -> SpringFeature:
    feature = part.get_feature(feature_id)
    if not isinstance(feature, SpringFeature):
        raise HTTPException(status_code=404, detail="Spring feature not found")
    return feature


@spring_router.patch("/parts/{part_id}/spring-features/{feature_id}", response_model=SpringFeatureResponse)
def update_spring_feature(part_id: str, feature_id: str, payload: SpringFeatureUpdate) -> SpringFeatureResponse:
    """Partial update: omitted fields keep their values; the candidate is built before anything
    changes, as `update_rack_feature`."""
    part = get_part_or_404(part_id)
    feature = _get_spring_feature_or_404(part, feature_id)
    changes = payload.model_dump(exclude_unset=True, exclude_none=True)
    plane_ref = _plane_ref_to_domain(payload.plane_ref) if payload.plane_ref is not None else feature.plane_ref
    _validate_plane_ref(part, plane_ref)
    candidate = SpringFeature(
        id=feature.id,
        plane_ref=plane_ref,
        mean_diameter=changes.get("mean_diameter", feature.mean_diameter),
        wire_diameter=changes.get("wire_diameter", feature.wire_diameter),
        free_length=changes.get("free_length", feature.free_length),
        active_coils=changes.get("active_coils", feature.active_coils),
        start_end=payload.start_end if payload.start_end is not None else feature.start_end,
        finish_end=payload.finish_end if payload.finish_end is not None else feature.finish_end,
        right_handed=changes.get("right_handed", feature.right_handed),
    )
    resolve_spring(part, candidate)

    feature.plane_ref = candidate.plane_ref
    feature.mean_diameter = candidate.mean_diameter
    feature.wire_diameter = candidate.wire_diameter
    feature.free_length = candidate.free_length
    feature.active_coils = candidate.active_coils
    feature.start_end = candidate.start_end
    feature.finish_end = candidate.finish_end
    feature.right_handed = candidate.right_handed
    return _feature_response(part, feature)
