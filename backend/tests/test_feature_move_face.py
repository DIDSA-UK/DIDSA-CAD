"""Direct Editing family, fifth/last entry: real-OCCT tests for
`MoveFaceFeature` - moves a single planar face along its own normal, an
explicit delta, or a picked edge's direction, via extrude-the-face-profile
+ Fuse/Cut (see `app.document.move_face`). Modifies its Body in place
(keeps the same id). Mirrors test_feature_delete_face.py's own structure
and helpers (copy-pasted, not shared via conftest, same as every other
test_feature_*.py file). Needs a real pythonocc-core environment (not
available in this repo's own dev sandbox - see docs/status.md's dated
entries for whether a real on-device/CI pass has actually run by the time
this is read).

Note on face/edge indices: every index used below was confirmed empirically
against the real backend (not assumed) - a box's own `topexp.MapShapes`
enumeration order is implementation-defined, and (for edges) only 4 of a
box's 12 edges run parallel to any given face's own normal (the other 8 are
correctly rejected by `move_face.py`'s own degenerate-direction check) - see
this module's own module docstring for why guessing these by hand isn't
safe.
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


def _mesh_for_body(part_id: str, body_id: str) -> dict:
    return next(e["mesh"] for e in _mesh(part_id) if e["body_id"] == body_id)


def _bbox_ranges(part_id: str, body_id: str) -> list[tuple[float, float]]:
    mesh = _mesh_for_body(part_id, body_id)
    return [
        (min(v[axis] for v in mesh["vertices"]), max(v[axis] for v in mesh["vertices"])) for axis in range(3)
    ]


def _edge_ref(body_id: str, index: int) -> dict:
    return {"body_id": body_id, "shape_type": "edge", "index": index}


def _face_ref(body_id: str, index: int) -> dict:
    return {"body_id": body_id, "shape_type": "face", "index": index}


def _create_move_face(part_id: str, face_ref: dict, **kwargs):
    payload = {"face_ref": face_ref}
    payload.update(kwargs)
    return client.post(f"/document/parts/{part_id}/move-face-features", json=payload)


def _make_box(part_id: str, *, x0: float, y0: float = 0.0, size: float = 10.0) -> str:
    """Creates a Boss Extrude box, `size` x `size` in XY at (x0, y0), 0..10
    in Z, and returns its own new Body id. Face index 1 is confirmed (see
    this file's own module docstring) to be the x=10 face, outward normal
    +X."""
    before = set(_body_ids(part_id))
    sketch = _create_square_sketch_feature(part_id, x0=x0, y0=y0, size=size)
    _create_extrude_feature(part_id, sketch["id"])
    after = _body_ids(part_id)
    return next(bid for bid in after if bid not in before)


# --- Creation validation -------------------------------------------------------


def test_move_face_with_a_non_face_ref_is_rejected():
    part = _create_part()
    body_id = _make_box(part["id"], x0=0.0)

    response = _create_move_face(part["id"], _edge_ref(body_id, 0), offset_distance=3.0)

    assert response.status_code == 422


def test_move_face_with_no_mode_set_is_rejected():
    part = _create_part()
    body_id = _make_box(part["id"], x0=0.0)

    response = _create_move_face(part["id"], _face_ref(body_id, 1))

    assert response.status_code == 422


def test_move_face_with_two_modes_set_is_rejected():
    part = _create_part()
    body_id = _make_box(part["id"], x0=0.0)

    response = _create_move_face(
        part["id"], _face_ref(body_id, 1), offset_distance=3.0, delta=[1.0, 0.0, 0.0]
    )

    assert response.status_code == 422


def test_move_face_with_zero_offset_is_rejected():
    part = _create_part()
    body_id = _make_box(part["id"], x0=0.0)

    response = _create_move_face(part["id"], _face_ref(body_id, 1), offset_distance=0.0)

    assert response.status_code == 422


def test_move_face_with_direction_ref_but_no_direction_distance_is_rejected():
    part = _create_part()
    body_id = _make_box(part["id"], x0=0.0)

    response = _create_move_face(
        part["id"], _face_ref(body_id, 1), direction_ref={"edge_ref": _edge_ref(body_id, 2)}
    )

    assert response.status_code == 422


# --- Offset mode ---------------------------------------------------------------


def test_offset_mode_outward_extends_the_bounding_box():
    part = _create_part()
    body_id = _make_box(part["id"], x0=0.0)

    response = _create_move_face(part["id"], _face_ref(body_id, 1), offset_distance=3.0)

    assert response.status_code == 201
    assert response.json()["type"] == "move_face"
    assert _body_ids(part["id"]) == [body_id]  # modifies in place, same id
    x_range, y_range, z_range = _bbox_ranges(part["id"], body_id)
    assert x_range == (0.0, 13.0)
    assert y_range == (0.0, 10.0)
    assert z_range == (0.0, 10.0)


def test_offset_mode_inward_shrinks_the_bounding_box():
    part = _create_part()
    body_id = _make_box(part["id"], x0=0.0)

    response = _create_move_face(part["id"], _face_ref(body_id, 1), offset_distance=-3.0)

    assert response.status_code == 201
    x_range, _y, _z = _bbox_ranges(part["id"], body_id)
    assert x_range == (0.0, 7.0)


def test_offset_mode_overshoot_past_the_bodys_own_extent_is_rejected():
    """Pushing a face inward by more than the Body's own extent in that
    direction has no valid result (an empty/negative-volume shape) - fails
    closed rather than producing a degenerate Body."""
    part = _create_part()
    body_id = _make_box(part["id"], x0=0.0)

    response = _create_move_face(part["id"], _face_ref(body_id, 1), offset_distance=-15.0)

    assert response.status_code == 422
    assert response.json()["detail"]["type"] == "move_face_failed"


# --- Delta mode ------------------------------------------------------------


def test_delta_mode_along_the_faces_own_normal():
    part = _create_part()
    body_id = _make_box(part["id"], x0=0.0)

    response = _create_move_face(part["id"], _face_ref(body_id, 1), delta=[3.0, 0.0, 0.0])

    assert response.status_code == 201
    assert response.json()["delta"] == [3.0, 0.0, 0.0]
    x_range, _y, _z = _bbox_ranges(part["id"], body_id)
    assert x_range == (0.0, 13.0)


# --- Direction mode --------------------------------------------------------


def test_direction_mode_along_a_parallel_edge():
    part = _create_part()
    body_id = _make_box(part["id"], x0=0.0)

    response = _create_move_face(
        part["id"],
        _face_ref(body_id, 1),
        direction_ref={"edge_ref": _edge_ref(body_id, 2)},
        direction_distance=3.0,
    )

    assert response.status_code == 201
    x_range, _y, _z = _bbox_ranges(part["id"], body_id)
    assert x_range == (0.0, 13.0)


def test_direction_mode_along_a_perpendicular_edge_is_rejected():
    """Edge 0 runs perpendicular to face 1's own normal (confirmed - see
    this file's own module docstring) - no meaningful perpendicular
    movement for this technique to act on, fails closed."""
    part = _create_part()
    body_id = _make_box(part["id"], x0=0.0)

    response = _create_move_face(
        part["id"],
        _face_ref(body_id, 1),
        direction_ref={"edge_ref": _edge_ref(body_id, 0)},
        direction_distance=3.0,
    )

    assert response.status_code == 422
    assert response.json()["detail"]["type"] == "move_face_failed"


# --- Update: mode switching ------------------------------------------------


def test_update_move_face_switches_from_offset_to_delta_mode():
    """Updating with a different mode's field must clear the previous
    mode's own field(s), not merge both - see `MoveFaceFeatureUpdate`'s own
    docstring."""
    part = _create_part()
    body_id = _make_box(part["id"], x0=0.0)
    feature = _create_move_face(part["id"], _face_ref(body_id, 1), offset_distance=3.0).json()
    assert feature["offset_distance"] == 3.0

    response = client.patch(
        f"/document/parts/{part['id']}/move-face-features/{feature['id']}",
        json={"delta": [5.0, 0.0, 0.0]},
    )

    assert response.status_code == 200
    assert response.json()["offset_distance"] is None
    assert response.json()["delta"] == [5.0, 0.0, 0.0]
    x_range, _y, _z = _bbox_ranges(part["id"], body_id)
    assert x_range == (0.0, 15.0)


# --- native_format round-trip -------------------------------------------------


def test_move_face_feature_round_trips_through_native_export_import():
    """Mirrors test_feature_delete_face.py's own identical native round-trip
    precedent - see that test's own docstring for the full save/restore-
    around-the-whole-test reasoning."""
    from app.document.store import get_document, replace_document
    from app.sketch.store import all_sketches, replace_all_sketches

    saved_document = get_document()
    saved_sketches = dict(all_sketches())
    try:
        part = _create_part()
        body_id = _make_box(part["id"], x0=0.0)
        move_face = _create_move_face(part["id"], _face_ref(body_id, 1), offset_distance=3.0).json()

        exported = client.get("/document/export/native")
        assert exported.status_code == 200

        imported = client.post("/document/import/native", json=exported.json())
        assert imported.status_code == 200

        features = client.get(f"/document/parts/{part['id']}/features").json()
        round_tripped = next(f for f in features if f["type"] == "move_face")
        assert round_tripped["face_ref"] == move_face["face_ref"]
        assert round_tripped["offset_distance"] == move_face["offset_distance"] == 3.0
    finally:
        replace_document(saved_document)
        replace_all_sketches(saved_sketches)


# --- Cascade delete ------------------------------------------------------------


def test_deleting_a_faces_owning_extrude_cascade_deletes_the_move_face_feature():
    part = _create_part()
    body_id = _make_box(part["id"], x0=0.0)
    move_face = _create_move_face(part["id"], _face_ref(body_id, 1), offset_distance=3.0).json()

    response = client.delete(f"/document/parts/{part['id']}/features/{body_id}/cascade")

    assert response.status_code == 200
    assert move_face["id"] in response.json()["deleted_feature_ids"]
