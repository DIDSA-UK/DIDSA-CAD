"""Real-OCCT tests for GearChainFeature's full router/HTTP surface -
`docs/gear-design/05-gear-chain-and-planetary.md`. Structurally mirrors
`test_rack_feature.py`/`test_loft_feature.py`'s own shape.
"""

import pytest
from fastapi.testclient import TestClient

from app.main import app
from tests.conftest import TEST_API_KEY

client = TestClient(app)
client.headers.update({"X-API-Key": TEST_API_KEY})


def _create_part(name: str = "Part 1") -> dict:
    response = client.post("/document/parts", json={"name": name})
    assert response.status_code == 201
    return response.json()


def _mesh(part_id: str) -> list[dict]:
    response = client.get(f"/document/parts/{part_id}/mesh")
    assert response.status_code == 200
    return response.json()


def _group(group_id: str, module: float, pressure_angle_degrees: float = 20.0) -> dict:
    return {"id": group_id, "module": module, "pressure_angle_degrees": pressure_angle_degrees}


def _member(member_type: str, group_id: str, tooth_count: int, face_width: float = 5.0, outer_diameter=None) -> dict:
    payload = {
        "member_type": member_type,
        "group_id": group_id,
        "tooth_count": tooth_count,
        "face_width": face_width,
    }
    if outer_diameter is not None:
        payload["outer_diameter"] = outer_diameter
    return payload


def _stage(
    turn_angle_degrees: float = 0.0,
    member=None,
    compound_member_a=None,
    compound_member_b=None,
    compound_axial_offset: float = 0.0,
    compound_merge: str = "fuse_into_one",
) -> dict:
    return {
        "turn_angle_degrees": turn_angle_degrees,
        "member": member,
        "compound_member_a": compound_member_a,
        "compound_member_b": compound_member_b,
        "compound_axial_offset": compound_axial_offset,
        "compound_merge": compound_merge,
    }


def _create_gear_chain(part_id: str, groups: list[dict], stages: list[dict], **overrides) -> dict:
    payload = {"groups": groups, "stages": stages}
    payload.update(overrides)
    return client.post(f"/document/parts/{part_id}/gear-chain-features", json=payload)


def _bbox_center(vertices: list[list[float]]) -> tuple[float, float]:
    xs = [v[0] for v in vertices]
    ys = [v[1] for v in vertices]
    return ((max(xs) + min(xs)) / 2, (max(ys) + min(ys)) / 2)


# --- Basic construction ----------------------------------------------------


def test_two_stage_chain_produces_two_bodies_with_real_mesh_geometry():
    part = _create_part()
    groups = [_group("g1", 2.0)]
    stages = [
        _stage(member=_member("external", "g1", 20)),
        _stage(member=_member("external", "g1", 15)),
    ]
    response = _create_gear_chain(part["id"], groups, stages)
    assert response.status_code == 201, response.json()
    body = response.json()
    assert body["type"] == "gear_chain"
    assert body["warnings"] == []

    mesh = _mesh(part["id"])
    assert len(mesh) == 2
    for entry in mesh:
        assert entry["source"] == "computed"
        assert len(entry["mesh"]["vertices"]) > 0


def test_chain_defaults_to_the_xy_plane_when_plane_ref_omitted():
    part = _create_part()
    groups = [_group("g1", 2.0)]
    stages = [_stage(member=_member("external", "g1", 20)), _stage(member=_member("external", "g1", 15))]
    response = _create_gear_chain(part["id"], groups, stages)
    assert response.status_code == 201, response.json()
    assert response.json()["plane_ref"] == {"face_ref": None, "fixed_plane": "XY", "plane_feature_id": None}


# --- Bent-path positioning: hand-verified against Spike 1's own worked example ---


def test_bent_chain_stage_positions_match_spike_1_hand_verified_example():
    """Module 2, external x4 then internal, one 90 degree turn then a -30
    degree turn back - the exact worked example
    `docs/gear-design/05-gear-chain-and-planetary.md`'s own Spike 1 hand-
    verified (`test_gear_chain_math.py` already checks the pure-math
    resolution against these same numbers directly; this test confirms
    the real OCCT solids actually land there too)."""
    part = _create_part()
    groups = [_group("g1", 2.0)]
    stages = [
        _stage(member=_member("external", "g1", 20)),
        _stage(turn_angle_degrees=0, member=_member("external", "g1", 15)),
        _stage(turn_angle_degrees=90, member=_member("external", "g1", 10)),
        _stage(turn_angle_degrees=-30, member=_member("external", "g1", 25)),
        _stage(turn_angle_degrees=0, member=_member("internal", "g1", 60, outer_diameter=140.0)),
    ]
    response = _create_gear_chain(part["id"], groups, stages)
    assert response.status_code == 201, response.json()

    mesh = _mesh(part["id"])
    assert len(mesh) == 5
    by_body_id = {entry["body_id"]: entry for entry in mesh}
    base_id = response.json()["id"]

    expected_centers = [
        (0.0, 0.0),
        (35.0, 0.0),
        (60.0, 0.0),
        (60.0, 35.0),
        (77.5, 65.310889),
    ]
    for i, expected_center in enumerate(expected_centers):
        body_id = f"{base_id}#{i}"
        assert body_id in by_body_id, sorted(by_body_id.keys())
        cx, cy = _bbox_center(by_body_id[body_id]["mesh"]["vertices"])
        # A gear's own bounding-box centre lands very close to its true
        # centre (exact for a rotationally-symmetric addendum circle), so
        # a generous 1mm tolerance still meaningfully checks the
        # *position*, not just "some geometry exists".
        assert cx == pytest.approx(expected_center[0], abs=1.0)
        assert cy == pytest.approx(expected_center[1], abs=1.0)


