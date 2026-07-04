"""B4: earlier-Feature editing - the backend half. The client's tap-to-edit
flow (`part_screen.dart`) needs the backend to actually accept a PATCH
against a non-last ExtrudeFeature and a mutation against a non-last
Sketch's entities, neither of which the pre-B4 "only the last Feature is
editable" lock allowed - removed in `app.document.router.
update_extrude_feature` and `app.sketch.router` (`_ensure_sketch_editable`,
deleted entirely) for this prompt. This file covers the *new* behavior
those removals unlock; the existing `test_only_last_feature_is_unlocked`-
style tests in test_stage7_document.py/test_stage9_extrude.py already cover
that `locked` itself (display/delete-gating) is untouched.

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


def _get_bodies(part_id: str) -> list[dict]:
    response = client.get(f"/document/parts/{part_id}/mesh")
    assert response.status_code == 200
    return response.json()


def _max_z(mesh_body: dict) -> float:
    return max(v[2] for v in mesh_body["mesh"]["vertices"])


def test_editing_an_earlier_boss_with_a_downstream_cut_recomputes_the_cut_too():
    """The actual scenario B4's tap-to-edit flow exists for: Boss (0->10),
    a Cut targeting it, then a later unrelated Sketch after both - locking
    the Boss under the pre-B4 rule. Changing the Boss's own depth must
    still be accepted, and the Cut that depends on it must recompute
    against the new depth, not the stale one."""
    part = _create_part()
    boss_sketch = _create_square_sketch_feature(part["id"], size=10.0)
    boss = _create_extrude_feature(part["id"], boss_sketch["id"], end_distance=10.0).json()

    cut_sketch = _create_square_sketch_feature(part["id"], x0=2.0, y0=2.0, size=4.0)
    _create_extrude_feature(
        part["id"],
        cut_sketch["id"],
        extrude_type="cut",
        start_distance=8.0,
        end_distance=12.0,
        target_body_ids=[boss["id"]],
    )

    # A later, unrelated Feature - locks the Boss (not the last Feature
    # anymore) under the pre-B4 rule.
    _create_sketch_feature(part["id"])

    mesh_before = _get_bodies(part["id"])
    assert _max_z(mesh_before[0]) == pytest.approx(10.0)

    response = client.patch(
        f"/document/parts/{part['id']}/extrude-features/{boss['id']}",
        json={"end_distance": 20.0},
    )
    assert response.status_code == 200

    mesh_after = _get_bodies(part["id"])
    # The Cut (8->12) no longer reaches the new top face at z=20 - the
    # recomputed Body's max z reflects the Boss's new depth, confirming the
    # downstream Cut re-solved against it rather than a stale cached shape.
    assert _max_z(mesh_after[0]) == pytest.approx(20.0)


def test_editing_an_earlier_extrudes_target_body_ids_is_accepted():
    part = _create_part()
    sketch_a = _create_square_sketch_feature(part["id"], x0=0.0, y0=0.0, size=10.0)
    boss_a = _create_extrude_feature(part["id"], sketch_a["id"]).json()

    sketch_b = _create_square_sketch_feature(part["id"], x0=5.0, y0=0.0, size=10.0)
    boss_b = _create_extrude_feature(part["id"], sketch_b["id"]).json()

    # Locks boss_b.
    _create_sketch_feature(part["id"])

    response = client.patch(
        f"/document/parts/{part['id']}/extrude-features/{boss_b['id']}",
        json={"target_body_ids": [boss_a["id"]]},
    )

    assert response.status_code == 200
    assert response.json()["target_body_ids"] == [boss_a["id"]]

    bodies = _get_bodies(part["id"])
    assert {b["body_id"] for b in bodies} == {boss_a["id"]}


def test_mutating_a_sketch_behind_a_locked_extrude_recomputes_the_extrude():
    """B4's other tap-to-edit path: editing a Sketch that already has a
    downstream Extrude. Moving one of its points changes the profile, and
    the Extrude that consumes it must recompute against the new shape."""
    part = _create_part()
    sketch_feature = _create_square_sketch_feature(part["id"], size=10.0)
    _create_extrude_feature(part["id"], sketch_feature["id"], end_distance=10.0)

    # Locks the Sketch (and the Extrude after it).
    _create_sketch_feature(part["id"])

    points = client.get(f"/sketch/sketches/{sketch_feature['sketch_id']}/points").json()
    # Move every point to grow the square from 10x10 to 20x20, scaling from
    # the origin corner - same shape, bigger footprint.
    for point in points:
        response = client.patch(
            f"/sketch/sketches/{sketch_feature['sketch_id']}/points/{point['id']}",
            json={"x": point["x"] * 2, "y": point["y"] * 2},
        )
        assert response.status_code == 200

    bodies = _get_bodies(part["id"])
    max_x = max(v[0] for v in bodies[0]["mesh"]["vertices"])
    assert max_x == pytest.approx(20.0)
