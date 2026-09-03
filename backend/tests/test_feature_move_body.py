"""Direct Editing family, third entry ("Move/Copy Body"): real-OCCT tests
for `MoveBodyFeature` - translates/rotates a single Body, via two
independent, sequential `BRepBuilderAPI_Transform` calls (see
`app.document.move_body`). Modifies its Body in place (keeps the same id)
when `make_copy=False` (default); mints a brand-new Body under this
Feature's own id when `make_copy=True`. Mirrors test_feature_scale_body.py's own
structure and helpers (copy-pasted, not shared via conftest, same as every
other test_feature_*.py file). Needs a real pythonocc-core environment (not
available in this repo's own dev sandbox - see docs/status.md's dated
entries for whether a real on-device/CI pass has actually run by the time
this is read).

Note on scope: this file deliberately does not assert exact post-rotation
bounding-box coordinates - which OCCT topology-enumeration index
corresponds to which physical edge of a box is implementation-defined, not
something derivable by hand without actually running pythonocc-core (unlike
the translate/scale cases, whose resulting geometry is simple, unambiguous
arithmetic). Rotation coverage here checks status codes, round-tripped
field values, and copy-vs-in-place id behaviour instead.
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


def _bbox_ranges(part_id: str, body_id: str) -> list[tuple[float, float]]:
    mesh = next(e for e in _mesh(part_id) if e["body_id"] == body_id)["mesh"]
    return [
        (min(v[axis] for v in mesh["vertices"]), max(v[axis] for v in mesh["vertices"])) for axis in range(3)
    ]


def _create_move_body(part_id: str, body_id: str, **kwargs):
    payload = {"body_id": body_id}
    payload.update(kwargs)
    return client.post(f"/document/parts/{part_id}/move-body-features", json=payload)


def _make_box(part_id: str, *, x0: float, y0: float = 0.0, size: float = 10.0) -> str:
    """Creates a Boss Extrude box, `size` x `size` in XY at (x0, y0), 0..10
    in Z, and returns its own new Body id."""
    before = set(_body_ids(part_id))
    sketch = _create_square_sketch_feature(part_id, x0=x0, y0=y0, size=size)
    _create_extrude_feature(part_id, sketch["id"])
    after = _body_ids(part_id)
    return next(bid for bid in after if bid not in before)


# --- Creation validation -------------------------------------------------------


def test_move_body_with_an_unknown_body_id_is_rejected():
    part = _create_part()

    response = _create_move_body(part["id"], "not-a-real-feature-id", delta=[1.0, 0.0, 0.0])

    assert response.status_code == 400


def test_move_body_with_a_malformed_rotation_axis_is_rejected():
    """`rotation_axis` with none of edge_ref/face_ref/sketch_line_ref set is
    rejected the same way Circular Pattern's own `axis` field is."""
    part = _create_part()
    body_id = _make_box(part["id"], x0=0.0)

    response = _create_move_body(part["id"], body_id, rotation_axis={}, rotation_angle_degrees=90.0)

    assert response.status_code == 422


# --- Translate geometry --------------------------------------------------------


def test_translating_a_box_by_a_delta_shifts_its_bounding_box():
    part = _create_part()
    body_id = _make_box(part["id"], x0=0.0)

    response = _create_move_body(part["id"], body_id, delta=[5.0, -2.0, 3.0])

    assert response.status_code == 201
    assert response.json()["type"] == "move_body"
    assert response.json()["body_id"] == body_id
    assert response.json()["delta"] == [5.0, -2.0, 3.0]
    assert response.json()["make_copy"] is False

    # Move modifies the Body in place - same id, no new Body minted.
    assert _body_ids(part["id"]) == [body_id]
    x_range, y_range, z_range = _bbox_ranges(part["id"], body_id)
    assert x_range == (5.0, 15.0)
    assert y_range == (-2.0, 8.0)
    assert z_range == (3.0, 13.0)