# --- Interference checking --------------------------------------------------


def test_interference_flagged_for_the_colliding_bent_chain():
    part = _create_part()
    groups = [_group("g1", 2.0)]
    stages = [
        _stage(member=_member("external", "g1", 20)),
        _stage(turn_angle_degrees=0, member=_member("external", "g1", 15)),
        _stage(turn_angle_degrees=90, member=_member("external", "g1", 10)),
        _stage(turn_angle_degrees=-30, member=_member("external", "g1", 25)),
        _stage(turn_angle_degrees=0, member=_member("internal", "g1", 60, outer_diameter=140.0)),
    ]
    response = _create_gear_chain(part["id"], groups, stages)
    assert response.status_code == 201, response.json()
    warnings = response.json()["warnings"]
    assert len(warnings) >= 3
    assert any("stage 1" in w and "stage 3" in w for w in warnings)


def test_interference_not_flagged_for_a_clear_straight_chain():
    part = _create_part()
    groups = [_group("g1", 1.0)]
    stages = [
        _stage(member=_member("external", "g1", 12)),
        _stage(member=_member("external", "g1", 12)),
        _stage(member=_member("external", "g1", 12)),
    ]
    response = _create_gear_chain(part["id"], groups, stages)
    assert response.status_code == 201, response.json()
    assert response.json()["warnings"] == []


# --- Structural validation --------------------------------------------------


def test_internal_stage_rejected_anywhere_but_last_position():
    part = _create_part()
    groups = [_group("g1", 2.0)]
    stages = [
        _stage(member=_member("internal", "g1", 60, outer_diameter=140.0)),
        _stage(member=_member("external", "g1", 15)),
    ]
    response = _create_gear_chain(part["id"], groups, stages)
    assert response.status_code == 422
    assert "internal" in response.json()["detail"].lower()


def test_internal_stage_allowed_at_last_position():
    part = _create_part()
    groups = [_group("g1", 2.0)]
    stages = [
        _stage(member=_member("external", "g1", 20)),
        _stage(member=_member("internal", "g1", 60, outer_diameter=140.0)),
    ]
    response = _create_gear_chain(part["id"], groups, stages)
    assert response.status_code == 201, response.json()


def test_rack_stage_rejected_in_the_middle():
    part = _create_part()
    groups = [_group("g1", 2.0)]
    stages = [
        _stage(member=_member("external", "g1", 20)),
        _stage(member=_member("rack", "g1", 10)),
        _stage(member=_member("external", "g1", 15)),
    ]
    response = _create_gear_chain(part["id"], groups, stages)
    assert response.status_code == 422


def test_rack_stage_allowed_at_the_end():
    part = _create_part()
    groups = [_group("g1", 2.0)]
    stages = [
        _stage(member=_member("external", "g1", 20)),
        _stage(member=_member("rack", "g1", 10)),
    ]
    response = _create_gear_chain(part["id"], groups, stages)
    assert response.status_code == 201, response.json()
    mesh = _mesh(part["id"])
    assert len(mesh) == 2


def test_last_stage_nonzero_turn_angle_is_rejected():
    part = _create_part()
    groups = [_group("g1", 2.0)]
    stages = [
        _stage(member=_member("external", "g1", 20)),
        _stage(turn_angle_degrees=15.0, member=_member("external", "g1", 15)),
    ]
    response = _create_gear_chain(part["id"], groups, stages)
    assert response.status_code == 422


def test_fewer_than_two_stages_rejected():
    part = _create_part()
    groups = [_group("g1", 2.0)]
    stages = [_stage(member=_member("external", "g1", 20))]
    response = _create_gear_chain(part["id"], groups, stages)
    assert response.status_code == 422


def test_adjacent_stages_with_different_groups_are_rejected_even_with_matching_module():
    """The group-id match is structural, not just a module-value coincidence
    - `05-gear-chain-and-planetary.md`'s own "two stages can only mesh if
    they share a group" rule."""
    part = _create_part()
    groups = [_group("g1", 2.0), _group("g2", 2.0)]
    stages = [
        _stage(member=_member("external", "g1", 20)),
        _stage(member=_member("external", "g2", 15)),
    ]
    response = _create_gear_chain(part["id"], groups, stages)
    assert response.status_code == 422


def test_unknown_group_id_is_rejected():
    part = _create_part()
    groups = [_group("g1", 2.0)]
    stages = [
        _stage(member=_member("external", "g1", 20)),
        _stage(member=_member("external", "does-not-exist", 15)),
    ]
    response = _create_gear_chain(part["id"], groups, stages)
    assert response.status_code == 422


