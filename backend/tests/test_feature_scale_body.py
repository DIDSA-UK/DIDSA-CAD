"""Direct Editing family, second entry: real-OCCT tests for
`ScaleBodyFeature` - uniformly scales a single Body by `factor` about its
own current bounding-box centre, via OCCT `gp_Trsf.SetScale` +
`BRepBuilderAPI_Transform` (see `app.document.scale_body`). Modifies its
Body in place (keeps the same id), mirroring Fillet/Chamfer's own in-place-
modify pattern. Mirrors test_feature_delete_body.py's/test_stage_q_merge.py's
own structure and helpers (copy-pasted, not shared via conftest, same as
every other test_feature_*.py file). Needs a real pythonocc-core environment
(not available in this repo's own dev sandbox - see docs/status.md's dated
entries for whether a real on-device/CI pass has actually run by the time
this is read).
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


def _create_scale_body(part_id: str, body_id: str, factor: float):
    return client.post(
        f"/document/parts/{part_id}/scale-body-features",
        json={"body_id": body_id, "factor": factor},
    )


def _make_box(part_id: str, *, x0: float, y0: float = 0.0, size: float = 10.0) -> str:
    """Creates a Boss Extrude box, `size` x `size` in XY at (x0, y0), 0..10
    in Z, and returns its own new Body id."""
    before = set(_body_ids(part_id))
    sketch = _create_square_sketch_feature(part_id, x0=x0, y0=y0, size=size)
    _create_extrude_feature(part_id, sketch["id"])
    after = _body_ids(part_id)
    return next(bid for bid in after if bid not in before)


# --- Creation validation -------------------------------------------------------


def test_scale_body_with_zero_factor_is_rejected():
    part = _create_part()
    body_id = _make_box(part["id"], x0=0.0)

    response = _create_scale_body(part["id"], body_id, 0.0)

    assert response.status_code == 422


def test_scale_body_with_negative_factor_is_rejected():
    part = _create_part()
    body_id = _make_box(part["id"], x0=0.0)

    response = _create_scale_body(part["id"], body_id, -2.0)

    assert response.status_code == 422


def test_scale_body_with_an_unknown_body_id_is_rejected():
    part = _create_part()

    response = _create_scale_body(part["id"], "not-a-real-feature-id", 2.0)

    assert response.status_code == 400


# --- Scale geometry ----------------------------------------------------------


def test_scaling_a_box_by_two_doubles_its_extent_about_its_own_centre():
    """A 10x10x10 box centred at (5,5,5), scaled by 2, spans -5..15 on
    every axis - the box's own bounding-box centre stays fixed, only its
    extent doubles."""
    part = _create_part()
    body_id = _make_box(part["id"], x0=0.0)

    response = _create_scale_body(part["id"], body_id, 2.0)

    assert response.status_code == 201
    assert response.json()["type"] == "scale_body"
    assert response.json()["body_id"] == body_id
    assert response.json()["factor"] == 2.0

    # Scale modifies the Body in place - same id, no new Body minted.
    assert _body_ids(part["id"]) == [body_id]
    for axis_range in _bbox_ranges(part["id"], body_id):
        assert axis_range == (-5.0, 15.0)


def test_scaling_a_box_by_half_shrinks_its_extent_about_its_own_centre():
    part = _create_part()
    body_id = _make_box(part["id"], x0=0.0)

    response = _create_scale_body(part["id"], body_id, 0.5)

    assert response.status_code == 201
    for axis_range in _bbox_ranges(part["id"], body_id):
        assert axis_range == (2.5, 7.5)


def test_update_scale_body_changes_the_factor():
    part = _create_part()
    body_id = _make_box(part["id"], x0=0.0)
    feature = _create_scale_body(part["id"], body_id, 2.0).json()

    response = client.patch(
        f"/document/parts/{part['id']}/scale-body-features/{feature['id']}",
        json={"factor": 3.0},
    )

    assert response.status_code == 200
    assert response.json()["factor"] == 3.0
    for axis_range in _bbox_ranges(part["id"], body_id):
        assert axis_range == (-10.0, 20.0)


# --- native_format round-trip -------------------------------------------------


def test_scale_body_feature_round_trips_through_native_export_import():
    """Mirrors test_feature_delete_body.py's own identical native round-trip
    precedent - see that test's own docstring for the full save/restore-
    around-the-whole-test reasoning."""
    from app.document.store import get_document, replace_document
    from app.sketch.store import all_sketches, replace_all_sketches

    saved_document = get_document()
    saved_sketches = dict(all_sketches())
    try:
        part = _create_part()
        body_id = _make_box(part["id"], x0=0.0)
        scale = _create_scale_body(part["id"], body_id, 1.5).json()

        exported = client.get("/document/export/native")
        assert exported.status_code == 200

        imported = client.post("/document/import/native", json=exported.json())
        assert imported.status_code == 200

        features = client.get(f"/document/parts/{part['id']}/features").json()
        round_tripped = next(f for f in features if f["type"] == "scale_body")
        assert round_tripped["body_id"] == scale["body_id"] == body_id
        assert round_tripped["factor"] == scale["factor"] == 1.5
    finally:
        replace_document(saved_document)
        replace_all_sketches(saved_sketches)


# --- Cascade delete ------------------------------------------------------------


def test_deleting_a_scaled_bodys_owning_extrude_cascade_deletes_the_scale_feature():
    part = _create_part()
    body_id = _make_box(part["id"], x0=0.0)
    scale = _create_scale_body(part["id"], body_id, 2.0).json()

    response = client.delete(f"/document/parts/{part['id']}/features/{body_id}/cascade")

    assert response.status_code == 200
    assert set(response.json()["deleted_feature_ids"]) == {body_id, scale["id"]}
