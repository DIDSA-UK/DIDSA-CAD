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


# --- Meshing-phase alignment ------------------------------------------------
#
# `app.document.bevel_pair`'s own "Meshing phase alignment" fix, generalized
# to an arbitrary chain in `app.document.gear_chain_math.meshing_phase_base`/
# `propagate_meshing_phase` - see that module's own extensive notes for the
# derivation and the real-OCCT counterexamples that ruled out two
# successively-simpler (and wrong) versions of this fix. Tooth counts here
# are deliberately >= 36 (or, for same-size external-external pairs, >= 34) -
# comfortably clear of the low-tooth-count real involute tip interference
# `gear_chain_math`'s own module note documents (a genuine, pre-existing,
# separate geometric limitation that a phase fix cannot itself resolve, and
# which this test suite is not trying to verify) - so any measured overlap
# here is unambiguously a phase bug, not that unrelated confound.

from OCC.Core.BRepAlgoAPI import BRepAlgoAPI_Common  # noqa: E402
from OCC.Core.BRepGProp import brepgprop  # noqa: E402
from OCC.Core.GProp import GProp_GProps  # noqa: E402

from app.document.extrude import _explode_solids  # noqa: E402
from app.document.gear_chain import resolve_gear_chain_from_bodies  # noqa: E402
from app.document.models import (  # noqa: E402
    GearChainFeature,
    GearChainMemberSpec,
    GearChainMemberType,
    GearChainStage,
    GearGroup,
    MergeMode,
    PlaneRef,
)
from app.sketch.models import Plane  # noqa: E402


def _total_pairwise_overlap(shapes: list) -> float:
    total = 0.0
    for i in range(len(shapes)):
        for j in range(i + 1, len(shapes)):
            common = BRepAlgoAPI_Common(shapes[i], shapes[j])
            common.Build()
            assert common.IsDone()
            props = GProp_GProps()
            brepgprop.VolumeProperties(common.Shape(), props)
            total += abs(props.Mass())
    return total


def _chain_member(
    tooth_count: int, member_type: GearChainMemberType = GearChainMemberType.EXTERNAL, outer_diameter=None
) -> GearChainMemberSpec:
    return GearChainMemberSpec(
        group_id="g1", member_type=member_type, tooth_count=tooth_count, face_width=10.0, outer_diameter=outer_diameter
    )


def _build_chain_overlap(stages: list[GearChainStage], *, module: float = 3.0, start_direction_degrees: float = 0.0) -> float:
    group = GearGroup(id="g1", module=module, pressure_angle_degrees=20.0)
    feature = GearChainFeature(
        id="chain-test",
        plane_ref=PlaneRef(fixed_plane=Plane.XY),
        groups=[group],
        stages=stages,
        start_direction_degrees=start_direction_degrees,
        print_clearance_margin=0.5,
    )
    compound, warnings = resolve_gear_chain_from_bodies(feature, None, {}, frozenset())
    shapes = _explode_solids(compound)
    assert warnings == [], f"unexpected warnings: {warnings}"
    return _total_pairwise_overlap(shapes)


def test_two_stage_chain_meshes_without_overlap():
    """Reproduces the originally-reported bug's own simplest case (a plain
    2-stage external/external chain) - before this fix, every tooth-count
    combination tried (at unsafe, low tooth counts) measured real,
    substantial overlap; this combination (36T/50T) is deliberately clear
    of that separate confound, so 0 overlap here isolates the phase fix
    itself."""
    stages = [GearChainStage(member=_chain_member(36)), GearChainStage(member=_chain_member(50))]
    assert _build_chain_overlap(stages) < 1.0


def test_three_stage_chain_meshes_without_overlap_including_the_second_junction():
    """The specific real-OCCT counterexample that drove this fix's own
    final revision: a purely local, predecessor-rotation-blind rule passes
    for the first junction but leaves ~566mm^3 of real overlap at the
    *second* junction, because the first junction's own correction leaves
    stage 1 at a non-trivial rotation that the second junction's phase
    must account for, not ignore."""
    stages = [
        GearChainStage(member=_chain_member(36)),
        GearChainStage(member=_chain_member(40)),
        GearChainStage(member=_chain_member(48)),
    ]
    assert _build_chain_overlap(stages) < 1.0