def test_a_zero_delta_and_no_rotation_leaves_the_box_unchanged():
    part = _create_part()
    body_id = _make_box(part["id"], x0=0.0)

    response = _create_move_body(part["id"], body_id)

    assert response.status_code == 201
    x_range, y_range, z_range = _bbox_ranges(part["id"], body_id)
    assert x_range == (0.0, 10.0)
    assert y_range == (0.0, 10.0)
    assert z_range == (0.0, 10.0)


def test_update_move_body_changes_the_delta():
    part = _create_part()
    body_id = _make_box(part["id"], x0=0.0)
    feature = _create_move_body(part["id"], body_id, delta=[1.0, 0.0, 0.0]).json()

    response = client.patch(
        f"/document/parts/{part['id']}/move-body-features/{feature['id']}",
        json={"delta": [0.0, 10.0, 0.0]},
    )

    assert response.status_code == 200
    x_range, y_range, z_range = _bbox_ranges(part["id"], body_id)
    assert x_range == (0.0, 10.0)
    assert y_range == (10.0, 20.0)
    assert z_range == (0.0, 10.0)


# --- Copy mode -----------------------------------------------------------------


def test_copy_mode_mints_a_new_body_and_leaves_the_original_untouched():
    part = _create_part()
    body_id = _make_box(part["id"], x0=0.0)

    response = _create_move_body(part["id"], body_id, delta=[20.0, 0.0, 0.0], make_copy=True)

    assert response.status_code == 201
    assert response.json()["make_copy"] is True

    body_ids = set(_body_ids(part["id"]))
    assert body_id in body_ids  # original untouched
    assert len(body_ids) == 2  # a new Body was minted alongside it
    original_x_range, _y, _z = _bbox_ranges(part["id"], body_id)
    assert original_x_range == (0.0, 10.0)


# --- Rotation (status/round-trip only - see this file's own top docstring) ----


def test_rotating_a_box_around_one_of_its_own_straight_edges_succeeds():
    part = _create_part()
    body_id = _make_box(part["id"], x0=0.0)

    response = _create_move_body(
        part["id"],
        body_id,
        rotation_axis={"edge_ref": {"body_id": body_id, "shape_type": "edge", "index": 0}},
        rotation_angle_degrees=90.0,
    )

    assert response.status_code == 201
    assert response.json()["rotation_angle_degrees"] == 90.0
    assert response.json()["rotation_axis"]["edge_ref"]["index"] == 0
    assert _body_ids(part["id"]) == [body_id]


# --- native_format round-trip -------------------------------------------------


def test_move_body_feature_round_trips_through_native_export_import():
    """Mirrors test_feature_scale_body.py's own identical native round-trip
    precedent - see that test's own docstring for the full save/restore-
    around-the-whole-test reasoning."""
    from app.document.store import get_document, replace_document
    from app.sketch.store import all_sketches, replace_all_sketches

    saved_document = get_document()
    saved_sketches = dict(all_sketches())
    try:
        part = _create_part()
        body_id = _make_box(part["id"], x0=0.0)
        move = _create_move_body(part["id"], body_id, delta=[1.0, 2.0, 3.0]).json()

        exported = client.get("/document/export/native")
        assert exported.status_code == 200

        imported = client.post("/document/import/native", json=exported.json())
        assert imported.status_code == 200

        features = client.get(f"/document/parts/{part['id']}/features").json()
        round_tripped = next(f for f in features if f["type"] == "move_body")
        assert round_tripped["body_id"] == move["body_id"] == body_id
        assert round_tripped["delta"] == move["delta"] == [1.0, 2.0, 3.0]
    finally:
        replace_document(saved_document)
        replace_all_sketches(saved_sketches)


# --- Cascade delete ------------------------------------------------------------


def test_deleting_a_moved_bodys_owning_extrude_cascade_deletes_the_move_feature():
    part = _create_part()
    body_id = _make_box(part["id"], x0=0.0)
    move = _create_move_body(part["id"], body_id, delta=[1.0, 0.0, 0.0]).json()

    response = client.delete(f"/document/parts/{part['id']}/features/{body_id}/cascade")

    assert response.status_code == 200
    assert set(response.json()["deleted_feature_ids"]) == {body_id, move["id"]}