# --- Compound stations -------------------------------------------------------


def test_compound_join_blocks_when_disconnected():
    """Spike 2's own resolution: an axial gap between a compound stage's
    two members produces 2 disconnected solids after the fuse - blocking,
    per `00-conventions.md`'s "no valid geometry to draw" exception."""
    part = _create_part()
    groups = [_group("ga", 1.0), _group("gb", 2.0)]
    stages = [
        _stage(
            compound_member_a=_member("external", "ga", 20, face_width=6.0),
            compound_member_b=_member("external", "gb", 10, face_width=6.0),
            compound_axial_offset=6.5,  # a real 0.5mm gap - Spike 2's own case 1
            compound_merge="fuse_into_one",
        ),
        _stage(member=_member("external", "gb", 15)),
    ]
    response = _create_gear_chain(part["id"], groups, stages)
    assert response.status_code == 422
    assert response.json()["detail"]["type"] == "gear_chain_compound_join_failed"


def test_compound_join_passes_when_well_formed():
    part = _create_part()
    groups = [_group("ga", 1.0), _group("gb", 2.0)]
    stages = [
        _stage(
            compound_member_a=_member("external", "ga", 20, face_width=6.0),
            compound_member_b=_member("external", "gb", 10, face_width=6.0),
            compound_axial_offset=6.0,  # flush - Spike 2's own well-formed case
            compound_merge="fuse_into_one",
        ),
        _stage(member=_member("external", "gb", 15)),
    ]
    response = _create_gear_chain(part["id"], groups, stages)
    assert response.status_code == 201, response.json()
    mesh = _mesh(part["id"])
    # The compound stage fuses into exactly one Body; the downstream stage
    # is a second - two Bodies total, not three.
    assert len(mesh) == 2


def test_compound_stage_rejects_matching_groups_on_its_two_members():
    part = _create_part()
    groups = [_group("ga", 1.0)]
    stages = [
        _stage(
            compound_member_a=_member("external", "ga", 20, face_width=6.0),
            compound_member_b=_member("external", "ga", 10, face_width=6.0),
            compound_axial_offset=6.0,
        ),
        _stage(member=_member("external", "ga", 15)),
    ]
    response = _create_gear_chain(part["id"], groups, stages)
    assert response.status_code == 422


def test_compound_member_cannot_be_a_rack():
    part = _create_part()
    groups = [_group("ga", 1.0), _group("gb", 2.0)]
    stages = [
        _stage(
            compound_member_a=_member("rack", "ga", 20, face_width=6.0),
            compound_member_b=_member("external", "gb", 10, face_width=6.0),
            compound_axial_offset=6.0,
        ),
        _stage(member=_member("external", "gb", 15)),
    ]
    response = _create_gear_chain(part["id"], groups, stages)
    assert response.status_code == 422


# --- Composability + native round-trip --------------------------------------


def test_step_export_succeeds_for_a_gear_chain():
    part = _create_part()
    groups = [_group("g1", 2.0)]
    stages = [_stage(member=_member("external", "g1", 20)), _stage(member=_member("external", "g1", 15))]
    response = _create_gear_chain(part["id"], groups, stages)
    assert response.status_code == 201, response.json()

    export_response = client.get(f"/document/parts/{part['id']}/export/step")
    assert export_response.status_code == 200
    assert b"ISO-10303-21" in export_response.content


def test_native_export_import_round_trips_a_gear_chain_feature():
    """Mirrors `test_rack_feature.py`'s own native round-trip regression
    test - guards against the exact `native_format.py` omission class
    `docs/status.md` flagged for GearFeature in Workstream 2."""
    from app.document.store import get_document, replace_document
    from app.sketch.store import all_sketches, replace_all_sketches

    saved_document = get_document()
    saved_sketches = dict(all_sketches())
    try:
        part = _create_part("Native Gear Chain Test")
        groups = [_group("g1", 2.0)]
        stages = [
            _stage(member=_member("external", "g1", 20)),
            _stage(member=_member("external", "g1", 15)),
        ]
        response = _create_gear_chain(part["id"], groups, stages)
        assert response.status_code == 201, response.json()
        feature_id = response.json()["id"]
        vertices_before = sorted(entry["body_id"] for entry in _mesh(part["id"]))

        export_response = client.get("/document/export/native")
        assert export_response.status_code == 200
        exported = export_response.json()
        chain_dicts = [
            f for p in exported["document"]["parts"] for f in p["features"] if f["type"] == "gear_chain"
        ]
        assert any(f["id"] == feature_id for f in chain_dicts)

        import_response = client.post("/document/import/native", json=exported)
        assert import_response.status_code == 200, import_response.json()

        refetch_response = client.get(f"/document/parts/{part['id']}")
        assert refetch_response.status_code == 200
        vertices_after = sorted(entry["body_id"] for entry in _mesh(part["id"]))
        assert vertices_after == vertices_before
    finally:
        replace_document(saved_document)
        replace_all_sketches(saved_sketches)
