"""Direct Editing family, first entry: real-OCCT tests for `DeleteBodyFeature`
- removes every currently-existing `body_ids` entry from a Part's Bodies
entirely, via `app.document.delete_body.apply_delete_body_to_bodies`'s plain
`bodies.pop(...)` loop (no OCCT geometry of its own to construct or fail).
Mirrors test_stage_q_merge.py's own structure and helpers (copy-pasted, not
shared via conftest, same as every other test_stage*.py/test_feature_*.py
file). Needs a real pythonocc-core environment (not available in this repo's
own dev sandbox - see docs/status.md's dated entries for whether a real
on-device/CI pass has actually run by the time this is read).
"""

from fastapi.testclient import TestClient

from app.main import app
from tests.conftest import TEST_API_KEY

client = TestClient(app)
client.headers.update({"X-API-Key": TEST_API_KEY})


# --- Helpers -----------------------------------------------------------------


def _create_part(name: str = "Part 1") -> dict:
    response = client.post("/document/parts", json={"name": name})
    assert response.status_code == 201
    return response.json()


def _create_sketch_feature(part_id: str, plane: str = "XY") -> dict:
    response = client.post(f"/document/parts/{part_id}/features/sketch", json={"plane": plane})
    assert response.status_code == 201
    return response.json()


def _add_point(sketch_id: str, x: float, y: float) -> dict:
    response = client.post(f"/sketch/sketches/{sketch_id}/points", json={"x": x, "y": y})
    assert response.status_code == 201
    return response.json()


def _add_line(sketch_id: str, start_point_id: str, end_point_id: str) -> dict:
    response = client.post(
        f"/sketch/sketches/{sketch_id}/lines",
        json={"start_point_id": start_point_id, "end_point_id": end_point_id},
    )
    assert response.status_code == 201
    return response.json()


def _add_square(sketch_id: str, x0: float, y0: float, size: float) -> None:
    corners = [
        _add_point(sketch_id, x, y)
        for x, y in [(x0, y0), (x0 + size, y0), (x0 + size, y0 + size), (x0, y0 + size)]
    ]
    for a, b in zip(corners, corners[1:] + corners[:1]):
        _add_line(sketch_id, a["id"], b["id"])


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
) -> dict:
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


def _mesh(part_id: str) -> list[dict]:
    return client.get(f"/document/parts/{part_id}/mesh").json()


def _body_ids(part_id: str) -> list[str]:
    return [entry["body_id"] for entry in _mesh(part_id)]


def _remaining_feature_ids(part_id: str) -> list[str]:
    return [f["id"] for f in client.get(f"/document/parts/{part_id}/features").json()]


def _create_delete_body(part_id: str, body_ids: list[str]):
    return client.post(f"/document/parts/{part_id}/delete-body-features", json={"body_ids": body_ids})


def _make_box(part_id: str, *, x0: float, y0: float = 0.0, size: float = 10.0) -> str:
    """Creates a Boss Extrude box, `size` x `size` in XY at (x0, y0), 0..10
    in Z, and returns its own new Body id."""
    before = set(_body_ids(part_id))
    sketch = _create_square_sketch_feature(part_id, x0=x0, y0=y0, size=size)
    _create_extrude_feature(part_id, sketch["id"])
    after = _body_ids(part_id)
    return next(bid for bid in after if bid not in before)


# --- Creation validation -------------------------------------------------------


def test_delete_body_with_zero_body_ids_is_rejected():
    part = _create_part()

    response = _create_delete_body(part["id"], [])

    assert response.status_code == 422


def test_delete_body_with_an_unknown_body_id_is_rejected():
    part = _create_part()

    response = _create_delete_body(part["id"], ["not-a-real-feature-id"])

    assert response.status_code == 400


def test_delete_body_accepts_a_single_body_id():
    """Unlike Merge's 2+ floor, deleting exactly one Body is the common
    case."""
    part = _create_part()
    body_id = _make_box(part["id"], x0=0.0)

    response = _create_delete_body(part["id"], [body_id])

    assert response.status_code == 201
    assert response.json()["type"] == "delete_body"
    assert response.json()["body_ids"] == [body_id]


# --- Deletion behavior -------------------------------------------------------


def test_deleting_one_of_two_bodies_leaves_the_other_untouched():
    part = _create_part()
    body_id_a = _make_box(part["id"], x0=0.0)
    body_id_b = _make_box(part["id"], x0=100.0)

    response = _create_delete_body(part["id"], [body_id_a])

    assert response.status_code == 201
    body_ids = _body_ids(part["id"])
    assert body_ids == [body_id_b]


def test_deleting_multiple_bodies_at_once():
    part = _create_part()
    body_id_a = _make_box(part["id"], x0=0.0)
    body_id_b = _make_box(part["id"], x0=100.0)
    body_id_c = _make_box(part["id"], x0=200.0)

    response = _create_delete_body(part["id"], [body_id_a, body_id_c])

    assert response.status_code == 201
    assert _body_ids(part["id"]) == [body_id_b]


def test_update_delete_body_changes_which_bodies_are_removed():
    part = _create_part()
    body_id_a = _make_box(part["id"], x0=0.0)
    body_id_b = _make_box(part["id"], x0=100.0)
    feature = _create_delete_body(part["id"], [body_id_a]).json()

    response = client.patch(
        f"/document/parts/{part['id']}/delete-body-features/{feature['id']}",
        json={"body_ids": [body_id_b]},
    )

    assert response.status_code == 200
    body_ids = _body_ids(part["id"])
    assert body_ids == [body_id_a]


# --- native_format round-trip -------------------------------------------------


def test_delete_body_feature_round_trips_through_native_export_import():
    """Mirrors test_stage_q_merge.py's own identical native round-trip
    precedent - see that test's own docstring for the full save/restore-
    around-the-whole-test reasoning."""
    from app.document.store import get_document, replace_document
    from app.sketch.store import all_sketches, replace_all_sketches

    saved_document = get_document()
    saved_sketches = dict(all_sketches())
    try:
        part = _create_part()
        body_id = _make_box(part["id"], x0=0.0)
        _make_box(part["id"], x0=100.0)
        delete_body = _create_delete_body(part["id"], [body_id]).json()

        exported = client.get("/document/export/native")
        assert exported.status_code == 200

        imported = client.post("/document/import/native", json=exported.json())
        assert imported.status_code == 200

        features = client.get(f"/document/parts/{part['id']}/features").json()
        round_tripped = next(f for f in features if f["type"] == "delete_body")
        assert round_tripped["body_ids"] == delete_body["body_ids"] == [body_id]
    finally:
        replace_document(saved_document)
        replace_all_sketches(saved_sketches)


# --- Cascade delete ------------------------------------------------------------


def test_deleting_a_body_deleting_extrude_cascade_deletes_the_delete_body_feature():
    """Deleting the Extrude that created the Body a DeleteBodyFeature
    targets must cascade-delete the DeleteBodyFeature too - it would
    otherwise be left trying to remove a Body that no longer exists."""
    part = _create_part()
    body_id = _make_box(part["id"], x0=0.0)
    delete_body = _create_delete_body(part["id"], [body_id]).json()

    response = client.delete(f"/document/parts/{part['id']}/features/{body_id}/cascade")

    assert response.status_code == 200
    assert set(response.json()["deleted_feature_ids"]) == {body_id, delete_body["id"]}
    remaining = _remaining_feature_ids(part["id"])
    assert delete_body["id"] not in remaining
    assert body_id not in remaining
