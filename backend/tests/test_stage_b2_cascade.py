"""B2: graph-aware cascade delete over the real `/cascade` endpoint - a
Sketch/Extrude DAG needs a real Part with real Sketch geometry to build
(`_require_closed_sketch_feature` requires an actual extrudable profile),
so unlike test_stage_b2_graph.py's pure `transitive_dependents` tests, this
needs real pythonocc-core, same as every other test_stage*.py file that
imports app.main.

Same helper conventions (copy-pasted, not shared via conftest) as every
other test_stage*.py file in this directory - see test_stage_a1_multibody.py.
"""

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
    response = client.post(
        f"/document/parts/{part_id}/extrude-features",
        json={
            "sketch_feature_id": sketch_feature_id,
            "extrude_type": extrude_type,
            "start_distance": start_distance,
            "end_distance": end_distance,
            "target_body_ids": target_body_ids or [],
        },
    )
    assert response.status_code == 201
    return response.json()


def _get_bodies(part_id: str) -> list[dict]:
    response = client.get(f"/document/parts/{part_id}/mesh")
    assert response.status_code == 200
    return response.json()


def _remaining_feature_ids(part_id: str) -> list[str]:
    return [f["id"] for f in client.get(f"/document/parts/{part_id}/features").json()]


def test_deleting_a_sketch_feeding_two_independent_extrudes_removes_both():
    part = _create_part()
    sketch = _create_sketch_feature(part["id"])
    _add_square(sketch["sketch_id"], 0.0, 0.0, 10.0)
    boss_a = _create_extrude_feature(part["id"], sketch["id"])
    boss_b = _create_extrude_feature(part["id"], sketch["id"])

    response = client.delete(f"/document/parts/{part['id']}/features/{sketch['id']}/cascade")

    assert response.status_code == 200
    body = response.json()
    assert set(body["deleted_feature_ids"]) == {sketch["id"], boss_a["id"], boss_b["id"]}
    assert body["deleted_sketch_ids"] == [sketch["sketch_id"]]
    assert _remaining_feature_ids(part["id"]) == []

    # Recompute after the cascade delete must not error, and the (now
    # entirely empty) Part falls back to the placeholder box, not a crash.
    bodies = _get_bodies(part["id"])
    assert len(bodies) == 1
    assert bodies[0]["source"] == "placeholder"


def test_deleting_one_of_two_sibling_extrudes_off_a_shared_sketch_leaves_the_other_intact():
    part = _create_part()
    sketch = _create_sketch_feature(part["id"])
    _add_square(sketch["sketch_id"], 0.0, 0.0, 10.0)
    boss_a = _create_extrude_feature(part["id"], sketch["id"])
    boss_b = _create_extrude_feature(part["id"], sketch["id"])

    response = client.delete(f"/document/parts/{part['id']}/features/{boss_a['id']}/cascade")

    assert response.status_code == 200
    body = response.json()
    assert body["deleted_feature_ids"] == [boss_a["id"]]
    assert body["deleted_sketch_ids"] == []
    assert set(_remaining_feature_ids(part["id"])) == {sketch["id"], boss_b["id"]}

    # The surviving Sketch and sibling Boss recompute cleanly, with no
    # dangling reference to the deleted Extrude.
    bodies = _get_bodies(part["id"])
    assert {b["body_id"] for b in bodies} == {boss_b["id"]}


def test_deleting_a_leaf_feature_removes_only_itself():
    part = _create_part()
    sketch = _create_sketch_feature(part["id"])
    _add_square(sketch["sketch_id"], 0.0, 0.0, 10.0)
    boss = _create_extrude_feature(part["id"], sketch["id"])
    cut_sketch = _create_square_sketch_feature(part["id"], x0=2.0, y0=2.0, size=4.0)
    cut = _create_extrude_feature(
        part["id"], cut_sketch["id"], extrude_type="cut", target_body_ids=[boss["id"]]
    )

    response = client.delete(f"/document/parts/{part['id']}/features/{cut['id']}/cascade")

    assert response.status_code == 200
    body = response.json()
    assert body["deleted_feature_ids"] == [cut["id"]]
    assert set(_remaining_feature_ids(part["id"])) == {sketch["id"], boss["id"], cut_sketch["id"]}

    # Recompute is unaffected - the surviving Boss's body is untouched by
    # the deleted Cut ever having existed.
    bodies = _get_bodies(part["id"])
    assert {b["body_id"] for b in bodies} == {boss["id"]}


def test_deleting_an_upstream_boss_cascades_through_a_target_body_ids_chain():
    """A chain that reaches back via `target_body_ids` (A1's far-back
    dependency edges), not just `sketch_feature_id` - deleting the root Boss
    must cascade all the way through, not just to features naming it as
    their Sketch."""
    part = _create_part()
    sketch = _create_sketch_feature(part["id"])
    _add_square(sketch["sketch_id"], 0.0, 0.0, 10.0)
    root_boss = _create_extrude_feature(part["id"], sketch["id"])

    cut_sketch = _create_square_sketch_feature(part["id"], x0=2.0, y0=2.0, size=4.0)
    cut = _create_extrude_feature(
        part["id"], cut_sketch["id"], extrude_type="cut", target_body_ids=[root_boss["id"]]
    )

    later_sketch = _create_square_sketch_feature(part["id"], x0=20.0, y0=0.0, size=10.0)
    later_boss = _create_extrude_feature(
        part["id"], later_sketch["id"], target_body_ids=[root_boss["id"]]
    )

    response = client.delete(f"/document/parts/{part['id']}/features/{root_boss['id']}/cascade")

    assert response.status_code == 200
    body = response.json()
    assert set(body["deleted_feature_ids"]) == {root_boss["id"], cut["id"], later_boss["id"]}

    # The Sketches that fed the deleted Extrudes are independent Feature-
    # graph nodes in their own right and are untouched by this cascade -
    # only the SketchFeature actually targeted by the delete itself would
    # have its Sketch removed, and none of these Sketches were the target.
    assert set(_remaining_feature_ids(part["id"])) == {sketch["id"], cut_sketch["id"], later_sketch["id"]}

    bodies = _get_bodies(part["id"])
    assert bodies == []


def test_deleting_a_feature_with_no_dependents_leaves_an_unrelated_independent_branch_alone():
    """Two entirely independent Boss chains in the same Part - deleting one
    must never touch the other, mirroring test_stage_b2_graph.py's pure
    `test_unrelated_branches_are_untouched_by_each_others_cascade`, now
    proven against a real recompute."""
    part = _create_part()
    sketch_a = _create_sketch_feature(part["id"])
    _add_square(sketch_a["sketch_id"], 0.0, 0.0, 10.0)
    boss_a = _create_extrude_feature(part["id"], sketch_a["id"])

    sketch_b = _create_square_sketch_feature(part["id"], x0=20.0, y0=0.0, size=10.0)
    boss_b = _create_extrude_feature(part["id"], sketch_b["id"])

    response = client.delete(f"/document/parts/{part['id']}/features/{sketch_a['id']}/cascade")

    assert response.status_code == 200
    assert set(response.json()["deleted_feature_ids"]) == {sketch_a["id"], boss_a["id"]}
    assert set(_remaining_feature_ids(part["id"])) == {sketch_b["id"], boss_b["id"]}

    bodies = _get_bodies(part["id"])
    assert {b["body_id"] for b in bodies} == {boss_b["id"]}