def test_three_stage_chain_with_a_turn_meshes_without_overlap():
    """The second real-OCCT counterexample: even a per-junction-correct
    rotation (mod that junction's own tooth pitch) still leaves real
    overlap at a *bent* junction unless the correction also accounts for
    the difference between the predecessor's own rotation and *this*
    junction's own contact direction - a term that's exactly zero (and so
    silently unverified) on a straight chain, which is why a -60 degree
    turn is used here rather than 0/45/90 (all, by coincidence, aligned
    with this chain's own tooth pitch)."""
    stages = [
        GearChainStage(member=_chain_member(36)),
        GearChainStage(member=_chain_member(40), turn_angle_degrees=-60.0),
        GearChainStage(member=_chain_member(48)),
    ]
    assert _build_chain_overlap(stages) < 1.0


def test_chain_with_start_direction_offset_meshes_without_overlap():
    stages = [GearChainStage(member=_chain_member(36)), GearChainStage(member=_chain_member(50))]
    assert _build_chain_overlap(stages, start_direction_degrees=30.0) < 1.0


def test_external_into_internal_ring_chain_meshes_without_overlap():
    """The internal-tangency case - `meshing_phase_base`'s own docstring
    derivation for why the contact azimuth flips (unflipped, not `+ pi`)
    when the *predecessor* is INTERNAL."""
    stages = [
        GearChainStage(member=_chain_member(36)),
        GearChainStage(member=_chain_member(90, GearChainMemberType.INTERNAL, outer_diameter=300.0)),
        GearChainStage(member=_chain_member(35)),
    ]
    assert _build_chain_overlap(stages) < 1.0


def test_ring_first_stage_chain_meshes_without_overlap():
    """The mirror case: an INTERNAL member as the chain's own first stage
    (predecessor for every downstream junction, never itself corrected -
    stage 0 always stays at this module's zero-reference)."""
    stages = [
        GearChainStage(member=_chain_member(90, GearChainMemberType.INTERNAL, outer_diameter=300.0)),
        GearChainStage(member=_chain_member(36)),
    ]
    assert _build_chain_overlap(stages) < 1.0


def test_compound_stage_meshes_without_overlap():
    group_a = GearGroup(id="g1", module=3.0, pressure_angle_degrees=20.0)
    group_b = GearGroup(id="g2", module=3.0, pressure_angle_degrees=20.0)
    compound_stage = GearChainStage(
        compound_member_a=GearChainMemberSpec(
            group_id="g1", member_type=GearChainMemberType.EXTERNAL, tooth_count=40, face_width=10.0
        ),
        compound_member_b=GearChainMemberSpec(
            group_id="g2", member_type=GearChainMemberType.EXTERNAL, tooth_count=44, face_width=10.0
        ),
        compound_axial_offset=15.0,
        compound_merge=MergeMode.KEEP_SEPARATE,
    )
    stages = [
        GearChainStage(member=GearChainMemberSpec(group_id="g1", member_type=GearChainMemberType.EXTERNAL, tooth_count=36, face_width=10.0)),
        compound_stage,
        GearChainStage(member=GearChainMemberSpec(group_id="g2", member_type=GearChainMemberType.EXTERNAL, tooth_count=50, face_width=10.0)),
    ]
    feature = GearChainFeature(
        id="chain-compound-test",
        plane_ref=PlaneRef(fixed_plane=Plane.XY),
        groups=[group_a, group_b],
        stages=stages,
        start_direction_degrees=0.0,
        print_clearance_margin=0.5,
    )
    compound, warnings = resolve_gear_chain_from_bodies(feature, None, {}, frozenset())
    shapes = _explode_solids(compound)
    assert warnings == [], f"unexpected warnings: {warnings}"
    assert _total_pairwise_overlap(shapes) < 1.0


def test_gear_into_rack_meshes_without_overlap_on_a_bent_junction():
    """The RACK-as-successor case - `propagate_meshing_phase`'s own arc-
    length correction applied without the division-by-radius a round
    successor needs."""
    stages = [
        GearChainStage(member=_chain_member(36), turn_angle_degrees=25.0),
        GearChainStage(member=_chain_member(15, GearChainMemberType.RACK)),
    ]
    assert _build_chain_overlap(stages) < 1.0
