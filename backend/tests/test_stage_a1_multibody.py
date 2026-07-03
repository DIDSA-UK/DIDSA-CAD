"""A1: multi-body identity tests - Boss/Cut against explicit
`target_body_ids`, body-id stability, and the array-of-bodies /mesh
response shape for genuinely independent bodies. Complements the
single-body-scenario updates made in test_stage9_extrude.py (which cover
the DAG-refactor regression requirement) - this file is specifically
about the *new* multi-body behaviour A1 introduces.

Same helper conventions (copy-pasted, not shared via conftest) as every
other test_stage*.py file in this directory - see test_stage9_extrude.py.
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


def _create_sketch_feature(part_id: str, plane: str = "XY") -> dict:
    response = client.post(f"/document/parts/{part_id}/features/sketch", json={"plane": plane})
    assert response.status_code == 201
    return response.json()


def _add_square(sketch_id: str, x0: float, y0: float, size: float) -> None:
    corners = [
        client.post(f"/sketch/sketches/{sketch_id}/points", json={"x": x, "y": y}).json()
        for x, y in [(x0, y0), (x0 + size, y0), (x0 + size, y0 + size), (x0, y0 + size)]
    ]
    for a, b in zip(corners, corners[1:] + corners[:1]):
        response = client.post(
            f"/sketch/sketches/{sketch_id}/lines",
            json={"start_point_id": a["id"], "end_point_id": b["id"]},
        )
        assert response.status_code == 201


def _create_square_sketch_feature(part_id: str, *, x0=0.0, y0=0.0, size=10.0, plane="XY") -> dict:
    feature = _create_sketch_feature(part_id, plane)
    _add_square(feature["sketch_id"], x0, y0, size)
    return feature


def _create_extrude_feature(
    part_id: str,
    sketch_feature_id: str,
    *,
    extrude_type: str = "boss",
    start_distance: float = 0.0,
    end_distance: float = 10.0,
    target_body_ids: list[str] | None = None,
):
    return client.post(
        f"/document/parts/{part_id}/extrude-features",
        json={
            "sketch_feature_id": sketch_feature_id,
            "extrude_type": extrude_type,
            "start_distance": start_distance,
            "end_distance": end_distance,
            "target_body_ids": target_body_ids or [],
        },
    )


def _get_bodies(part_id: str, hidden_feature_ids: list[str] | None = None) -> list[dict]:
    response = client.get(
        f"/document/parts/{part_id}/mesh",
        params={"hidden_feature_ids": hidden_feature_ids} if hidden_feature_ids else None,
    )
    assert response.status_code == 200
    return response.json()


def _boss(part_id: str, *, x0: float, y0: float, size: float = 10.0) -> dict:
    """Convenience: a fresh, non-overlapping square Sketch + Boss
    ExtrudeFeature, starting a brand-new Body (empty target_body_ids)."""
    sketch = _create_square_sketch_feature(part_id, x0=x0, y0=y0, size=size)
    response = _create_extrude_feature(part_id, sketch["id"], extrude_type="boss")
    assert response.status_code == 201
    return response.json()


# --- Boss: new body vs fuse-into-one vs fuse-into-multiple ------------------


def test_boss_with_empty_target_body_ids_creates_a_new_body():
    part = _create_part()
    boss = _boss(part["id"], x0=0.0, y0=0.0)

    bodies = _get_bodies(part["id"])

    assert {b["body_id"] for b in bodies} == {boss["id"]}


def test_boss_with_one_target_body_id_fuses_into_that_body_keeping_its_id():
    part = _create_part()
    boss1 = _boss(part["id"], x0=0.0, y0=0.0, size=10.0)

    # Overlapping footprint so the fuse produces genuinely merged geometry,
    # not just two disjoint solids inside one compound.
    sketch2 = _create_square_sketch_feature(part["id"], x0=5.0, y0=0.0, size=10.0)
    boss2_response = _create_extrude_feature(
        part["id"], sketch2["id"], extrude_type="boss", target_body_ids=[boss1["id"]]
    )
    assert boss2_response.status_code == 201

    bodies = _get_bodies(part["id"])

    assert {b["body_id"] for b in bodies} == {boss1["id"]}
    assert len(bodies[0]["mesh"]["vertices"]) > 0


def test_boss_with_multiple_target_body_ids_fuses_all_into_one_body():
    part = _create_part()
    boss1 = _boss(part["id"], x0=0.0, y0=0.0)
    boss2 = _boss(part["id"], x0=20.0, y0=0.0)
    assert len(_get_bodies(part["id"])) == 2

    bridge_sketch = _create_square_sketch_feature(part["id"], x0=8.0, y0=0.0, size=14.0)
    bridge_response = _create_extrude_feature(
        part["id"],
        bridge_sketch["id"],
        extrude_type="boss",
        target_body_ids=[boss1["id"], boss2["id"]],
    )
    assert bridge_response.status_code == 201

    bodies = _get_bodies(part["id"])

    # One fewer body than before - all three solids fused into one.
    assert len(bodies) == 1
    # Deterministic merge tie-break (A1): the surviving id belongs to
    # whichever named target Feature appears earliest in the Part's
    # Feature list - boss1 was created before boss2.
    assert bodies[0]["body_id"] == boss1["id"]


def test_boss_merge_survivor_id_is_the_earliest_target_regardless_of_argument_order():
    """Same scenario as above, but target_body_ids lists boss2 before
    boss1 - the survivor must still be boss1 (earliest in Part.features),
    confirming the tie-break is driven by Feature-list position, not
    target_body_ids argument order."""
    part = _create_part()
    boss1 = _boss(part["id"], x0=0.0, y0=0.0)
    boss2 = _boss(part["id"], x0=20.0, y0=0.0)

    bridge_sketch = _create_square_sketch_feature(part["id"], x0=8.0, y0=0.0, size=14.0)
    _create_extrude_feature(
        part["id"],
        bridge_sketch["id"],
        extrude_type="boss",
        target_body_ids=[boss2["id"], boss1["id"]],
    )

    bodies = _get_bodies(part["id"])

    assert len(bodies) == 1
    assert bodies[0]["body_id"] == boss1["id"]


# --- Cut: requires non-empty target_body_ids, only affects named bodies -----


def test_cut_with_empty_target_body_ids_is_422():
    part = _create_part()
    sketch = _create_square_sketch_feature(part["id"])

    response = _create_extrude_feature(part["id"], sketch["id"], extrude_type="cut")

    assert response.status_code == 422


def test_cut_only_removes_material_from_its_named_target_body():
    part = _create_part()
    boss1 = _boss(part["id"], x0=0.0, y0=0.0, size=10.0)
    boss2 = _boss(part["id"], x0=20.0, y0=0.0, size=10.0)
    bodies_before = {b["body_id"]: b["mesh"]["vertices"] for b in _get_bodies(part["id"])}

    cut_sketch = _create_square_sketch_feature(part["id"], x0=3.0, y0=3.0, size=4.0)
    cut_response = _create_extrude_feature(
        part["id"], cut_sketch["id"], extrude_type="cut", target_body_ids=[boss1["id"]]
    )
    assert cut_response.status_code == 201

    bodies_after = {b["body_id"]: b["mesh"]["vertices"] for b in _get_bodies(part["id"])}

    assert set(bodies_after.keys()) == {boss1["id"], boss2["id"]}
    assert bodies_after[boss1["id"]] != bodies_before[boss1["id"]]
    # boss2 was never named as a target - its geometry is untouched.
    assert bodies_after[boss2["id"]] == bodies_before[boss2["id"]]


def test_cut_can_target_multiple_bodies_at_once():
    part = _create_part()
    boss1 = _boss(part["id"], x0=0.0, y0=0.0, size=10.0)
    boss2 = _boss(part["id"], x0=20.0, y0=0.0, size=10.0)

    cut_sketch = _create_square_sketch_feature(part["id"], x0=3.0, y0=3.0, size=4.0)
    cut_response = _create_extrude_feature(
        part["id"],
        cut_sketch["id"],
        extrude_type="cut",
        target_body_ids=[boss1["id"], boss2["id"]],
    )
    assert cut_response.status_code == 201

    bodies = _get_bodies(part["id"])
    assert {b["body_id"] for b in bodies} == {boss1["id"], boss2["id"]}


# --- target_body_ids validation ---------------------------------------------


def test_boss_naming_an_unknown_target_body_id_is_rejected():
    part = _create_part()
    sketch = _create_square_sketch_feature(part["id"])

    response = _create_extrude_feature(
        part["id"], sketch["id"], extrude_type="boss", target_body_ids=["does-not-exist"]
    )

    assert response.status_code == 400


def test_cut_naming_an_unknown_target_body_id_is_rejected():
    part = _create_part()
    sketch = _create_square_sketch_feature(part["id"])

    response = _create_extrude_feature(
        part["id"], sketch["id"], extrude_type="cut", target_body_ids=["does-not-exist"]
    )

    assert response.status_code == 400


def test_patch_clearing_target_body_ids_on_a_cut_is_rejected():
    part = _create_part()
    boss = _boss(part["id"], x0=0.0, y0=0.0)
    cut_sketch = _create_square_sketch_feature(part["id"], x0=3.0, y0=3.0, size=4.0)
    cut = _create_extrude_feature(
        part["id"], cut_sketch["id"], extrude_type="cut", target_body_ids=[boss["id"]]
    ).json()

    response = client.patch(
        f"/document/parts/{part['id']}/extrude-features/{cut['id']}",
        json={"target_body_ids": []},
    )

    assert response.status_code == 422


# --- Multi-body /mesh response shape ----------------------------------------


def test_mesh_on_two_independent_bodies_returns_two_array_entries():
    part = _create_part()
    boss1 = _boss(part["id"], x0=0.0, y0=0.0, size=10.0)
    boss2 = _boss(part["id"], x0=100.0, y0=0.0, size=10.0)

    bodies = _get_bodies(part["id"])

    assert len(bodies) == 2
    body_ids = {b["body_id"] for b in bodies}
    assert body_ids == {boss1["id"], boss2["id"]}
    for body in bodies:
        assert body["source"] == "computed"
        assert len(body["mesh"]["vertices"]) > 0
        # Each Body's face_ids are dense/self-contained (6 faces for a box,
        # ids 0..5) - not offset by the other Body's own face count.
        assert set(body["mesh"]["face_ids"]) == {0, 1, 2, 3, 4, 5}


def test_response_target_body_ids_round_trips_on_the_extrude_feature():
    part = _create_part()
    boss = _boss(part["id"], x0=0.0, y0=0.0)
    cut_sketch = _create_square_sketch_feature(part["id"], x0=3.0, y0=3.0, size=4.0)

    response = _create_extrude_feature(
        part["id"], cut_sketch["id"], extrude_type="cut", target_body_ids=[boss["id"]]
    )

    assert response.status_code == 201
    assert response.json()["target_body_ids"] == [boss["id"]]

    fetched = client.get(f"/document/parts/{part['id']}/features/{response.json()['id']}").json()
    assert fetched["target_body_ids"] == [boss["id"]]
