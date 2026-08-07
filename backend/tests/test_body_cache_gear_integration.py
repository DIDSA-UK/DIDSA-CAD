"""Real-OCCT proof that `app.document.body_cache`'s checkpoint-chain cache
delivers what it was actually built for (herringbone/complex-gear timeout
investigation): once a Part contains an expensive helical/herringbone
`GearFeature`, adding an unrelated Feature afterward must not rebuild the
Gear's own solid again. `test_body_cache.py` already covers the caching
*logic* in isolation with a fake `apply_step`; this file instead drives the
real `app.document.extrude.compute_part_bodies` (via the real HTTP router,
same as every other real-OCCT gear test) and asserts on Python object
identity of the returned `TopoDS_Shape` - the only way to actually prove
"not rebuilt" rather than merely "produced an equal-looking result"."""

from fastapi.testclient import TestClient

from app.document.extrude import compute_part_bodies
from app.document.store import get_part_or_404
from app.main import app
from tests.conftest import TEST_API_KEY

client = TestClient(app)
client.headers.update({"X-API-Key": TEST_API_KEY})


def _create_part(name: str = "Part 1") -> dict:
    response = client.post("/document/parts", json={"name": name})
    assert response.status_code == 201
    return response.json()


def _create_herringbone_gear(part_id: str) -> dict:
    response = client.post(
        f"/document/parts/{part_id}/gear-features",
        json={
            "gear_type": "boss",
            "is_internal": False,
            "module": 2.0,
            "tooth_count": 16,
            "face_width": 20.0,
            "helix_angle_degrees": 18.0,
            "herringbone": True,
        },
    )
    assert response.status_code == 201, response.json()
    return response.json()


def _create_independent_box_sketch_and_extrude(part_id: str) -> dict:
    """A brand-new Body with no relationship at all to the Gear - the
    "add an unrelated Extrude cut after the gear already exists" scenario
    from the on-device report, minus the "cut" (a Boss is enough to prove
    the caching behaviour; Cut's own OCCT boolean op isn't what's under
    test here)."""
    sketch_feature_response = client.post(
        f"/document/parts/{part_id}/features/sketch", json={"plane": "XY"}
    )
    assert sketch_feature_response.status_code == 201, sketch_feature_response.json()
    sketch_feature_id = sketch_feature_response.json()["id"]
    sketch_id = sketch_feature_response.json()["sketch_id"]

    p1 = client.post(f"/sketch/sketches/{sketch_id}/points", json={"x": 100.0, "y": 100.0}).json()
    p2 = client.post(f"/sketch/sketches/{sketch_id}/points", json={"x": 110.0, "y": 100.0}).json()
    p3 = client.post(f"/sketch/sketches/{sketch_id}/points", json={"x": 110.0, "y": 110.0}).json()
    p4 = client.post(f"/sketch/sketches/{sketch_id}/points", json={"x": 100.0, "y": 110.0}).json()
    for a, b in [(p1, p2), (p2, p3), (p3, p4), (p4, p1)]:
        line_response = client.post(
            f"/sketch/sketches/{sketch_id}/lines",
            json={"start_point_id": a["id"], "end_point_id": b["id"]},
        )
        assert line_response.status_code == 201, line_response.json()

    extrude_response = client.post(
        f"/document/parts/{part_id}/extrude-features",
        json={
            "sketch_feature_id": sketch_feature_id,
            "extrude_type": "boss",
            "start_distance": 0.0,
            "end_distance": 5.0,
        },
    )
    assert extrude_response.status_code == 201, extrude_response.json()
    return extrude_response.json()


def test_adding_an_unrelated_feature_does_not_rebuild_the_herringbone_gear():
    part_dto = _create_part("Cache integration test")
    gear = _create_herringbone_gear(part_dto["id"])
    part = get_part_or_404(part_dto["id"])

    bodies_before = compute_part_bodies(part)
    assert gear["id"] in bodies_before
    gear_shape_before = bodies_before[gear["id"]]

    extrude = _create_independent_box_sketch_and_extrude(part_dto["id"])

    bodies_after = compute_part_bodies(part)
    assert extrude["id"] in bodies_after
    assert bodies_after[gear["id"]] is gear_shape_before, (
        "the gear's own TopoDS_Shape must be the exact same Python object as before - "
        "a fresh object here means the cache rebuilt it unnecessarily"
    )


def test_editing_the_gear_itself_does_rebuild_it():
    """The correctness counterpart to the test above - a real change to the
    Gear itself must still invalidate its own cached Body, not silently
    keep serving the old geometry forever."""
    part_dto = _create_part("Cache invalidation test")
    gear = _create_herringbone_gear(part_dto["id"])
    part = get_part_or_404(part_dto["id"])

    bodies_before = compute_part_bodies(part)
    gear_shape_before = bodies_before[gear["id"]]

    update_response = client.patch(
        f"/document/parts/{part_dto['id']}/gear-features/{gear['id']}",
        json={"tooth_count": 18},
    )
    assert update_response.status_code == 200, update_response.json()

    bodies_after = compute_part_bodies(part)
    assert bodies_after[gear["id"]] is not gear_shape_before


def test_repeated_identical_calls_return_the_exact_same_shape_object():
    part_dto = _create_part("Cache identical-call test")
    gear = _create_herringbone_gear(part_dto["id"])
    part = get_part_or_404(part_dto["id"])

    first = compute_part_bodies(part)
    second = compute_part_bodies(part)
    assert second[gear["id"]] is first[gear["id"]]
