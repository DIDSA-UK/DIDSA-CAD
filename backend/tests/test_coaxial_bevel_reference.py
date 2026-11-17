"""N1a on the gear-train demo's Bevel A (DIDSA-VR `demo/assemblies/gear_train/Gear_train.didsa`, VR commit 5d8faaf; the Part is copied below so this repo's CI
needs no VR checkout). Its bore (face 105, cylinder R 4) and its rim (face 81, cylinder R 28.04) share the gear's axis, so before N1a a renumbering left either
reference `lost` / `ambiguous` (N1 plan, "What was found": the signature-rules table). With the radius in the signature each is re-found. The renumbering is
simulated by a wrong stored index. Named `*bevel*`, so conftest marks it `gears` (not `bevel_pair`)."""

import dataclasses

import pytest

from app.document.extrude import compute_part_bodies
from app.document.native_format import SCHEMA_VERSION
from app.document.models import SubShapeRef, SubShapeType
from app.document.reference_signature import BodyFaceMeasurer
from app.document.router import get_part_or_404
from app.document.subshape_identity import decide_subshape, measure_signature
from app.sketch.reference_signature import ReferenceStatus
from tests.test_reference_identity import _json, client

# "Bevel gear A (20 teeth)" exactly as the demo file holds it (one bevel_gear feature).
_BEVEL_A = {
    "id": "d45ac52f-a067-4cf2-81cd-2a046d93b1ee",
    "name": "Bevel gear A (20 teeth)",
    "features": [
        {
            "type": "bevel_gear",
            "id": "b804fc71-ad15-4fb4-9439-20a812f9f67f",
            "plane_ref": {"face_ref": None, "fixed_plane": "XY", "plane_feature_id": None},
            "bevel_type": "boss",
            "module": 3.0,
            "tooth_count": 20,
            "face_width": 12.0,
            "pitch_cone_angle_degrees": 45.0,
            "pressure_angle_degrees": 20.0,
            "backlash": 0.0,
            "profile_shift": 0.0,
            "target_body_ids": [],
            "points_per_flank": 12,
            "spiral_angle_degrees": 0.0,
            "spiral_hand": "right",
            "bore_diameter": 8.0,
        }
    ],
    "occurrences": [],
    "mates": [],
}
BORE, RIM = 105, 81


@pytest.fixture(scope="module")
def bevel_a():
    payload = {"schema_version": SCHEMA_VERSION, "document": {"id": "bevel-a-doc", "root_part_id": _BEVEL_A["id"], "parts": [_BEVEL_A]}, "sketches": []}
    _json(client.post("/document/import/native", json=payload))
    ((body_id, body),) = compute_part_bodies(get_part_or_404(_BEVEL_A["id"])).items()
    return body_id, body


def _signed(body_id, body, signed_at: int, index: int) -> SubShapeRef:
    ref = SubShapeRef(body_id=body_id, shape_type=SubShapeType.FACE, index=signed_at)
    return dataclasses.replace(ref, signature=measure_signature(body, ref, signed_at), index=index)


def test_the_bore_and_the_rim_are_where_the_demo_says_and_share_the_axis(bevel_a):
    _, body = bevel_a
    signatures = BodyFaceMeasurer(body).all()
    bore, rim = signatures[BORE], signatures[RIM]
    assert (bore.surface_kind, rim.surface_kind) == ("cylinder", "cylinder")
    assert bore.radius == pytest.approx(4.0) and rim.radius == pytest.approx(28.04, abs=0.01)
    assert abs(bore.direction[2]) > 0.999 and abs(rim.direction[2]) > 0.999
    assert max(abs(bore.position[0]), abs(bore.position[1]), abs(rim.position[0]), abs(rim.position[1])) < 1e-6


@pytest.mark.parametrize(
    "signed_at, renumbered_to",
    [(BORE, RIM), (RIM, BORE), (BORE, 104), (RIM, 3), (BORE, 0)],
    ids=["bore index on the rim", "rim index on the bore", "bore index on the back plane", "rim index on a sphere", "bore index on face 0"],
)
def test_a_renumbered_bore_or_rim_is_re_found_by_radius(bevel_a, signed_at, renumbered_to):
    body_id, body = bevel_a
    decision = decide_subshape(_signed(body_id, body, signed_at, renumbered_to), body)
    assert (decision.status, decision.index, decision.reason) == (ReferenceStatus.FOLLOWED, signed_at, "nearest_radius"), decision


def test_without_the_radius_it_is_ambiguous_as_before(bevel_a):
    body_id, body = bevel_a
    ref = _signed(body_id, body, BORE, 104)
    old = dataclasses.replace(ref, signature=dataclasses.replace(ref.signature, radius=None))
    decision = decide_subshape(old, body)
    assert (decision.status, decision.reason) == (ReferenceStatus.LOST, "ambiguous")
