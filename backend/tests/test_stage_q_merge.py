"""Boolean family, first entry: real-OCCT tests for `MergeFeature` - fuses
2+ named Bodies into a single Body via `BRepAlgoAPI_Fuse`, reusing
`app.document.extrude._fuse_realized_instances` (see that function's and
`MergeFeature`'s own docstrings). Symmetric, no target/tool distinction, no
options - every input Body is always consumed into the result. Mirrors
test_stage_m_merge.py's/test_surface.py's own structure and helpers (copy-
pasted, not shared via conftest, same as every other test_stage*.py file).
Needs a real pythonocc-core environment (not available in this repo's own
dev sandbox - see docs/status.md's dated entries for whether a real
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


def _first_body_id(part_id: str) -> str:
    mesh = _mesh(part_id)
    assert len(mesh) >= 1
    return mesh[0]["body_id"]


def _bbox_ranges(part_id: str, body_id: str) -> list[tuple[float, float]]:
    mesh = next(e for e in _mesh(part_id) if e["body_id"] == body_id)["mesh"]
    return [
        (min(v[axis] for v in mesh["vertices"]), max(v[axis] for v in mesh["vertices"])) for axis in range(3)
    ]


def _remaining_feature_ids(part_id: str) -> list[str]:
    return [f["id"] for f in client.get(f"/document/parts/{part_id}/features").json()]


def _create_merge(part_id: str, body_ids: list[str]):
    return client.post(f"/document/parts/{part_id}/merge-features", json={"body_ids": body_ids})


def _make_box(part_id: str, *, x0: float, y0: float = 0.0, size: float = 10.0) -> str:
    """Creates a Boss Extrude box, `size` x `size` in XY at (x0, y0), 0..10
    in Z, and returns its own new Body id."""
    before = set(_body_ids(part_id))
    sketch = _create_square_sketch_feature(part_id, x0=x0, y0=y0, size=size)
    _create_extrude_feature(part_id, sketch["id"])
    after = _body_ids(part_id)
    return next(bid for bid in after if bid not in before)


# --- Creation validation -------------------------------------------------------


def test_merge_requires_at_least_two_body_ids():
    part = _create_part()
    body_id = _make_box(part["id"], x0=0.0)

    response = _create_merge(part["id"], [body_id])

    assert response.status_code == 422


def test_merge_with_zero_body_ids_is_rejected():
    part = _create_part()

    response = _create_merge(part["id"], [])

    assert response.status_code == 422


def test_merge_with_an_unknown_body_id_is_rejected():
    part = _create_part()
    body_id = _make_box(part["id"], x0=0.0)

    response = _create_merge(part["id"], [body_id, "not-a-real-feature-id"])

    assert response.status_code == 400


# --- Fuse geometry ---------------------------------------------------------


def test_merging_two_touching_bodies_produces_a_single_body():
    """Two boxes ([0,10] and [10,20] in x, touching at x=10) merged together
    - a single connected solid spanning the full [0, 20] range once fused."""
    part = _create_part()
    body_id_a = _make_box(part["id"], x0=0.0)
    body_id_b = _make_box(part["id"], x0=10.0)

    response = _create_merge(part["id"], [body_id_a, body_id_b])

    assert response.status_code == 201
    assert response.json()["type"] == "merge"
    assert response.json()["body_ids"] == [body_id_a, body_id_b]

    body_ids = _body_ids(part["id"])
    assert body_ids == [body_id_a]  # survivor = the earlier-created input
    x_range, _y, _z = _bbox_ranges(part["id"], body_id_a)
    assert x_range == (0.0, 20.0)


def test_merging_three_bodies_produces_a_single_body():
    part = _create_part()
    body_id_a = _make_box(part["id"], x0=0.0)
    body_id_b = _make_box(part["id"], x0=10.0)
    body_id_c = _make_box(part["id"], x0=20.0)

    response = _create_merge(part["id"], [body_id_a, body_id_b, body_id_c])

    assert response.status_code == 201
    body_ids = _body_ids(part["id"])
    assert body_ids == [body_id_a]
    x_range, _y, _z = _bbox_ranges(part["id"], body_id_a)
    assert x_range == (0.0, 30.0)


def test_merging_disconnected_bodies_still_splits_into_separate_bodies():
    """Boxes at x=0 and x=100 - no overlap at all. `_fuse_realized_
    instances`'s own `_register_solids` call must still split this into two
    separate Bodies, not silently merge or drop one."""
    part = _create_part()
    body_id_a = _make_box(part["id"], x0=0.0)
    body_id_b = _make_box(part["id"], x0=100.0)

    response = _create_merge(part["id"], [body_id_a, body_id_b])

    assert response.status_code == 201
    body_ids = _body_ids(part["id"])
    assert len(body_ids) == 2
    assert all(bid == body_id_a or bid.startswith(f"{body_id_a}#") for bid in body_ids)
    ranges = {_bbox_ranges(part["id"], bid)[0] for bid in body_ids}
    assert ranges == {(0.0, 10.0), (100.0, 110.0)}


def test_merge_survivor_id_is_the_earliest_created_input_regardless_of_order():
    """Passing body_ids in reverse creation order still keeps `body_id_a`
    (the earliest-created input, per `_fuse_realized_instances`'s own
    `feature_index` tie-break) as the survivor - not `body_id_c`, not a
    brand-new id."""
    part = _create_part()
    body_id_a = _make_box(part["id"], x0=0.0)
    body_id_b = _make_box(part["id"], x0=10.0)
    body_id_c = _make_box(part["id"], x0=20.0)

    response = _create_merge(part["id"], [body_id_c, body_id_a, body_id_b])

    assert response.status_code == 201
    assert _body_ids(part["id"]) == [body_id_a]


# --- native_format round-trip -------------------------------------------------


def test_merge_feature_round_trips_through_native_export_import():
    """Mirrors test_surface.py's own identical native round-trip precedent -
    see that test's own docstring for the full save/restore-around-the-
    whole-test reasoning."""
    from app.document.store import get_document, replace_document
    from app.sketch.store import all_sketches, replace_all_sketches

    saved_document = get_document()
    saved_sketches = dict(all_sketches())
    try:
        part = _create_part()
        body_id_a = _make_box(part["id"], x0=0.0)
        body_id_b = _make_box(part["id"], x0=10.0)
        merge = _create_merge(part["id"], [body_id_a, body_id_b]).json()

        exported = client.get("/document/export/native")
        assert exported.status_code == 200

        imported = client.post("/document/import/native", json=exported.json())
        assert imported.status_code == 200

        features = client.get(f"/document/parts/{part['id']}/features").json()
        round_tripped = next(f for f in features if f["type"] == "merge")
        assert round_tripped["body_ids"] == merge["body_ids"] == [body_id_a, body_id_b]
    finally:
        replace_document(saved_document)
        replace_all_sketches(saved_sketches)


# --- Cascade delete ------------------------------------------------------------


def test_deleting_one_merged_bodys_owning_extrude_cascade_deletes_the_merge_feature():
    part = _create_part()
    body_id_a = _make_box(part["id"], x0=0.0)
    body_id_b = _make_box(part["id"], x0=10.0)
    merge = _create_merge(part["id"], [body_id_a, body_id_b]).json()

    response = client.delete(f"/document/parts/{part['id']}/features/{body_id_b}/cascade")

    assert response.status_code == 200
    assert set(response.json()["deleted_feature_ids"]) == {body_id_b, merge["id"]}
    remaining = _remaining_feature_ids(part["id"])
    assert merge["id"] not in remaining
    assert body_id_b not in remaining
    assert body_id_a in remaining
